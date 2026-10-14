# META
source_lines=1363
stages=DESUGAR,MARK
# SOURCE
{- | An immutable map from keys to values, ordered by key.

   `Map k v` is a balanced binary search tree. Lookup, insertion, and
   deletion cost `O(log n)`, and `size` is `O(1)`. Every operation returns a
   new map and leaves the original unchanged; the two share whatever
   structure they have in common, so keeping old versions is cheap.

   Keys are ordered by their `Ord` instance, and `keys`, `values`, `entries`,
   and the folds visit entries in ascending key order. The `Map { k => v }`
   literal builds a map; the empty map is `empty`. For keys that are
   `Hashable` but not `Ord`, or when order does not matter, see
   `hash_map`. -}

-- `Map k v` is a weight-balanced binary search tree (the Adams / Haskell
-- `Data.Map` scheme): every interior node caches the size of its subtree,
-- and the two invariants
--
--   • search:   keys in the left subtree < node key < keys in the right
--   • balance:  neither subtree is more than `delta` times the size of the
--               other (`delta = 3`)
--
-- are maintained by a single smart constructor, `balance`, that rotates when
-- an insert or delete tips a node out of balance.  Caching the size makes
-- `size` O(1) and the balancing decision a couple of integer comparisons; it
-- also pays for the `split`-style operations.
--
-- Most operations carry an `Ord k` constraint; the few that only walk an
-- existing tree (`size`, `map`, `keys`, the folds) do not, because the tree
-- is already in order.

-- map/set are identical weight-balanced-tree bodies over DISTINCT ADTs; consolidation needs a Set = Map _ Unit refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{
  Ordering(..),
  Ord,
  Debug,
  Display,
  Mappable,
  Filterable,
  Semigroup,
  Monoid,
  Option,
  FromEntries,
  Index,
}
import list.{intersperse, reverse, take, sort, sortBy}

{- | The map type.

   `Tip` is the empty tree and `Bin` is an interior node holding its
   subtree's size, a key, a value, and the left and right subtrees. The
   constructors are visible for pattern matching, but build maps with the
   functions in this module, which keep the tree balanced. -}
public export data Map k v = Tip | Bin Int k v (Map k v) (Map k v)

-- ── Internal smart constructors ─────────────────────────────────────────

{- `bin` assembles a node and computes its cached size from the children.
   Use it whenever the children are already balanced relative to each other
   (after a rotation, or when only values changed). -}
bin : k -> v -> Map k v -> Map k v -> Map k v
bin k v l r = Bin (size l + size r + 1) k v l r

