# META
source_lines=304
stages=DESUGAR,MARK
# SOURCE
{- | Differences between two sequences, and between two texts in the unified
   format that `diff -u` prints.

   `editScript` compares any two lists and answers with the steps that turn
   the first into the second: `Keep` an element, `Delete` one of the first
   list, `Insert` one of the second. The script is a shortest one, so it has
   as many `Keep`s as the longest common subsequence has elements. Where
   several shortest scripts exist, the one returned may differ from the one
   another tool picks. Within a run of changes, deletions come before
   insertions.

   `unified` compares two texts line by line. Lines are cut on LF alone, so a
   CR is part of its line, and a final line without its LF differs from the
   same line with one. -}

import core.{Eq, Debug}
import list.{reverse, take, groupBy}
import string.{split, concat, endsWith}

-- # Edit scripts

{- | One step of an edit script.

   > Keep 1
   Keep 1 -}
public export data Edit a = Keep a | Insert a | Delete a deriving (Eq, Debug)

{- | A shortest edit script turning the first list into the second.

   Runs in time proportional to the combined length of the two lists times
   the number of insertions and deletions in the script, so similar inputs
   are cheap. Memory grows with the square of the edit distance: two
   completely different texts of 8,000 lines use about 2 GB, while similar
   texts stay small.

   > editScript [1, 2, 3] [1, 3, 4]
   [Keep 1, Delete 2, Keep 3, Insert 4]
   > editScript ['a', 'b'] ['b', 'a']
   [Delete 'a', Keep 'b', Insert 'a']
   > editScript [1, 2] ([] : List Int)
   [Delete 1, Delete 2] -}
export
editScript : Eq a => List a -> List a -> List (Edit a)
editScript a b = deletesFirst (shortest a b)

shortest : Eq a => List a -> List a -> List (Edit a)
shortest a b =
  let xs = arrayFromList a
  let ys = arrayFromList b
  let n = arrayLength xs
  let m = arrayLength ys
  let off = n + m + 1
  let v = arrayMake (2 * (n + m) + 3) 0
  let (d, snaps) = forward xs ys n m off v 0 []
  backtrack xs ys off n m d snaps []

-- Within each run of changes, moves the deletions ahead of the insertions.
deletesFirst : List (Edit a) -> List (Edit a)
deletesFirst script = deletesFirstGo script [] [] []

deletesFirstGo : List (Edit a) ->
  List (Edit a) ->
  List (Edit a) ->
  List (Edit a) ->
  List (Edit a)
deletesFirstGo [] dels ins acc = reverse (ins ++ dels ++ acc)
deletesFirstGo ((Delete x) :: rest) dels ins acc =
  deletesFirstGo rest (Delete x :: dels) ins acc
deletesFirstGo ((Insert x) :: rest) dels ins acc =
  deletesFirstGo rest dels (Insert x :: ins) acc
deletesFirstGo ((Keep x) :: rest) dels ins acc =
  deletesFirstGo rest [] [] (Keep x :: ins ++ dels ++ acc)

-- The furthest-reaching x on each diagonal k lives in `v[off + k]`. Before
-- sweeping edit distance `d`, the slice of `v` for diagonals `-d-1..d+1` is saved:
-- the backtrack reads it to learn which neighbour each diagonal came from.
forward : Eq a =>
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  Array Int ->
  Int ->
  List (Array Int) ->
  (Int, List (Array Int))
forward xs ys n m off v d snaps =
  let saved =
    arrayMakeWith (2 * d + 3) (i => arrayGetUnsafe (off - d - 1 + i) v)
  if sweep xs ys n m off v d (0 - d) then
    (d, saved :: snaps)
  else
    forward xs ys n m off v (d + 1) (saved :: snaps)

sweep : Eq a =>
  Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  Array Int ->
  Int ->
  Int ->
  Bool
sweep xs ys n m off v d k
  | k > d = False
  | otherwise =
    let up = arrayGetUnsafe (off + k + 1) v
    let left = arrayGetUnsafe (off + k - 1) v
    let x0 = if comesFromAbove d k left up then up else left + 1
    let x = snake xs ys n m x0 (x0 - k)
    let _ = arraySetUnsafe (off + k) x v
    if x >= n && x - k >= m then True else sweep xs ys n m off v d (k + 2)

-- Diagonal k is reached from diagonal k + 1 by an insertion, or from k - 1 by
-- a deletion. The edge diagonals have one choice; otherwise the further one
-- wins, and a tie goes to the deletion.
comesFromAbove : Int -> Int -> Int -> Int -> Bool
comesFromAbove d k left up = k == 0 - d || k /= d && left < up

snake : Eq a => Array a -> Array a -> Int -> Int -> Int -> Int -> Int
snake xs ys n m x y
  | x < n && y < m && arrayGetUnsafe x xs == arrayGetUnsafe y ys =
    snake xs ys n m (x + 1) (y + 1)
  | otherwise = x

-- Walks from (x, y) back to the origin, one edit distance at a time, building
-- the script front to back.
backtrack : Array a ->
  Array a ->
  Int ->
  Int ->
  Int ->
  Int ->
  List (Array Int) ->
  List (Edit a) ->
  List (Edit a)
