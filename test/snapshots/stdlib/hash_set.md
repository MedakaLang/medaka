# META
source_lines=279
stages=DESUGAR,MARK
# SOURCE
{- | A mutable set of distinct elements, keyed by hash.

   `HashSet a` gives `O(1)` average membership, insertion, and deletion.
   The writing operations, `insertInPlace` and `deleteInPlace`, change the
   set in place and return `Unit`; every other operation reads it. Iteration
   order is unspecified. Use `set` instead when you want an immutable value
   or ordered elements.

   Elements need `Eq` and `Hashable`, and the two must agree: equal elements
   must hash equally. `deriving (Hashable)` gives an element type an
   instance that agrees with its derived `Eq`. The `Foldable` instance
   makes `toList`, `elem`, `length`, and `any` work on a set. -}

-- Separate chaining (each bucket a `List a`) in a `Ref`-held array plus a
-- `Ref Int` count, mirroring `hash_map.mdk`.  Standalone rather than a wrapper
-- over `HashMap a Unit`, for the same reasons set.mdk is not `Map a Unit`
-- (self-contained, no qualified-import gymnastics, no `Unit` payload).  A
-- hash may be NEGATIVE (the fold wraps); `slotOf` masks the sign off before
-- indexing.

-- hash_set/hash_map share identical resize/rehash bodies over DISTINCT ADTs; consolidation needs a shared-core refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{Eq, Ord, Debug, Display, Foldable, Hashable}
import list as L

{- | The hash set type. Its fields are the bucket array and the element
   count, both mutable. -}
public export data HashSet a = HashSet (Ref (Array (List a))) (Ref Int)

initialCapacity : Int
initialCapacity = 8

{- Bucket index of an element at a given capacity (cap > 0). The `Hashable`
   contract requires only eq-agreement, NOT a non-negative hash, so a
   contract-compliant user impl may hand us any `Int` — and `%` on a negative
   dividend is negative, which would index the bucket array out of bounds.
   Clearing the sign bit maps every `Int`, `intMinBound` included, into
   `[0, intMaxBound]` before the `%`. -}
slotOf : Hashable a => a -> Int -> Int
slotOf x cap = bitAnd (hash x) intMaxBound % cap

-- # Construction

{- | A new, empty set.

   Each call allocates its own set, which is why it takes `Unit`.

   > size (new () : HashSet Int)
   0 -}
export
new : Unit -> HashSet a
new _ = HashSet (Ref (arrayMake initialCapacity [])) (Ref 0)

{- | A set holding the elements of a list, without duplicates.

   > size (fromList [1, 2, 3, 2, 1])
   3 -}
export
fromList : (Eq a, Hashable a) => List a -> HashSet a
fromList xs =
  let s = new ()
  insertAll xs s
  s

-- > size (fromList [1, 2, 3, 4, 5, 6, 7, 8, 8, 1])
-- 8

insertAll : (Eq a, Hashable a) => List a -> HashSet a -> Unit
insertAll [] _ = ()
insertAll (x::rest) s =
  insertInPlace x s
  insertAll rest s

-- # Query

{- | The number of elements, in `O(1)`.

   > size (fromList [1, 2, 3])
   3 -}
export
size : HashSet a -> Int
size (HashSet _ count) = !count

bucketHas : Eq a => a -> List a -> Bool
bucketHas _ [] = False
bucketHas x (y::rest)
  | x == y = True
  | otherwise = bucketHas x rest

{- | Whether `x` is a member.

   > has 2 (fromList [1, 2, 3])
   True
   > has 9 (fromList [1, 2, 3])
   False -}
export
has : (Eq a, Hashable a) => a -> HashSet a -> Bool
has x (HashSet buckets _) =
  let arr = !buckets
  bucketHas x (arrayGetUnsafe (slotOf x (arrayLength arr)) arr)

-- # Insertion and deletion

bucketRemove : Eq a => a -> List a -> List a
bucketRemove _ [] = []
bucketRemove x (y::rest)
  | x == y = rest
  | otherwise = y :: bucketRemove x rest

{- | Adds `x` to the set, in place.

   Nothing happens when `x` is already a member. The set grows as needed. -}
export
insertInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
insertInPlace x (HashSet buckets count) =
  let arr = !buckets
  let idx = slotOf x (arrayLength arr)
  insertAt x arr idx buckets count

insertAt : (Eq a, Hashable a) => a -> Array (List a) -> Int -> Ref (Array (List a)) -> Ref Int -> Unit
insertAt x arr idx buckets count
  | bucketHas x (arrayGetUnsafe idx arr) = ()
  | otherwise =
    arraySetUnsafe idx (x :: arrayGetUnsafe idx arr) arr
    count := !count + 1
    maybeResize buckets count

