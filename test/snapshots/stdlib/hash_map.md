# META
source_lines=379
stages=DESUGAR,MARK
# SOURCE
{- | A mutable hash table from keys to values.

   `HashMap k v` gives `O(1)` average lookup, insertion, and deletion. The
   writing operations, `setInPlace` and `deleteInPlace`, change the table in
   place and return `Unit`; every other operation reads it. Iteration order
   is unspecified. Use `map` instead when you want an immutable value or
   ordered keys.

   Keys need `Eq` and `Hashable`, and the two must agree: equal keys must
   hash equally. `deriving (Hashable)` gives a key type an instance that
   agrees with its derived `Eq`. -}

-- Separate chaining: each bucket is a `List (k, v)` in an `Array` held by a
-- `Ref` so it can be swapped on resize, plus a `Ref Int` count.  Mutation is
-- untracked (no effect in the signature).  A hash may be NEGATIVE (the fold
-- wraps); `slotOf` masks the sign off before indexing.
--
-- The mutating ops sequence mutation statements in block bodies.  A
-- conditional mutation whose body is a multi-statement block (`deleteAt`)
-- uses an else-less `if` (both the block branch and the missing `else`
-- survive `medaka fmt`), dropping the noisy `| otherwise = ()`.  The rest stay
-- as guards: `maybeResize` (the fmt'd else-less form would be one over-long
-- line, since its single-application body can't soft-break) and the recursion
-- base-cases (`reinsertAll`, `collectBuckets`), where `| i >= n` reads best.

-- hash_map/hash_set share identical resize/rehash bodies over DISTINCT ADTs; consolidation needs a shared-core refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{Eq, Ord, Debug, Display, Option, Mappable, Hashable, Index}
import list as L

{- | The hash table type. Its fields are the bucket array and the entry
   count, both mutable. -}
public export data HashMap k v = HashMap (Ref (Array (List (k, v)))) (Ref Int)

initialCapacity : Int
initialCapacity = 8

{- Bucket index of a key at a given capacity (cap > 0). The `Hashable` contract
   requires only eq-agreement, NOT a non-negative hash, so a contract-compliant
   user impl may hand us any `Int` — and `%` on a negative dividend is negative,
   which would index the bucket array out of bounds. Clearing the sign bit maps
   every `Int`, `intMinBound` included, into `[0, intMaxBound]` before the `%`. -}
slotOf : Hashable k => k -> Int -> Int
slotOf key cap = bitAnd (hash key) intMaxBound % cap

-- # Construction

{- | A new, empty table.

   Each call allocates its own table, which is why it takes `Unit`.

   > size (new () : HashMap Int Int)
   0 -}
export
new : Unit -> HashMap k v
new _ = HashMap (Ref (arrayMake initialCapacity [])) (Ref 0)

{- | A table holding the pairs of an association list.

   When a key appears more than once, the later pair wins.

   > size (fromList [(1, 10), (2, 20), (1, 30)])
   2 -}
export
fromList : (Eq k, Hashable k) => List (k, v) -> HashMap k v
fromList pairs =
  let m = new ()
  insertAll pairs m
  m

-- > size (fromList [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8)])
-- 8

insertAll : (Eq k, Hashable k) => List (k, v) -> HashMap k v -> Unit
insertAll [] _ = ()
insertAll ((k, v) :: rest) m =
  setInPlace k v m
  insertAll rest m

-- # Query

{- | The number of entries, in `O(1)`.

   > size (fromList [(1, 10), (2, 20)])
   2 -}
export
size : HashMap k v -> Int
size (HashMap _ count) = !count

{- | Whether the table has no entries.

   > isEmpty (new () : HashMap Int Int)
   True -}
export
isEmpty : HashMap k v -> Bool
isEmpty m = size m == 0

bucketLookup : Eq k => k -> List (k, v) -> Option v
bucketLookup _ [] = None
bucketLookup key ((k, v) :: rest)
  | key == k = Some v
  | otherwise = bucketLookup key rest

{- | The value at `key`, or `None` when the key is absent.

   > get 2 (fromList [(1, 10), (2, 20)])
   Some 20
   > get 9 (fromList [(1, 10), (2, 20)])
   None -}