{- `balance` is `bin` plus a rebalancing check.  When one subtree grows past
   `delta` (= 3) times the other, a single or double rotation restores the
   weight invariant.  `ratio` (= 2) decides single vs. double: a double
   rotation is needed when the heavy subtree's *inner* grandchild is the bulk. -}
balance : k -> v -> Map k v -> Map k v -> Map k v
balance k v l r
  | size l + size r <= 1 = bin k v l r
  | size r > 3 * size l = rotateL k v l r
  | size l > 3 * size r = rotateR k v l r
  | otherwise = bin k v l r

-- `balanceL` repairs a node whose left subtree may have grown (an insert into
-- `l`) or whose right subtree may have shrunk (a delete from `r`). Only the
-- left-heavy check can fire, so the right side is never inspected for a
-- rotation. Matching each child once reads the cached sizes directly; the
-- result is identical to `balance` under that precondition.
balanceL : k -> v -> Map k v -> Map k v -> Map k v
balanceL k v Tip r = Bin (size r + 1) k v Tip r
balanceL k v (l@(Bin sl _ _ _ _)) Tip =
  if sl <= 1 then Bin (sl + 1) k v l Tip else rotateR k v l Tip
balanceL k v (l@(Bin sl _ _ _ _)) (r@(Bin sr _ _ _ _)) =
  if sl > 3 * sr && sl + sr > 1 then
    rotateR k v l r
  else
    Bin (sl + sr + 1) k v l r

-- Mirror of `balanceL`: the right subtree may have grown (an insert into `r`)
-- or the left subtree may have shrunk (a delete from `l`).
balanceR : k -> v -> Map k v -> Map k v -> Map k v
balanceR k v l Tip = Bin (size l + 1) k v l Tip
balanceR k v Tip (r@(Bin sr _ _ _ _)) =
  if sr <= 1 then Bin (sr + 1) k v Tip r else rotateL k v Tip r
balanceR k v (l@(Bin sl _ _ _ _)) (r@(Bin sr _ _ _ _)) =
  if sr > 3 * sl && sl + sr > 1 then
    rotateL k v l r
  else
    Bin (sl + sr + 1) k v l r

-- Right subtree too heavy: single left rotation, or double if its left
-- grandchild outweighs its right.
rotateL : k -> v -> Map k v -> Map k v -> Map k v
rotateL k v l (r@(Bin _ _ _ rl rr)) =
  if size rl < 2 * size rr then singleL k v l r else doubleL k v l r
rotateL k v l Tip = panic "Map.rotateL: empty right subtree"

-- Left subtree too heavy: mirror of rotateL.
rotateR : k -> v -> Map k v -> Map k v -> Map k v
rotateR k v (l@(Bin _ _ _ ll lr)) r =
  if size lr < 2 * size ll then singleR k v l r else doubleR k v l r
rotateR k v Tip r = panic "Map.rotateR: empty left subtree"

singleL : k -> v -> Map k v -> Map k v -> Map k v
singleL k1 v1 t1 (Bin _ k2 v2 t2 t3) = bin k2 v2 (bin k1 v1 t1 t2) t3
singleL k1 v1 t1 Tip = panic "Map.singleL: empty right subtree"

singleR : k -> v -> Map k v -> Map k v -> Map k v
singleR k1 v1 (Bin _ k2 v2 t1 t2) t3 = bin k2 v2 t1 (bin k1 v1 t2 t3)
singleR k1 v1 Tip t3 = panic "Map.singleR: empty left subtree"

doubleL : k -> v -> Map k v -> Map k v -> Map k v
doubleL k1 v1 t1 (Bin _ k2 v2 (Bin _ k3 v3 t2 t3) t4) =
  bin k3 v3 (bin k1 v1 t1 t2) (bin k2 v2 t3 t4)
doubleL k1 v1 t1 _ = panic "Map.doubleL: malformed right subtree"

doubleR : k -> v -> Map k v -> Map k v -> Map k v
doubleR k1 v1 (Bin _ k2 v2 t1 (Bin _ k3 v3 t2 t3)) t4 =
  bin k3 v3 (bin k2 v2 t1 t2) (bin k1 v1 t3 t4)
doubleR k1 v1 _ t4 = panic "Map.doubleR: malformed left subtree"

-- # Construction

-- The empty map is `Monoid.empty` (see `impl Monoid (Map k v)` below); use
-- the `Tip` constructor directly inside this module.

{- | A map with one entry.

   > size (singleton 1 "a")
   1 -}
export
singleton : k -> v -> Map k v
singleton k v = Bin 1 k v Tip Tip

{- | A map holding the pairs of an association list.

   When a key appears more than once, the later pair wins. The
   `Map { k => v, ... }` literal is the same operation.

   > keys (fromList [(3, 0), (1, 0), (2, 0)])
   [1, 2, 3]
   > findWithDefault 0 1 (fromList [(1, 10), (1, 20)])
   20 -}
export
fromList : Ord k => List (k, v) -> Map k v
fromList xs =
  let n = ascendingRunLength xs
  let (m, rest) = buildAscending n xs
  match rest
    [] => m
    _ => fromUnsorted xs

-- Stable-sorts by key, keeps the last pair of each run of equal keys (the
-- later pair wins), and builds the tree in one linear pass.
fromUnsorted : Ord k => List (k, v) -> Map k v
fromUnsorted xs =
  let ys = dedupeLast (sortBy ((a, _) (b, _) => compare a b) xs)
  fst (buildAscending (length ys) ys)

dedupeLast : Ord k => List (k, v) -> List (k, v)
dedupeLast [] = []
dedupeLast [p] = [p]
dedupeLast ((k1, v1) :: rest@((k2, _) :: _)) =
  if eq k1 k2 then dedupeLast rest else (k1, v1) :: dedupeLast rest

-- Length of the longest prefix whose keys are strictly ascending.
ascendingRunLength : Ord k => List (k, v) -> Int
ascendingRunLength [] = 0
ascendingRunLength ((k, _) :: rest) = ascendingRunFrom k 1 rest

ascendingRunFrom : Ord k => k -> Int -> List (k, v) -> Int
ascendingRunFrom _ n [] = n
ascendingRunFrom prev n ((k, _) :: rest) =
  if lt prev k then ascendingRunFrom k (n + 1) rest else n

-- Builds a perfectly balanced tree from the first `n` pairs and returns it
-- with the pairs that follow. The first `n` keys must be strictly ascending.
buildAscending : Int -> List (k, v) -> (Map k v, List (k, v))
buildAscending n xs
  | n <= 0 = (Tip, xs)
  | otherwise = buildNode n xs

buildNode : Int -> List (k, v) -> (Map k v, List (k, v))
buildNode n xs =
  let nl = (n - 1) / 2
  let nr = n - 1 - nl
  let (l, rest) = buildAscending nl xs
  match rest
    (k, v) :: rest2 =>
      let (r, rest3) = buildAscending nr rest2
      (Bin n k v l r, rest3)
    [] => panic "Map.buildNode: fewer pairs than the run length"

-- > size (Map { 1 => 10, 2 => 20, 3 => 30 })
-- 3
-- > findWithDefault 0 2 (Map { 1 => 10, 2 => 20 })
-- 20
-- > size (Map { } : Map Int Int)
-- 0

-- # Query

{- | The number of entries, in `O(1)`.

   > size (fromList [(1, 10), (2, 20), (1, 30)])
   2 -}
export
size : Map k v -> Int
size Tip = 0
size (Bin s _ _ _ _) = s

{- | Whether the map has no entries.

   > isEmpty (empty : Map Int Int)
   True -}
export
isEmpty : Map k v -> Bool
isEmpty Tip = True
isEmpty _ = False

{- | The value at `k`, or `None` when the key is absent.

   > get 2 (fromList [(1, 10), (2, 20)])
   Some 20
   > get 9 (fromList [(1, 10), (2, 20)])
   None -}
export
get : Ord k => k -> Map k v -> Option v
get k Tip = None
get k (Bin _ k2 v l r) = match compare k k2
  Lt => get k l
  Gt => get k r
  Eq => Some v

{- | `m[k]` is the value at `k`.

   Panics with an index error when the key is absent; `get` is the
   `Option`-returning form. The `Index` interface takes the map first, so
   this is `index m k` where `get` is `get k m`. -}
export impl Index (Map k v) k v requires Ord k, Debug k where
  index m k = match get k m
    Some v => v
    None => indexError "key not found: \{debug k}"

{- | Whether `k` is present.

   > has 2 (fromList [(1, 10), (2, 20)])
   True
   > has 9 (fromList [(1, 10), (2, 20)])
   False -}
export
has : Ord k => k -> Map k v -> Bool
has k Tip = False
has k (Bin _ k2 _ l r) = match compare k k2
  Lt => has k l
  Gt => has k r
  Eq => True

{- | The value at `k`, or `d` when the key is absent.

   > findWithDefault 0 2 (fromList [(1, 10), (2, 20)])
   20
   > findWithDefault 0 9 (fromList [(1, 10), (2, 20)])
   0 -}
export
findWithDefault : Ord k => v -> k -> Map k v -> v
findWithDefault d k Tip = d
findWithDefault d k (Bin _ k2 v l r) = match compare k k2
  Lt => findWithDefault d k l
  Gt => findWithDefault d k r
  Eq => v

-- # Insertion

{- | The map with `v` stored at `k`, replacing any existing value.

   > findWithDefault 0 2 (set 2 99 (fromList [(1, 10), (2, 20)]))
   99 -}
export
set : Ord k => k -> v -> Map k v -> Map k v
set k v Tip = singleton k v
set k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balanceL k2 v2 (set k v l) r
  Gt => balanceR k2 v2 l (set k v r)
  Eq => Bin s k v l r

{- | The map with `v` stored at `k`, combining with an existing value.

   When `k` is already present, the stored value becomes `f v old`. When it
   is absent, `v` is stored as it is.

   > findWithDefault 0 1 (insertWith (n o => n + o) 1 5 (fromList [(1, 10)]))
   15 -}
export
insertWith : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
insertWith f k v Tip = singleton k v
insertWith f k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balanceL k2 v2 (insertWith f k v l) r
  Gt => balanceR k2 v2 l (insertWith f k v r)
  Eq => Bin s k2 (f v v2) l r

{- | The map with `f` applied to the value at `k`.

   Unchanged when `k` is absent.

   > findWithDefault 0 1 (adjust (n => n * 10) 1 (fromList [(1, 5), (2, 6)]))
   50 -}
export
adjust : Ord k => (v -> v) -> k -> Map k v -> Map k v
adjust f k Tip = Tip
adjust f k (Bin s k2 v2 l r) = match compare k k2
  Lt => Bin s k2 v2 (adjust f k l) r
  Gt => Bin s k2 v2 l (adjust f k r)
  Eq => Bin s k2 (f v2) l r

-- # Deletion

{- | The map without the entry at `k`.

   Unchanged when `k` is absent.

   > has 2 (delete 2 (fromList [(1, 10), (2, 20)]))
   False -}
export
delete : Ord k => k -> Map k v -> Map k v
delete k Tip = Tip
delete k (Bin _ k2 v2 l r) = match compare k k2
  Lt => balanceR k2 v2 (delete k l) r
  Gt => balanceL k2 v2 l (delete k r)
  Eq => glue l r

-- > size (delete 9 (fromList [(1, 10), (2, 20)]))
-- 2

{- `glue` joins two subtrees that were siblings under a now-deleted node, so
   every key on the left is below every key on the right.  It promotes the max
   of the larger side (or the min of the other) to be the new root, keeping the
   result balanced. -}
glue : Map k v -> Map k v -> Map k v
glue Tip r = r
glue l Tip = l
glue l r
  | size l > size r = glueMax l r
  | otherwise = glueMin l r

-- `glueMax` removes the maximum of `l`, so only the left subtree shrinks and
-- only the right-heavy check can fire; `glueMin` is the mirror image.
glueMax : Map k v -> Map k v -> Map k v
glueMax l r = match getMax l
  None => r
  Some (k, v) => balanceR k v (deleteMax l) r

glueMin : Map k v -> Map k v -> Map k v
glueMin l r = match getMin r
  None => l
  Some (k, v) => balanceL k v l (deleteMin r)

-- # Minimum and maximum

{- | The smallest entry and the map without it, or `None` when the map is
   empty.

   > minView (fromList [(2, "b"), (1, "a")])
   Some (1, "a", fromList [(2, "b")]) -}
export
minView : Map k v -> Option (k, v, Map k v)
minView Tip = None
-- The explicit match avoids the closure that `map` would allocate per call.
-- lint-disable-next-line rule-match-to-map
minView m = match getMin m
  None => None
  Some (k, v) => Some (k, v, deleteMin m)

{- | The largest entry and the map without it, or `None` when the map is
   empty.

   > maxView (fromList [(2, "b"), (1, "a")])
   Some (2, "b", fromList [(1, "a")]) -}
export
maxView : Map k v -> Option (k, v, Map k v)
maxView Tip = None
-- The explicit match avoids the closure that `map` would allocate per call.
-- lint-disable-next-line rule-match-to-map
maxView m = match getMax m
  None => None
  Some (k, v) => Some (k, v, deleteMax m)

{- | The entry with the smallest key, or `None` when the map is empty.

   > getMin (fromList [(3, 0), (1, 0), (2, 0)])
   Some (1, 0) -}
export
getMin : Map k v -> Option (k, v)
getMin Tip = None
getMin (Bin _ k v Tip _) = Some (k, v)
getMin (Bin _ _ _ l _) = getMin l

{- | The entry with the largest key, or `None` when the map is empty.

   > getMax (fromList [(3, 0), (1, 0), (2, 0)])
   Some (3, 0) -}
export
getMax : Map k v -> Option (k, v)
getMax Tip = None
getMax (Bin _ k v _ Tip) = Some (k, v)
getMax (Bin _ _ _ _ r) = getMax r

{- | The map without its smallest entry.

   Unchanged when the map is empty.

   > keys (deleteMin (fromList [(3, 0), (1, 0), (2, 0)]))
   [2, 3] -}
export
deleteMin : Map k v -> Map k v
deleteMin Tip = Tip
deleteMin (Bin _ _ _ Tip r) = r
deleteMin (Bin _ k v l r) = balanceR k v (deleteMin l) r

{- | The map without its largest entry.

   Unchanged when the map is empty.

   > keys (deleteMax (fromList [(3, 0), (1, 0), (2, 0)]))
   [1, 2] -}
export
deleteMax : Map k v -> Map k v
deleteMax Tip = Tip
deleteMax (Bin _ _ _ l Tip) = l
deleteMax (Bin _ k v l r) = balanceL k v l (deleteMax r)

-- # Folds and traversal

{- | A right fold over the entries in ascending key order.

   > foldrWithKey (k v acc => k :: acc) [] (fromList [(2, 0), (1, 0)])
   [1, 2] -}
export
foldrWithKey : (k -> v -> b -> <e> b) -> b -> Map k v -> <e> b
foldrWithKey f z Tip = z
foldrWithKey f z (Bin _ k v l r) = foldrWithKey f (f k v (foldrWithKey f z r)) l

{- | A left fold over the entries in ascending key order.

   > foldlWithKey (acc k v => acc + v) 0 (fromList [(1, 10), (2, 20)])
   30 -}
export
foldlWithKey : (b -> k -> v -> <e> b) -> b -> Map k v -> <e> b
foldlWithKey f z Tip = z
foldlWithKey f z (Bin _ k v l r) = foldlWithKey f (f (foldlWithKey f z l) k v) r

{- | The entries as pairs, in ascending key order.

   > entries (fromList [(2, 20), (1, 10), (3, 30)])
   [(1, 10), (2, 20), (3, 30)] -}
export
entries : Map k v -> List (k, v)
entries m = entriesOnto m []

entriesOnto : Map k v -> List (k, v) -> List (k, v)
entriesOnto Tip acc = acc
entriesOnto (Bin _ k v l r) acc = entriesOnto l ((k, v) :: entriesOnto r acc)

{- | The entries from `start` upwards in ascending key order, at most `limit`
   of them.

   A `start` of `None` begins at the smallest key and a `limit` of `None` reads
   to the end, so `entriesFrom None None` is `entries`. The start key is
   inclusive and need not be present: the read begins at the next key above it.
   A `limit` of zero or less reads nothing.

   The read descends to `start` and stops as soon as the limit is met, without
   visiting the entries on either side of what it returns, so a page of a large
   map costs the page: `O(log n + limit)`, against the `O(n)` of taking a prefix
   of `entries`.

   > entriesFrom (Some "b") (Some 2) (fromList [("a", 1), ("b", 2), ("c", 3), ("d", 4)])
   [("b", 2), ("c", 3)]
   > entriesFrom (Some "b") (Some 0) (fromList [("a", 1), ("b", 2)])
   []
   > entriesFrom (Some "z") None (fromList [("a", 1), ("b", 2)])
   []
   > entriesFrom None None (fromList [("b", 2), ("a", 1)])
   [("a", 1), ("b", 2)] -}
export
entriesFrom : Ord k => Option k -> Option Int -> Map k v -> List (k, v)
entriesFrom start limit m =
  let (Scan taken _ _) = scanFrom start m (scanStart limit)
  reverse taken

{- The entries taken so far in reverse traversal order, how many more the limit
   still allows, and whether the limit is filled. Every later step is a no-op
   once it is. -}
data Scan k v = Scan (List (k, v)) (Option Int) Bool

scanDone : Scan k v -> Bool
scanDone (Scan _ _ done) = done

-- A limit of no entries at all leaves the scan with nothing to do.
scanStart : Option Int -> Scan k v
scanStart None = Scan [] None False
scanStart (Some limit) = Scan [] (Some limit) (limit <= 0)

-- Take one in-range entry, ending the scan when it was the last the limit
-- allows.
takeEntry : k -> v -> Scan k v -> Scan k v
takeEntry k v (Scan taken remaining _) =
  let kept = (k, v) :: taken
  match remaining
    None => Scan kept None False
    Some left => Scan kept (Some (left - 1)) (left <= 1)

belowBound : Ord k => k -> Option k -> Bool
belowBound _ None = False
belowBound k (Some bound) = lt k bound

{- Walk from `start` in key order, entering a subtree only when it can still
   hold an entry the read wants. A node below the bound puts its whole left
   subtree below the bound too, by the search invariant, so that subtree is
   discarded without one of its nodes being visited; at or above the bound the
   bound is discharged, because every key right of an in-range key is in range
   as well. A filled limit ends the descent where it stands rather than
   trimming a larger result. -}
scanFrom : Ord k => Option k -> Map k v -> Scan k v -> Scan k v
scanFrom _ Tip scan = scan
scanFrom lo (Bin _ k v l r) scan =
  if scanDone scan then
    scan
  else if belowBound k lo then
    scanFrom lo r scan
  else
    let afterLeft = scanFrom lo l scan
    if scanDone afterLeft then
      afterLeft
    else
      scanFrom None r (takeEntry k v afterLeft)

{- | The keys, in ascending order.

   > keys (fromList [(2, 0), (3, 0), (1, 0)])
   [1, 2, 3] -}
export
keys : Map k v -> List k
keys m = keysOnto m []

keysOnto : Map k v -> List k -> List k
keysOnto Tip acc = acc
keysOnto (Bin _ k _ l r) acc = keysOnto l (k :: keysOnto r acc)

{- | The values, in ascending order of their keys.

   > values (fromList [(2, 20), (1, 10), (3, 30)])
   [10, 20, 30] -}
export
values : Map k v -> List v
values m = valuesOnto m []

valuesOnto : Map k v -> List v -> List v
valuesOnto Tip acc = acc
valuesOnto (Bin _ _ v l r) acc = valuesOnto l (v :: valuesOnto r acc)

{- | The map with `f` applied to every value, where `f` also receives the
   key.

   `map` is the form whose function sees only the value.

   > values (mapWithKey (k v => k + v) (fromList [(1, 10), (2, 20)]))
   [11, 22] -}
export
mapWithKey : (k -> v -> <e> w) -> Map k v -> <e> Map k w
mapWithKey f Tip = Tip
mapWithKey f (Bin s k v l r) = Bin s k (f k v) (mapWithKey f l) (mapWithKey f r)

-- ── Split / join ────────────────────────────────────────────────────────

{- The join-based kit (Adams 1992; Blelloch, Ferizovic & Sun 2016).  `balance`
   above only ever repairs an imbalance of *one* element, which is all an
   insert or a delete can create.  Combining two whole maps needs two stronger
   primitives that cope with subtrees of wildly different weights:

     • `link k v l r`  — rebuild `l < k < r` into one balanced map, for any
                         weights of `l` and `r`.  Adams' `concat3`.
     • `link2 l r`     — the same without a dividing key, for when that key is
                         being dropped (`difference`, `filterWithKey`).

   Both descend the heavier side until the two weights are within `delta`, then
   hand back to `balance` on the way out — so each is O(|log |l| - log |r||).
   With `splitAt`, every combining operation below becomes a divide-and-conquer
   over the *structure* instead of a re-insert of every element, which is what
   turns O(m·log(n+m)) into O(m·log(n/m + 1)).

   None of these need `Ord` except `splitAt`/`splitLookup`, which compare keys. -}

-- Insert at the far left / far right.  Used when one side of a `link` is empty:
-- the key still has to be pushed down to its extreme and rebalanced.
insertMin : k -> v -> Map k v -> Map k v
insertMin k v Tip = singleton k v
insertMin k v (Bin _ k2 v2 l r) = balanceL k2 v2 (insertMin k v l) r

insertMax : k -> v -> Map k v -> Map k v
insertMax k v Tip = singleton k v
insertMax k v (Bin _ k2 v2 l r) = balanceR k2 v2 l (insertMax k v r)

{- `link` joins `l < k,v < r` for arbitrarily unbalanced `l`/`r`.  When one side
   outweighs the other by more than `delta` we cannot just `bin` them: we
   recurse into the heavy side's inner subtree, which brings the weights into
   range, and rebalance on the way back out. -}
link : k -> v -> Map k v -> Map k v -> Map k v
link k v Tip r = insertMin k v r
link k v l Tip = insertMax k v l
link k v (l@(Bin sl kl vl ll rl)) (r@(Bin sr kr vr lr rr))
  | 3 * sl < sr = balance kr vr (link k v l lr) rr
  | 3 * sr < sl = balance kl vl ll (link k v rl r)
  | otherwise = bin k v l r

{- `link2` is `link` with no dividing key — every key in `l` is below every key
   in `r`.  Once the weights are comparable it falls back to `glue`, which
   promotes an extreme element to be the new root. -}
link2 : Map k v -> Map k v -> Map k v
link2 Tip r = r
link2 l Tip = l
link2 (l@(Bin sl kl vl ll rl)) (r@(Bin sr kr vr lr rr))
  | 3 * sl < sr = balance kr vr (link2 l lr) rr
  | 3 * sr < sl = balance kl vl ll (link2 rl r)
  | otherwise = glue l r

{- Split a map around a key: every entry below `k`, and every entry above it.
   The entry *at* `k` (if any) is dropped -- `splitLookup` hands it back. -}
splitAt : Ord k => k -> Map k v -> (Map k v, Map k v)
splitAt k Tip = (Tip, Tip)
splitAt k (Bin _ k2 v2 l r) = match compare k k2
  Lt =>
    let (below, above) = splitAt k l
    (below, link k2 v2 above r)
  Gt =>
    let (below, above) = splitAt k r
    (link k2 v2 l below, above)
  Eq => (l, r)

-- `splitAt` that also reports the value that sat at the split key.
splitLookup : Ord k => k -> Map k v -> (Map k v, Option v, Map k v)
splitLookup k Tip = (Tip, None, Tip)
splitLookup k (Bin _ k2 v2 l r) = match compare k k2
  Lt =>
    let (below, found, above) = splitLookup k l
    (below, found, link k2 v2 above r)
  Gt =>
    let (below, found, above) = splitLookup k r
    (link k2 v2 l below, found, above)
  Eq => (l, Some v2, r)

-- # Filtering

{- | The entries whose key and value satisfy `p`.

   `filter` is the form whose predicate sees only the value.

   > keys (filterWithKey (k v => v > 15) (fromList [(1, 10), (2, 20), (3, 30)]))
   [2, 3] -}
export
filterWithKey : Ord k => (k -> v -> <e> Bool) -> Map k v -> <e> Map k v
filterWithKey p Tip = Tip
filterWithKey p (Bin _ k v l r) =
  let l2 = filterWithKey p l
  let r2 = filterWithKey p r
  if p k v then link k v l2 r2 else link2 l2 r2

-- # Combining

-- The combining operations are divide-and-conquer over the tree structure,
-- costing `O(m log(n/m + 1))` for maps of sizes `m <= n`.

{- | The entries of both maps. On a shared key, the first map's value wins.

   `++` on maps is `union`.

   > findWithDefault 0 1 (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
   1 -}
export
union : Ord k => Map k v -> Map k v -> Map k v
union Tip b = b
union a Tip = a
-- A side at most a sixteenth the size of the other is cheaper to insert entry by entry.
union a b
  | size b * 16 <= size a = foldlWithKey (acc k v => insertAbsent k v acc) a b
  | size a * 16 <= size b = foldlWithKey (acc k v => set k v acc) b a
  | otherwise = unionSplit a b

-- `insertAbsent` adds `k` only when it is missing; an existing entry is kept.
insertAbsent : Ord k => k -> v -> Map k v -> Map k v
insertAbsent k v Tip = singleton k v
insertAbsent k v (m@(Bin _ k2 v2 l r)) = match compare k k2
  Lt => balanceL k2 v2 (insertAbsent k v l) r
  Gt => balanceR k2 v2 l (insertAbsent k v r)
  Eq => m

unionSplit : Ord k => Map k v -> Map k v -> Map k v
unionSplit Tip b = b
unionSplit a Tip = a
unionSplit (Bin _ k v l r) b =
  let (bl, br) = splitAt k b
  -- `k`'s own entry in `b` was dropped by `splitAt`, so the left map wins.
  link k v (unionSplit l bl) (unionSplit r br)

-- > size (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
-- 2

{- | The entries of both maps. On a shared key, the value is `f left right`.

   > findWithDefault 0 1 (unionWith (x y => x + y) (fromList [(1, 1)]) (fromList [(1, 2)]))
   3 -}
export
unionWith : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
unionWith f Tip b = b
unionWith f a Tip = a
unionWith f a b
  | size b * 16 <= size a =
    foldlWithKey (acc k w => insertWith (x y => f y x) k w acc) a b
  | size a * 16 <= size b = foldlWithKey (acc k v => setWith f k v acc) b a
  | otherwise = unionWithSplit f a b

-- `insertWith` that stores the given key on a collision, so a key of the first
-- map survives a union even when `Eq`-equal keys are distinguishable.
setWith : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
setWith f k v Tip = singleton k v
setWith f k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balanceL k2 v2 (setWith f k v l) r
  Gt => balanceR k2 v2 l (setWith f k v r)
  Eq => Bin s k (f v v2) l r

unionWithSplit : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
unionWithSplit f Tip b = b
unionWithSplit f a Tip = a
unionWithSplit f (Bin _ k v l r) b =
  let (bl, found, br) = splitLookup k b
  let v2 = match found
    None => v
    Some w => f v w
  link k v2 (unionWithSplit f l bl) (unionWithSplit f r br)

{- | The entries of the first map whose keys are absent from the second.

   > keys (difference (fromList [(1, 0), (2, 0), (3, 0)]) (fromList [(2, 0)]))
   [1, 3] -}
export
difference : Ord k => Map k v -> Map k w -> Map k v
difference Tip b = Tip
difference a Tip = a
difference a (Bin _ k _ l r) =
  let (al, ar) = splitAt k a
  -- `splitAt` already dropped `k` from both halves, so it is simply not rebuilt.
  link2 (difference al l) (difference ar r)

{- | The keys present in both maps, each with the value `f left right`.

   > entries (intersectionWith (x y => x + y) (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
   [(2, 22)] -}
export
intersectionWith : Ord k => (v -> w -> x) -> Map k v -> Map k w -> Map k x
intersectionWith f Tip b = Tip
intersectionWith f a Tip = Tip
intersectionWith f (Bin _ k v l r) b =
  let (bl, found, br) = splitLookup k b
  let l2 = intersectionWith f l bl
  let r2 = intersectionWith f r br
  match found
    None => link2 l2 r2
    Some w => link k (f v w) l2 r2

{- | The keys present in both maps, each with the first map's value.

   > entries (intersection (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
   [(2, 20)] -}
export
intersection : Ord k => Map k v -> Map k w -> Map k v
intersection a b = intersectionWith (x _ => x) a b

-- ── Typeclass instances ─────────────────────────────────────────────────

{- | `map` applies a function to every value, keeping the keys.

   > values (map (n => n * 10) (fromList [(1, 1), (2, 2)]))
   [10, 20] -}
export impl Mappable (Map k) where
  map f Tip = Tip
  map f (Bin s k v l r) = Bin s k (f v) (map f l) (map f r)

{- | `filter` and `filterMap` test each value, keeping the keys of the
   entries that survive. `filterWithKey` is the form that also sees the
   key. -}
export impl Filterable (Map k) where
  filterMap f Tip = Tip
  filterMap f (Bin _ k v l r) =
    let l2 = filterMap f l
    let r2 = filterMap f r
    match f v
      Some w => link k w l2 r2
      None => link2 l2 r2

{- | The `Foldable` methods visit the values in ascending key order, so
   `toList`, `length`, `elem`, `sum`, `maximum`, `any`, and `all` fold over
   the values, not the `(k, v)` pairs. `entries` gives the pairs.

   > toList (fromList [(2, 20), (1, 10)])
   [10, 20]
   > length (fromList [(1, 10), (2, 20)])
   2
   > isEmpty (fromList [(1, 10)] : Map Int Int)
   False
   > elem 20 (fromList [(1, 10), (2, 20)])
   True
   > sum (fromList [(1, 10), (2, 20)])
   30 -}
export impl Foldable (Map k) where
  fold f z m = foldlWithKey (acc _ v => f acc v) z m
  foldRight f z m = foldrWithKey (_ v acc => f v acc) z m
  toList m = values m
  isEmpty Tip = True
  isEmpty _ = False
  length m = size m

{- | Two maps are equal when they hold the same keys with equal values,
   regardless of how they were built.

   > eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
   True -}
export impl Eq (Map k v) requires Eq k, Eq v where
  eq a b = if size a /= size b then False else eq (entries a) (entries b)

{- | Maps compare lexicographically by their ascending `(key, value)` pairs.

   > compare (fromList [(1, 10)]) (fromList [(1, 20)])
   Lt -}
export impl Ord (Map k v) requires Ord k, Ord v where
  compare a b = compare (entries a) (entries b)

{- | `debug` renders a map as `fromList [(k, v), ...]`.

   > debug (fromList [(1, 10), (2, 20)])
   "fromList [(1, 10), (2, 20)]" -}
export impl Debug (Map k v) requires Debug k, Debug v where
  debug m = "fromList \{debug (entries m)}"

-- Comma-joined `k => v` entries for `Display (Map k v)`; keys/values render via
-- `display` (unquoted), the Display convention.  `entries` gives ascending pairs.
displayMapEntries : (Display k, Display v) => List (k, v) -> String
displayMapEntries es =
  stringConcat (intersperse ", " (map ((k, v) => "\{k} => \{v}") es))

{- | `display` renders a map in its literal syntax, `Map { k => v, ... }`.

   > display (fromList [(1, 10), (2, 20)])
   "Map { 1 => 10, 2 => 20 }"
   > display (empty : Map Int Int)
   "Map {}" -}
export impl Display (Map k v) requires Display k, Display v where
  display m = match entries m
    [] => "Map {}"
    es => "Map { \{displayMapEntries es} }"

-- | `++` on maps is `union`: the left map wins on shared keys.
export impl Semigroup (Map k v) requires Ord k where
  append a b = union a b

-- | The `Map { k => v, ... }` literal builds its map through this instance.
export impl FromEntries (Map k v) (k, v) requires Ord k where
  fromEntries es = fromList es

-- `empty` is nullary and so dispatches on its result type; the impl's
-- `requires Ord k` carries no dict here because `Tip` needs none, so a
-- return-position `empty : Map k v` grounds cleanly.
{- | The map with no entries.

   > isEmpty (empty : Map Int Int)
   True -}
export impl Monoid (Map k v) requires Ord k where
  empty = Tip

-- # Invariants

{- | Whether the map's internal tree satisfies its invariants: keys in
   search order, correct cached sizes, and balanced subtrees.

   Every map built with this module's functions is well formed. This is a
   debugging aid and the basis of the module's property tests. It costs
   `O(n log n)`. -}
export
wellFormed : Ord k => Map k v -> Bool
wellFormed Tip = True
wellFormed (Bin s k v l r) =
  let sizeOk = size l + size r + 1 == s
  let orderOk = allKeys (lk => lt lk k) l && allKeys (gk => gt gk k) r
  sizeOk && balancedAt l r && orderOk && wellFormed l && wellFormed r

-- Every key in the subtree satisfies the predicate.
allKeys : (k -> Bool) -> Map k v -> Bool
allKeys p Tip = True
allKeys p (Bin _ k _ l r) = p k && allKeys p l && allKeys p r

-- The weight-balance bound between two siblings: tiny pairs are exempt,
-- otherwise neither may exceed `delta` (= 3) times the other.
balancedAt : Map k v -> Map k v -> Bool
balancedAt l r =
  let sl = size l
  let sr = size r
  if sl + sr <= 1 then True else sl <= 3 * sr && sr <= 3 * sl

-- Strictly-ascending check used by the key-ordering property.
ascending : Ord a => List a -> Bool
ascending [] = True
ascending [x] = True
ascending (x :: y :: rest) = lt x y && ascending (y :: rest)

-- ── Properties ──────────────────────────────────────────────────────────

prop "fromList builds a well-formed tree" (xs : List (Int, Int)) =
  wellFormed (fromList xs)

prop "keys come out strictly ascending" (xs : List (Int, Int)) =
  ascending (keys (fromList xs))

prop "insert then lookup returns the inserted value" (k : Int) (v : Int) (xs : List (Int, Int)) =
  eq (get k (set k v (fromList xs))) (Some v)

prop "insert preserves well-formedness" (k : Int) (v : Int) (xs : List (Int, Int)) =
  wellFormed (set k v (fromList xs))

prop "delete removes the key and preserves well-formedness" (k : Int) (xs : List (Int, Int)) =
  let m = delete k (fromList xs)
  not (has k m) && wellFormed m

prop "union preserves well-formedness" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  wellFormed (union (fromList xs) (fromList ys))

prop "union is left-biased on shared keys" (k : Int) (xs : List (Int, Int)) =
  let l = set k 1 (fromList xs)
  let r = set k 2 (fromList xs)
  eq (get k (union l r)) (Some 1)

{- The naive fold-insert bodies the join-based combining operations replaced.
   They are obviously correct and obviously slow, which makes them the
   differential oracle for the fast versions: the properties below assert the
   two agree entry-for-entry on random inputs.  A join-based operation that
   silently corrupted the weight-balance invariant would still answer every
   doctest correctly, so `wellFormed` is asserted alongside each one. -}

naiveUnion : Ord k => Map k v -> Map k v -> Map k v
naiveUnion a b = foldrWithKey (k v acc => set k v acc) b a

naiveUnionWith : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
naiveUnionWith f a b = foldrWithKey (k v acc => insertWith f k v acc) b a

naiveDifference : Ord k => Map k v -> Map k w -> Map k v
naiveDifference a b = foldrWithKey (k _ acc => delete k acc) a b

naiveIntersectionWith : Ord k => (v -> w -> x) -> Map k v -> Map k w -> Map k x
naiveIntersectionWith f a b = foldrWithKey (naiveIntersectStep f b) Tip a

naiveIntersectStep : Ord k =>
  (v -> w -> x) ->
  Map k w ->
  k ->
  v ->
  Map k x ->
  Map k x
naiveIntersectStep f b k v acc = match get k b
  None => acc
  Some w => set k (f v w) acc

naiveFilterWithKey : Ord k => (k -> v -> Bool) -> Map k v -> Map k v
naiveFilterWithKey p m = foldrWithKey (naiveFilterStep p) Tip m

naiveFilterStep : Ord k => (k -> v -> Bool) -> k -> v -> Map k v -> Map k v
naiveFilterStep p k v acc = if p k v then set k v acc else acc

-- Reference bodies built on `balance` alone, for the shape props below, which
-- compare node for node.
setOld : Ord k => k -> v -> Map k v -> Map k v
setOld k v Tip = singleton k v
setOld k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (setOld k v l) r
  Gt => balance k2 v2 l (setOld k v r)
  Eq => Bin s k v l r

insertWithOld : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
insertWithOld f k v Tip = singleton k v
insertWithOld f k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (insertWithOld f k v l) r
  Gt => balance k2 v2 l (insertWithOld f k v r)
  Eq => Bin s k2 (f v v2) l r

deleteOld : Ord k => k -> Map k v -> Map k v
deleteOld k Tip = Tip
deleteOld k (Bin _ k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (deleteOld k l) r
  Gt => balance k2 v2 l (deleteOld k r)
  Eq => glueOld l r

insertMinOld : k -> v -> Map k v -> Map k v
insertMinOld k v Tip = singleton k v
insertMinOld k v (Bin _ k2 v2 l r) = balance k2 v2 (insertMinOld k v l) r

insertMaxOld : k -> v -> Map k v -> Map k v
insertMaxOld k v Tip = singleton k v
insertMaxOld k v (Bin _ k2 v2 l r) = balance k2 v2 l (insertMaxOld k v r)

glueOld : Map k v -> Map k v -> Map k v
glueOld Tip r = r
glueOld l Tip = l
glueOld l r
  | size l > size r = glueMaxOld l r
  | otherwise = glueMinOld l r

glueMaxOld : Map k v -> Map k v -> Map k v
glueMaxOld l r = match maxViewOld l
  None => r
  Some (k, v, l') => balance k v l' r

glueMinOld : Map k v -> Map k v -> Map k v
glueMinOld l r = match minViewOld r
  None => l
  Some (k, v, r') => balance k v l r'

minViewOld : Map k v -> Option (k, v, Map k v)
minViewOld Tip = None
minViewOld (Bin _ k v l r) = match minViewOld l
  None => Some (k, v, r)
  Some (km, vm, l') => Some (km, vm, balance k v l' r)

maxViewOld : Map k v -> Option (k, v, Map k v)
maxViewOld Tip = None
maxViewOld (Bin _ k v l r) = match maxViewOld r
  None => Some (k, v, l)
  Some (km, vm, r') => Some (km, vm, balance k v l r')

getMinOld : Map k v -> Option (k, v)
getMinOld m = map ((k, v, _) => (k, v)) (minViewOld m)

getMaxOld : Map k v -> Option (k, v)
getMaxOld m = map ((k, v, _) => (k, v)) (maxViewOld m)

deleteMinOld : Map k v -> Map k v
deleteMinOld m = match minViewOld m
  None => Tip
  Some (_, _, m') => m'

deleteMaxOld : Map k v -> Map k v
deleteMaxOld m = match maxViewOld m
  None => Tip
  Some (_, _, m') => m'

-- Structural equality: same shape, cached sizes, keys and values at every node.
sameShape : (Eq k, Eq v) => Map k v -> Map k v -> Bool
sameShape Tip Tip = True
sameShape (Bin s1 k1 v1 l1 r1) (Bin s2 k2 v2 l2 r2) =
  s1 == s2 && eq k1 k2 && eq v1 v2 && sameShape l1 l2 && sameShape r1 r2
sameShape _ _ = False

-- Applies `step` to each pair in order, left to right.
foldInserts : (k -> v -> Map k v -> Map k v) ->
  List (k, v) ->
  Map k v ->
  Map k v
foldInserts step [] m = m
foldInserts step ((k, v) :: rest) m = foldInserts step rest (step k v m)

-- Folds each key through `step` in order, for the delete props.
foldDeletes : (k -> Map k v -> Map k v) -> List k -> Map k v -> Map k v
foldDeletes step [] m = m
foldDeletes step (k :: rest) m = foldDeletes step rest (step k m)

-- Collapses keys onto 0..7 so that the props hit the duplicate (`Eq`) paths.
modKeys : List (Int, Int) -> List (Int, Int)
modKeys [] = []
modKeys ((k, v) :: rest) = (k % 8, v) :: modKeys rest

fstKeys : List (Int, Int) -> List Int
fstKeys [] = []
fstKeys ((k, _) :: rest) = k :: fstKeys rest

prop "set builds the same tree shape as the balance-only body" (xs : List (Int, Int)) =
  let got = foldInserts set xs Tip
  sameShape got (foldInserts setOld xs Tip) && wellFormed got

prop "set on duplicate keys builds the same tree shape as the balance-only body" (xs : List (Int, Int)) =
  let ys = modKeys xs
  let got = foldInserts set ys Tip
  sameShape got (foldInserts setOld ys Tip) && wellFormed got

prop "insertWith builds the same tree shape as the balance-only body" (xs : List (Int, Int)) =
  let ys = modKeys xs
  let got = foldInserts (k v m => insertWith (a b => a + b) k v m) ys Tip
  sameShape
      got
      (foldInserts (k v m => insertWithOld (a b => a + b) k v m) ys Tip)
    && wellFormed got

prop "insertMin and insertMax match the balance-only body shape" (xs : List (Int, Int)) =
  let got = foldInserts (k v m => insertMin k v m) xs Tip
  let gotMax = foldInserts (k v m => insertMax k v m) xs Tip
  sameShape got (foldInserts (k v m => insertMinOld k v m) xs Tip)
    && sameShape gotMax (foldInserts (k v m => insertMaxOld k v m) xs Tip)

prop "delete matches the balance-only body shape" (xs : List (Int, Int)) (ks : List Int) =
  let ys = modKeys xs
  let base = foldInserts set ys Tip
  let got = foldDeletes delete ks (foldDeletes delete (fstKeys ys) base)
  sameShape
      got
      (foldDeletes deleteOld ks (foldDeletes deleteOld (fstKeys ys) base))
    && wellFormed got

-- Walks the new tree and the balance-only tree through repeated removals of
-- the minimum (or maximum) in lockstep, so every intermediate shape is compared.
minChainOk : Map Int Int -> Map Int Int -> Bool
minChainOk got old =
  if isEmpty old then
    isEmpty got
  else
    sameShape got old
      && wellFormed got
      && minChainOk (deleteMin got) (deleteMinOld old)

maxChainOk : Map Int Int -> Map Int Int -> Bool
maxChainOk got old =
  if isEmpty old then
    isEmpty got
  else
    sameShape got old
      && wellFormed got
      && maxChainOk (deleteMax got) (deleteMaxOld old)

-- Checks `glue` at every node of a tree, where its two arguments are siblings.
glueAgrees : Map Int Int -> Bool
glueAgrees Tip = True
glueAgrees (Bin _ _ _ l r) =
  sameShape (glue l r) (glueOld l r)
    && wellFormed (glue l r)
    && glueAgrees l
    && glueAgrees r

minViewAgrees : Map Int Int -> Bool
minViewAgrees m = match minView m
  None => isEmpty m
  Some (k, v, rest) =>
    eq (getMinOld m) (Some (k, v))
      && sameShape rest (deleteMinOld m)
      && wellFormed rest

maxViewAgrees : Map Int Int -> Bool
maxViewAgrees m = match maxView m
  None => isEmpty m
  Some (k, v, rest) =>
    eq (getMaxOld m) (Some (k, v))
      && sameShape rest (deleteMaxOld m)
      && wellFormed rest

prop "deleteMin matches the balance-only body shape at every step" (xs : List (Int, Int)) =
  let m = foldInserts set xs Tip
  minChainOk m m

prop "deleteMax matches the balance-only body shape at every step" (xs : List (Int, Int)) =
  let m = foldInserts set xs Tip
  maxChainOk m m

prop "getMin, getMax, minView and maxView agree with the balance-only bodies" (xs : List (Int, Int)) =
  let m = foldInserts set xs Tip
  eq (getMin m) (getMinOld m)
    && eq (getMax m) (getMaxOld m)
    && minViewAgrees m
    && maxViewAgrees m

prop "glue matches the balance-only body shape at every node" (xs : List (Int, Int)) =
  glueAgrees (foldInserts set xs Tip) && glueAgrees (fromList xs)

prop "glue on duplicate-heavy inserts matches the balance-only body shape" (xs : List (Int, Int)) =
  glueAgrees (foldInserts set (modKeys xs) Tip)

naiveFromList : Ord k => List (k, v) -> Map k v
naiveFromList xs = fold (m (k, v) => set k v m) Tip xs

prop "fromList agrees with naive fold-insert" (xs : List (Int, Int)) =
  eq (entries (fromList xs)) (entries (naiveFromList xs))
    && wellFormed (fromList xs)

prop "fromList agrees with naive on sorted input" (xs : List (Int, Int)) =
  let ys = sort xs
  eq (entries (fromList ys)) (entries (naiveFromList ys))
    && wellFormed (fromList ys)

prop "fromList agrees with naive on sorted duplicate-heavy input" (xs : List (Int, Int)) =
  let ys = sort (map (p => (fst p % 50, snd p)) xs)
  eq (entries (fromList ys)) (entries (naiveFromList ys))
    && wellFormed (fromList ys)

prop "fromList agrees with naive on sorted prefix then unsorted tail" (xs : List (Int, Int)) =
  let ys = sort xs ++ xs
  eq (entries (fromList ys)) (entries (naiveFromList ys))
    && wellFormed (fromList ys)

prop "fromList agrees with naive on sorted prefix then duplicate-heavy tail" (xs : List (Int, Int)) =
  let ys = sort xs ++ map (p => (fst p % 50, snd p)) xs
  eq (entries (fromList ys)) (entries (naiveFromList ys))
    && wellFormed (fromList ys)

prop "a later pair overrides an entry from the ascending prefix" (k : Int) (v : Int) (xs : List (Int, Int)) =
  let ys = sort xs ++ [(k, v)]
  eq (get k (fromList ys)) (Some v) && wellFormed (fromList ys)

prop "union agrees with naive fold-insert" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  eq (entries (union a b)) (entries (naiveUnion a b))

prop "union with a tiny side agrees with naive in both orders" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let big = fromList (map (i => (i, i)) [0..=63] ++ xs)
  let small = fromList (map ((k, v) => (k % 64, v)) (take 2 ys))
  eq (entries (union big small)) (entries (naiveUnion big small))
    && eq (entries (union small big)) (entries (naiveUnion small big))
    && wellFormed (union big small)
    && wellFormed (union small big)

prop "unionWith with a tiny side agrees with naive in both orders" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let big = fromList (map (i => (i, i)) [0..=63] ++ xs)
  let small = fromList (map ((k, v) => (k % 64, v)) (take 2 ys))
  let f = x y => 2 * x + y
  eq (entries (unionWith f big small)) (entries (naiveUnionWith f big small))
    && eq
      (entries (unionWith f small big))
      (entries (naiveUnionWith f small big))
    && wellFormed (unionWith f big small)
    && wellFormed (unionWith f small big)

-- A key whose `Eq` and `Ord` ignore the tag, so two keys can be equal yet
-- distinguishable by which map they came from.
data Tagged = Tagged Int Int

impl Eq Tagged where
  eq (Tagged a _) (Tagged b _) = a == b

impl Ord Tagged where
  compare (Tagged a _) (Tagged b _) = compare a b

taggedAt : Int -> Map Tagged Int -> List Int
taggedAt n m = filterMap (tagIfAt n) (keys m)

tagIfAt : Int -> Tagged -> Option Int
tagIfAt n (Tagged i t) = if i == n then Some t else None

prop "union and unionWith keep the first map's key on a shared key" (j : Int) =
  let n = (j % 64 + 64) % 64
  let big = fromList (map (i => (Tagged i 0, i)) [0..=63])
  let small = fromList [(Tagged n 1, 7)]
  let sameSize = fromList (map (i => (Tagged i 1, i)) [0..=63])
  eq (taggedAt n (union small big)) [1]
    && eq (taggedAt n (union big small)) [0]
    && eq (taggedAt n (unionWith (x y => x + y) small big)) [1]
    && eq (taggedAt n (unionWith (x y => x + y) big small)) [0]
    && eq (taggedAt n (union sameSize big)) [1]
    && eq (taggedAt n (unionWith (x y => x + y) sameSize big)) [1]

prop "union keys stay strictly ascending" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  ascending (keys (union (fromList xs) (fromList ys)))

prop "unionWith agrees with naive and stays well-formed" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  let got = unionWith (x y => x + y) a b
  eq (entries got) (entries (naiveUnionWith (x y => x + y) a b))
    && wellFormed got

prop "difference agrees with naive and stays well-formed" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  let got = difference a b
  eq (entries got) (entries (naiveDifference a b)) && wellFormed got

prop "intersectionWith agrees with naive and stays well-formed" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  let got = intersectionWith (x y => x + y) a b
  eq (entries got) (entries (naiveIntersectionWith (x y => x + y) a b))
    && wellFormed got

-- LAW: `intersection` is exactly the left-biased `intersectionWith`, and its
-- key set is the set intersection of the two key sets — the same relationship
-- `union`/`unionWith` and `set.intersection` already satisfy.
prop "intersection is the left-biased intersectionWith" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  let got = intersection a b
  eq (entries got) (entries (intersectionWith (x _ => x) a b)) && wellFormed got

prop "intersection keeps exactly the shared keys, with the left value" (xs : List (Int, Int)) (ys : List (Int, Int)) =
  let a = fromList xs
  let b = fromList ys
  let got = intersection a b
  -- every surviving key is in both inputs and carries the LEFT value ...
  all (k => isSome (get k b) && get k got == get k a) (keys got)
    -- ... and every key shared by both inputs survives.
    && all (k => not (isSome (get k b)) || isSome (get k got)) (keys a)

-- LAW (Filterable): `filterMap Some` is the identity, `filter` agrees with the
-- key-aware `filterWithKey` that ignores its key, and the result is still a
-- well-formed search tree.
prop "Filterable: filterMap Some is the identity" (xs : List (Int, Int)) =
  let m = fromList xs
  let got = filterMap (v => Some v) m
  eq (entries got) (entries m) && wellFormed got

prop "Filterable: filter agrees with filterWithKey ignoring the key" (xs : List (Int, Int)) =
  let m = fromList xs
  let got = filter (v => v > 0) m
  eq (entries got) (entries (filterWithKey (_ v => v > 0) m)) && wellFormed got

prop "filterWithKey agrees with naive and stays well-formed" (xs : List (Int, Int)) =
  let m = fromList xs
  let got = filterWithKey (k v => v > 0) m
  eq (entries got) (entries (naiveFilterWithKey (k v => v > 0) m))
    && wellFormed got

prop "splitAt partitions around the key and both halves stay well-formed" (k : Int) (xs : List (Int, Int)) =
  let (below, above) = splitAt k (fromList xs)
  wellFormed below
    && wellFormed above
    && allKeys (bk => lt bk k) below
    && allKeys (ak => gt ak k) above

prop "link rebuilds a well-formed map from a split" (k : Int) (xs : List (Int, Int)) =
  let (below, above) = splitAt k (fromList xs)
  let rebuilt = link k 0 below above
  wellFormed rebuilt && eq (get k rebuilt) (Some 0)

prop "link2 rejoins a split without its key" (k : Int) (xs : List (Int, Int)) =
  let (below, above) = splitAt k (fromList xs)
  let rebuilt = link2 below above
  wellFormed rebuilt && eq (entries rebuilt) (entries (delete k (fromList xs)))

prop "entriesFrom is the limited run of entries from the start key" (k : Int) (n : Int) (xs : List (Int, Int)) =
  let m = fromList xs
  eq
    (entriesFrom (Some k) (Some n) m)
    (take n (filter ((key, _) => gte key k) (entries m)))

prop "entriesFrom bounded on one side only still agrees with entries" (k : Int) (n : Int) (xs : List (Int, Int)) =
  let m = fromList xs
  eq (entriesFrom None None m) (entries m)
    && eq (entriesFrom None (Some n) m) (take n (entries m))
    && eq
      (entriesFrom (Some k) None m)
      (filter ((key, _) => gte key k) (entries m))
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Option" false) (mem "FromEntries" false) (mem "Index" false))))
(DUse false (UseGroup ("list") ((mem "intersperse" false) (mem "reverse" false) (mem "take" false) (mem "sort" false) (mem "sortBy" false))))
(DData Public "Map" ("k" "v") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "bin" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balance" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balanceL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EApp (EVar "size") (EVar "r")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r")))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PCon "Tip")) (EIf (EBinOp "<=" (EVar "sl") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EVar "sl") (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip")) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip"))))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp ">" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DTypeSig false "balanceR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EApp (EVar "size") (EVar "l")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip")))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PCon "Tip") (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "<=" (EVar "sr") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EVar "sr") (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r"))))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))) (EBinOp ">" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DTypeSig false "rotateL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EApp (EVar "singleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" PWild PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EApp (EVar "singleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Map.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Map.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Map.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Map.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "singleton" ((PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "ascendingRunLength") (EVar "xs"))) (DoLet false false (PTuple (PVar "m") (PVar "rest")) (EApp (EApp (EVar "buildAscending") (EVar "n")) (EVar "xs"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (EVar "m")) (arm PWild () (EApp (EVar "fromUnsorted") (EVar "xs")))))))
(DTypeSig false "fromUnsorted" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromUnsorted" ((PVar "xs")) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "dedupeLast") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "a") PWild) (PTuple (PVar "b") PWild)) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))) (EVar "xs")))) (DoExpr (EApp (EVar "fst") (EApp (EApp (EVar "buildAscending") (EApp (EVar "length") (EVar "ys"))) (EVar "ys"))))))
(DTypeSig false "dedupeLast" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))
(DFunDef false "dedupeLast" ((PList)) (EListLit))
(DFunDef false "dedupeLast" ((PList (PVar "p"))) (EListLit (EVar "p")))
(DFunDef false "dedupeLast" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PAs "rest" (PCons (PTuple (PVar "k2") PWild) PWild)))) (EIf (EApp (EApp (EVar "eq") (EVar "k1")) (EVar "k2")) (EApp (EVar "dedupeLast") (EVar "rest")) (EBinOp "::" (ETuple (EVar "k1") (EVar "v1")) (EApp (EVar "dedupeLast") (EVar "rest")))))
(DTypeSig false "ascendingRunLength" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Int"))))
(DFunDef false "ascendingRunLength" ((PList)) (ELit (LInt 0)))
(DFunDef false "ascendingRunLength" ((PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EApp (EApp (EApp (EVar "ascendingRunFrom") (EVar "k")) (ELit (LInt 1))) (EVar "rest")))
(DTypeSig false "ascendingRunFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Int"))))))
(DFunDef false "ascendingRunFrom" (PWild (PVar "n") (PList)) (EVar "n"))
(DFunDef false "ascendingRunFrom" ((PVar "prev") (PVar "n") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "lt") (EVar "prev")) (EVar "k")) (EApp (EApp (EApp (EVar "ascendingRunFrom") (EVar "k")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EVar "n")))
(DTypeSig false "buildAscending" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "buildAscending" ((PVar "n") (PVar "xs")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EVar "Tip") (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "buildNode") (EVar "n")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildNode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "buildNode" ((PVar "n") (PVar "xs")) (EBlock (DoLet false false (PVar "nl") (EBinOp "/" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (ELit (LInt 2)))) (DoLet false false (PVar "nr") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "nl"))) (DoLet false false (PTuple (PVar "l") (PVar "rest")) (EApp (EApp (EVar "buildAscending") (EVar "nl")) (EVar "xs"))) (DoExpr (EMatch (EVar "rest") (arm (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest2")) () (EBlock (DoLet false false (PTuple (PVar "r") (PVar "rest3")) (EApp (EApp (EVar "buildAscending") (EVar "nr")) (EVar "rest2"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "n")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EVar "rest3"))))) (arm (PList) () (EApp (EVar "panic") (ELit (LString "Map.buildNode: fewer pairs than the run length"))))))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "isEmpty" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty" ((PCon "Tip")) (EVar "True"))
(DFunDef false "isEmpty" (PWild) (EVar "False"))
(DTypeSig true "get" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "get" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EVar "get") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EVar "get") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EApp (EVar "Some") (EVar "v")))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Ord" ((TyVar "k"))) (req "Debug" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "key not found: ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "k")))) (ELit (LString "")))))))))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EVar "has") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EVar "has") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PCon "Tip")) (EVar "d"))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EVar "findWithDefault") (EVar "d")) (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EVar "findWithDefault") (EVar "d")) (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "v"))))
(DTypeSig true "set" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig true "insertWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "adjust" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyVar "v")) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "adjust") (EVar "f")) (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "adjust") (EVar "f")) (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EVar "f") (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "delete" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "getMax") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k")) (EVar "v")) (EApp (EVar "deleteMax") (EVar "l"))) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "getMin") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k")) (EVar "v")) (EVar "l")) (EApp (EVar "deleteMin") (EVar "r"))))))
(DTypeSig true "minView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PVar "m")) (EMatch (EApp (EVar "getMin") (EVar "m")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EApp (EVar "deleteMin") (EVar "m")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PVar "m")) (EMatch (EApp (EVar "getMax") (EVar "m")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EApp (EVar "deleteMax") (EVar "m")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMin" ((PCon "Tip")) (EVar "None"))
(DFunDef false "getMin" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PCon "Tip") PWild)) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "getMin" ((PCon "Bin" PWild PWild PWild (PVar "l") PWild)) (EApp (EVar "getMin") (EVar "l")))
(DTypeSig true "getMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMax" ((PCon "Tip")) (EVar "None"))
(DFunDef false "getMax" ((PCon "Bin" PWild (PVar "k") (PVar "v") PWild (PCon "Tip"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "getMax" ((PCon "Bin" PWild PWild PWild PWild (PVar "r"))) (EApp (EVar "getMax") (EVar "r")))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMin" ((PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteMin" ((PCon "Bin" PWild PWild PWild (PCon "Tip") (PVar "r"))) (EVar "r"))
(DFunDef false "deleteMin" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k")) (EVar "v")) (EApp (EVar "deleteMin") (EVar "l"))) (EVar "r")))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMax" ((PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteMax" ((PCon "Bin" PWild PWild PWild (PVar "l") (PCon "Tip"))) (EVar "l"))
(DFunDef false "deleteMax" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k")) (EVar "v")) (EVar "l")) (EApp (EVar "deleteMax") (EVar "r"))))
(DTypeSig true "foldrWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig true "foldlWithKey" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "k")) (EVar "v"))) (EVar "r")))
(DTypeSig true "entries" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PVar "m")) (EApp (EApp (EVar "entriesOnto") (EVar "m")) (EListLit)))
(DTypeSig false "entriesOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))
(DFunDef false "entriesOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "entriesOnto" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "entriesOnto") (EVar "l")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "entriesOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "entriesFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "entriesFrom" ((PVar "start") (PVar "limit") (PVar "m")) (EBlock (DoLet false false (PCon "Scan" (PVar "taken") PWild PWild) (EApp (EApp (EApp (EVar "scanFrom") (EVar "start")) (EVar "m")) (EApp (EVar "scanStart") (EVar "limit")))) (DoExpr (EApp (EVar "reverse") (EVar "taken")))))
(DData Private "Scan" ("k" "v") ((variant "Scan" (ConPos (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Bool")))) ())
(DTypeSig false "scanDone" (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "scanDone" ((PCon "Scan" PWild PWild (PVar "done"))) (EVar "done"))
(DTypeSig false "scanStart" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v"))))
(DFunDef false "scanStart" ((PCon "None")) (EApp (EApp (EApp (EVar "Scan") (EListLit)) (EVar "None")) (EVar "False")))
(DFunDef false "scanStart" ((PCon "Some" (PVar "limit"))) (EApp (EApp (EApp (EVar "Scan") (EListLit)) (EApp (EVar "Some") (EVar "limit"))) (EBinOp "<=" (EVar "limit") (ELit (LInt 0)))))
(DTypeSig false "takeEntry" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "takeEntry" ((PVar "k") (PVar "v") (PCon "Scan" (PVar "taken") (PVar "remaining") PWild)) (EBlock (DoLet false false (PVar "kept") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "taken"))) (DoExpr (EMatch (EVar "remaining") (arm (PCon "None") () (EApp (EApp (EApp (EVar "Scan") (EVar "kept")) (EVar "None")) (EVar "False"))) (arm (PCon "Some" (PVar "left")) () (EApp (EApp (EApp (EVar "Scan") (EVar "kept")) (EApp (EVar "Some") (EBinOp "-" (EVar "left") (ELit (LInt 1))))) (EBinOp "<=" (EVar "left") (ELit (LInt 1)))))))))
(DTypeSig false "belowBound" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyCon "Bool")))))
(DFunDef false "belowBound" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "belowBound" ((PVar "k") (PCon "Some" (PVar "bound"))) (EApp (EApp (EVar "lt") (EVar "k")) (EVar "bound")))
(DTypeSig false "scanFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "scanFrom" (PWild (PCon "Tip") (PVar "scan")) (EVar "scan"))
(DFunDef false "scanFrom" ((PVar "lo") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "scan")) (EIf (EApp (EVar "scanDone") (EVar "scan")) (EVar "scan") (EIf (EApp (EApp (EVar "belowBound") (EVar "k")) (EVar "lo")) (EApp (EApp (EApp (EVar "scanFrom") (EVar "lo")) (EVar "r")) (EVar "scan")) (EBlock (DoLet false false (PVar "afterLeft") (EApp (EApp (EApp (EVar "scanFrom") (EVar "lo")) (EVar "l")) (EVar "scan"))) (DoExpr (EIf (EApp (EVar "scanDone") (EVar "afterLeft")) (EVar "afterLeft") (EApp (EApp (EApp (EVar "scanFrom") (EVar "None")) (EVar "r")) (EApp (EApp (EApp (EVar "takeEntry") (EVar "k")) (EVar "v")) (EVar "afterLeft")))))))))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EVar "keysOnto") (EVar "m")) (EListLit)))
(DTypeSig false "keysOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyVar "k")) (TyApp (TyCon "List") (TyVar "k")))))
(DFunDef false "keysOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "keysOnto" ((PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "keysOnto") (EVar "l")) (EBinOp "::" (EVar "k") (EApp (EApp (EVar "keysOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EVar "valuesOnto") (EVar "m")) (EListLit)))
(DTypeSig false "valuesOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "valuesOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "valuesOnto" ((PCon "Bin" PWild PWild (PVar "v") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "valuesOnto") (EVar "l")) (EBinOp "::" (EVar "v") (EApp (EApp (EVar "valuesOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "mapWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "w")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w"))))))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "k")) (EVar "v"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "r"))))
(DTypeSig false "insertMin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMin" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMin" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMax" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMax" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMax" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "r"))))
(DTypeSig false "link" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "link" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "r")))
(DFunDef false "link" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "l")))
(DFunDef false "link" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") (PVar "kl") (PVar "vl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "kr") (PVar "vr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kr")) (EVar "vr")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kl")) (EVar "vl")) (EVar "ll")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "link2" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "link2" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "link2" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "link2" ((PAs "l" (PCon "Bin" (PVar "sl") (PVar "kl") (PVar "vl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "kr") (PVar "vr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kr")) (EVar "vr")) (EApp (EApp (EVar "link2") (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kl")) (EVar "vl")) (EVar "ll")) (EApp (EApp (EVar "link2") (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitAt" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "splitAt" ((PVar "k") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "Tip")))
(DFunDef false "splitAt" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "l")) (EVar "below")) (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "r")))))
(DTypeSig false "splitLookup" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "splitLookup" ((PVar "k") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "None") (EVar "Tip")))
(DFunDef false "splitLookup" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EVar "splitLookup") (EVar "k")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EVar "found") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EVar "splitLookup") (EVar "k")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "l")) (EVar "below")) (EVar "found") (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EApp (EVar "Some") (EVar "v2")) (EVar "r")))))
(DTypeSig true "filterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "filterWithKey" ((PVar "p") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "filterWithKey" ((PVar "p") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EVar "filterWithKey") (EVar "p")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EVar "filterWithKey") (EVar "p")) (EVar "r"))) (DoExpr (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))))))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "union" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "union" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "union" ((PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "b")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "a"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EVar "insertAbsent") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "a")) (EVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "a")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")) (EIf (EVar "otherwise") (EApp (EApp (EVar "unionSplit") (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "insertAbsent" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "insertAbsent" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertAbsent" ((PVar "k") (PVar "v") (PAs "m" (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r")))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "insertAbsent") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "insertAbsent") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EVar "m"))))
(DTypeSig false "unionSplit" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "unionSplit" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionSplit" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionSplit" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "br")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EApp (EApp (EVar "unionSplit") (EVar "l")) (EVar "bl"))) (EApp (EApp (EVar "unionSplit") (EVar "r")) (EVar "br"))))))
(DTypeSig true "unionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWith" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "b")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "a"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "x") (PVar "y")) (EApp (EApp (EVar "f") (EVar "y")) (EVar "x")))) (EVar "k")) (EVar "w")) (EVar "acc")))) (EVar "a")) (EVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "a")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EVar "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "unionWithSplit") (EVar "f")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "setWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "setWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "setWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig false "unionWithSplit" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWithSplit" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionWithSplit" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionWithSplit" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EVar "splitLookup") (EVar "k")) (EVar "b"))) (DoLet false false (PVar "v2") (EMatch (EVar "found") (arm (PCon "None") () (EVar "v")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v2")) (EApp (EApp (EApp (EVar "unionWithSplit") (EVar "f")) (EVar "l")) (EVar "bl"))) (EApp (EApp (EApp (EVar "unionWithSplit") (EVar "f")) (EVar "r")) (EVar "br"))))))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "difference" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "difference" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "difference" ((PVar "a") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "al") (PVar "ar")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "link2") (EApp (EApp (EVar "difference") (EVar "al")) (EVar "l"))) (EApp (EApp (EVar "difference") (EVar "ar")) (EVar "r"))))))
(DTypeSig true "intersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "intersectionWith" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "intersectionWith" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "intersectionWith" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EVar "splitLookup") (EVar "k")) (EVar "b"))) (DoLet false false (PVar "l2") (EApp (EApp (EApp (EVar "intersectionWith") (EVar "f")) (EVar "l")) (EVar "bl"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EVar "intersectionWith") (EVar "f")) (EVar "r")) (EVar "br"))) (DoExpr (EMatch (EVar "found") (arm (PCon "None") () (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "l2")) (EVar "r2")))))))
(DTypeSig true "intersection" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "intersection" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "intersectionWith") (ELam ((PVar "x") PWild) (EVar "x"))) (EVar "a")) (EVar "b")))
(DImpl true "Mappable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "map" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "map" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EVar "f") (EVar "v"))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "r"))))))
(DImpl true "Filterable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "filterMap" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "filterMap" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "r"))) (DoExpr (EMatch (EApp (EVar "f") (EVar "v")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "w")) (EVar "l2")) (EVar "r2"))) (arm (PCon "None") () (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2")))))))))
(DImpl true "Foldable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "fold" ((PVar "f") (PVar "z") (PVar "m")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") PWild (PVar "v")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "v")))) (EVar "z")) (EVar "m"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam (PWild (PVar "v") (PVar "acc")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "acc")))) (EVar "z")) (EVar "m"))) (im "toList" ((PVar "m")) (EApp (EVar "values") (EVar "m"))) (im "isEmpty" ((PCon "Tip")) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PVar "m")) (EApp (EVar "size") (EVar "m")))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "a"))) (EApp (EVar "entries") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k"))) (req "Ord" ((TyVar "v")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "entries") (EVar "a"))) (EApp (EVar "entries") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayMapEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayMapEntries" ((PVar "es")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "intersperse") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))) (EVar "es")))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v")))) ((im "display" ((PVar "m")) (EMatch (EApp (EVar "entries") (EVar "m")) (arm (PList) () (ELit (LString "Map {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "Map { ")) (EApp (EVar "display") (EApp (EVar "displayMapEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyVar "k") (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "fromEntries" ((PVar "es")) (EApp (EVar "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allKeys") (ELam ((PVar "lk")) (EApp (EApp (EVar "lt") (EVar "lk")) (EVar "k")))) (EVar "l")) (EApp (EApp (EVar "allKeys") (ELam ((PVar "gk")) (EApp (EApp (EVar "gt") (EVar "gk")) (EVar "k")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EVar "wellFormed") (EVar "l"))) (EApp (EVar "wellFormed") (EVar "r"))))))
(DTypeSig false "allKeys" (TyFun (TyFun (TyVar "k") (TyCon "Bool")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "allKeys" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allKeys" ((PVar "p") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "k")) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")) (EApp (EVar "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "xs"))))
(DProp false "keys come out strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "ascending") (EApp (EVar "keys") (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "insert then lookup returns the inserted value" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EApp (EVar "fromList") (EVar "xs"))))) (EApp (EVar "Some") (EVar "v"))))
(DProp false "insert preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "delete removes the key and preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EVar "delete") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "k")) (EVar "m"))) (EApp (EVar "wellFormed") (EVar "m"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "union") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys")))))
(DProp false "union is left-biased on shared keys" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EApp (EVar "set") (EVar "k")) (ELit (LInt 1))) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "set") (EVar "k")) (ELit (LInt 2))) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EApp (EApp (EVar "union") (EVar "l")) (EVar "r")))) (EApp (EVar "Some") (ELit (LInt 1)))))))
(DTypeSig false "naiveUnion" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveUnion" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveUnionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "naiveUnionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveDifference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveDifference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig false "naiveIntersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "naiveIntersectionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EApp (EVar "naiveIntersectStep") (EVar "f")) (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "naiveIntersectStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))))
(DFunDef false "naiveIntersectStep" ((PVar "f") (PVar "b") (PVar "k") (PVar "v") (PVar "acc")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "b")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EVar "set") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "acc")))))
(DTypeSig false "naiveFilterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyCon "Bool"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveFilterWithKey" ((PVar "p") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EVar "naiveFilterStep") (EVar "p"))) (EVar "Tip")) (EVar "m")))
(DTypeSig false "naiveFilterStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyCon "Bool"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "naiveFilterStep" ((PVar "p") (PVar "k") (PVar "v") (PVar "acc")) (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "setOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "setOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "setOld" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "setOld") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "setOld") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig false "insertWithOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWithOld" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWithOld" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "insertWithOld") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "insertWithOld") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig false "deleteOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "deleteOld" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteOld" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EVar "deleteOld") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EVar "deleteOld") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glueOld") (EVar "l")) (EVar "r")))))
(DTypeSig false "insertMinOld" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMinOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMinOld" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "insertMinOld") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMaxOld" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMaxOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMaxOld" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "insertMaxOld") (EVar "k")) (EVar "v")) (EVar "r"))))
(DTypeSig false "glueOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueOld" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glueOld" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glueOld" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMaxOld") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMinOld") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMaxOld" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxViewOld") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "l'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMinOld" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minViewOld") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "r'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))
(DTypeSig false "minViewOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minViewOld" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minViewOld" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minViewOld") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))))
(DTypeSig false "maxViewOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxViewOld" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxViewOld" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxViewOld") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))))
(DTypeSig false "getMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMinOld" ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "minViewOld") (EVar "m"))))
(DTypeSig false "getMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMaxOld" ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "maxViewOld") (EVar "m"))))
(DTypeSig false "deleteMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMinOld" ((PVar "m")) (EMatch (EApp (EVar "minViewOld") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig false "deleteMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMaxOld" ((PVar "m")) (EMatch (EApp (EVar "maxViewOld") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig false "sameShape" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "sameShape" ((PCon "Tip") (PCon "Tip")) (EVar "True"))
(DFunDef false "sameShape" ((PCon "Bin" (PVar "s1") (PVar "k1") (PVar "v1") (PVar "l1") (PVar "r1")) (PCon "Bin" (PVar "s2") (PVar "k2") (PVar "v2") (PVar "l2") (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "s1") (EVar "s2")) (EApp (EApp (EVar "eq") (EVar "k1")) (EVar "k2"))) (EApp (EApp (EVar "eq") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "sameShape") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EVar "sameShape") (EVar "r1")) (EVar "r2"))))
(DFunDef false "sameShape" (PWild PWild) (EVar "False"))
(DTypeSig false "foldInserts" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "foldInserts" ((PVar "step") (PList) (PVar "m")) (EVar "m"))
(DFunDef false "foldInserts" ((PVar "step") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "foldInserts") (EVar "step")) (EVar "rest")) (EApp (EApp (EApp (EVar "step") (EVar "k")) (EVar "v")) (EVar "m"))))
(DTypeSig false "foldDeletes" (TyFun (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))) (TyFun (TyApp (TyCon "List") (TyVar "k")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "foldDeletes" ((PVar "step") (PList) (PVar "m")) (EVar "m"))
(DFunDef false "foldDeletes" ((PVar "step") (PCons (PVar "k") (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "foldDeletes") (EVar "step")) (EVar "rest")) (EApp (EApp (EVar "step") (EVar "k")) (EVar "m"))))
(DTypeSig false "modKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "modKeys" ((PList)) (EListLit))
(DFunDef false "modKeys" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 8))) (EVar "v")) (EApp (EVar "modKeys") (EVar "rest"))))
(DTypeSig false "fstKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "fstKeys" ((PList)) (EListLit))
(DFunDef false "fstKeys" ((PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "::" (EVar "k") (EApp (EVar "fstKeys") (EVar "rest"))))
(DProp false "set builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (EVar "setOld")) (EVar "xs")) (EVar "Tip"))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "set on duplicate keys builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "ys")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (EVar "setOld")) (EVar "ys")) (EVar "Tip"))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "insertWith builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b")))) (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "ys")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EApp (EVar "insertWithOld") (ELam ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b")))) (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "ys")) (EVar "Tip"))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "insertMin and insertMax match the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (DoLet false false (PVar "gotMax") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMinOld") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (EApp (EApp (EVar "sameShape") (EVar "gotMax")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMaxOld") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip")))))))
(DProp false "delete matches the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ks" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "ys")) (EVar "Tip"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldDeletes") (EVar "delete")) (EVar "ks")) (EApp (EApp (EApp (EVar "foldDeletes") (EVar "delete")) (EApp (EVar "fstKeys") (EVar "ys"))) (EVar "base")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldDeletes") (EVar "deleteOld")) (EVar "ks")) (EApp (EApp (EApp (EVar "foldDeletes") (EVar "deleteOld")) (EApp (EVar "fstKeys") (EVar "ys"))) (EVar "base")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DTypeSig false "minChainOk" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "minChainOk" ((PVar "got") (PVar "old")) (EIf (EApp (EVar "isEmpty") (EVar "old")) (EApp (EVar "isEmpty") (EVar "got")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EVar "old")) (EApp (EVar "wellFormed") (EVar "got"))) (EApp (EApp (EVar "minChainOk") (EApp (EVar "deleteMin") (EVar "got"))) (EApp (EVar "deleteMinOld") (EVar "old"))))))
(DTypeSig false "maxChainOk" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "maxChainOk" ((PVar "got") (PVar "old")) (EIf (EApp (EVar "isEmpty") (EVar "old")) (EApp (EVar "isEmpty") (EVar "got")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EVar "got")) (EVar "old")) (EApp (EVar "wellFormed") (EVar "got"))) (EApp (EApp (EVar "maxChainOk") (EApp (EVar "deleteMax") (EVar "got"))) (EApp (EVar "deleteMaxOld") (EVar "old"))))))
(DTypeSig false "glueAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "glueAgrees" ((PCon "Tip")) (EVar "True"))
(DFunDef false "glueAgrees" ((PCon "Bin" PWild PWild PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameShape") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r"))) (EApp (EApp (EVar "glueOld") (EVar "l")) (EVar "r"))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))) (EApp (EVar "glueAgrees") (EVar "l"))) (EApp (EVar "glueAgrees") (EVar "r"))))
(DTypeSig false "minViewAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "minViewAgrees" ((PVar "m")) (EMatch (EApp (EVar "minView") (EVar "m")) (arm (PCon "None") () (EApp (EVar "isEmpty") (EVar "m"))) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "rest"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "getMinOld") (EVar "m"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v")))) (EApp (EApp (EVar "sameShape") (EVar "rest")) (EApp (EVar "deleteMinOld") (EVar "m")))) (EApp (EVar "wellFormed") (EVar "rest"))))))
(DTypeSig false "maxViewAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "maxViewAgrees" ((PVar "m")) (EMatch (EApp (EVar "maxView") (EVar "m")) (arm (PCon "None") () (EApp (EVar "isEmpty") (EVar "m"))) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "rest"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "getMaxOld") (EVar "m"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v")))) (EApp (EApp (EVar "sameShape") (EVar "rest")) (EApp (EVar "deleteMaxOld") (EVar "m")))) (EApp (EVar "wellFormed") (EVar "rest"))))))
(DProp false "deleteMin matches the balance-only body shape at every step" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "minChainOk") (EVar "m")) (EVar "m")))))
(DProp false "deleteMax matches the balance-only body shape at every step" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "maxChainOk") (EVar "m")) (EVar "m")))))
(DProp false "getMin, getMax, minView and maxView agree with the balance-only bodies" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "getMin") (EVar "m"))) (EApp (EVar "getMinOld") (EVar "m"))) (EApp (EApp (EVar "eq") (EApp (EVar "getMax") (EVar "m"))) (EApp (EVar "getMaxOld") (EVar "m")))) (EApp (EVar "minViewAgrees") (EVar "m"))) (EApp (EVar "maxViewAgrees") (EVar "m"))))))
(DProp false "glue matches the balance-only body shape at every node" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBinOp "&&" (EApp (EVar "glueAgrees") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EVar "xs")) (EVar "Tip"))) (EApp (EVar "glueAgrees") (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "glue on duplicate-heavy inserts matches the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "glueAgrees") (EApp (EApp (EApp (EVar "foldInserts") (EVar "set")) (EApp (EVar "modKeys") (EVar "xs"))) (EVar "Tip"))))
(DTypeSig false "naiveFromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "naiveFromList" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "Tip")) (EVar "xs")))
(DProp false "fromList agrees with naive fold-insert" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EVar "fromList") (EVar "xs")))) (EApp (EVar "entries") (EApp (EVar "naiveFromList") (EVar "xs")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "fromList agrees with naive on sorted input" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "sort") (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EVar "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EVar "naiveFromList") (EVar "ys")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted duplicate-heavy input" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "sort") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EBinOp "%" (EApp (EVar "fst") (EVar "p")) (ELit (LInt 50))) (EApp (EVar "snd") (EVar "p"))))) (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EVar "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EVar "naiveFromList") (EVar "ys")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted prefix then unsorted tail" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EVar "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EVar "naiveFromList") (EVar "ys")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted prefix then duplicate-heavy tail" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EBinOp "%" (EApp (EVar "fst") (EVar "p")) (ELit (LInt 50))) (EApp (EVar "snd") (EVar "p"))))) (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EVar "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EVar "naiveFromList") (EVar "ys")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "a later pair overrides an entry from the ascending prefix" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EListLit (ETuple (EVar "k") (EVar "v"))))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EApp (EVar "fromList") (EVar "ys")))) (EApp (EVar "Some") (EVar "v"))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "union agrees with naive fold-insert" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EApp (EVar "union") (EVar "a")) (EVar "b")))) (EApp (EVar "entries") (EApp (EApp (EVar "naiveUnion") (EVar "a")) (EVar "b")))))))
(DProp false "union with a tiny side agrees with naive in both orders" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "big") (EApp (EVar "fromList") (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)) (EVar "xs")))) (DoLet false false (PVar "small") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 64))) (EVar "v")))) (EApp (EApp (EVar "take") (ELit (LInt 2))) (EVar "ys"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EApp (EVar "union") (EVar "big")) (EVar "small")))) (EApp (EVar "entries") (EApp (EApp (EVar "naiveUnion") (EVar "big")) (EVar "small")))) (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EApp (EVar "union") (EVar "small")) (EVar "big")))) (EApp (EVar "entries") (EApp (EApp (EVar "naiveUnion") (EVar "small")) (EVar "big"))))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "union") (EVar "big")) (EVar "small")))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "union") (EVar "small")) (EVar "big")))))))
(DProp false "unionWith with a tiny side agrees with naive in both orders" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "big") (EApp (EVar "fromList") (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)) (EVar "xs")))) (DoLet false false (PVar "small") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 64))) (EVar "v")))) (EApp (EApp (EVar "take") (ELit (LInt 2))) (EVar "ys"))))) (DoLet false false (PVar "f") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "x")) (EVar "y")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EApp (EApp (EVar "unionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "naiveUnionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EApp (EApp (EApp (EVar "unionWith") (EVar "f")) (EVar "small")) (EVar "big")))) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "naiveUnionWith") (EVar "f")) (EVar "small")) (EVar "big"))))) (EApp (EVar "wellFormed") (EApp (EApp (EApp (EVar "unionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EVar "wellFormed") (EApp (EApp (EApp (EVar "unionWith") (EVar "f")) (EVar "small")) (EVar "big")))))))
(DData Private "Tagged" () ((variant "Tagged" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl false "Eq" ((TyCon "Tagged")) () ((im "eq" ((PCon "Tagged" (PVar "a") PWild) (PCon "Tagged" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Ord" ((TyCon "Tagged")) () ((im "compare" ((PCon "Tagged" (PVar "a") PWild) (PCon "Tagged" (PVar "b") PWild)) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))))
(DTypeSig false "taggedAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Tagged")) (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "taggedAt" ((PVar "n") (PVar "m")) (EApp (EApp (EVar "filterMap") (EApp (EVar "tagIfAt") (EVar "n"))) (EApp (EVar "keys") (EVar "m"))))
(DTypeSig false "tagIfAt" (TyFun (TyCon "Int") (TyFun (TyCon "Tagged") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tagIfAt" ((PVar "n") (PCon "Tagged" (PVar "i") (PVar "t"))) (EIf (EBinOp "==" (EVar "i") (EVar "n")) (EApp (EVar "Some") (EVar "t")) (EVar "None")))
(DProp false "union and unionWith keep the first map's key on a shared key" ((pp "j" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "j") (ELit (LInt 64))) (ELit (LInt 64))) (ELit (LInt 64)))) (DoLet false false (PVar "big") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "Tagged") (EVar "i")) (ELit (LInt 0))) (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (DoLet false false (PVar "small") (EApp (EVar "fromList") (EListLit (ETuple (EApp (EApp (EVar "Tagged") (EVar "n")) (ELit (LInt 1))) (ELit (LInt 7)))))) (DoLet false false (PVar "sameSize") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "Tagged") (EVar "i")) (ELit (LInt 1))) (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EVar "union") (EVar "small")) (EVar "big")))) (EListLit (ELit (LInt 1)))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EVar "union") (EVar "big")) (EVar "small")))) (EListLit (ELit (LInt 0))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EVar "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "small")) (EVar "big")))) (EListLit (ELit (LInt 1))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EVar "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "big")) (EVar "small")))) (EListLit (ELit (LInt 0))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EVar "union") (EVar "sameSize")) (EVar "big")))) (EListLit (ELit (LInt 1))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EVar "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "sameSize")) (EVar "big")))) (EListLit (ELit (LInt 1))))))))
(DProp false "union keys stay strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "ascending") (EApp (EVar "keys") (EApp (EApp (EVar "union") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys"))))))
(DProp false "unionWith agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "naiveUnionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "difference agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "difference") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EVar "naiveDifference") (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "intersectionWith agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "intersectionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "naiveIntersectionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "intersection is the left-biased intersectionWith" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EVar "intersectionWith") (ELam ((PVar "x") PWild) (EVar "x"))) (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "intersection keeps exactly the shared keys, with the left value" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "k")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "get") (EVar "k")) (EVar "b"))) (EBinOp "==" (EApp (EApp (EVar "get") (EVar "k")) (EVar "got")) (EApp (EApp (EVar "get") (EVar "k")) (EVar "a")))))) (EApp (EVar "keys") (EVar "got"))) (EApp (EApp (EVar "all") (ELam ((PVar "k")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isSome") (EApp (EApp (EVar "get") (EVar "k")) (EVar "b")))) (EApp (EVar "isSome") (EApp (EApp (EVar "get") (EVar "k")) (EVar "got")))))) (EApp (EVar "keys") (EVar "a")))))))
(DProp false "Filterable: filterMap Some is the identity" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "filterMap") (ELam ((PVar "v")) (EApp (EVar "Some") (EVar "v")))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EVar "m"))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "Filterable: filter agrees with filterWithKey ignoring the key" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "filter") (ELam ((PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EVar "filterWithKey") (ELam (PWild (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "filterWithKey agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "filterWithKey") (ELam ((PVar "k") (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EVar "naiveFilterWithKey") (ELam ((PVar "k") (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "splitAt partitions around the key and both halves stay well-formed" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "below")) (EApp (EVar "wellFormed") (EVar "above"))) (EApp (EApp (EVar "allKeys") (ELam ((PVar "bk")) (EApp (EApp (EVar "lt") (EVar "bk")) (EVar "k")))) (EVar "below"))) (EApp (EApp (EVar "allKeys") (ELam ((PVar "ak")) (EApp (EApp (EVar "gt") (EVar "ak")) (EVar "k")))) (EVar "above"))))))
(DProp false "link rebuilds a well-formed map from a split" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (ELit (LInt 0))) (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "rebuilt")) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EVar "rebuilt"))) (EApp (EVar "Some") (ELit (LInt 0))))))))
(DProp false "link2 rejoins a split without its key" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "link2") (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "rebuilt")) (EApp (EApp (EVar "eq") (EApp (EVar "entries") (EVar "rebuilt"))) (EApp (EVar "entries") (EApp (EApp (EVar "delete") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))))))))
(DProp false "entriesFrom is the limited run of entries from the start key" ((pp "k" (TyCon "Int")) (pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "entriesFrom") (EApp (EVar "Some") (EVar "k"))) (EApp (EVar "Some") (EVar "n"))) (EVar "m"))) (EApp (EApp (EVar "take") (EVar "n")) (EApp (EApp (EVar "filter") (ELam ((PTuple (PVar "key") PWild)) (EApp (EApp (EVar "gte") (EVar "key")) (EVar "k")))) (EApp (EVar "entries") (EVar "m"))))))))
(DProp false "entriesFrom bounded on one side only still agrees with entries" ((pp "k" (TyCon "Int")) (pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "entriesFrom") (EVar "None")) (EVar "None")) (EVar "m"))) (EApp (EVar "entries") (EVar "m"))) (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "entriesFrom") (EVar "None")) (EApp (EVar "Some") (EVar "n"))) (EVar "m"))) (EApp (EApp (EVar "take") (EVar "n")) (EApp (EVar "entries") (EVar "m"))))) (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "entriesFrom") (EApp (EVar "Some") (EVar "k"))) (EVar "None")) (EVar "m"))) (EApp (EApp (EVar "filter") (ELam ((PTuple (PVar "key") PWild)) (EApp (EApp (EVar "gte") (EVar "key")) (EVar "k")))) (EApp (EVar "entries") (EVar "m"))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Option" false) (mem "FromEntries" false) (mem "Index" false))))
(DUse false (UseGroup ("list") ((mem "intersperse" false) (mem "reverse" false) (mem "take" false) (mem "sort" false) (mem "sortBy" false))))
(DData Public "Map" ("k" "v") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "bin" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balance" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balanceL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EApp (EVar "size") (EVar "r")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r")))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PCon "Tip")) (EIf (EBinOp "<=" (EVar "sl") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EVar "sl") (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip")) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip"))))
(DFunDef false "balanceL" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp ">" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DTypeSig false "balanceR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EApp (EVar "size") (EVar "l")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "Tip")))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PCon "Tip") (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "<=" (EVar "sr") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EVar "sr") (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "r"))))
(DFunDef false "balanceR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") PWild PWild PWild PWild)) (PAs "r" (PCon "Bin" (PVar "sr") PWild PWild PWild PWild))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))) (EBinOp ">" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DTypeSig false "rotateL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EApp (EVar "singleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" PWild PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EApp (EVar "singleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Map.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Map.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Map.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Map.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "singleton" ((PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "n") (EApp (EDictApp "ascendingRunLength") (EVar "xs"))) (DoLet false false (PTuple (PVar "m") (PVar "rest")) (EApp (EApp (EVar "buildAscending") (EVar "n")) (EVar "xs"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (EVar "m")) (arm PWild () (EApp (EDictApp "fromUnsorted") (EVar "xs")))))))
(DTypeSig false "fromUnsorted" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromUnsorted" ((PVar "xs")) (EBlock (DoLet false false (PVar "ys") (EApp (EDictApp "dedupeLast") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "a") PWild) (PTuple (PVar "b") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))) (EVar "xs")))) (DoExpr (EApp (EVar "fst") (EApp (EApp (EVar "buildAscending") (EApp (EMethodRef "length") (EVar "ys"))) (EVar "ys"))))))
(DTypeSig false "dedupeLast" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))
(DFunDef false "dedupeLast" ((PList)) (EListLit))
(DFunDef false "dedupeLast" ((PList (PVar "p"))) (EListLit (EVar "p")))
(DFunDef false "dedupeLast" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PAs "rest" (PCons (PTuple (PVar "k2") PWild) PWild)))) (EIf (EApp (EApp (EMethodRef "eq") (EVar "k1")) (EVar "k2")) (EApp (EDictApp "dedupeLast") (EVar "rest")) (EBinOp "::" (ETuple (EVar "k1") (EVar "v1")) (EApp (EDictApp "dedupeLast") (EVar "rest")))))
(DTypeSig false "ascendingRunLength" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Int"))))
(DFunDef false "ascendingRunLength" ((PList)) (ELit (LInt 0)))
(DFunDef false "ascendingRunLength" ((PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EApp (EApp (EApp (EDictApp "ascendingRunFrom") (EVar "k")) (ELit (LInt 1))) (EVar "rest")))
(DTypeSig false "ascendingRunFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Int"))))))
(DFunDef false "ascendingRunFrom" (PWild (PVar "n") (PList)) (EVar "n"))
(DFunDef false "ascendingRunFrom" ((PVar "prev") (PVar "n") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EApp (EApp (EMethodRef "lt") (EVar "prev")) (EVar "k")) (EApp (EApp (EApp (EDictApp "ascendingRunFrom") (EVar "k")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EVar "n")))
(DTypeSig false "buildAscending" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "buildAscending" ((PVar "n") (PVar "xs")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EVar "Tip") (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "buildNode") (EVar "n")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildNode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "buildNode" ((PVar "n") (PVar "xs")) (EBlock (DoLet false false (PVar "nl") (EBinOp "/" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (ELit (LInt 2)))) (DoLet false false (PVar "nr") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "nl"))) (DoLet false false (PTuple (PVar "l") (PVar "rest")) (EApp (EApp (EVar "buildAscending") (EVar "nl")) (EVar "xs"))) (DoExpr (EMatch (EVar "rest") (arm (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest2")) () (EBlock (DoLet false false (PTuple (PVar "r") (PVar "rest3")) (EApp (EApp (EVar "buildAscending") (EVar "nr")) (EVar "rest2"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "n")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EVar "rest3"))))) (arm (PList) () (EApp (EVar "panic") (ELit (LString "Map.buildNode: fewer pairs than the run length"))))))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "isEmpty#shadow" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty#shadow" ((PCon "Tip")) (EVar "True"))
(DFunDef false "isEmpty#shadow" (PWild) (EVar "False"))
(DTypeSig true "get" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "get" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EApp (EVar "Some") (EVar "v")))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Ord" ((TyVar "k"))) (req "Debug" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "key not found: ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "k")))) (ELit (LString "")))))))))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PCon "Tip")) (EVar "d"))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EDictApp "findWithDefault") (EVar "d")) (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EDictApp "findWithDefault") (EVar "d")) (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "v"))))
(DTypeSig true "set" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig true "insertWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "adjust" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyVar "v")) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "adjust") (EVar "f")) (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "adjust") (EVar "f")) (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EVar "f") (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "delete" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "getMax") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k")) (EVar "v")) (EApp (EVar "deleteMax") (EVar "l"))) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "getMin") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k")) (EVar "v")) (EVar "l")) (EApp (EVar "deleteMin") (EVar "r"))))))
(DTypeSig true "minView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PVar "m")) (EMatch (EApp (EVar "getMin") (EVar "m")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EApp (EVar "deleteMin") (EVar "m")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PVar "m")) (EMatch (EApp (EVar "getMax") (EVar "m")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v"))) () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EApp (EVar "deleteMax") (EVar "m")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMin" ((PCon "Tip")) (EVar "None"))
(DFunDef false "getMin" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PCon "Tip") PWild)) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "getMin" ((PCon "Bin" PWild PWild PWild (PVar "l") PWild)) (EApp (EVar "getMin") (EVar "l")))
(DTypeSig true "getMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMax" ((PCon "Tip")) (EVar "None"))
(DFunDef false "getMax" ((PCon "Bin" PWild (PVar "k") (PVar "v") PWild (PCon "Tip"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "getMax" ((PCon "Bin" PWild PWild PWild PWild (PVar "r"))) (EApp (EVar "getMax") (EVar "r")))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMin" ((PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteMin" ((PCon "Bin" PWild PWild PWild (PCon "Tip") (PVar "r"))) (EVar "r"))
(DFunDef false "deleteMin" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k")) (EVar "v")) (EApp (EVar "deleteMin") (EVar "l"))) (EVar "r")))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMax" ((PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteMax" ((PCon "Bin" PWild PWild PWild (PVar "l") (PCon "Tip"))) (EVar "l"))
(DFunDef false "deleteMax" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k")) (EVar "v")) (EVar "l")) (EApp (EVar "deleteMax") (EVar "r"))))
(DTypeSig true "foldrWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig true "foldlWithKey" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "k")) (EVar "v"))) (EVar "r")))
(DTypeSig true "entries" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PVar "m")) (EApp (EApp (EVar "entriesOnto") (EVar "m")) (EListLit)))
(DTypeSig false "entriesOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))
(DFunDef false "entriesOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "entriesOnto" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "entriesOnto") (EVar "l")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "entriesOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "entriesFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "entriesFrom" ((PVar "start") (PVar "limit") (PVar "m")) (EBlock (DoLet false false (PCon "Scan" (PVar "taken") PWild PWild) (EApp (EApp (EApp (EDictApp "scanFrom") (EVar "start")) (EVar "m")) (EApp (EVar "scanStart") (EVar "limit")))) (DoExpr (EApp (EVar "reverse") (EVar "taken")))))
(DData Private "Scan" ("k" "v") ((variant "Scan" (ConPos (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Bool")))) ())
(DTypeSig false "scanDone" (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "scanDone" ((PCon "Scan" PWild PWild (PVar "done"))) (EVar "done"))
(DTypeSig false "scanStart" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v"))))
(DFunDef false "scanStart" ((PCon "None")) (EApp (EApp (EApp (EVar "Scan") (EListLit)) (EVar "None")) (EVar "False")))
(DFunDef false "scanStart" ((PCon "Some" (PVar "limit"))) (EApp (EApp (EApp (EVar "Scan") (EListLit)) (EApp (EVar "Some") (EVar "limit"))) (EBinOp "<=" (EVar "limit") (ELit (LInt 0)))))
(DTypeSig false "takeEntry" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "takeEntry" ((PVar "k") (PVar "v") (PCon "Scan" (PVar "taken") (PVar "remaining") PWild)) (EBlock (DoLet false false (PVar "kept") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "taken"))) (DoExpr (EMatch (EVar "remaining") (arm (PCon "None") () (EApp (EApp (EApp (EVar "Scan") (EVar "kept")) (EVar "None")) (EVar "False"))) (arm (PCon "Some" (PVar "left")) () (EApp (EApp (EApp (EVar "Scan") (EVar "kept")) (EApp (EVar "Some") (EBinOp "-" (EVar "left") (ELit (LInt 1))))) (EBinOp "<=" (EVar "left") (ELit (LInt 1)))))))))
(DTypeSig false "belowBound" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyCon "Bool")))))
(DFunDef false "belowBound" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "belowBound" ((PVar "k") (PCon "Some" (PVar "bound"))) (EApp (EApp (EMethodRef "lt") (EVar "k")) (EVar "bound")))
(DTypeSig false "scanFrom" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Option") (TyVar "k")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Scan") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "scanFrom" (PWild (PCon "Tip") (PVar "scan")) (EVar "scan"))
(DFunDef false "scanFrom" ((PVar "lo") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "scan")) (EIf (EApp (EVar "scanDone") (EVar "scan")) (EVar "scan") (EIf (EApp (EApp (EDictApp "belowBound") (EVar "k")) (EVar "lo")) (EApp (EApp (EApp (EDictApp "scanFrom") (EVar "lo")) (EVar "r")) (EVar "scan")) (EBlock (DoLet false false (PVar "afterLeft") (EApp (EApp (EApp (EDictApp "scanFrom") (EVar "lo")) (EVar "l")) (EVar "scan"))) (DoExpr (EIf (EApp (EVar "scanDone") (EVar "afterLeft")) (EVar "afterLeft") (EApp (EApp (EApp (EDictApp "scanFrom") (EVar "None")) (EVar "r")) (EApp (EApp (EApp (EVar "takeEntry") (EVar "k")) (EVar "v")) (EVar "afterLeft")))))))))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EVar "keysOnto") (EVar "m")) (EListLit)))
(DTypeSig false "keysOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyVar "k")) (TyApp (TyCon "List") (TyVar "k")))))
(DFunDef false "keysOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "keysOnto" ((PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "keysOnto") (EVar "l")) (EBinOp "::" (EVar "k") (EApp (EApp (EVar "keysOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EVar "valuesOnto") (EVar "m")) (EListLit)))
(DTypeSig false "valuesOnto" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyCon "List") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "valuesOnto" ((PCon "Tip") (PVar "acc")) (EVar "acc"))
(DFunDef false "valuesOnto" ((PCon "Bin" PWild PWild (PVar "v") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EVar "valuesOnto") (EVar "l")) (EBinOp "::" (EVar "v") (EApp (EApp (EVar "valuesOnto") (EVar "r")) (EVar "acc")))))
(DTypeSig true "mapWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "w")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w"))))))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "k")) (EVar "v"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "r"))))
(DTypeSig false "insertMin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMin" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMin" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMax" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMax" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMax" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "r"))))
(DTypeSig false "link" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "link" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "r")))
(DFunDef false "link" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "l")))
(DFunDef false "link" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" (PVar "sl") (PVar "kl") (PVar "vl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "kr") (PVar "vr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kr")) (EVar "vr")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kl")) (EVar "vl")) (EVar "ll")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "link2" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "link2" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "link2" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "link2" ((PAs "l" (PCon "Bin" (PVar "sl") (PVar "kl") (PVar "vl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "kr") (PVar "vr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kr")) (EVar "vr")) (EApp (EApp (EVar "link2") (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "kl")) (EVar "vl")) (EVar "ll")) (EApp (EApp (EVar "link2") (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitAt" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "splitAt" ((PVar "k") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "Tip")))
(DFunDef false "splitAt" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "l")) (EVar "below")) (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "r")))))
(DTypeSig false "splitLookup" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "splitLookup" ((PVar "k") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "None") (EVar "Tip")))
(DFunDef false "splitLookup" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EDictApp "splitLookup") (EVar "k")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EVar "found") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EDictApp "splitLookup") (EVar "k")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "link") (EVar "k2")) (EVar "v2")) (EVar "l")) (EVar "below")) (EVar "found") (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EApp (EVar "Some") (EVar "v2")) (EVar "r")))))
(DTypeSig true "filterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "filterWithKey" ((PVar "p") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "filterWithKey" ((PVar "p") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EDictApp "filterWithKey") (EVar "p")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EDictApp "filterWithKey") (EVar "p")) (EVar "r"))) (DoExpr (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))))))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "union" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "union" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "union" ((PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "b")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "a"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EDictApp "insertAbsent") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "a")) (EVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "a")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "unionSplit") (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "insertAbsent" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "insertAbsent" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertAbsent" ((PVar "k") (PVar "v") (PAs "m" (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r")))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "insertAbsent") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "insertAbsent") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EVar "m"))))
(DTypeSig false "unionSplit" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "unionSplit" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionSplit" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionSplit" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "br")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v")) (EApp (EApp (EDictApp "unionSplit") (EVar "l")) (EVar "bl"))) (EApp (EApp (EDictApp "unionSplit") (EVar "r")) (EVar "br"))))))
(DTypeSig true "unionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWith" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "b")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "a"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "w")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (ELam ((PVar "x") (PVar "y")) (EApp (EApp (EVar "f") (EVar "y")) (EVar "x")))) (EVar "k")) (EVar "w")) (EVar "acc")))) (EVar "a")) (EVar "b")) (EIf (EBinOp "<=" (EBinOp "*" (EApp (EVar "size") (EVar "a")) (ELit (LInt 16))) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") (PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EDictApp "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EDictApp "unionWithSplit") (EVar "f")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "setWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "setWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "setWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balanceL") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EDictApp "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balanceR") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EDictApp "setWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig false "unionWithSplit" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWithSplit" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "unionWithSplit" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "unionWithSplit" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EDictApp "splitLookup") (EVar "k")) (EVar "b"))) (DoLet false false (PVar "v2") (EMatch (EVar "found") (arm (PCon "None") () (EVar "v")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "unionWithSplit") (EVar "f")) (EVar "l")) (EVar "bl"))) (EApp (EApp (EApp (EDictApp "unionWithSplit") (EVar "f")) (EVar "r")) (EVar "br"))))))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "difference" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "difference" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "difference" ((PVar "a") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "al") (PVar "ar")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "link2") (EApp (EApp (EDictApp "difference") (EVar "al")) (EVar "l"))) (EApp (EApp (EDictApp "difference") (EVar "ar")) (EVar "r"))))))
(DTypeSig true "intersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "intersectionWith" ((PVar "f") (PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "intersectionWith" ((PVar "f") (PVar "a") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "intersectionWith" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EDictApp "splitLookup") (EVar "k")) (EVar "b"))) (DoLet false false (PVar "l2") (EApp (EApp (EApp (EDictApp "intersectionWith") (EVar "f")) (EVar "l")) (EVar "bl"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EDictApp "intersectionWith") (EVar "f")) (EVar "r")) (EVar "br"))) (DoExpr (EMatch (EVar "found") (arm (PCon "None") () (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "l2")) (EVar "r2")))))))
(DTypeSig true "intersection" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "intersection" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EDictApp "intersectionWith") (ELam ((PVar "x") PWild) (EVar "x"))) (EVar "a")) (EVar "b")))
(DImpl true "Mappable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "map" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "map" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EVar "f") (EVar "v"))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "l"))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "r"))))))
(DImpl true "Filterable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "filterMap" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "filterMap" ((PVar "f") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "r"))) (DoExpr (EMatch (EApp (EVar "f") (EVar "v")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (EVar "w")) (EVar "l2")) (EVar "r2"))) (arm (PCon "None") () (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2")))))))))
(DImpl true "Foldable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "fold" ((PVar "f") (PVar "z") (PVar "m")) (EApp (EApp (EApp (EVar "foldlWithKey") (ELam ((PVar "acc") PWild (PVar "v")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "v")))) (EVar "z")) (EVar "m"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam (PWild (PVar "v") (PVar "acc")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "acc")))) (EVar "z")) (EVar "m"))) (im "toList" ((PVar "m")) (EApp (EVar "values") (EVar "m"))) (im "isEmpty" ((PCon "Tip")) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PVar "m")) (EApp (EVar "size") (EVar "m")))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "a"))) (EApp (EVar "entries") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k"))) (req "Ord" ((TyVar "v")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "entries") (EVar "a"))) (EApp (EVar "entries") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayMapEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayMapEntries" ((PVar "es")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "intersperse") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))) (EVar "es")))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v")))) ((im "display" ((PVar "m")) (EMatch (EApp (EVar "entries") (EVar "m")) (arm (PList) () (ELit (LString "Map {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "Map { ")) (EApp (EMethodRef "display") (EApp (EDictApp "displayMapEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyVar "k") (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "fromEntries" ((PVar "es")) (EApp (EDictApp "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allKeys") (ELam ((PVar "lk")) (EApp (EApp (EMethodRef "lt") (EVar "lk")) (EVar "k")))) (EVar "l")) (EApp (EApp (EVar "allKeys") (ELam ((PVar "gk")) (EApp (EApp (EMethodRef "gt") (EVar "gk")) (EVar "k")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EDictApp "wellFormed") (EVar "l"))) (EApp (EDictApp "wellFormed") (EVar "r"))))))
(DTypeSig false "allKeys" (TyFun (TyFun (TyVar "k") (TyCon "Bool")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "allKeys" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allKeys" ((PVar "p") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "k")) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")) (EApp (EDictApp "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "xs"))))
(DProp false "keys come out strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "ascending") (EApp (EVar "keys") (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "insert then lookup returns the inserted value" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EApp (EDictApp "fromList") (EVar "xs"))))) (EApp (EVar "Some") (EVar "v"))))
(DProp false "insert preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "delete removes the key and preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EDictApp "delete") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "m"))) (EApp (EDictApp "wellFormed") (EVar "m"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "union") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys")))))
(DProp false "union is left-biased on shared keys" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (ELit (LInt 1))) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (ELit (LInt 2))) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EApp (EApp (EDictApp "union") (EVar "l")) (EVar "r")))) (EApp (EVar "Some") (ELit (LInt 1)))))))
(DTypeSig false "naiveUnion" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveUnion" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveUnionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "naiveUnionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveDifference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveDifference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig false "naiveIntersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "naiveIntersectionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EApp (EDictApp "naiveIntersectStep") (EVar "f")) (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "naiveIntersectStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))))
(DFunDef false "naiveIntersectStep" ((PVar "f") (PVar "b") (PVar "k") (PVar "v") (PVar "acc")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "b")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "acc")))))
(DTypeSig false "naiveFilterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyCon "Bool"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "naiveFilterWithKey" ((PVar "p") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EDictApp "naiveFilterStep") (EVar "p"))) (EVar "Tip")) (EVar "m")))
(DTypeSig false "naiveFilterStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyCon "Bool"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "naiveFilterStep" ((PVar "p") (PVar "k") (PVar "v") (PVar "acc")) (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "setOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "setOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "setOld" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "setOld") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "setOld") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig false "insertWithOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWithOld" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWithOld" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EDictApp "insertWithOld") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EDictApp "insertWithOld") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig false "deleteOld" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "deleteOld" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "deleteOld" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EDictApp "deleteOld") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EDictApp "deleteOld") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glueOld") (EVar "l")) (EVar "r")))))
(DTypeSig false "insertMinOld" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMinOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMinOld" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "insertMinOld") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMaxOld" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "insertMaxOld" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertMaxOld" ((PVar "k") (PVar "v") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "insertMaxOld") (EVar "k")) (EVar "v")) (EVar "r"))))
(DTypeSig false "glueOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueOld" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glueOld" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glueOld" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMaxOld") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMinOld") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMaxOld" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxViewOld") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "l'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMinOld" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minViewOld") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "r'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))
(DTypeSig false "minViewOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minViewOld" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minViewOld" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minViewOld") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))))
(DTypeSig false "maxViewOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxViewOld" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxViewOld" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxViewOld") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))))
(DTypeSig false "getMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMinOld" ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "minViewOld") (EVar "m"))))
(DTypeSig false "getMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMaxOld" ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "maxViewOld") (EVar "m"))))
(DTypeSig false "deleteMinOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMinOld" ((PVar "m")) (EMatch (EApp (EVar "minViewOld") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig false "deleteMaxOld" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMaxOld" ((PVar "m")) (EMatch (EApp (EVar "maxViewOld") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig false "sameShape" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "sameShape" ((PCon "Tip") (PCon "Tip")) (EVar "True"))
(DFunDef false "sameShape" ((PCon "Bin" (PVar "s1") (PVar "k1") (PVar "v1") (PVar "l1") (PVar "r1")) (PCon "Bin" (PVar "s2") (PVar "k2") (PVar "v2") (PVar "l2") (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "s1") (EVar "s2")) (EApp (EApp (EMethodRef "eq") (EVar "k1")) (EVar "k2"))) (EApp (EApp (EMethodRef "eq") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EDictApp "sameShape") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EDictApp "sameShape") (EVar "r1")) (EVar "r2"))))
(DFunDef false "sameShape" (PWild PWild) (EVar "False"))
(DTypeSig false "foldInserts" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "foldInserts" ((PVar "step") (PList) (PVar "m")) (EVar "m"))
(DFunDef false "foldInserts" ((PVar "step") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "foldInserts") (EVar "step")) (EVar "rest")) (EApp (EApp (EApp (EVar "step") (EVar "k")) (EVar "v")) (EVar "m"))))
(DTypeSig false "foldDeletes" (TyFun (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))) (TyFun (TyApp (TyCon "List") (TyVar "k")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "foldDeletes" ((PVar "step") (PList) (PVar "m")) (EVar "m"))
(DFunDef false "foldDeletes" ((PVar "step") (PCons (PVar "k") (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "foldDeletes") (EVar "step")) (EVar "rest")) (EApp (EApp (EVar "step") (EVar "k")) (EVar "m"))))
(DTypeSig false "modKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "modKeys" ((PList)) (EListLit))
(DFunDef false "modKeys" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 8))) (EVar "v")) (EApp (EVar "modKeys") (EVar "rest"))))
(DTypeSig false "fstKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "fstKeys" ((PList)) (EListLit))
(DFunDef false "fstKeys" ((PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "::" (EVar "k") (EApp (EVar "fstKeys") (EVar "rest"))))
(DProp false "set builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "setOld")) (EVar "xs")) (EVar "Tip"))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "set on duplicate keys builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "ys")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "setOld")) (EVar "ys")) (EVar "Tip"))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "insertWith builds the same tree shape as the balance-only body" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (ELam ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b")))) (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "ys")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EApp (EDictApp "insertWithOld") (ELam ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b")))) (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "ys")) (EVar "Tip"))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "insertMin and insertMax match the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMin") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (DoLet false false (PVar "gotMax") (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMax") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMinOld") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip"))) (EApp (EApp (EDictApp "sameShape") (EVar "gotMax")) (EApp (EApp (EApp (EVar "foldInserts") (ELam ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "insertMaxOld") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "xs")) (EVar "Tip")))))))
(DProp false "delete matches the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ks" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "modKeys") (EVar "xs"))) (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "ys")) (EVar "Tip"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EVar "foldDeletes") (EDictApp "delete")) (EVar "ks")) (EApp (EApp (EApp (EVar "foldDeletes") (EDictApp "delete")) (EApp (EVar "fstKeys") (EVar "ys"))) (EVar "base")))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EApp (EApp (EApp (EVar "foldDeletes") (EDictApp "deleteOld")) (EVar "ks")) (EApp (EApp (EApp (EVar "foldDeletes") (EDictApp "deleteOld")) (EApp (EVar "fstKeys") (EVar "ys"))) (EVar "base")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DTypeSig false "minChainOk" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "minChainOk" ((PVar "got") (PVar "old")) (EIf (EApp (EVar "isEmpty#shadow") (EVar "old")) (EApp (EVar "isEmpty#shadow") (EVar "got")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EVar "old")) (EApp (EDictApp "wellFormed") (EVar "got"))) (EApp (EApp (EVar "minChainOk") (EApp (EVar "deleteMin") (EVar "got"))) (EApp (EVar "deleteMinOld") (EVar "old"))))))
(DTypeSig false "maxChainOk" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "maxChainOk" ((PVar "got") (PVar "old")) (EIf (EApp (EVar "isEmpty#shadow") (EVar "old")) (EApp (EVar "isEmpty#shadow") (EVar "got")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EVar "got")) (EVar "old")) (EApp (EDictApp "wellFormed") (EVar "got"))) (EApp (EApp (EVar "maxChainOk") (EApp (EVar "deleteMax") (EVar "got"))) (EApp (EVar "deleteMaxOld") (EVar "old"))))))
(DTypeSig false "glueAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "glueAgrees" ((PCon "Tip")) (EVar "True"))
(DFunDef false "glueAgrees" ((PCon "Bin" PWild PWild PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EDictApp "sameShape") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r"))) (EApp (EApp (EVar "glueOld") (EVar "l")) (EVar "r"))) (EApp (EDictApp "wellFormed") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))) (EApp (EVar "glueAgrees") (EVar "l"))) (EApp (EVar "glueAgrees") (EVar "r"))))
(DTypeSig false "minViewAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "minViewAgrees" ((PVar "m")) (EMatch (EApp (EVar "minView") (EVar "m")) (arm (PCon "None") () (EApp (EVar "isEmpty#shadow") (EVar "m"))) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "rest"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "getMinOld") (EVar "m"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v")))) (EApp (EApp (EDictApp "sameShape") (EVar "rest")) (EApp (EVar "deleteMinOld") (EVar "m")))) (EApp (EDictApp "wellFormed") (EVar "rest"))))))
(DTypeSig false "maxViewAgrees" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "maxViewAgrees" ((PVar "m")) (EMatch (EApp (EVar "maxView") (EVar "m")) (arm (PCon "None") () (EApp (EVar "isEmpty#shadow") (EVar "m"))) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "rest"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "getMaxOld") (EVar "m"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v")))) (EApp (EApp (EDictApp "sameShape") (EVar "rest")) (EApp (EVar "deleteMaxOld") (EVar "m")))) (EApp (EDictApp "wellFormed") (EVar "rest"))))))
(DProp false "deleteMin matches the balance-only body shape at every step" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "minChainOk") (EVar "m")) (EVar "m")))))
(DProp false "deleteMax matches the balance-only body shape at every step" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "maxChainOk") (EVar "m")) (EVar "m")))))
(DProp false "getMin, getMax, minView and maxView agree with the balance-only bodies" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "xs")) (EVar "Tip"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "getMin") (EVar "m"))) (EApp (EVar "getMinOld") (EVar "m"))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "getMax") (EVar "m"))) (EApp (EVar "getMaxOld") (EVar "m")))) (EApp (EVar "minViewAgrees") (EVar "m"))) (EApp (EVar "maxViewAgrees") (EVar "m"))))))
(DProp false "glue matches the balance-only body shape at every node" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBinOp "&&" (EApp (EVar "glueAgrees") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EVar "xs")) (EVar "Tip"))) (EApp (EVar "glueAgrees") (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "glue on duplicate-heavy inserts matches the balance-only body shape" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "glueAgrees") (EApp (EApp (EApp (EVar "foldInserts") (EDictApp "set")) (EApp (EVar "modKeys") (EVar "xs"))) (EVar "Tip"))))
(DTypeSig false "naiveFromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "naiveFromList" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "Tip")) (EVar "xs")))
(DProp false "fromList agrees with naive fold-insert" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EDictApp "fromList") (EVar "xs")))) (EApp (EVar "entries") (EApp (EDictApp "naiveFromList") (EVar "xs")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "fromList agrees with naive on sorted input" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "sort") (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EDictApp "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EDictApp "naiveFromList") (EVar "ys")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted duplicate-heavy input" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "sort") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EBinOp "%" (EApp (EVar "fst") (EVar "p")) (ELit (LInt 50))) (EApp (EVar "snd") (EVar "p"))))) (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EDictApp "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EDictApp "naiveFromList") (EVar "ys")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted prefix then unsorted tail" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EDictApp "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EDictApp "naiveFromList") (EVar "ys")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "fromList agrees with naive on sorted prefix then duplicate-heavy tail" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EBinOp "%" (EApp (EVar "fst") (EVar "p")) (ELit (LInt 50))) (EApp (EVar "snd") (EVar "p"))))) (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EDictApp "fromList") (EVar "ys")))) (EApp (EVar "entries") (EApp (EDictApp "naiveFromList") (EVar "ys")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "a later pair overrides an entry from the ascending prefix" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "ys") (EBinOp "++" (EApp (EVar "sort") (EVar "xs")) (EListLit (ETuple (EVar "k") (EVar "v"))))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EApp (EDictApp "fromList") (EVar "ys")))) (EApp (EVar "Some") (EVar "v"))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "union agrees with naive fold-insert" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b")))) (EApp (EVar "entries") (EApp (EApp (EDictApp "naiveUnion") (EVar "a")) (EVar "b")))))))
(DProp false "union with a tiny side agrees with naive in both orders" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "big") (EApp (EDictApp "fromList") (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)) (EVar "xs")))) (DoLet false false (PVar "small") (EApp (EDictApp "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 64))) (EVar "v")))) (EApp (EApp (EVar "take") (ELit (LInt 2))) (EVar "ys"))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EApp (EDictApp "union") (EVar "big")) (EVar "small")))) (EApp (EVar "entries") (EApp (EApp (EDictApp "naiveUnion") (EVar "big")) (EVar "small")))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EApp (EDictApp "union") (EVar "small")) (EVar "big")))) (EApp (EVar "entries") (EApp (EApp (EDictApp "naiveUnion") (EVar "small")) (EVar "big"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "union") (EVar "big")) (EVar "small")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "union") (EVar "small")) (EVar "big")))))))
(DProp false "unionWith with a tiny side agrees with naive in both orders" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "big") (EApp (EDictApp "fromList") (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)) (EVar "xs")))) (DoLet false false (PVar "small") (EApp (EDictApp "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EBinOp "%" (EVar "k") (ELit (LInt 64))) (EVar "v")))) (EApp (EApp (EVar "take") (ELit (LInt 2))) (EVar "ys"))))) (DoLet false false (PVar "f") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "x")) (EVar "y")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "unionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "naiveUnionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "unionWith") (EVar "f")) (EVar "small")) (EVar "big")))) (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "naiveUnionWith") (EVar "f")) (EVar "small")) (EVar "big"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EApp (EDictApp "unionWith") (EVar "f")) (EVar "big")) (EVar "small")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EApp (EDictApp "unionWith") (EVar "f")) (EVar "small")) (EVar "big")))))))
(DData Private "Tagged" () ((variant "Tagged" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl false "Eq" ((TyCon "Tagged")) () ((im "eq" ((PCon "Tagged" (PVar "a") PWild) (PCon "Tagged" (PVar "b") PWild)) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Ord" ((TyCon "Tagged")) () ((im "compare" ((PCon "Tagged" (PVar "a") PWild) (PCon "Tagged" (PVar "b") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))))
(DTypeSig false "taggedAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Tagged")) (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "taggedAt" ((PVar "n") (PVar "m")) (EApp (EApp (EMethodRef "filterMap") (EApp (EVar "tagIfAt") (EVar "n"))) (EApp (EVar "keys") (EVar "m"))))
(DTypeSig false "tagIfAt" (TyFun (TyCon "Int") (TyFun (TyCon "Tagged") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tagIfAt" ((PVar "n") (PCon "Tagged" (PVar "i") (PVar "t"))) (EIf (EBinOp "==" (EVar "i") (EVar "n")) (EApp (EVar "Some") (EVar "t")) (EVar "None")))
(DProp false "union and unionWith keep the first map's key on a shared key" ((pp "j" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "j") (ELit (LInt 64))) (ELit (LInt 64))) (ELit (LInt 64)))) (DoLet false false (PVar "big") (EApp (EDictApp "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "Tagged") (EVar "i")) (ELit (LInt 0))) (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (DoLet false false (PVar "small") (EApp (EDictApp "fromList") (EListLit (ETuple (EApp (EApp (EVar "Tagged") (EVar "n")) (ELit (LInt 1))) (ELit (LInt 7)))))) (DoLet false false (PVar "sameSize") (EApp (EDictApp "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "Tagged") (EVar "i")) (ELit (LInt 1))) (EVar "i")))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EDictApp "union") (EVar "small")) (EVar "big")))) (EListLit (ELit (LInt 1)))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EDictApp "union") (EVar "big")) (EVar "small")))) (EListLit (ELit (LInt 0))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EDictApp "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "small")) (EVar "big")))) (EListLit (ELit (LInt 1))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EDictApp "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "big")) (EVar "small")))) (EListLit (ELit (LInt 0))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EDictApp "union") (EVar "sameSize")) (EVar "big")))) (EListLit (ELit (LInt 1))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "taggedAt") (EVar "n")) (EApp (EApp (EApp (EDictApp "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "sameSize")) (EVar "big")))) (EListLit (ELit (LInt 1))))))))
(DProp false "union keys stay strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "ascending") (EApp (EVar "keys") (EApp (EApp (EDictApp "union") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys"))))))
(DProp false "unionWith agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EDictApp "unionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "naiveUnionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "difference agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "difference") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EDictApp "naiveDifference") (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "intersectionWith agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EApp (EDictApp "intersectionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "naiveIntersectionWith") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "intersection is the left-biased intersectionWith" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EApp (EDictApp "intersectionWith") (ELam ((PVar "x") PWild) (EVar "x"))) (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "intersection keeps exactly the shared keys, with the left value" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "k")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "b"))) (EBinOp "==" (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "got")) (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "a")))))) (EApp (EVar "keys") (EVar "got"))) (EApp (EApp (EDictApp "all") (ELam ((PVar "k")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isSome") (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "b")))) (EApp (EVar "isSome") (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "got")))))) (EApp (EVar "keys") (EVar "a")))))))
(DProp false "Filterable: filterMap Some is the identity" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "v")) (EApp (EVar "Some") (EVar "v")))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EVar "m"))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "Filterable: filter agrees with filterWithKey ignoring the key" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EDictApp "filterWithKey") (ELam (PWild (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "filterWithKey agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "filterWithKey") (ELam ((PVar "k") (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "got"))) (EApp (EVar "entries") (EApp (EApp (EDictApp "naiveFilterWithKey") (ELam ((PVar "k") (PVar "v")) (EBinOp ">" (EVar "v") (ELit (LInt 0))))) (EVar "m")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "splitAt partitions around the key and both halves stay well-formed" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "below")) (EApp (EDictApp "wellFormed") (EVar "above"))) (EApp (EApp (EVar "allKeys") (ELam ((PVar "bk")) (EApp (EApp (EMethodRef "lt") (EVar "bk")) (EVar "k")))) (EVar "below"))) (EApp (EApp (EVar "allKeys") (ELam ((PVar "ak")) (EApp (EApp (EMethodRef "gt") (EVar "ak")) (EVar "k")))) (EVar "above"))))))
(DProp false "link rebuilds a well-formed map from a split" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EApp (EApp (EVar "link") (EVar "k")) (ELit (LInt 0))) (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "rebuilt")) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "rebuilt"))) (EApp (EVar "Some") (ELit (LInt 0))))))))
(DProp false "link2 rejoins a split without its key" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "link2") (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "rebuilt")) (EApp (EApp (EMethodRef "eq") (EApp (EVar "entries") (EVar "rebuilt"))) (EApp (EVar "entries") (EApp (EApp (EDictApp "delete") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))))))))
(DProp false "entriesFrom is the limited run of entries from the start key" ((pp "k" (TyCon "Int")) (pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "entriesFrom") (EApp (EVar "Some") (EVar "k"))) (EApp (EVar "Some") (EVar "n"))) (EVar "m"))) (EApp (EApp (EVar "take") (EVar "n")) (EApp (EApp (EMethodRef "filter") (ELam ((PTuple (PVar "key") PWild)) (EApp (EApp (EMethodRef "gte") (EVar "key")) (EVar "k")))) (EApp (EVar "entries") (EVar "m"))))))))
(DProp false "entriesFrom bounded on one side only still agrees with entries" ((pp "k" (TyCon "Int")) (pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "entriesFrom") (EVar "None")) (EVar "None")) (EVar "m"))) (EApp (EVar "entries") (EVar "m"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "entriesFrom") (EVar "None")) (EApp (EVar "Some") (EVar "n"))) (EVar "m"))) (EApp (EApp (EVar "take") (EVar "n")) (EApp (EVar "entries") (EVar "m"))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "entriesFrom") (EApp (EVar "Some") (EVar "k"))) (EVar "None")) (EVar "m"))) (EApp (EApp (EMethodRef "filter") (ELam ((PTuple (PVar "key") PWild)) (EApp (EApp (EMethodRef "gte") (EVar "key")) (EVar "k")))) (EApp (EVar "entries") (EVar "m"))))))))