-- Doubles the bucket array when the load factor passes 0.75.
maybeResize : Hashable a => Ref (Array (List a)) -> Ref Int -> Unit
maybeResize buckets count
  | !count * 4 > arrayLength !buckets * 3 = resize buckets count
  | otherwise = ()

resize : Hashable a => Ref (Array (List a)) -> Ref Int -> Unit
resize buckets count =
  let oldArr = !buckets
  let newArr = arrayMake (arrayLength oldArr * 2) []
  buckets := newArr
  count := 0
  reinsertAll oldArr 0 (arrayLength oldArr) buckets count

reinsertAll : Hashable a => Array (List a) -> Int -> Int -> Ref (Array (List a)) -> Ref Int -> Unit
reinsertAll oldArr i n buckets count
  | i >= n = ()
  | otherwise =
    reinsertBucket (arrayGetUnsafe i oldArr) buckets count
    reinsertAll oldArr (i + 1) n buckets count

reinsertBucket : Hashable a => List a -> Ref (Array (List a)) -> Ref Int -> Unit
reinsertBucket [] _ _ = ()
reinsertBucket (x::rest) buckets count =
  putRaw x buckets count
  reinsertBucket rest buckets count

putRaw : Hashable a => a -> Ref (Array (List a)) -> Ref Int -> Unit
putRaw x buckets count =
  let arr = !buckets
  let idx = slotOf x (arrayLength arr)
  arraySetUnsafe idx (x :: arrayGetUnsafe idx arr) arr
  count := !count + 1

{- | Removes `x` from the set, in place.

   Nothing happens when `x` is not a member. -}
export
deleteInPlace : (Eq a, Hashable a) => a -> HashSet a -> Unit
deleteInPlace x (HashSet buckets count) =
  let arr = !buckets
  let idx = slotOf x (arrayLength arr)
  deleteAt x arr idx count

deleteAt : (Eq a, Hashable a) => a -> Array (List a) -> Int -> Ref Int -> Unit
deleteAt x arr idx count =
  if bucketHas x (arrayGetUnsafe idx arr) then
    arraySetUnsafe idx (bucketRemove x (arrayGetUnsafe idx arr)) arr
    count := !count - 1

-- ── Iteration / folds ───────────────────────────────────────────────────

collectElems : Array (List a) -> Int -> Int -> List a -> List a
collectElems arr i n acc
  | i >= n = acc
  | otherwise = collectElems arr (i + 1) n (arrayGetUnsafe i arr ++ acc)

elemList : HashSet a -> List a
elemList (HashSet buckets _) = collectElems !buckets 0 (arrayLength !buckets) []

foldrElems : (a -> b -> <e> b) -> b -> List a -> <e> b
foldrElems _ z [] = z
foldrElems f z (x::rest) = f x (foldrElems f z rest)

foldlElems : (b -> a -> <e> b) -> b -> List a -> <e> b
foldlElems _ z [] = z
foldlElems f z (x::rest) = foldlElems f (f z x) rest

-- ── Instances ───────────────────────────────────────────────────────────

{- | The `Foldable` methods visit the elements in unspecified order, so
   `toList`, `length`, `elem`, `any`, and `sum` work on a set.

   > length (fromList [3, 1, 2, 1])
   3 -}
export impl Foldable HashSet where
  fold f z s = foldlElems f z (elemList s)
  foldRight f z s = foldrElems f z (elemList s)
  toList s = elemList s
  isEmpty s = size s == 0
  length s = size s

-- > toList (fromList [1, 1, 2]) /= []
-- True

allIn : (Eq a, Hashable a) => List a -> HashSet a -> Bool
allIn [] _ = True
allIn (x::rest) s
  | has x s = allIn rest s
  | otherwise = False

{- | Two sets are equal when they hold the same elements, whatever their
   internal layout.

   > eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
   True -}
export impl Eq (HashSet a) requires Eq a, Hashable a where
  eq a b = if size a /= size b then False else allIn (elemList a) b

{- | `debug` renders a set as `fromList [x, ...]` in internal order, so the
   text depends on the set's layout. Compare sets with `eq`, not by their
   rendering. -}
export impl Debug (HashSet a) requires Debug a where
  debug s = "fromList \{debug (elemList s)}"

-- `Debug` above renders in hash order, which is layout-dependent by design.
-- `Display` may not be: a rendering that changes when the set is rebuilt from
-- its own elements is not a rendering of the value.  So `Display` sorts, which
-- is why it asks for `Ord a` that `Debug` does not, and the law it buys is
-- `display s == display (fromList (toList s))`.  The sort is `list.sort`: one
-- ordering routine for the whole stdlib.