export
get : (Eq k, Hashable k) => k -> HashMap k v -> Option v
get key (HashMap buckets _) =
  let arr = !buckets
  bucketLookup key (arrayGetUnsafe (slotOf key (arrayLength arr)) arr)

{- | Whether `key` is present.

   > has 2 (fromList [(1, 10), (2, 20)])
   True -}
export
has : (Eq k, Hashable k) => k -> HashMap k v -> Bool
has key m = isSome (get key m)

{- | The value at `key`, or `d` when the key is absent.

   > findWithDefault 0 9 (fromList [(1, 10)])
   0 -}
export
findWithDefault : (Eq k, Hashable k) => v -> k -> HashMap k v -> v
findWithDefault d key m = optionOr d (get key m)

-- ── Bucket helpers (for insert/delete) ──────────────────────────────────

bucketHas : Eq k => k -> List (k, v) -> Bool
bucketHas _ [] = False
bucketHas key ((k, _) :: rest)
  | key == k = True
  | otherwise = bucketHas key rest

bucketReplace : Eq k => k -> v -> List (k, v) -> List (k, v)
bucketReplace _ _ [] = []
bucketReplace key val ((k, v) :: rest)
  | key == k = (key, val) :: rest
  | otherwise = (k, v) :: bucketReplace key val rest

bucketRemove : Eq k => k -> List (k, v) -> List (k, v)
bucketRemove _ [] = []
bucketRemove key ((k, v) :: rest)
  | key == k = rest
  | otherwise = (k, v) :: bucketRemove key rest

-- # Insertion

{- | Stores `val` at `key`, replacing any existing value.

   The table is changed in place and grows as needed. -}
export
setInPlace : (Eq k, Hashable k) => k -> v -> HashMap k v -> Unit
setInPlace key val (HashMap buckets count) =
  let arr = !buckets
  let idx = slotOf key (arrayLength arr)
  insertAt key val arr idx buckets count

insertAt : (Eq k, Hashable k) =>
  k ->
  v ->
  Array (List (k, v)) ->
  Int ->
  Ref (Array (List (k, v))) ->
  Ref Int ->
  Unit
insertAt key val arr idx buckets count
  | bucketHas key (arrayGetUnsafe idx arr) =
    arraySetUnsafe idx (bucketReplace key val (arrayGetUnsafe idx arr)) arr
  | otherwise =
    arraySetUnsafe idx ((key, val) :: arrayGetUnsafe idx arr) arr
    count := !count + 1
    maybeResize buckets count

-- Doubles the bucket array when the load factor passes 0.75.
maybeResize : (Eq k, Hashable k) => Ref (Array (List (k, v))) -> Ref Int -> Unit
maybeResize buckets count
  | !count * 4 > arrayLength !buckets * 3 = resize buckets count
  | otherwise = ()

resize : (Eq k, Hashable k) => Ref (Array (List (k, v))) -> Ref Int -> Unit
resize buckets count =
  let oldArr = !buckets
  let newArr = arrayMake (arrayLength oldArr * 2) []
  buckets := newArr
  count := 0
  reinsertAll oldArr 0 (arrayLength oldArr) buckets count

reinsertAll : (Eq k, Hashable k) =>
  Array (List (k, v)) ->
  Int ->
  Int ->
  Ref (Array (List (k, v))) ->
  Ref Int ->
  Unit
reinsertAll oldArr i n buckets count
  | i >= n = ()
  | otherwise =
    reinsertBucket (arrayGetUnsafe i oldArr) buckets count
    reinsertAll oldArr (i + 1) n buckets count

reinsertBucket : (Eq k, Hashable k) =>
  List (k, v) ->
  Ref (Array (List (k, v))) ->
  Ref Int ->
  Unit
reinsertBucket [] _ _ = ()
reinsertBucket ((k, v) :: rest) buckets count =
  putRaw k v buckets count
  reinsertBucket rest buckets count