backtrack xs ys off x y d (saved :: rest) acc
  | d > 0 =
    let k = x - y
    let up = arrayGetUnsafe (k + d + 2) saved
    let left = arrayGetUnsafe (k + d) saved
    let fromAbove = comesFromAbove d k left up
    let prevX = if fromAbove then up else left
    let prevY = prevX - (if fromAbove then k + 1 else k - 1)
    let midX = if fromAbove then prevX else prevX + 1
    let edit =
      if fromAbove then
        Insert (arrayGetUnsafe prevY ys)
      else
        Delete (arrayGetUnsafe prevX xs)
    backtrack
      xs
      ys
      off
      prevX
      prevY
      (d - 1)
      rest
      (edit :: keepsBetween xs midX x acc)
backtrack xs _ _ x _ _ _ acc = keepsBetween xs 0 x acc

-- Prepends `Keep xs[i]` for each `i` in `[lo, hi)`.
keepsBetween : Array a -> Int -> Int -> List (Edit a) -> List (Edit a)
keepsBetween xs lo hi acc =
  if hi <= lo then
    acc
  else
    keepsBetween xs lo (hi - 1) (Keep (arrayGetUnsafe (hi - 1) xs) :: acc)

-- # Unified format

{- | Compares two texts and prints the difference in unified format, with
   `ctx` unchanged lines around each change.

   Each text comes with the label that names it in the two header lines. The
   result is empty when the texts are equal. The format has no timestamps,
   so the headers are the label alone.

   > unified 1 ("old", "a\nb\nc\n") ("new", "a\nB\nc\n")
   "--- old\n+++ new\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
   > unified 3 ("old", "same\n") ("new", "same\n")
   ""
   > unified 0 ("old", "") ("new", "x\n")
   "--- old\n+++ new\n@@ -0,0 +1 @@\n+x\n" -}
export
unified : Int -> (String, String) -> (String, String) -> String
unified ctx (labelA, a) (labelB, b)
  | a == b = ""
  | otherwise =
    let script = editScript (splitLines a) (splitLines b)
    let hs = hunks (if ctx < 0 then 0 else ctx) (runs (annotate script 0 0 []))
    concat ("--- \{labelA}\n+++ \{labelB}\n" :: map renderHunk hs)

-- An edit with the number of lines of each text that precede it.
data Entry = Entry (Edit String) Int Int

-- Lines keep their LF, so a last line without one differs from the same line
-- with one, as it does for `diff`. `string.lines` drops the LF and a CR, which
-- would hide that difference.
splitLines : String -> List String
-- Keeps each LF, which string.lines drops.
-- lint-disable-next-line rule-stdlib-reimpl
splitLines text = terminate (split "\n" text) []

terminate : List String -> List String -> List String
terminate [] acc = reverse acc
terminate [lastPiece] acc =
  reverse (if lastPiece == "" then acc else lastPiece :: acc)
terminate (piece :: rest) acc = terminate rest ("\{piece}\n" :: acc)

annotate : List (Edit String) -> Int -> Int -> List Entry -> List Entry
annotate [] _ _ acc = reverse acc
annotate ((e@(Keep _)) :: rest) i j acc =
  annotate rest (i + 1) (j + 1) (Entry e i j :: acc)
annotate ((e@(Delete _)) :: rest) i j acc =
  annotate rest (i + 1) j (Entry e i j :: acc)
annotate ((e@(Insert _)) :: rest) i j acc =
  annotate rest i (j + 1) (Entry e i j :: acc)

isKeep : Entry -> Bool
isKeep (Entry (Keep _) _ _) = True
isKeep _ = False

runs : List Entry -> List (List Entry)
runs = groupBy (e1 e2 => isKeep e1 == isKeep e2)

-- Cuts the runs into hunks. `prev` is the unchanged run before the current
-- change, `cur` the open hunk in reverse, `acc` the finished hunks in reverse.
-- Unchanged runs of at most `2 * ctx` lines between changes keep the hunk open.
hunks : Int -> List (List Entry) -> List (List Entry)
hunks ctx rs = hunksGo ctx rs [] [] []

hunksGo : Int ->
  List (List Entry) ->
  List Entry ->
  List Entry ->
  List (List Entry) ->
  List (List Entry)
hunksGo _ [] _ cur acc = reverse (closeHunk cur acc)
hunksGo ctx ((run@(entry :: _)) :: rest) _prev cur acc
  | isKeep entry = keepRun ctx run rest cur acc
hunksGo ctx (run :: rest) prev cur acc =
  hunksGo ctx rest prev (reverse run ++ opened ctx prev cur) acc

-- The open hunk, or the context that opens one when none is open.
opened : Int -> List Entry -> List Entry -> List Entry
opened ctx prev [] = take ctx (reverse prev)
opened _ _ cur = cur

keepRun : Int ->
  List Entry ->
  List (List Entry) ->
  List Entry ->
  List (List Entry) ->
  List (List Entry)
keepRun ctx run rest [] acc = hunksGo ctx rest run [] acc
keepRun ctx run [] cur acc =
  reverse (closeHunk (reverse (take ctx run) ++ cur) acc)
keepRun ctx run rest cur acc
  | length run <= 2 * ctx = hunksGo ctx rest run (reverse run ++ cur) acc
  | otherwise =
    hunksGo ctx rest run [] (closeHunk (reverse (take ctx run) ++ cur) acc)