displayItems : Display a => List a -> String
displayItems [] = ""
displayItems [x] = "\{x}"
displayItems (y::rest) = "\{y}, \{displayItems rest}"

{- | `display` renders a set as `HashSet { x, ... }` with the elements in
   ascending order, so the text depends only on the elements.

   > display (fromList [3, 1, 2])
   "HashSet { 1, 2, 3 }"
   > display (new () : HashSet Int)
   "HashSet {}" -}
export impl Display (HashSet a) requires Display a, Ord a where
  display s = match L.sort (elemList s)
    [] => "HashSet {}"
    xs => "HashSet { \{displayItems xs} }"

-- ── Property tests ──────────────────────────────────────────────────────

ascendingL : Ord a => List a -> Bool
ascendingL [] = True
ascendingL (_::[]) = True
ascendingL (x::y::rest) = lte x y && ascendingL (y::rest)

-- LAW: `Display` must depend on the VALUE, not on the set's internal layout.
-- Rebuilding from its own elements, and from those elements reversed (which
-- fills the chains in a different order), must not change the rendering --
-- the law `Debug`, documented as hash-ordered, cannot satisfy.
prop "Display HashSet is layout-independent" (xs : List Int) =
  let s = fromList xs
  display s == display (fromList (toList s))
    && display s == display (fromList (L.reverse (toList s)))

-- LAW: the fixed order is ASCENDING, and `Display` agrees with `Eq` -- two
-- sets that compare equal render identically.
prop "Display HashSet agrees with Eq and lists elements ascending" (xs : List Int) =
  let a = fromList xs
  let b = fromList (L.reverse xs)
  ascendingL (L.sort (elemList a)) && eq a b == (display a == display b)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Hashable" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "HashSet" ("a") ((variant "HashSet" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "x") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EVar "hash") (EVar "x"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "HashSet") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashSet") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "HashSet") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "xs")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EVar "insertInPlace") (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "rest")) (EVar "s")))))