-- Insert into a freshly-resized table (key known absent, so just prepend).
putRaw : Hashable k => k -> v -> Ref (Array (List (k, v))) -> Ref Int -> Unit
putRaw key val buckets count =
  let arr = !buckets
  let idx = slotOf key (arrayLength arr)
  arraySetUnsafe idx ((key, val) :: arrayGetUnsafe idx arr) arr
  count := !count + 1

-- # Deletion

{- | Removes the entry at `key` from the table, in place.

   Nothing happens when the key is absent. -}
export
deleteInPlace : (Eq k, Hashable k) => k -> HashMap k v -> Unit
deleteInPlace key (HashMap buckets count) =
  let arr = !buckets
  let idx = slotOf key (arrayLength arr)
  deleteAt key arr idx count

deleteAt : (Eq k, Hashable k) =>
  k ->
  Array (List (k, v)) ->
  Int ->
  Ref Int ->
  Unit
deleteAt key arr idx count =
  if bucketHas key (arrayGetUnsafe idx arr) then
    arraySetUnsafe idx (bucketRemove key (arrayGetUnsafe idx arr)) arr
    count := !count - 1

-- # Iteration

collectBuckets : Array (List (k, v)) -> Int -> Int -> List (k, v) -> List (k, v)
collectBuckets arr i n acc
  | i >= n = acc
  | otherwise = collectBuckets arr (i + 1) n (arrayGetUnsafe i arr ++ acc)

-- Private collector behind the exported `toList`.  It is deliberately not
-- named `toList` itself: `toList` is a `Foldable` method (returning
-- elements), and `HashMap` isn't `Foldable`, so a file-local `toList` used
-- from the definitions below risks being read as the method and mistyped
-- (`List v` vs the pairs `List (k, v)`).
entries : HashMap k v -> List (k, v)
entries (HashMap buckets _) =
  collectBuckets !buckets 0 (arrayLength !buckets) []

{- | The entries as pairs, in unspecified order.

   > toList (fromList [(5, 50)])
   [(5, 50)] -}
export
toList : HashMap k v -> List (k, v)
toList m = entries m

{- | The keys, in unspecified order.

   > keys (fromList [(5, 50)])
   [5] -}
export
keys : HashMap k v -> List k
keys m = map fst (entries m)

{- | The values, in unspecified order.

   > values (fromList [(5, 50)])
   [50] -}
export
values : HashMap k v -> List v
values m = map snd (entries m)

-- ── Instances ───────────────────────────────────────────────────────────

allEntriesIn : (Eq k, Eq v, Hashable k) => List (k, v) -> HashMap k v -> Bool
allEntriesIn [] _ = True
allEntriesIn ((k, v) :: rest) m
  | get k m == Some v = allEntriesIn rest m
  | otherwise = False

{- | Two tables are equal when they hold the same entries, whatever their
   internal layout.

   > eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
   True -}
export impl Eq (HashMap k v) requires Eq k, Eq v, Hashable k where
  eq a b = if size a /= size b then False else allEntriesIn (entries a) b

{- | `debug` renders a table as `fromList [(k, v), ...]` in internal order,
   so the text depends on the table's layout. Compare tables with `eq`, not
   by their rendering. -}
export impl Debug (HashMap k v) requires Debug k, Debug v where
  debug m = "fromList \{debug (entries m)}"

-- `Debug` above renders in hash order, which is layout-dependent by design.
-- `Display` may not be: a rendering that changes when the table is rebuilt
-- with the same entries is not a rendering of the value.  So `Display` sorts
-- by key, which is why it asks for `Ord k` that `Debug` does not, and the law
-- it buys is `display m == display (fromList (toList m))`.  The sort is
-- `list.sortOn fst`: one ordering routine for the whole stdlib.

-- Comma-joined `k => v` entries, mirroring `map.mdk`'s `displayMapEntries`.
displayEntries : (Display k, Display v) => List (k, v) -> String
displayEntries [] = ""
displayEntries [(k, v)] = "\{k} => \{v}"
displayEntries ((k, v) :: rest) = "\{k} => \{v}, \{displayEntries rest}"

{- | `display` renders a table as `HashMap { k => v, ... }` with the entries
   in ascending key order, so the text depends only on the entries.

   > display (fromList [(2, 20), (1, 10)])
   "HashMap { 1 => 10, 2 => 20 }"
   > display (new () : HashMap Int Int)
   "HashMap {}" -}