closeHunk : List Entry -> List (List Entry) -> List (List Entry)
closeHunk [] acc = acc
closeHunk cur acc = reverse cur :: acc

renderHunk : List Entry -> String
renderHunk [] = ""
renderHunk (es@((Entry _ i j) :: _)) =
  let nA = count (e => not (isInsert e)) es
  let nB = count (e => not (isDelete e)) es
  let header = "@@ -\{range i nA} +\{range j nB} @@\n"
  concat (header :: map renderEntry es)

-- `start,count`, with the count dropped when it is 1. An empty range starts at
-- the line before it.
range : Int -> Int -> String
range before count
  | count == 0 = "\{before},0"
  | count == 1 = "\{before + 1}"
  | otherwise = "\{before + 1},\{count}"

isInsert : Entry -> Bool
isInsert (Entry (Insert _) _ _) = True
isInsert _ = False

isDelete : Entry -> Bool
isDelete (Entry (Delete _) _ _) = True
isDelete _ = False

renderEntry : Entry -> String
renderEntry (Entry e _ _) = match e
  Keep l => renderLine " " l
  Delete l => renderLine "-" l
  Insert l => renderLine "+" l

renderLine : String -> String -> String
renderLine sign l =
  if endsWith "\n" l then
    "\{sign}\{l}"
  else
    "\{sign}\{l}\n\\ No newline at end of file\n"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "take" false) (mem "groupBy" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "concat" false) (mem "endsWith" false))))
