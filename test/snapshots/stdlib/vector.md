# META
source_lines=479
stages=DESUGAR,MARK
# SOURCE
{- | A growable, mutable array.

   `Vector a` holds its elements in an array with spare capacity, so `push`
   costs amortized `O(1)` and indexing is `O(1)`. The writing operations
   change the vector in place and return `Unit`. Use `array` when the length
   is known up front, and `Vector` when elements accumulate.

   `length` is the number of elements; `capacity` is the size of the backing
   store, which doubles when it fills. The `Foldable` instance makes
   `toList`, `sum`, `elem`, and `any` work on a vector. -}

-- Representation: `Vector backing len` where `!backing` is the backing array
-- (its `arrayLength` is the capacity) and `!len` is the number of live
-- elements (`0 <= len <= capacity`).  Both are `Ref`s, mutated in place.
-- Slots `[len, capacity)` are scratch, never read; they hold whatever value
-- last filled them (the most recent `push`'s element on a grow).  Iteration
-- and instances only ever touch the live range `[0, len)`.  `new` starts at
-- capacity 0 and allocates on first `push`, using the pushed element as the
-- fill, so no dummy value is needed to construct one.

import core.{
  Eq,
  Ord,
  Ordering,
  Debug,
  Display,
  Foldable,
  Option,
  Index,
  IndexMut,
}

-- The list versions of `insertAt`/`removeAt`/`sortBy` define the semantics
-- the in-place mutators transport onto the vector, so delegating is what
-- keeps the two in step.
import list as L

{- | The vector type. Its fields are the backing array and the element
   count, both mutable. -}
public export data Vector a = Vector (Ref (Array a)) (Ref Int)

-- Live element count (internal; the public name is `Foldable.length`).
count : Vector a -> Int
count (Vector _ len) = !len

-- # Construction

{- | A new, empty vector.

   Each call allocates its own vector, which is why it takes `Unit`. The
   backing store is allocated on the first `push`.

   > length (new () : Vector Int)
   0 -}
export
new : Unit -> Vector a
new _ = Vector (Ref [||]) (Ref 0)

{- | A vector holding the elements of a list, in order.

   The capacity equals the length, so the next `push` grows the store.

   > length (fromList [1, 2, 3])
   3 -}
export
fromList : List a -> Vector a
fromList xs =
  let arr = arrayFromList xs
  Vector (Ref arr) (Ref (arrayLength arr))

{- | A vector holding a copy of an array's elements.

   Later changes to the vector do not affect the array.

   > toList (fromArray [|1, 2|])
   [1, 2] -}
export
fromArray : Array a -> Vector a
fromArray arr =
  let c = arrayCopy arr
  Vector (Ref c) (Ref (arrayLength c))

-- # Reading

{- | The size of the backing store, which is at least `length`.

   > capacity (fromList [1, 2, 3])
   3 -}
export
capacity : Vector a -> Int
capacity (Vector backing _) = arrayLength !backing

{- | The element at index `i`, or `None` when `i` is out of range.

   > get 1 (fromList [10, 20, 30])
   Some 20
   > get 5 (fromList [10, 20, 30])
   None -}
export
get : Int -> Vector a -> Option a
get i (Vector backing len)
  | i >= 0 && i < !len = Some (arrayGetUnsafe i !backing)
  | otherwise = None

{- | `v[i]` is the element at index `i`, in `O(1)`.

   Panics with an index error when `i` is out of range; `get` is the
   `Option`-returning form. -}
export impl Index (Vector a) Int a where
  index (Vector backing len) i =
    if i >= 0 && i < !len then
      arrayGetUnsafe i !backing
    else
      indexErrorAt i

{- | The first element, or `None` when the vector is empty.

   > first (fromList [10, 20, 30])
   Some 10 -}
export
first : Vector a -> Option a
first ma = get 0 ma

{- | The last element, or `None` when the vector is empty.

   > last (fromList [10, 20, 30])
   Some 30 -}
export
last : Vector a -> Option a
last ma = get (count ma - 1) ma

-- # Conversion

elemsGo : Array a -> Int -> List a -> List a
elemsGo arr i acc
  | i < 0 = acc
  | otherwise = elemsGo arr (i - 1) (arrayGetUnsafe i arr :: acc)

-- The live elements as a list, in order (used by `Foldable.toList`).
elems : Vector a -> List a
elems (Vector backing len) = elemsGo !backing (!len - 1) []

{- | A new array holding the vector's elements.

   > arrayLength (toArray (fromList [1, 2, 3]))
   3 -}
export
toArray : Vector a -> Array a
toArray (Vector backing len) =
  let arr = !backing
  arrayMakeWith !len (i => arrayGetUnsafe i arr)

-- # Mutation

{- | Appends `x` to the end of the vector.

   Amortized `O(1)`: the backing store doubles when it is full.

   > let v = fromList [1, 2] in let _ = push 3 v in toList v
   [1, 2, 3] -}
export
push : a -> Vector a -> Unit
push x (Vector backing len)
  | !len < arrayLength !backing =
    arraySetUnsafe !len x !backing
    len := !len + 1
  | otherwise =
    let oldArr = !backing
    let oldLen = !len
    let newCap = if oldLen == 0 then 1 else oldLen * 2
    let newArr = arrayMake newCap x
    arrayBlit oldArr 0 newArr 0 oldLen
    backing := newArr
    len := oldLen + 1

{- | Removes and returns the last element, or `None` when the vector is
   empty.

   The capacity is kept.

   > pop (fromList [1, 2, 3])
   Some 3 -}
export
pop : Vector a -> Option a
pop (Vector backing len)
  | !len == 0 = None
  | otherwise =
    let i = !len - 1
    let x = arrayGetUnsafe i !backing
    len := i
    Some x

{- | Replaces the element at index `i` with `x`.

   Panics when `i` is out of range; `push` extends the vector.

   > let v = fromList [1, 2, 3] in let _ = setInPlace 1 9 v in toList v
   [1, 9, 3] -}
export
setInPlace : Int -> a -> Vector a -> Unit
setInPlace i x (Vector backing len)
  | i >= 0 && i < !len = arraySetUnsafe i x !backing
  | otherwise = panic "Vector.setInPlace: index out of bounds"

{- | `v[i] = x` replaces the element at index `i` in place, in `O(1)`.

   Panics with an index error when `i` is out of range. -}
export impl IndexMut (Vector a) Int a where
  setIndex (Vector backing len) i v =
    if i >= 0 && i < !len then
      let _ = arraySetUnsafe i v !backing
      Vector backing len
    else indexErrorAt i

{- | Exchanges the elements at indices `i` and `j`.

   Both indices must be in range.

   > let v = fromList [1, 2, 3] in let _ = swap 0 2 v in toList v
   [3, 2, 1] -}
export
swap : Int -> Int -> Vector a -> Unit
swap i j (Vector backing _) =
  let arr = !backing
  let xi = arrayGetUnsafe i arr
  let xj = arrayGetUnsafe j arr
  arraySetUnsafe i xj arr
  arraySetUnsafe j xi arr

{- | Removes every element.

   The capacity is kept.

   > let v = fromList [1, 2, 3] in let _ = clear v in length v
   0 -}
export
clear : Vector a -> Unit
clear (Vector _ len) = len := 0

mapInPlaceGo : (a -> a) -> Array a -> Int -> Int -> Unit
mapInPlaceGo f arr i n
  | i >= n = ()
  | otherwise =
    arraySetUnsafe i (f (arrayGetUnsafe i arr)) arr
    mapInPlaceGo f arr (i + 1) n

{- | Replaces every element with `f` applied to it.

   > let v = fromList [1, 2, 3] in let _ = mapInPlace (x => x * 10) v in toList v
   [10, 20, 30] -}
export
mapInPlace : (a -> a) -> Vector a -> Unit
mapInPlace f (Vector backing len) = mapInPlaceGo f !backing 0 !len

-- # Editing and sorting

-- All four mutate and return `Unit`, which is `vector`'s half of the mutation
-- contract (`map`/`set`/`list` return the container; `hash_map`/`hash_set`/
-- `array`/`vector` return `Unit`).  Index handling matches `list.insertAt`/
-- `list.removeAt` exactly: both clamp rather than panic.
--
-- `isEmpty` is deliberately not added here: `impl Foldable Vector` below
-- already defines it, so a module-level one would shadow the method.

-- Push every element of a list, in order.
pushAll : List a -> Vector a -> Unit
pushAll [] _ = ()
pushAll (x::xs) ma =
  push x ma
  pushAll xs ma

-- Replace the live range with `xs`, in place (same `Ref` cells, so every
-- alias of `ma` observes the edit).  Capacity grows via `push` as needed.
refill : Vector a -> List a -> Unit
refill ma xs =
  clear ma
  pushAll xs ma

{- | Inserts `x` at index `i`, shifting the following elements right.

   An index at or below `0` prepends; an index at or beyond the length
   appends.

   > let v = fromList [1, 2, 3] in let _ = insertAtInPlace 1 9 v in toList v
   [1, 9, 2, 3] -}
export
insertAtInPlace : Int -> a -> Vector a -> Unit
insertAtInPlace i x ma = refill ma (L.insertAt i x (elems ma))

-- > let v = fromList [1, 2] in let _ = insertAtInPlace 7 9 v in toList v
-- [1, 2, 9]

{- | Removes the element at index `i`.

   Nothing happens when `i` is out of range.

   > let v = fromList [1, 2, 3] in let _ = removeAtInPlace 1 v in toList v
   [1, 3] -}
export
removeAtInPlace : Int -> Vector a -> Unit
removeAtInPlace i ma = refill ma (L.removeAt i (elems ma))

-- > let v = fromList [1, 2] in let _ = removeAtInPlace 7 v in toList v
-- [1, 2]

{- | Sorts the elements in place by `cmp`.

   The sortInPlace is stable: elements that compare equal keep their original
   order.

   > let v = fromList [3, 1, 4, 1, 5] in let _ = sortInPlaceBy compare v in toList v
   [1, 1, 3, 4, 5] -}
export
sortInPlaceBy : (a -> a -> <e> Ordering) -> Vector a -> <e> Unit
sortInPlaceBy cmp ma = refill ma (L.sortBy cmp (elems ma))

{- | Sorts the elements in place in ascending order.

   The sortInPlace is stable.

   > let v = fromList [3, 1, 2] in let _ = sortInPlace v in toList v
   [1, 2, 3] -}
export
sortInPlace : Ord a => Vector a -> Unit
sortInPlace ma = sortInPlaceBy compare ma

-- ── Folds (index-based; never allocate a list) ──────────────────────────

foldGo : (b -> a -> <e> b) -> b -> Array a -> Int -> Int -> <e> b
foldGo f z arr i n
  | i >= n = z
  | otherwise = foldGo f (f z (arrayGetUnsafe i arr)) arr (i + 1) n

foldRightGo : (a -> b -> <e> b) -> b -> Array a -> Int -> <e> b
foldRightGo f z arr i
  | i < 0 = z
  | otherwise = foldRightGo f (f (arrayGetUnsafe i arr) z) arr (i - 1)

-- ── Instances ───────────────────────────────────────────────────────────

{- | The `Foldable` methods visit the elements in order, so `toList`,
   `length`, `sum`, `elem`, and `any` work on a vector.

   > sum (fromList [1, 2, 3, 4])
   10 -}
export impl Foldable Vector where
  fold f z (Vector backing len) = foldGo f z !backing 0 !len
  foldRight f z (Vector backing len) = foldRightGo f z !backing (!len - 1)
  toList ma = elems ma
  isEmpty (Vector _ len) = !len == 0
  length (Vector _ len) = !len

-- > length (fromList [9, 8, 7])
-- 3

{- | Two vectors are equal when they hold equal elements in the same order.
   Capacity does not matter.

   > eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
   True -}
export impl Eq (Vector a) requires Eq a where
  eq a b = if count a /= count b then False else eq (elems a) (elems b)

{- | `debug` renders a vector as `fromList [x, ...]`.

   > debug (fromList [1, 2, 3])
   "fromList [1, 2, 3]" -}
export impl Debug (Vector a) requires Debug a where
  debug ma = "fromList \{debug (elems ma)}"

{- | `display` renders a vector as `fromList [x, ...]`, with the elements
   in their own `display` form.

   > display (fromList ["a", "b"])
   "fromList [a, b]" -}
export impl Display (Vector a) requires Display a where
  display ma = "fromList \{display (elems ma)}"

-- ── Property tests ──────────────────────────────────────────────────────

-- An INDEPENDENT sortInPlace oracle (insertion sortInPlace, not a mergesort) so the laws
-- below cross-check `sortInPlaceBy` against a different algorithm rather than
-- against a rearrangement of itself.
-- lint-disable-next-line rule-stdlib-reimpl
naiveInsert : Ord a => a -> List a -> List a
naiveInsert x [] = [x]
naiveInsert x (y::ys) = if lte x y then x :: y::ys else y :: naiveInsert x ys

naiveSort : Ord a => List a -> List a
-- lint-disable-next-line rule-stdlib-reimpl
naiveSort [] = []
naiveSort (x::xs) = naiveInsert x (naiveSort xs)

-- `list.insertAt`'s clamp, restated so the laws can name the landing index.
clampIdx : Int -> Int -> Int
clampIdx i n
  | i < 0 = 0
  | i > n = n
  | otherwise = i

-- Pair each element with its input position, for the stability law.
tagFrom : Int -> List a -> List (Int, a)
tagFrom _ [] = []
tagFrom i (x::xs) = (i, x) :: tagFrom (i + 1) xs

-- A deliberately COARSE sortInPlace key, so ties are common.
coarseKey : (Int, Int) -> Int
coarseKey (_, x) = if x < 0 then (0 - x) % 3 else x % 3

posOf : (Int, Int) -> Int
posOf (i, _) = i

{- Sorted by `coarseKey`, and STABLE: within a run of equal keys the original
   positions must still ascend.  Checked pairwise over the output. -}
sortedAndStable : List (Int, Int) -> Bool
sortedAndStable [] = True
sortedAndStable (_::[]) = True
sortedAndStable (a::b::rest) = coarseKey a <= coarseKey b
  && (coarseKey a < coarseKey b || posOf a < posOf b)
  && sortedAndStable (b::rest)

-- LAW: `sortInPlace` agrees with an independent sortInPlace oracle, so it is both
-- ascending AND a permutation of the input -- either property alone is
-- satisfiable by a wrong implementation (`[]` is ascending; the identity is a
-- permutation).
prop "sortInPlace agrees with an independent insertion sortInPlace" (xs : List Int) =
  let ma = fromList xs
  sortInPlace ma
  eq (toList ma) (naiveSort xs)

-- LAW: sorting an already-sorted vector changes nothing.
prop "sortInPlace is idempotent" (xs : List Int) =
  let ma = fromList xs
  sortInPlace ma
  let once = toList ma
  sortInPlace ma
  eq (toList ma) once

-- LAW: `sortInPlaceBy` is STABLE -- sorting on a coarse key must leave tied
-- elements in their original relative order.  A total-order oracle cannot see
-- this, which is why it gets its own law.
prop "sortInPlaceBy is stable on ties" (xs : List Int) =
  let ma = fromList (tagFrom 0 xs)
  sortInPlaceBy (a b => compare (coarseKey a) (coarseKey b)) ma
  sortedAndStable (toList ma) && length ma == length (fromList xs)

-- LAW: `insertAtInPlace` grows the vector by one and lands `x` at the CLAMPED
-- index; `removeAtInPlace` at that same index undoes it exactly.  Stating them as a
-- round trip pins both functions' index conventions at once.
prop "insertAtInPlace lands at the clamped index and removeAtInPlace undoes it" (xs : List Int) (n : Int) (x : Int) =
  let ma = fromList xs
  let i = clampIdx n (length ma)
  insertAtInPlace n x ma
  let grew = length ma == length (fromList xs) + 1
  let landed = eq (get i ma) (Some x)
  removeAtInPlace i ma
  grew && landed && eq (toList ma) xs

-- LAW: `removeAtInPlace` out of range is a NO-OP -- not a panic, and not a silent
-- edit of the nearest element (`list.removeAt`'s behavior).
prop "removeAtInPlace out of range is a no-op" (xs : List Int) =
  let ma = fromList xs
  removeAtInPlace (length ma) ma
  removeAtInPlace (0 - 1) ma
  eq (toList ma) xs

-- LAW: `Display (Vector a)` renders the LIVE range in the same
-- `fromList [...]` shape as `Debug`, and agrees with `Eq` -- equal vectors
-- render identically, unequal ones do not.  The `push`-then-`pop` clause is
-- what proves the scratch tail past `len` stays invisible.
prop "Display Vector shows only the live range and agrees with Eq" (xs : List Int) (y : Int) =
  let a = fromList xs
  let b = fromList xs
  push y b
  let differs = not (eq (display a) (display b))
  let _ = pop b
  differs
    && eq (display a) (display b)
    && eq (display a) "fromList \{display xs}"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Option" false) (mem "Index" false) (mem "IndexMut" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "Vector" ("a") ((variant "Vector" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "count" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int")))