export impl Display (HashMap k v) requires Display k, Display v, Ord k where
  display m = match L.sortOn fst (entries m)
    [] => "HashMap {}"
    es => "HashMap { \{displayEntries es} }"

{- | `m[k]` is the value at `k`.

   Panics with an index error when the key is absent; `get` is the
   `Option`-returning form.

   > (fromList [(1, 10), (2, 20)])[2]
   20 -}
export impl Index (HashMap k v) k v requires Eq k, Hashable k where
  index m k = match get k m
    Some v => v
    None => indexError "key not found"

-- ── Property tests ──────────────────────────────────────────────────────

-- LAW: `Display` must depend on the VALUE, not on the table's internal
-- layout.  Rebuilding a table from its own entries (and from those entries
-- reversed, which lands them in different buckets in a different order) must
-- not change the rendering.  This is the law the ordering choice exists for,
-- and it is what `Debug` -- documented as hash-ordered -- cannot satisfy.
prop "Display HashMap is layout-independent" (xs : List (Int, Int)) =
  let m = fromList xs
  display m == display (fromList (toList m))
    && display m == display (fromList (L.reverse (toList m)))

-- LAW: the fixed order is ASCENDING BY KEY, and `Display` agrees with `Eq` --
-- two tables that compare equal render identically.
prop "Display HashMap agrees with Eq and lists keys ascending" (xs : List (Int, Int)) =
  let a = fromList xs
  let b = fromList (L.reverse xs)
  ascendingKeys (L.sortOn fst (entries a)) && eq a b == (display a == display b)

ascendingKeys : Ord k => List (k, v) -> Bool
ascendingKeys [] = True
ascendingKeys (_ :: []) = True
ascendingKeys ((k1, _) :: (k2, v2) :: rest) =
  lte k1 k2 && ascendingKeys ((k2, v2) :: rest)

-- LAW: `Index` is `get` with the `None` case turned into the coded index
-- error -- i.e. for every key the table HAS, `m[k]` is exactly `get k m`'s
-- payload.  (The absent-key panic is exercised by the `Index (Map k v)`
-- convention this mirrors; a prop cannot catch a panic.)
prop "Index HashMap agrees with get on present keys" (xs : List (Int, Int)) =
  let m = fromList xs
  all (k => eq (Some m[k]) (get k m)) (keys m)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Mappable" false) (mem "Hashable" false) (mem "Index" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "HashMap" ("k" "v") ((variant "HashMap" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "key") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EVar "hash") (EVar "key"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashMap") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "pairs")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "k")) (EVar "v")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "rest")) (EVar "m")))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashMap" PWild (PVar "count"))) (EUnOp "!" (EVar "count")))