(DData Public "Edit" ("a") ((variant "Keep" (ConPos (TyVar "a"))) (variant "Insert" (ConPos (TyVar "a"))) (variant "Delete" (ConPos (TyVar "a")))) ())
(DImpl true "Eq" ((TyApp (TyCon "Edit") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Keep" (PVar "__a0")) (PCon "Keep" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Insert" (PVar "__a0")) (PCon "Insert" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Delete" (PVar "__a0")) (PCon "Delete" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyApp (TyCon "Edit") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Keep" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Keep ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Insert" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Insert ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Delete" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Delete ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig true "editScript" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))))
(DFunDef false "editScript" ((PVar "a") (PVar "b")) (EApp (EVar "deletesFirst") (EApp (EApp (EVar "shortest") (EVar "a")) (EVar "b"))))
(DTypeSig false "shortest" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))))
(DFunDef false "shortest" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "xs") (EApp (EVar "arrayFromList") (EVar "a"))) (DoLet false false (PVar "ys") (EApp (EVar "arrayFromList") (EVar "b"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "xs"))) (DoLet false false (PVar "m") (EApp (EVar "arrayLength") (EVar "ys"))) (DoLet false false (PVar "off") (EBinOp "+" (EBinOp "+" (EVar "n") (EVar "m")) (ELit (LInt 1)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "arrayMake") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "n") (EVar "m"))) (ELit (LInt 3)))) (ELit (LInt 0)))) (DoLet false false (PTuple (PVar "d") (PVar "snaps")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "forward") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (ELit (LInt 0))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "backtrack") (EVar "xs")) (EVar "ys")) (EVar "off")) (EVar "n")) (EVar "m")) (EVar "d")) (EVar "snaps")) (EListLit)))))
(DTypeSig false "deletesFirst" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))
(DFunDef false "deletesFirst" ((PVar "script")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "script")) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "deletesFirstGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))
(DFunDef false "deletesFirstGo" ((PList) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EVar "reverse") (EBinOp "++" (EBinOp "++" (EVar "ins") (EVar "dels")) (EVar "acc"))))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Delete" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EBinOp "::" (EApp (EVar "Delete") (EVar "x")) (EVar "dels"))) (EVar "ins")) (EVar "acc")))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Insert" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EVar "dels")) (EBinOp "::" (EApp (EVar "Insert") (EVar "x")) (EVar "ins"))) (EVar "acc")))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Keep" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EListLit)) (EListLit)) (EBinOp "::" (EApp (EVar "Keep") (EVar "x")) (EBinOp "++" (EBinOp "++" (EVar "ins") (EVar "dels")) (EVar "acc")))))
(DTypeSig false "forward" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))))))))))))))
(DFunDef false "forward" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "off") (PVar "v") (PVar "d") (PVar "snaps")) (EBlock (DoLet false false (PVar "saved") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "d")) (ELit (LInt 3)))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "-" (EBinOp "-" (EVar "off") (EVar "d")) (ELit (LInt 1))) (EVar "i"))) (EVar "v"))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sweep") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EVar "d")) (EBinOp "-" (ELit (LInt 0)) (EVar "d"))) (ETuple (EVar "d") (EBinOp "::" (EVar "saved") (EVar "snaps"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "forward") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EBinOp "::" (EVar "saved") (EVar "snaps")))))))
(DTypeSig false "sweep" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))))))
(DFunDef false "sweep" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "off") (PVar "v") (PVar "d") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (EVar "d")) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "up") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "+" (EVar "off") (EVar "k")) (ELit (LInt 1)))) (EVar "v"))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "+" (EVar "off") (EVar "k")) (ELit (LInt 1)))) (EVar "v"))) (DoLet false false (PVar "x0") (EIf (EApp (EApp (EApp (EApp (EVar "comesFromAbove") (EVar "d")) (EVar "k")) (EVar "left")) (EVar "up")) (EVar "up") (EBinOp "+" (EVar "left") (ELit (LInt 1))))) (DoLet false false (PVar "x") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "snake") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "x0")) (EBinOp "-" (EVar "x0") (EVar "k")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "+" (EVar "off") (EVar "k"))) (EVar "x")) (EVar "v"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "x") (EVar "n")) (EBinOp ">=" (EBinOp "-" (EVar "x") (EVar "k")) (EVar "m"))) (EVar "True") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sweep") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EVar "d")) (EBinOp "+" (EVar "k") (ELit (LInt 2))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "comesFromAbove" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "comesFromAbove" ((PVar "d") (PVar "k") (PVar "left") (PVar "up")) (EBinOp "||" (EBinOp "==" (EVar "k") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))) (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "d")) (EBinOp "<" (EVar "left") (EVar "up")))))
(DTypeSig false "snake" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "snake" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "x") (PVar "y")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "x") (EVar "n")) (EBinOp "<" (EVar "y") (EVar "m"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "x")) (EVar "xs")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "y")) (EVar "ys")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "snake") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EBinOp "+" (EVar "x") (ELit (LInt 1)))) (EBinOp "+" (EVar "y") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "backtrack" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))))))
(DFunDef false "backtrack" ((PVar "xs") (PVar "ys") (PVar "off") (PVar "x") (PVar "y") (PVar "d") (PCons (PVar "saved") (PVar "rest")) (PVar "acc")) (EIf (EBinOp ">" (EVar "d") (ELit (LInt 0))) (EBlock (DoLet false false (PVar "k") (EBinOp "-" (EVar "x") (EVar "y"))) (DoLet false false (PVar "up") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "+" (EVar "k") (EVar "d")) (ELit (LInt 2)))) (EVar "saved"))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "k") (EVar "d"))) (EVar "saved"))) (DoLet false false (PVar "fromAbove") (EApp (EApp (EApp (EApp (EVar "comesFromAbove") (EVar "d")) (EVar "k")) (EVar "left")) (EVar "up"))) (DoLet false false (PVar "prevX") (EIf (EVar "fromAbove") (EVar "up") (EVar "left"))) (DoLet false false (PVar "prevY") (EBinOp "-" (EVar "prevX") (EIf (EVar "fromAbove") (EBinOp "+" (EVar "k") (ELit (LInt 1))) (EBinOp "-" (EVar "k") (ELit (LInt 1)))))) (DoLet false false (PVar "midX") (EIf (EVar "fromAbove") (EVar "prevX") (EBinOp "+" (EVar "prevX") (ELit (LInt 1))))) (DoLet false false (PVar "edit") (EIf (EVar "fromAbove") (EApp (EVar "Insert") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "prevY")) (EVar "ys"))) (EApp (EVar "Delete") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "prevX")) (EVar "xs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "backtrack") (EVar "xs")) (EVar "ys")) (EVar "off")) (EVar "prevX")) (EVar "prevY")) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "edit") (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (EVar "midX")) (EVar "x")) (EVar "acc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "backtrack" ((PVar "xs") PWild PWild (PVar "x") PWild PWild PWild (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (ELit (LInt 0))) (EVar "x")) (EVar "acc")))
(DTypeSig false "keepsBetween" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))
(DFunDef false "keepsBetween" ((PVar "xs") (PVar "lo") (PVar "hi") (PVar "acc")) (EIf (EBinOp "<=" (EVar "hi") (EVar "lo")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Keep") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EVar "xs"))) (EVar "acc")))))
(DTypeSig true "unified" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))))
(DFunDef false "unified" ((PVar "ctx") (PTuple (PVar "labelA") (PVar "a")) (PTuple (PVar "labelB") (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "script") (EApp (EApp (EVar "editScript") (EApp (EVar "splitLines") (EVar "a"))) (EApp (EVar "splitLines") (EVar "b")))) (DoLet false false (PVar "hs") (EApp (EApp (EVar "hunks") (EIf (EBinOp "<" (EVar "ctx") (ELit (LInt 0))) (ELit (LInt 0)) (EVar "ctx"))) (EApp (EVar "runs") (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "script")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))) (DoExpr (EApp (EVar "concat") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "--- ")) (EApp (EVar "display") (EVar "labelA"))) (ELit (LString "\n+++ "))) (EApp (EVar "display") (EVar "labelB"))) (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EVar "renderHunk")) (EVar "hs")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyApp (TyCon "Edit") (TyCon "String")) (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "text")) (EApp (EApp (EVar "terminate") (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "text"))) (EListLit)))
(DTypeSig false "terminate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "terminate" ((PList) (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "terminate" ((PList (PVar "lastPiece")) (PVar "acc")) (EApp (EVar "reverse") (EIf (EBinOp "==" (EVar "lastPiece") (ELit (LString ""))) (EVar "acc") (EBinOp "::" (EVar "lastPiece") (EVar "acc")))))
(DFunDef false "terminate" ((PCons (PVar "piece") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "terminate") (EVar "rest")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "piece"))) (ELit (LString "\n"))) (EVar "acc"))))
(DTypeSig false "annotate" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyCon "Entry")))))))
(DFunDef false "annotate" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Keep" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Delete" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "j")) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Insert" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DTypeSig false "isKeep" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isKeep" ((PCon "Entry" (PCon "Keep" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isKeep" (PWild) (EVar "False"))
(DTypeSig false "runs" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))
(DFunDef false "runs" () (EApp (EVar "groupBy") (ELam ((PVar "e1") (PVar "e2")) (EBinOp "==" (EApp (EVar "isKeep") (EVar "e1")) (EApp (EVar "isKeep") (EVar "e2"))))))
(DTypeSig false "hunks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "hunks" ((PVar "ctx") (PVar "rs")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rs")) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "hunksGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))))))
(DFunDef false "hunksGo" (PWild (PList) PWild (PVar "cur") (PVar "acc")) (EApp (EVar "reverse") (EApp (EApp (EVar "closeHunk") (EVar "cur")) (EVar "acc"))))
(DFunDef false "hunksGo" ((PVar "ctx") (PCons (PAs "run" (PCons (PVar "entry") PWild)) (PVar "rest")) (PVar "_prev") (PVar "cur") (PVar "acc")) (EIf (EApp (EVar "isKeep") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EVar "keepRun") (EVar "ctx")) (EVar "run")) (EVar "rest")) (EVar "cur")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "hunksGo" ((PVar "ctx") (PCons (PVar "run") (PVar "rest")) (PVar "prev") (PVar "cur") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "prev")) (EBinOp "++" (EApp (EVar "reverse") (EVar "run")) (EApp (EApp (EApp (EVar "opened") (EVar "ctx")) (EVar "prev")) (EVar "cur")))) (EVar "acc")))
(DTypeSig false "opened" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "opened" ((PVar "ctx") (PVar "prev") (PList)) (EApp (EApp (EVar "take") (EVar "ctx")) (EApp (EVar "reverse") (EVar "prev"))))
(DFunDef false "opened" (PWild PWild (PVar "cur")) (EVar "cur"))
(DTypeSig false "keepRun" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))))))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PVar "rest") (PList) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EListLit)) (EVar "acc")))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PList) (PVar "cur") (PVar "acc")) (EApp (EVar "reverse") (EApp (EApp (EVar "closeHunk") (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EVar "take") (EVar "ctx")) (EVar "run"))) (EVar "cur"))) (EVar "acc"))))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PVar "rest") (PVar "cur") (PVar "acc")) (EIf (EBinOp "<=" (EApp (EVar "length") (EVar "run")) (EBinOp "*" (ELit (LInt 2)) (EVar "ctx"))) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EBinOp "++" (EApp (EVar "reverse") (EVar "run")) (EVar "cur"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EListLit)) (EApp (EApp (EVar "closeHunk") (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EVar "take") (EVar "ctx")) (EVar "run"))) (EVar "cur"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeHunk" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "closeHunk" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "closeHunk" ((PVar "cur") (PVar "acc")) (EBinOp "::" (EApp (EVar "reverse") (EVar "cur")) (EVar "acc")))
(DTypeSig false "renderHunk" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyCon "String")))
(DFunDef false "renderHunk" ((PList)) (ELit (LString "")))
(DFunDef false "renderHunk" ((PAs "es" (PCons (PCon "Entry" PWild (PVar "i") (PVar "j")) PWild))) (EBlock (DoLet false false (PVar "nA") (EApp (EApp (EVar "count") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isInsert") (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "nB") (EApp (EApp (EVar "count") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isDelete") (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "@@ -")) (EApp (EVar "display") (EApp (EApp (EVar "range") (EVar "i")) (EVar "nA")))) (ELit (LString " +"))) (EApp (EVar "display") (EApp (EApp (EVar "range") (EVar "j")) (EVar "nB")))) (ELit (LString " @@\n")))) (DoExpr (EApp (EVar "concat") (EBinOp "::" (EVar "header") (EApp (EApp (EVar "map") (EVar "renderEntry")) (EVar "es")))))))
(DTypeSig false "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "range" ((PVar "before") (PVar "count")) (EIf (EBinOp "==" (EVar "count") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "before"))) (ELit (LString ",0"))) (EIf (EBinOp "==" (EVar "count") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EBinOp "+" (EVar "before") (ELit (LInt 1))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EBinOp "+" (EVar "before") (ELit (LInt 1))))) (ELit (LString ","))) (EApp (EVar "display") (EVar "count"))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isInsert" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isInsert" ((PCon "Entry" (PCon "Insert" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isInsert" (PWild) (EVar "False"))
(DTypeSig false "isDelete" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isDelete" ((PCon "Entry" (PCon "Delete" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isDelete" (PWild) (EVar "False"))
(DTypeSig false "renderEntry" (TyFun (TyCon "Entry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "Entry" (PVar "e") PWild PWild)) (EMatch (EVar "e") (arm (PCon "Keep" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString " "))) (EVar "l"))) (arm (PCon "Delete" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString "-"))) (EVar "l"))) (arm (PCon "Insert" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString "+"))) (EVar "l")))))
(DTypeSig false "renderLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renderLine" ((PVar "sign") (PVar "l")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\n"))) (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sign"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "l"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sign"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "\n\\ No newline at end of file\n")))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "take" false) (mem "groupBy" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "concat" false) (mem "endsWith" false))))
(DData Public "Edit" ("a") ((variant "Keep" (ConPos (TyVar "a"))) (variant "Insert" (ConPos (TyVar "a"))) (variant "Delete" (ConPos (TyVar "a")))) ())
(DImpl true "Eq" ((TyApp (TyCon "Edit") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Keep" (PVar "__a0")) (PCon "Keep" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Insert" (PVar "__a0")) (PCon "Insert" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Delete" (PVar "__a0")) (PCon "Delete" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyApp (TyCon "Edit") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Keep" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Keep ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Insert" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Insert ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Delete" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Delete ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig true "editScript" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))))
(DFunDef false "editScript" ((PVar "a") (PVar "b")) (EApp (EVar "deletesFirst") (EApp (EApp (EDictApp "shortest") (EVar "a")) (EVar "b"))))
(DTypeSig false "shortest" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))))
(DFunDef false "shortest" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "xs") (EApp (EVar "arrayFromList") (EVar "a"))) (DoLet false false (PVar "ys") (EApp (EVar "arrayFromList") (EVar "b"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "xs"))) (DoLet false false (PVar "m") (EApp (EVar "arrayLength") (EVar "ys"))) (DoLet false false (PVar "off") (EBinOp "+" (EBinOp "+" (EVar "n") (EVar "m")) (ELit (LInt 1)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "arrayMake") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "n") (EVar "m"))) (ELit (LInt 3)))) (ELit (LInt 0)))) (DoLet false false (PTuple (PVar "d") (PVar "snaps")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "forward") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (ELit (LInt 0))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "backtrack") (EVar "xs")) (EVar "ys")) (EVar "off")) (EVar "n")) (EVar "m")) (EVar "d")) (EVar "snaps")) (EListLit)))))
(DTypeSig false "deletesFirst" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a")))))
(DFunDef false "deletesFirst" ((PVar "script")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "script")) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "deletesFirstGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))
(DFunDef false "deletesFirstGo" ((PList) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EVar "reverse") (EBinOp "++" (EBinOp "++" (EVar "ins") (EVar "dels")) (EVar "acc"))))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Delete" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EBinOp "::" (EApp (EVar "Delete") (EVar "x")) (EVar "dels"))) (EVar "ins")) (EVar "acc")))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Insert" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EVar "dels")) (EBinOp "::" (EApp (EVar "Insert") (EVar "x")) (EVar "ins"))) (EVar "acc")))
(DFunDef false "deletesFirstGo" ((PCons (PCon "Keep" (PVar "x")) (PVar "rest")) (PVar "dels") (PVar "ins") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "deletesFirstGo") (EVar "rest")) (EListLit)) (EListLit)) (EBinOp "::" (EApp (EVar "Keep") (EVar "x")) (EBinOp "++" (EBinOp "++" (EVar "ins") (EVar "dels")) (EVar "acc")))))
(DTypeSig false "forward" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))))))))))))))
(DFunDef false "forward" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "off") (PVar "v") (PVar "d") (PVar "snaps")) (EBlock (DoLet false false (PVar "saved") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "d")) (ELit (LInt 3)))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "-" (EBinOp "-" (EVar "off") (EVar "d")) (ELit (LInt 1))) (EVar "i"))) (EVar "v"))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "sweep") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EVar "d")) (EBinOp "-" (ELit (LInt 0)) (EVar "d"))) (ETuple (EVar "d") (EBinOp "::" (EVar "saved") (EVar "snaps"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "forward") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EBinOp "::" (EVar "saved") (EVar "snaps")))))))
(DTypeSig false "sweep" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))))))
(DFunDef false "sweep" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "off") (PVar "v") (PVar "d") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (EVar "d")) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "up") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "+" (EVar "off") (EVar "k")) (ELit (LInt 1)))) (EVar "v"))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "+" (EVar "off") (EVar "k")) (ELit (LInt 1)))) (EVar "v"))) (DoLet false false (PVar "x0") (EIf (EApp (EApp (EApp (EApp (EVar "comesFromAbove") (EVar "d")) (EVar "k")) (EVar "left")) (EVar "up")) (EVar "up") (EBinOp "+" (EVar "left") (ELit (LInt 1))))) (DoLet false false (PVar "x") (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "snake") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "x0")) (EBinOp "-" (EVar "x0") (EVar "k")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "+" (EVar "off") (EVar "k"))) (EVar "x")) (EVar "v"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "x") (EVar "n")) (EBinOp ">=" (EBinOp "-" (EVar "x") (EVar "k")) (EVar "m"))) (EVar "True") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "sweep") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EVar "off")) (EVar "v")) (EVar "d")) (EBinOp "+" (EVar "k") (ELit (LInt 2))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "comesFromAbove" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "comesFromAbove" ((PVar "d") (PVar "k") (PVar "left") (PVar "up")) (EBinOp "||" (EBinOp "==" (EVar "k") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))) (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "d")) (EBinOp "<" (EVar "left") (EVar "up")))))
(DTypeSig false "snake" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "snake" ((PVar "xs") (PVar "ys") (PVar "n") (PVar "m") (PVar "x") (PVar "y")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "x") (EVar "n")) (EBinOp "<" (EVar "y") (EVar "m"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "x")) (EVar "xs")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "y")) (EVar "ys")))) (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "snake") (EVar "xs")) (EVar "ys")) (EVar "n")) (EVar "m")) (EBinOp "+" (EVar "x") (ELit (LInt 1)))) (EBinOp "+" (EVar "y") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "backtrack" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Array") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))))))
(DFunDef false "backtrack" ((PVar "xs") (PVar "ys") (PVar "off") (PVar "x") (PVar "y") (PVar "d") (PCons (PVar "saved") (PVar "rest")) (PVar "acc")) (EIf (EBinOp ">" (EVar "d") (ELit (LInt 0))) (EBlock (DoLet false false (PVar "k") (EBinOp "-" (EVar "x") (EVar "y"))) (DoLet false false (PVar "up") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "+" (EVar "k") (EVar "d")) (ELit (LInt 2)))) (EVar "saved"))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "k") (EVar "d"))) (EVar "saved"))) (DoLet false false (PVar "fromAbove") (EApp (EApp (EApp (EApp (EVar "comesFromAbove") (EVar "d")) (EVar "k")) (EVar "left")) (EVar "up"))) (DoLet false false (PVar "prevX") (EIf (EVar "fromAbove") (EVar "up") (EVar "left"))) (DoLet false false (PVar "prevY") (EBinOp "-" (EVar "prevX") (EIf (EVar "fromAbove") (EBinOp "+" (EVar "k") (ELit (LInt 1))) (EBinOp "-" (EVar "k") (ELit (LInt 1)))))) (DoLet false false (PVar "midX") (EIf (EVar "fromAbove") (EVar "prevX") (EBinOp "+" (EVar "prevX") (ELit (LInt 1))))) (DoLet false false (PVar "edit") (EIf (EVar "fromAbove") (EApp (EVar "Insert") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "prevY")) (EVar "ys"))) (EApp (EVar "Delete") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "prevX")) (EVar "xs"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "backtrack") (EVar "xs")) (EVar "ys")) (EVar "off")) (EVar "prevX")) (EVar "prevY")) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "edit") (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (EVar "midX")) (EVar "x")) (EVar "acc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "backtrack" ((PVar "xs") PWild PWild (PVar "x") PWild PWild PWild (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (ELit (LInt 0))) (EVar "x")) (EVar "acc")))
(DTypeSig false "keepsBetween" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))))))))
(DFunDef false "keepsBetween" ((PVar "xs") (PVar "lo") (PVar "hi") (PVar "acc")) (EIf (EBinOp "<=" (EVar "hi") (EVar "lo")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "keepsBetween") (EVar "xs")) (EVar "lo")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Keep") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EVar "xs"))) (EVar "acc")))))
(DTypeSig true "unified" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))))
(DFunDef false "unified" ((PVar "ctx") (PTuple (PVar "labelA") (PVar "a")) (PTuple (PVar "labelB") (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "script") (EApp (EApp (EDictApp "editScript") (EApp (EVar "splitLines") (EVar "a"))) (EApp (EVar "splitLines") (EVar "b")))) (DoLet false false (PVar "hs") (EApp (EApp (EVar "hunks") (EIf (EBinOp "<" (EVar "ctx") (ELit (LInt 0))) (ELit (LInt 0)) (EVar "ctx"))) (EApp (EVar "runs") (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "script")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))) (DoExpr (EApp (EVar "concat") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "--- ")) (EApp (EMethodRef "display") (EVar "labelA"))) (ELit (LString "\n+++ "))) (EApp (EMethodRef "display") (EVar "labelB"))) (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderHunk")) (EVar "hs")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Private "Entry" () ((variant "Entry" (ConPos (TyApp (TyCon "Edit") (TyCon "String")) (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "text")) (EApp (EApp (EVar "terminate") (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "text"))) (EListLit)))
(DTypeSig false "terminate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "terminate" ((PList) (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "terminate" ((PList (PVar "lastPiece")) (PVar "acc")) (EApp (EVar "reverse") (EIf (EBinOp "==" (EVar "lastPiece") (ELit (LString ""))) (EVar "acc") (EBinOp "::" (EVar "lastPiece") (EVar "acc")))))
(DFunDef false "terminate" ((PCons (PVar "piece") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "terminate") (EVar "rest")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "piece"))) (ELit (LString "\n"))) (EVar "acc"))))
(DTypeSig false "annotate" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyCon "Entry")))))))
(DFunDef false "annotate" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Keep" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Delete" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "j")) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DFunDef false "annotate" ((PCons (PAs "e" (PCon "Insert" PWild)) (PVar "rest")) (PVar "i") (PVar "j") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "annotate") (EVar "rest")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Entry") (EVar "e")) (EVar "i")) (EVar "j")) (EVar "acc"))))
(DTypeSig false "isKeep" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isKeep" ((PCon "Entry" (PCon "Keep" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isKeep" (PWild) (EVar "False"))
(DTypeSig false "runs" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))
(DFunDef false "runs" () (EApp (EVar "groupBy") (ELam ((PVar "e1") (PVar "e2")) (EBinOp "==" (EApp (EVar "isKeep") (EVar "e1")) (EApp (EVar "isKeep") (EVar "e2"))))))
(DTypeSig false "hunks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "hunks" ((PVar "ctx") (PVar "rs")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rs")) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "hunksGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))))))
(DFunDef false "hunksGo" (PWild (PList) PWild (PVar "cur") (PVar "acc")) (EApp (EVar "reverse") (EApp (EApp (EVar "closeHunk") (EVar "cur")) (EVar "acc"))))
(DFunDef false "hunksGo" ((PVar "ctx") (PCons (PAs "run" (PCons (PVar "entry") PWild)) (PVar "rest")) (PVar "_prev") (PVar "cur") (PVar "acc")) (EIf (EApp (EVar "isKeep") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EVar "keepRun") (EVar "ctx")) (EVar "run")) (EVar "rest")) (EVar "cur")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "hunksGo" ((PVar "ctx") (PCons (PVar "run") (PVar "rest")) (PVar "prev") (PVar "cur") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "prev")) (EBinOp "++" (EApp (EVar "reverse") (EVar "run")) (EApp (EApp (EApp (EVar "opened") (EVar "ctx")) (EVar "prev")) (EVar "cur")))) (EVar "acc")))
(DTypeSig false "opened" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "opened" ((PVar "ctx") (PVar "prev") (PList)) (EApp (EApp (EVar "take") (EVar "ctx")) (EApp (EVar "reverse") (EVar "prev"))))
(DFunDef false "opened" (PWild PWild (PVar "cur")) (EVar "cur"))
(DTypeSig false "keepRun" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry")))))))))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PVar "rest") (PList) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EListLit)) (EVar "acc")))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PList) (PVar "cur") (PVar "acc")) (EApp (EVar "reverse") (EApp (EApp (EVar "closeHunk") (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EVar "take") (EVar "ctx")) (EVar "run"))) (EVar "cur"))) (EVar "acc"))))
(DFunDef false "keepRun" ((PVar "ctx") (PVar "run") (PVar "rest") (PVar "cur") (PVar "acc")) (EIf (EBinOp "<=" (EApp (EMethodRef "length") (EVar "run")) (EBinOp "*" (ELit (LInt 2)) (EVar "ctx"))) (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EBinOp "++" (EApp (EVar "reverse") (EVar "run")) (EVar "cur"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "hunksGo") (EVar "ctx")) (EVar "rest")) (EVar "run")) (EListLit)) (EApp (EApp (EVar "closeHunk") (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EVar "take") (EVar "ctx")) (EVar "run"))) (EVar "cur"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeHunk" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Entry"))))))
(DFunDef false "closeHunk" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "closeHunk" ((PVar "cur") (PVar "acc")) (EBinOp "::" (EApp (EVar "reverse") (EVar "cur")) (EVar "acc")))
(DTypeSig false "renderHunk" (TyFun (TyApp (TyCon "List") (TyCon "Entry")) (TyCon "String")))
(DFunDef false "renderHunk" ((PList)) (ELit (LString "")))
(DFunDef false "renderHunk" ((PAs "es" (PCons (PCon "Entry" PWild (PVar "i") (PVar "j")) PWild))) (EBlock (DoLet false false (PVar "nA") (EApp (EApp (EDictApp "count") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isInsert") (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "nB") (EApp (EApp (EDictApp "count") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isDelete") (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "@@ -")) (EApp (EMethodRef "display") (EApp (EApp (EVar "range") (EVar "i")) (EVar "nA")))) (ELit (LString " +"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "range") (EVar "j")) (EVar "nB")))) (ELit (LString " @@\n")))) (DoExpr (EApp (EVar "concat") (EBinOp "::" (EVar "header") (EApp (EApp (EMethodRef "map") (EVar "renderEntry")) (EVar "es")))))))
(DTypeSig false "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "range" ((PVar "before") (PVar "count")) (EIf (EBinOp "==" (EDictApp "count") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "before"))) (ELit (LString ",0"))) (EIf (EBinOp "==" (EDictApp "count") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EBinOp "+" (EVar "before") (ELit (LInt 1))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EBinOp "+" (EVar "before") (ELit (LInt 1))))) (ELit (LString ","))) (EApp (EMethodRef "display") (EDictApp "count"))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isInsert" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isInsert" ((PCon "Entry" (PCon "Insert" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isInsert" (PWild) (EVar "False"))
(DTypeSig false "isDelete" (TyFun (TyCon "Entry") (TyCon "Bool")))
(DFunDef false "isDelete" ((PCon "Entry" (PCon "Delete" PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isDelete" (PWild) (EVar "False"))
(DTypeSig false "renderEntry" (TyFun (TyCon "Entry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "Entry" (PVar "e") PWild PWild)) (EMatch (EVar "e") (arm (PCon "Keep" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString " "))) (EVar "l"))) (arm (PCon "Delete" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString "-"))) (EVar "l"))) (arm (PCon "Insert" (PVar "l")) () (EApp (EApp (EVar "renderLine") (ELit (LString "+"))) (EVar "l")))))
(DTypeSig false "renderLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renderLine" ((PVar "sign") (PVar "l")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\n"))) (EVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sign"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sign"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "\n\\ No newline at end of file\n")))))