(DFunDef false "count" ((PCon "Vector" PWild (PVar "len"))) (EUnOp "!" (EVar "len")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EArrayLit))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "arrayFromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EVar "arr"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "arr")))))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "fromArray" ((PVar "arr")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EVar "c"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "c")))))))
(DTypeSig true "capacity" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int")))
(DFunDef false "capacity" ((PCon "Vector" (PVar "backing") PWild)) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "backing"))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Index" ((TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PCon "Vector" (PVar "backing") (PVar "len")) (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing"))) (EApp (EVar "indexErrorAt") (EVar "i"))))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "ma")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "ma")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "ma")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "count") (EVar "ma")) (ELit (LInt 1)))) (EVar "ma")))
(DTypeSig false "elemsGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "elemsGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemsGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elems" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elems" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EVar "elemsGo") (EUnOp "!" (EVar "backing"))) (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))) (EListLit)))
(DTypeSig true "toArray" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "toArray" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "backing"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EUnOp "!" (EVar "len"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))
(DTypeSig true "push" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "push" ((PVar "x") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "<" (EUnOp "!" (EVar "len")) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "backing")))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EUnOp "!" (EVar "len"))) (EVar "x")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "backing"))) (DoLet false false (PVar "oldLen") (EUnOp "!" (EVar "len"))) (DoLet false false (PVar "newCap") (EIf (EBinOp "==" (EVar "oldLen") (ELit (LInt 0))) (ELit (LInt 1)) (EBinOp "*" (EVar "oldLen") (ELit (LInt 2))))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EVar "newCap")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "oldArr")) (ELit (LInt 0))) (EVar "newArr")) (ELit (LInt 0))) (EVar "oldLen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "backing")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EVar "oldLen") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pop" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "pop" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "len")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))) (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EVar "i"))) (DoExpr (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "x") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EUnOp "!" (EVar "backing"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "Vector.setInPlace: index out of bounds"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "IndexMut" ((TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PCon "Vector" (PVar "backing") (PVar "len")) (PVar "i") (PVar "v")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "Vector") (EVar "backing")) (EVar "len")))) (EApp (EVar "indexErrorAt") (EVar "i"))))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PCon "Vector" (PVar "backing") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "backing"))) (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "clear" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))
(DFunDef false "clear" ((PCon "Vector" PWild (PVar "len"))) (EApp (EApp (EVar "setRef") (EVar "len")) (ELit (LInt 0))))
(DTypeSig false "mapInPlaceGo" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "mapInPlaceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapInPlace" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "mapInPlace" ((PVar "f") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EUnOp "!" (EVar "backing"))) (ELit (LInt 0))) (EUnOp "!" (EVar "len"))))
(DTypeSig false "pushAll" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "pushAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "pushAll" ((PCons (PVar "x") (PVar "xs")) (PVar "ma")) (EBlock (DoExpr (EApp (EApp (EVar "push") (EVar "x")) (EVar "ma"))) (DoExpr (EApp (EApp (EVar "pushAll") (EVar "xs")) (EVar "ma")))))
(DTypeSig false "refill" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "refill" ((PVar "ma") (PVar "xs")) (EBlock (DoExpr (EApp (EVar "clear") (EVar "ma"))) (DoExpr (EApp (EApp (EVar "pushAll") (EVar "xs")) (EVar "ma")))))
(DTypeSig true "insertAtInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAtInPlace" ((PVar "i") (PVar "x") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EApp (EVar "L.insertAt") (EVar "i")) (EVar "x")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "removeAtInPlace" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "removeAtInPlace" ((PVar "i") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EVar "L.removeAt") (EVar "i")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EVar "L.sortBy") (EVar "cmp")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "ma")) (EApp (EApp (EVar "sortInPlaceBy") (EVar "compare")) (EVar "ma")))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "z"))) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Foldable" ((TyCon "Vector")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "z")) (EUnOp "!" (EVar "backing"))) (ELit (LInt 0))) (EUnOp "!" (EVar "len")))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "z")) (EUnOp "!" (EVar "backing"))) (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1))))) (im "toList" ((PVar "ma")) (EApp (EVar "elems") (EVar "ma"))) (im "isEmpty" ((PCon "Vector" PWild (PVar "len"))) (EBinOp "==" (EUnOp "!" (EVar "len")) (ELit (LInt 0)))) (im "length" ((PCon "Vector" PWild (PVar "len"))) (EUnOp "!" (EVar "len")))))
(DImpl true "Eq" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "count") (EVar "a")) (EApp (EVar "count") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "eq") (EApp (EVar "elems") (EVar "a"))) (EApp (EVar "elems") (EVar "b")))))))
(DImpl true "Debug" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
(DImpl true "Display" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "display") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
(DTypeSig false "naiveInsert" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "naiveInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "naiveInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "lte") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "naiveInsert") (EVar "x")) (EVar "ys")))))
(DTypeSig false "naiveSort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "naiveSort" ((PList)) (EListLit))
(DFunDef false "naiveSort" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "naiveInsert") (EVar "x")) (EApp (EVar "naiveSort") (EVar "xs"))))
(DTypeSig false "clampIdx" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "clampIdx" ((PVar "i") (PVar "n")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp ">" (EVar "i") (EVar "n")) (EVar "n") (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tagFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a"))))))
(DFunDef false "tagFrom" (PWild (PList)) (EListLit))
(DFunDef false "tagFrom" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EApp (EApp (EVar "tagFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "coarseKey" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "coarseKey" ((PTuple PWild (PVar "x"))) (EIf (EBinOp "<" (EVar "x") (ELit (LInt 0))) (EBinOp "%" (EBinOp "-" (ELit (LInt 0)) (EVar "x")) (ELit (LInt 3))) (EBinOp "%" (EVar "x") (ELit (LInt 3)))))
(DTypeSig false "posOf" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "posOf" ((PTuple (PVar "i") PWild)) (EVar "i"))
(DTypeSig false "sortedAndStable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "sortedAndStable" ((PList)) (EVar "True"))
(DFunDef false "sortedAndStable" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "sortedAndStable" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "<=" (EApp (EVar "coarseKey") (EVar "a")) (EApp (EVar "coarseKey") (EVar "b"))) (EBinOp "||" (EBinOp "<" (EApp (EVar "coarseKey") (EVar "a")) (EApp (EVar "coarseKey") (EVar "b"))) (EBinOp "<" (EApp (EVar "posOf") (EVar "a")) (EApp (EVar "posOf") (EVar "b"))))) (EApp (EVar "sortedAndStable") (EBinOp "::" (EVar "b") (EVar "rest")))))
(DProp false "sortInPlace agrees with an independent insertion sortInPlace" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EVar "sortInPlace") (EVar "ma"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "ma"))) (EApp (EVar "naiveSort") (EVar "xs"))))))
(DProp false "sortInPlace is idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EVar "sortInPlace") (EVar "ma"))) (DoLet false false (PVar "once") (EApp (EVar "toList") (EVar "ma"))) (DoExpr (EApp (EVar "sortInPlace") (EVar "ma"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "ma"))) (EVar "once")))))
(DProp false "sortInPlaceBy is stable on ties" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EApp (EApp (EVar "tagFrom") (ELit (LInt 0))) (EVar "xs")))) (DoExpr (EApp (EApp (EVar "sortInPlaceBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "coarseKey") (EVar "a"))) (EApp (EVar "coarseKey") (EVar "b"))))) (EVar "ma"))) (DoExpr (EBinOp "&&" (EApp (EVar "sortedAndStable") (EApp (EVar "toList") (EVar "ma"))) (EBinOp "==" (EApp (EVar "length") (EVar "ma")) (EApp (EVar "length") (EApp (EVar "fromList") (EVar "xs"))))))))
(DProp false "insertAtInPlace lands at the clamped index and removeAtInPlace undoes it" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int")) (pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "i") (EApp (EApp (EVar "clampIdx") (EVar "n")) (EApp (EVar "length") (EVar "ma")))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EVar "n")) (EVar "x")) (EVar "ma"))) (DoLet false false (PVar "grew") (EBinOp "==" (EApp (EVar "length") (EVar "ma")) (EBinOp "+" (EApp (EVar "length") (EApp (EVar "fromList") (EVar "xs"))) (ELit (LInt 1))))) (DoLet false false (PVar "landed") (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "i")) (EVar "ma"))) (EApp (EVar "Some") (EVar "x")))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "i")) (EVar "ma"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "grew") (EVar "landed")) (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "ma"))) (EVar "xs"))))))
(DProp false "removeAtInPlace out of range is a no-op" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EApp (EVar "length") (EVar "ma"))) (EVar "ma"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "ma"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "ma"))) (EVar "xs")))))
(DProp false "Display Vector shows only the live range and agrees with Eq" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "y" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "push") (EVar "y")) (EVar "b"))) (DoLet false false (PVar "differs") (EApp (EVar "not") (EApp (EApp (EVar "eq") (EApp (EVar "display") (EVar "a"))) (EApp (EVar "display") (EVar "b"))))) (DoLet false false PWild (EApp (EVar "pop") (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "differs") (EApp (EApp (EVar "eq") (EApp (EVar "display") (EVar "a"))) (EApp (EVar "display") (EVar "b")))) (EApp (EApp (EVar "eq") (EApp (EVar "display") (EVar "a"))) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "display") (EVar "xs")))) (ELit (LString ""))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Ordering" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Option" false) (mem "Index" false) (mem "IndexMut" false))))
(DUse false (UseAlias ("list") "L"))
(DData Public "Vector" ("a") ((variant "Vector" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "count" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int")))
(DFunDef false "count" ((PCon "Vector" PWild (PVar "len"))) (EUnOp "!" (EVar "len")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EArrayLit))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "arrayFromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EVar "arr"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "arr")))))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Vector") (TyVar "a"))))
(DFunDef false "fromArray" ((PVar "arr")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "Vector") (EApp (EVar "Ref") (EVar "c"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "c")))))))
(DTypeSig true "capacity" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int")))
(DFunDef false "capacity" ((PCon "Vector" (PVar "backing") PWild)) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "backing"))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Index" ((TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PCon "Vector" (PVar "backing") (PVar "len")) (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing"))) (EApp (EVar "indexErrorAt") (EVar "i"))))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "ma")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "ma")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "ma")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "count") (EVar "ma")) (ELit (LInt 1)))) (EVar "ma")))
(DTypeSig false "elemsGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "elemsGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemsGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elems" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elems" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EVar "elemsGo") (EUnOp "!" (EVar "backing"))) (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))) (EListLit)))
(DTypeSig true "toArray" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "toArray" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "backing"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EUnOp "!" (EVar "len"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))
(DTypeSig true "push" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "push" ((PVar "x") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "<" (EUnOp "!" (EVar "len")) (EApp (EVar "arrayLength") (EUnOp "!" (EVar "backing")))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EUnOp "!" (EVar "len"))) (EVar "x")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "oldArr") (EUnOp "!" (EVar "backing"))) (DoLet false false (PVar "oldLen") (EUnOp "!" (EVar "len"))) (DoLet false false (PVar "newCap") (EIf (EBinOp "==" (EVar "oldLen") (ELit (LInt 0))) (ELit (LInt 1)) (EBinOp "*" (EVar "oldLen") (ELit (LInt 2))))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EVar "newCap")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "oldArr")) (ELit (LInt 0))) (EVar "newArr")) (ELit (LInt 0))) (EVar "oldLen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "backing")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EVar "oldLen") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pop" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "pop" ((PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "len")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1)))) (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EVar "i"))) (DoExpr (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "x") (PCon "Vector" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EUnOp "!" (EVar "backing"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "Vector.setInPlace: index out of bounds"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "IndexMut" ((TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PCon "Vector" (PVar "backing") (PVar "len")) (PVar "i") (PVar "v")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EUnOp "!" (EVar "len")))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EUnOp "!" (EVar "backing")))) (DoExpr (EApp (EApp (EVar "Vector") (EVar "backing")) (EVar "len")))) (EApp (EVar "indexErrorAt") (EVar "i"))))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PCon "Vector" (PVar "backing") PWild)) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "backing"))) (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "clear" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))
(DFunDef false "clear" ((PCon "Vector" PWild (PVar "len"))) (EApp (EApp (EVar "setRef") (EVar "len")) (ELit (LInt 0))))
(DTypeSig false "mapInPlaceGo" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "mapInPlaceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapInPlace" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "mapInPlace" ((PVar "f") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EUnOp "!" (EVar "backing"))) (ELit (LInt 0))) (EUnOp "!" (EVar "len"))))
(DTypeSig false "pushAll" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "pushAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "pushAll" ((PCons (PVar "x") (PVar "xs")) (PVar "ma")) (EBlock (DoExpr (EApp (EApp (EVar "push") (EVar "x")) (EVar "ma"))) (DoExpr (EApp (EApp (EVar "pushAll") (EVar "xs")) (EVar "ma")))))
(DTypeSig false "refill" (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "refill" ((PVar "ma") (PVar "xs")) (EBlock (DoExpr (EApp (EVar "clear") (EVar "ma"))) (DoExpr (EApp (EApp (EVar "pushAll") (EVar "xs")) (EVar "ma")))))
(DTypeSig true "insertAtInPlace" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAtInPlace" ((PVar "i") (PVar "x") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EApp (EVar "L.insertAt") (EVar "i")) (EVar "x")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "removeAtInPlace" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "removeAtInPlace" ((PVar "i") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EVar "L.removeAt") (EVar "i")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "ma")) (EApp (EApp (EVar "refill") (EVar "ma")) (EApp (EApp (EVar "L.sortBy") (EVar "cmp")) (EApp (EVar "elems") (EVar "ma")))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Vector") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "ma")) (EApp (EApp (EVar "sortInPlaceBy") (EMethodRef "compare")) (EVar "ma")))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "z"))) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Foldable" ((TyCon "Vector")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "z")) (EUnOp "!" (EVar "backing"))) (ELit (LInt 0))) (EUnOp "!" (EVar "len")))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "Vector" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "z")) (EUnOp "!" (EVar "backing"))) (EBinOp "-" (EUnOp "!" (EVar "len")) (ELit (LInt 1))))) (im "toList" ((PVar "ma")) (EApp (EVar "elems") (EVar "ma"))) (im "isEmpty" ((PCon "Vector" PWild (PVar "len"))) (EBinOp "==" (EUnOp "!" (EVar "len")) (ELit (LInt 0)))) (im "length" ((PCon "Vector" PWild (PVar "len"))) (EUnOp "!" (EVar "len")))))
(DImpl true "Eq" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "count") (EVar "a")) (EApp (EVar "count") (EVar "b"))) (EVar "False") (EApp (EApp (EMethodRef "eq") (EApp (EVar "elems") (EVar "a"))) (EApp (EVar "elems") (EVar "b")))))))
(DImpl true "Debug" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
(DImpl true "Display" ((TyApp (TyCon "Vector") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
(DTypeSig false "naiveInsert" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "naiveInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "naiveInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EMethodRef "lte") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EDictApp "naiveInsert") (EVar "x")) (EVar "ys")))))
(DTypeSig false "naiveSort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "naiveSort" ((PList)) (EListLit))
(DFunDef false "naiveSort" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EDictApp "naiveInsert") (EVar "x")) (EApp (EDictApp "naiveSort") (EVar "xs"))))
(DTypeSig false "clampIdx" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "clampIdx" ((PVar "i") (PVar "n")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp ">" (EVar "i") (EVar "n")) (EVar "n") (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tagFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a"))))))
(DFunDef false "tagFrom" (PWild (PList)) (EListLit))
(DFunDef false "tagFrom" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EApp (EApp (EVar "tagFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "coarseKey" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "coarseKey" ((PTuple PWild (PVar "x"))) (EIf (EBinOp "<" (EVar "x") (ELit (LInt 0))) (EBinOp "%" (EBinOp "-" (ELit (LInt 0)) (EVar "x")) (ELit (LInt 3))) (EBinOp "%" (EVar "x") (ELit (LInt 3)))))
(DTypeSig false "posOf" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "posOf" ((PTuple (PVar "i") PWild)) (EVar "i"))
(DTypeSig false "sortedAndStable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "sortedAndStable" ((PList)) (EVar "True"))
(DFunDef false "sortedAndStable" ((PCons PWild (PList))) (EVar "True"))
(DFunDef false "sortedAndStable" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "<=" (EApp (EVar "coarseKey") (EVar "a")) (EApp (EVar "coarseKey") (EVar "b"))) (EBinOp "||" (EBinOp "<" (EApp (EVar "coarseKey") (EVar "a")) (EApp (EVar "coarseKey") (EVar "b"))) (EBinOp "<" (EApp (EVar "posOf") (EVar "a")) (EApp (EVar "posOf") (EVar "b"))))) (EApp (EVar "sortedAndStable") (EBinOp "::" (EVar "b") (EVar "rest")))))
(DProp false "sortInPlace agrees with an independent insertion sortInPlace" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EDictApp "sortInPlace") (EVar "ma"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "ma"))) (EApp (EDictApp "naiveSort") (EVar "xs"))))))
(DProp false "sortInPlace is idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EDictApp "sortInPlace") (EVar "ma"))) (DoLet false false (PVar "once") (EApp (EMethodRef "toList") (EVar "ma"))) (DoExpr (EApp (EDictApp "sortInPlace") (EVar "ma"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "ma"))) (EVar "once")))))
(DProp false "sortInPlaceBy is stable on ties" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EApp (EApp (EVar "tagFrom") (ELit (LInt 0))) (EVar "xs")))) (DoExpr (EApp (EApp (EVar "sortInPlaceBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "coarseKey") (EVar "a"))) (EApp (EVar "coarseKey") (EVar "b"))))) (EVar "ma"))) (DoExpr (EBinOp "&&" (EApp (EVar "sortedAndStable") (EApp (EMethodRef "toList") (EVar "ma"))) (EBinOp "==" (EApp (EMethodRef "length") (EVar "ma")) (EApp (EMethodRef "length") (EApp (EVar "fromList") (EVar "xs"))))))))
(DProp false "insertAtInPlace lands at the clamped index and removeAtInPlace undoes it" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int")) (pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "i") (EApp (EApp (EVar "clampIdx") (EVar "n")) (EApp (EMethodRef "length") (EVar "ma")))) (DoExpr (EApp (EApp (EApp (EVar "insertAtInPlace") (EVar "n")) (EVar "x")) (EVar "ma"))) (DoLet false false (PVar "grew") (EBinOp "==" (EApp (EMethodRef "length") (EVar "ma")) (EBinOp "+" (EApp (EMethodRef "length") (EApp (EVar "fromList") (EVar "xs"))) (ELit (LInt 1))))) (DoLet false false (PVar "landed") (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "get") (EVar "i")) (EVar "ma"))) (EApp (EVar "Some") (EVar "x")))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EVar "i")) (EVar "ma"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "grew") (EVar "landed")) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "ma"))) (EVar "xs"))))))
(DProp false "removeAtInPlace out of range is a no-op" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ma") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EApp (EMethodRef "length") (EVar "ma"))) (EVar "ma"))) (DoExpr (EApp (EApp (EVar "removeAtInPlace") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "ma"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "ma"))) (EVar "xs")))))
(DProp false "Display Vector shows only the live range and agrees with Eq" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "y" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "push") (EVar "y")) (EVar "b"))) (DoLet false false (PVar "differs") (EApp (EVar "not") (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "display") (EVar "a"))) (EApp (EMethodRef "display") (EVar "b"))))) (DoLet false false PWild (EApp (EVar "pop") (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "differs") (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "display") (EVar "a"))) (EApp (EMethodRef "display") (EVar "b")))) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "display") (EVar "a"))) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EVar "xs")))) (ELit (LString ""))))))))