(DTypeSig true "isEmpty" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty" ((PVar "m")) (EBinOp "==" (EApp (EVar "size") (EVar "m")) (ELit (LInt 0))))
(DTypeSig false "bucketLookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "bucketLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "bucketLookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketLookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "get" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "key") (PCon "HashMap" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoExpr (EApp (EApp (EVar "bucketLookup") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "key") (PVar "m")) (EApp (EVar "isSome") (EApp (EApp (EVar "get") (EVar "key")) (EVar "m"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "key") (PVar "m")) (EApp (EApp (EVar "optionOr") (EVar "d")) (EApp (EApp (EVar "get") (EVar "key")) (EVar "m"))))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "key") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketHas") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketReplace" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "bucketReplace" (PWild PWild (PList)) (EListLit))
(DFunDef false "bucketReplace" ((PVar "key") (PVar "val") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "bucketReplace") (EVar "key")) (EVar "val")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "bucketRemove") (EVar "key")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "setInPlace" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit"))))))
(DFunDef false "setInPlace" ((PVar "key") (PVar "val") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "insertAt") (EVar "key")) (EVar "val")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "insertAt" ((PVar "key") (PVar "val") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EApp (EVar "bucketReplace") (EVar "key")) (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EUnOp "!" (EVar "count")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "maybeResize") (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EUnOp "!" (EVar "count")) (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 3)))) (EApp (EApp (EVar "resize") (EVar "buckets")) (EVar "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "putRaw") (EVar "k")) (EVar "v")) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "putRaw" ((PVar "key") (PVar "val") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EUnOp "!" (EVar "count")) (ELit (LInt 1)))))))
(DTypeSig true "deleteInPlace" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "deleteInPlace" ((PVar "key") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deleteAt") (EVar "key")) (EVar "arr")) (EVar "idx")) (EVar "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "key") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EVar "bucketRemove") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EUnOp "!" (EVar "count")) (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectBuckets" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "collectBuckets" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PCon "HashMap" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets")))) (EListLit)))
(DTypeSig true "toList" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList" ((PVar "m")) (EApp (EVar "entries") (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig false "allEntriesIn" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "allEntriesIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allEntriesIn" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (EApp (EVar "Some") (EVar "v"))) (EApp (EApp (EVar "allEntriesIn") (EVar "rest")) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v"))) (req "Hashable" ((TyVar "k")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "allEntriesIn") (EApp (EVar "entries") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayEntries" ((PList)) (ELit (LString "")))
(DFunDef false "displayEntries" ((PList (PTuple (PVar "k") (PVar "v")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))
(DFunDef false "displayEntries" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "displayEntries") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v"))) (req "Ord" ((TyVar "k")))) ((im "display" ((PVar "m")) (EMatch (EApp (EApp (EVar "L.sortOn") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))) (arm (PList) () (ELit (LString "HashMap {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "HashMap { ")) (EApp (EVar "display") (EApp (EVar "displayEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Eq" ((TyVar "k"))) (req "Hashable" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (ELit (LString "key not found"))))))))
(DProp false "Display HashMap is layout-independent" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "display") (EVar "m")) (EApp (EVar "display") (EApp (EVar "fromList") (EApp (EVar "toList") (EVar "m"))))) (EBinOp "==" (EApp (EVar "display") (EVar "m")) (EApp (EVar "display") (EApp (EVar "fromList") (EApp (EVar "L.reverse") (EApp (EVar "toList") (EVar "m"))))))))))
(DProp false "Display HashMap agrees with Eq and lists keys ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EApp (EVar "L.reverse") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "ascendingKeys") (EApp (EApp (EVar "L.sortOn") (EVar "fst")) (EApp (EVar "entries") (EVar "a")))) (EBinOp "==" (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b")) (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "b"))))))))
(DTypeSig false "ascendingKeys" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool"))))
(DFunDef false "ascendingKeys" ((PList)) (EVar "True"))
(DFunDef false "ascendingKeys" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "ascendingKeys" ((PCons (PTuple (PVar "k1") PWild) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lte") (EVar "k1")) (EVar "k2")) (EApp (EVar "ascendingKeys") (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EVar "rest")))))
(DProp false "Index HashMap agrees with get on present keys" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "all") (ELam ((PVar "k")) (EApp (EApp (EVar "eq") (EApp (EVar "Some") (EApp (EApp (EVar "index") (EVar "m")) (EVar "k")))) (EApp (EApp (EVar "get") (EVar "k")) (EVar "m"))))) (EApp (EVar "keys") (EVar "m"))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Mappable" false) (mem "Hashable" false) (mem "Index" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "HashMap" ("k" "v") ((variant "HashMap" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "key") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EMethodRef "hash") (EVar "key"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashMap") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "pairs")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "setInPlace") (EVar "k")) (EVar "v")) (EVar "m"))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "rest")) (EVar "m")))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashMap" PWild (PVar "count"))) (EUnOp "!" (EDictApp "count")))
(DTypeSig true "isEmpty#shadow" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty#shadow" ((PVar "m")) (EBinOp "==" (EApp (EVar "size") (EVar "m")) (ELit (LInt 0))))
(DTypeSig false "bucketLookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "bucketLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "bucketLookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketLookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "get" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "key") (PCon "HashMap" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoExpr (EApp (EApp (EDictApp "bucketLookup") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "key") (PVar "m")) (EApp (EVar "isSome") (EApp (EApp (EDictApp "get") (EVar "key")) (EVar "m"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "key") (PVar "m")) (EApp (EApp (EVar "optionOr") (EVar "d")) (EApp (EApp (EDictApp "get") (EVar "key")) (EVar "m"))))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "key") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketReplace" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "bucketReplace" (PWild PWild (PList)) (EListLit))
(DFunDef false "bucketReplace" ((PVar "key") (PVar "val") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EDictApp "bucketReplace") (EVar "key")) (EVar "val")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EDictApp "bucketRemove") (EVar "key")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "setInPlace" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit"))))))
(DFunDef false "setInPlace" ((PVar "key") (PVar "val") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "insertAt") (EVar "key")) (EVar "val")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "insertAt" ((PVar "key") (PVar "val") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EApp (EDictApp "bucketReplace") (EVar "key")) (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EDictApp "maybeResize") (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EUnOp "!" (EDictApp "count")) (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 3)))) (EApp (EApp (EDictApp "resize") (EVar "buckets")) (EDictApp "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EDictApp "putRaw") (EVar "k")) (EVar "v")) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "putRaw" ((PVar "key") (PVar "val") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1)))))))
(DTypeSig true "deleteInPlace" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "deleteInPlace" ((PVar "key") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EDictApp "deleteAt") (EVar "key")) (EVar "arr")) (EVar "idx")) (EDictApp "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "key") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EDictApp "bucketRemove") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectBuckets" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "collectBuckets" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PCon "HashMap" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets")))) (EListLit)))
(DTypeSig true "toList#shadow" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList#shadow" ((PVar "m")) (EApp (EVar "entries") (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig false "allEntriesIn" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "allEntriesIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allEntriesIn" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (EApp (EVar "Some") (EVar "v"))) (EApp (EApp (EDictApp "allEntriesIn") (EVar "rest")) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v"))) (req "Hashable" ((TyVar "k")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EDictApp "allEntriesIn") (EApp (EVar "entries") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayEntries" ((PList)) (ELit (LString "")))
(DFunDef false "displayEntries" ((PList (PTuple (PVar "k") (PVar "v")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))
(DFunDef false "displayEntries" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "displayEntries") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v"))) (req "Ord" ((TyVar "k")))) ((im "display" ((PVar "m")) (EMatch (EApp (EApp (EVar "L.sortOn") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))) (arm (PList) () (ELit (LString "HashMap {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "HashMap { ")) (EApp (EMethodRef "display") (EApp (EDictApp "displayEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Eq" ((TyVar "k"))) (req "Hashable" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (ELit (LString "key not found"))))))))
(DProp false "Display HashMap is layout-independent" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "display") (EVar "m")) (EApp (EMethodRef "display") (EApp (EDictApp "fromList") (EApp (EVar "toList#shadow") (EVar "m"))))) (EBinOp "==" (EApp (EMethodRef "display") (EVar "m")) (EApp (EMethodRef "display") (EApp (EDictApp "fromList") (EApp (EVar "L.reverse") (EApp (EVar "toList#shadow") (EVar "m"))))))))))
(DProp false "Display HashMap agrees with Eq and lists keys ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EApp (EVar "L.reverse") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EDictApp "ascendingKeys") (EApp (EApp (EVar "L.sortOn") (EVar "fst")) (EApp (EVar "entries") (EVar "a")))) (EBinOp "==" (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b")) (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "b"))))))))
(DTypeSig false "ascendingKeys" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool"))))
(DFunDef false "ascendingKeys" ((PList)) (EVar "True"))
(DFunDef false "ascendingKeys" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "ascendingKeys" ((PCons (PTuple (PVar "k1") PWild) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lte") (EVar "k1")) (EVar "k2")) (EApp (EDictApp "ascendingKeys") (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EVar "rest")))))
(DProp false "Index HashMap agrees with get on present keys" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EDictApp "all") (ELam ((PVar "k")) (EApp (EApp (EMethodRef "eq") (EApp (EVar "Some") (EApp (EApp (EMethodRef "index") (EVar "m")) (EVar "k")))) (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m"))))) (EApp (EVar "keys") (EVar "m"))))))