(DTypeSig true "size" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashSet" PWild (PVar "count"))) (EUnOp "!" (EVar "count")))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketHas") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "HashSet" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoExpr (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "bucketRemove") (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insertInPlace" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertInPlace" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "insertAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EUnOp "!" (EVar "count")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "maybeResize") (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EUnOp "!" (EVar "count")) (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 3)))) (EApp (EApp (EVar "resize") (EVar "buckets")) (EVar "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PVar "x") (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "putRaw") (EVar "x")) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "putRaw" ((PVar "x") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EUnOp "!" (EVar "count")) (ELit (LInt 1)))))))
(DTypeSig true "deleteInPlace" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "deleteInPlace" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deleteAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EVar "bucketRemove") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EUnOp "!" (EVar "count")) (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectElems" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "collectElems" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectElems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elemList" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elemList" ((PCon "HashSet" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectElems") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets")))) (EListLit)))
(DTypeSig false "foldrElems" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldrElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EVar "rest"))))
(DTypeSig false "foldlElems" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldlElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "rest")))
(DImpl true "Foldable" ((TyCon "HashSet")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "toList" ((PVar "s")) (EApp (EVar "elemList") (EVar "s"))) (im "isEmpty" ((PVar "s")) (EBinOp "==" (EApp (EVar "size") (EVar "s")) (ELit (LInt 0)))) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DTypeSig false "allIn" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "allIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allIn" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "s")) (EApp (EApp (EVar "allIn") (EVar "rest")) (EVar "s")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Eq" ((TyVar "a"))) (req "Hashable" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "allIn") (EApp (EVar "elemList") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "elemList") (EVar "s"))))) (ELit (LString ""))))))
(DTypeSig false "displayItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displayItems" ((PList)) (ELit (LString "")))
(DFunDef false "displayItems" ((PList (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))))
(DFunDef false "displayItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "displayItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Display" ((TyVar "a"))) (req "Ord" ((TyVar "a")))) ((im "display" ((PVar "s")) (EMatch (EApp (EVar "L.sort") (EApp (EVar "elemList") (EVar "s"))) (arm (PList) () (ELit (LString "HashSet {}"))) (arm (PVar "xs") () (EBinOp "++" (EBinOp "++" (ELit (LString "HashSet { ")) (EApp (EVar "display") (EApp (EVar "displayItems") (EVar "xs")))) (ELit (LString " }"))))))))
(DTypeSig false "ascendingL" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascendingL" ((PList)) (EVar "True"))
(DFunDef false "ascendingL" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "ascendingL" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lte") (EVar "x")) (EVar "y")) (EApp (EVar "ascendingL") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "Display HashSet is layout-independent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "display") (EVar "s")) (EApp (EVar "display") (EApp (EVar "fromList") (EApp (EVar "toList") (EVar "s"))))) (EBinOp "==" (EApp (EVar "display") (EVar "s")) (EApp (EVar "display") (EApp (EVar "fromList") (EApp (EVar "L.reverse") (EApp (EVar "toList") (EVar "s"))))))))))
(DProp false "Display HashSet agrees with Eq and lists elements ascending" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EApp (EVar "L.reverse") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "ascendingL") (EApp (EVar "L.sort") (EApp (EVar "elemList") (EVar "a")))) (EBinOp "==" (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b")) (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "b"))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Hashable" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "HashSet" ("a") ((variant "HashSet" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "x") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EMethodRef "hash") (EVar "x"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "HashSet") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashSet") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "HashSet") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "xs")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EDictApp "insertInPlace") (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "rest")) (EVar "s")))))
(DTypeSig true "size" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashSet" PWild (PVar "count"))) (EUnOp "!" (EDictApp "count")))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "HashSet" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoExpr (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EDictApp "bucketRemove") (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insertInPlace" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertInPlace" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "insertAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "insertAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EDictApp "maybeResize") (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EUnOp "!" (EDictApp "count")) (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 3)))) (EApp (EApp (EDictApp "resize") (EVar "buckets")) (EDictApp "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PVar "x") (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "putRaw") (EVar "x")) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "putRaw" ((PVar "x") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1)))))))
(DTypeSig true "deleteInPlace" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "deleteInPlace" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "buckets"))) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EDictApp "deleteAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EDictApp "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EDictApp "bucketRemove") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EUnOp "!" (EDictApp "count")) (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectElems" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "collectElems" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectElems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elemList" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elemList" ((PCon "HashSet" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectElems") (EUnOp "!" (EVar "buckets"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "buckets")))) (EListLit)))
(DTypeSig false "foldrElems" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldrElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EVar "rest"))))
(DTypeSig false "foldlElems" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldlElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "rest")))
(DImpl true "Foldable" ((TyCon "HashSet")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "toList" ((PVar "s")) (EApp (EVar "elemList") (EVar "s"))) (im "isEmpty" ((PVar "s")) (EBinOp "==" (EApp (EVar "size") (EVar "s")) (ELit (LInt 0)))) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DTypeSig false "allIn" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "allIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allIn" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EIf (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "s")) (EApp (EApp (EDictApp "allIn") (EVar "rest")) (EVar "s")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Eq" ((TyVar "a"))) (req "Hashable" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EDictApp "allIn") (EApp (EVar "elemList") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "elemList") (EVar "s"))))) (ELit (LString ""))))))
(DTypeSig false "displayItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displayItems" ((PList)) (ELit (LString "")))
(DFunDef false "displayItems" ((PList (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))))
(DFunDef false "displayItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "displayItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Display" ((TyVar "a"))) (req "Ord" ((TyVar "a")))) ((im "display" ((PVar "s")) (EMatch (EApp (EVar "L.sort") (EApp (EVar "elemList") (EVar "s"))) (arm (PList) () (ELit (LString "HashSet {}"))) (arm (PVar "xs") () (EBinOp "++" (EBinOp "++" (ELit (LString "HashSet { ")) (EApp (EMethodRef "display") (EApp (EDictApp "displayItems") (EVar "xs")))) (ELit (LString " }"))))))))
(DTypeSig false "ascendingL" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascendingL" ((PList)) (EVar "True"))
(DFunDef false "ascendingL" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "ascendingL" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lte") (EVar "x")) (EVar "y")) (EApp (EDictApp "ascendingL") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "Display HashSet is layout-independent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "display") (EVar "s")) (EApp (EMethodRef "display") (EApp (EDictApp "fromList") (EApp (EMethodRef "toList") (EVar "s"))))) (EBinOp "==" (EApp (EMethodRef "display") (EVar "s")) (EApp (EMethodRef "display") (EApp (EDictApp "fromList") (EApp (EVar "L.reverse") (EApp (EMethodRef "toList") (EVar "s"))))))))))
(DProp false "Display HashSet agrees with Eq and lists elements ascending" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EApp (EVar "L.reverse") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EDictApp "ascendingL") (EApp (EVar "L.sort") (EApp (EVar "elemList") (EVar "a")))) (EBinOp "==" (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b")) (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "b"))))))))
