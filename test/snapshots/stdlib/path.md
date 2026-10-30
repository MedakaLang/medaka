# META
source_lines=407
stages=DESUGAR,MARK
# SOURCE
{- | Manipulation of `/`-separated paths as text.

   Nothing here touches the filesystem. A path is split, joined, and
   simplified by its text alone, so `normalize` cannot tell a directory
   from a symbolic link. `fs` is the module that reads the filesystem.

   An extension includes its leading dot: `extname "a.txt"` is `".txt"`.
   A name that starts with a dot and has no other dot, such as `.bashrc`,
   has no extension. -}

-- This module is the public-API sibling of the compiler-private
-- `compiler/support/path.mdk` (a minimal internal helper used by the
-- self-hosted compiler's own module loader); the two are not merged because
-- `compiler/` deliberately avoids depending on `stdlib/`'s heavier surface
-- for its own bootstrap path.

import list.{reverse}
import string.{split, startsWith, endsWith, contains, lastIndexOf, toChars}

-- # Components

{- | The directory part of a path: everything before the last `/`.

   `"."` when the path has no `/`. A trailing `/` is itself the last `/`, so
   it is stripped without also dropping the segment before it: `dirname "a/"`
   is `"a"`, not `"."`. Apply `normalize` first to collapse a trailing slash
   when that segment should be dropped as well.

   > dirname "a/b/c.txt"
   "a/b"
   > dirname "c.txt"
   "."
   > dirname "/a"
   "/" -}
export
dirname : String -> String
dirname path = match lastIndexOf "/" path
  None => "."
  Some i =>
    let head = stringSlice 0 i path
    if head == "" then "/" else head

{- | The last component of a path: everything after the last `/`.

   The whole path when it has no `/`, and `""` when it ends in `/`. Apply
   `normalize` first to ignore a trailing slash.

   > basename "a/b/c.txt"
   "c.txt"
   > basename "a/b/"
   "" -}
export
basename : String -> String
basename path = match lastIndexOf "/" path
  None => path
  Some i => stringSlice (i + 1) (stringLength path) path

-- > basename "c.txt"
-- "c.txt"

{- | The extension of the last component, with its dot.

   `""` when there is none, including for a name that starts with its only
   dot.

   > extname "a/b/c.txt"
   ".txt"
   > extname ".bashrc"
   "" -}
export
extname : String -> String
extname path =
  let b = basename path
  match lastIndexOf "." b
    None => ""
    Some j => if j == 0 then "" else stringSlice j (stringLength b) b

-- > extname "README"
-- ""

{- | The last component without its extension.

   > stem "a/b/c.txt"
   "c"
   > stem ".bashrc"
   ".bashrc" -}
export
stem : String -> String
stem path =
  let b = basename path
  let e = extname path
  if e == "" then b else stringSlice 0 (stringLength b - stringLength e) b

{- | Whether the last component has the extension `ext`.

   The leading dot on `ext` is optional.

   > hasExtension "txt" "a/b.txt"
   True
   > hasExtension ".md" "a/b.txt"
   False -}
export
hasExtension : String -> String -> Bool
hasExtension ext path = normalizeExt (extname path) == normalizeExt ext

normalizeExt : String -> String
normalizeExt e = if startsWith "." e || e == "" then e else "." ++ e

{- | The path with the last component's extension replaced by `ext`.

   The leading dot on `ext` is optional. When the path has no extension,
   `ext` is appended.

   > withExtension ".md" "a/b.txt"
   "a/b.md"
   > withExtension "md" "a/b"
   "a/b.md" -}
export
withExtension : String -> String -> String
withExtension ext path =
  let base = basename path
  let e = extname path
  let newBase =
    (if e == "" then
        base
      else
        stringSlice 0 (stringLength base - stringLength e) base)
      ++ normalizeExt ext
  if contains "/" path then joinPath (dirname path) newBase else newBase

-- # Joining and splitting

{- | Two path segments joined with a single `/`.

   Slashes already at the boundary are collapsed, and an empty segment is
   skipped.

   > joinPath "a/b" "c.txt"
   "a/b/c.txt"
   > joinPath "a/b/" "/c.txt"
   "a/b/c.txt" -}
export
joinPath : String -> String -> String
joinPath a b =
  if a == "" then
    b
  else if b == "" then
    a
  else
    "\{stripTrailingSlash a}/\{stripLeadingSlash b}"

-- > joinPath "" "c.txt"
-- "c.txt"

stripTrailingSlash : String -> String
stripTrailingSlash s =
  if endsWith "/" s then stringSlice 0 (stringLength s - 1) s else s

stripLeadingSlash : String -> String
stripLeadingSlash s =
  if startsWith "/" s then stringSlice 1 (stringLength s) s else s

{- | The segments joined in order with `joinPath`.

   `""` for the empty list.

   > joinAll ["a", "b", "c.txt"]
   "a/b/c.txt" -}
export
joinAll : List String -> String
joinAll [] = ""
joinAll (s :: rest) = joinAllGo s rest

-- > joinAll []
-- ""

-- Same declared signature as `string.join`, but folds via `joinPath`'s
-- slash-normalizing join (collapses a trailing/leading `/` at each seam)
-- rather than `join`'s literal separator insertion — not a real duplicate.
joinAllGo : String -> List String -> String
-- lint-disable-next-line rule-stdlib-reimpl
joinAllGo acc [] = acc
joinAllGo acc (s :: rest) = joinAllGo (joinPath acc s) rest

{- | The non-empty components of a path, split on `/`.

   `.` and `..` are kept; apply `normalize` first to resolve them.

   > segments "a/b/c.txt"
   ["a", "b", "c.txt"]
   > segments "/a//b/"
   ["a", "b"] -}
export
segments : String -> List String
segments path = filterEmpty (split "/" path)

filterEmpty : List String -> List String
filterEmpty [] = []
filterEmpty (s :: rest) =
  if s == "" then filterEmpty rest else s :: filterEmpty rest

-- # Glob patterns

{- | Whether `path` matches the glob `pattern`.

   Both are split into segments on `/`, so repeated and trailing slashes do
   not matter, but a leading `/` must be on both or on neither. Within one
   segment `*` matches any run of characters and `?` exactly one character;
   neither crosses a `/`, and a leading `.` is matched like any other
   character. A segment that is exactly `**` matches any number of whole
   segments, none included, so `a/**/b` matches `a/b`. `**` inside a longer
   segment acts as `*`. There are no braces, character classes or escapes.
   The empty pattern matches only the empty path.

   > matchGlob "*.mdk" "a.mdk"
   True
   > matchGlob "*.mdk" "sub/a.mdk"
   False
   > matchGlob "a/**/b" "a/b"
   True
   > matchGlob "a/**/b" "a/x/y/b"
   True
   > matchGlob "a/**" "a/x/y"
   True
   > matchGlob "?.txt" "a.txt"
   True
   > matchGlob "?.txt" "ab.txt"
   False
   > matchGlob "a/b.txt" "a/b.txt"
   True
   > matchGlob "a**b" "axyb"
   True
   > matchGlob "a**b" "ax/yb"
   False
   > matchGlob "*" ".hidden"
   True
   > matchGlob "/a/*" "/a/b"
   True
   > matchGlob "/a/*" "a/b"
   False
   > matchGlob "a/*" "a/b/"
   True
   > matchGlob "" ""
   True
   > matchGlob "" "a"
   False
   > matchGlob "*a*a*a*a*a*a*b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
   False -}
export
matchGlob : String -> String -> Bool
matchGlob pattern path =
  isAbsolute pattern == isAbsolute path
    && matchSegments (segments pattern) (segments path)

matchSegments : List String -> List String -> Bool
matchSegments [] [] = True
matchSegments [] _ = False
matchSegments ("**" :: ps) xs = matchSegments ps xs || skipSegment ps xs
matchSegments (_ :: _) [] = False
matchSegments (p :: ps) (x :: xs) =
  matchChars (toList (toChars p)) (toList (toChars x)) && matchSegments ps xs

skipSegment : List String -> List String -> Bool
skipSegment _ [] = False
skipSegment ps (_ :: xs) = matchSegments ("**" :: ps) xs

-- Matches one segment by tracking every pattern suffix the text read so far
-- can leave unmatched, so the cost is the text length times the pattern
-- length however many `*` the pattern holds. A run of `*` counts as one.
matchChars : List Char -> List Char -> Bool
matchChars pat cs = matchRun (closeStars [collapseStars pat]) cs

collapseStars : List Char -> List Char
collapseStars ('*' :: '*' :: ps) = collapseStars ('*' :: ps)
collapseStars (p :: ps) = p :: collapseStars ps
collapseStars [] = []

matchRun : List (List Char) -> List Char -> Bool
matchRun [] _ = False
matchRun states [] = any (== []) states
matchRun states (c :: cs) = matchRun (closeStars (stepStates c states)) cs

-- Adds, after each suffix that starts with `*`, the suffix that skips it.
closeStars : List (List Char) -> List (List Char)
closeStars states = dedupeRuns (flatMap skipStar states)

skipStar : List Char -> List (List Char)
skipStar ('*' :: rest) = ['*' :: rest, rest]
skipStar s = [s]

stepStates : Char -> List (List Char) -> List (List Char)
stepStates c states = dedupeRuns (flatMap (stepState c) states)

stepState : Char -> List Char -> List (List Char)
stepState _ [] = []
stepState _ ('*' :: rest) = ['*' :: rest]
stepState _ ('?' :: rest) = [rest]
stepState c (p :: rest) = if p == c then [rest] else []

-- The suffixes arrive ordered by position, so equal ones are adjacent.
dedupeRuns : List (List Char) -> List (List Char)
dedupeRuns (a :: b :: rest) =
  if a == b then dedupeRuns (b :: rest) else a :: dedupeRuns (b :: rest)
dedupeRuns xs = xs

-- # Predicates

{- | Whether the path starts with `/`.

   > isAbsolute "/a/b"
   True
   > isAbsolute "a/b"
   False -}
export
isAbsolute : String -> Bool
isAbsolute path = startsWith "/" path

{- | The path with `prefix` removed from its front, or `None` when the path
   does not start with `prefix` at a component boundary.

   The empty prefix always matches.

   > stripPrefix "a/b" "a/b/c.txt"
   Some "c.txt"
   > stripPrefix "a/x" "a/b/c.txt"
   None -}
export
stripPrefix : String -> String -> Option String
-- Same declared signature as `string.stripPrefix`, but component-boundary
-- aware (only strips at a `/` or the end of the path, per the doctest
-- above) rather than a plain text-prefix strip — not a real duplicate.
-- lint-disable-next-line rule-stdlib-reimpl
stripPrefix prefix path =
  let plen = stringLength prefix
  if prefix == "" then
    Some path
  else if not (startsWith prefix path) then
    None
  else if stringLength path == plen then
    Some ""
  else if stringSlice plen (plen + 1) path == "/" then
    Some (stringSlice (plen + 1) (stringLength path) path)
  else
    None

-- > stripPrefix "a/b" "a/b"
-- Some ""
-- > stripPrefix "" "a/b"
-- Some "a/b"

-- # Normalization

{- | The path simplified by its text alone.

   Repeated `/` are collapsed, `.` segments are dropped, a `..` cancels the
   segment before it, and a trailing `/` is dropped. A leading `..` on a
   relative path is kept, and a `..` above the root of an absolute path is
   dropped. The empty path becomes `"."`.

   > normalize "a//b/./c/../d"
   "a/b/d"
   > normalize "../a/../../b"
   "../../b" -}
export
normalize : String -> String
normalize path =
  let abs = isAbsolute path
  let cleaned = normGo abs (segments path) []
  let body = joinAll (reverse cleaned)
  if abs then "/" ++ body else if body == "" then "." else body

-- > normalize "/../a"
-- "/a"
-- > normalize ""
-- "."

-- `abs`: on an absolute path, a `..` with nothing left to cancel is above the
-- root and is simply dropped; on a relative path it has no target to cancel
-- against, so it is kept (e.g. `../../b`).
normGo : Bool -> List String -> List String -> List String
normGo _ [] acc = acc
normGo abs ("." :: rest) acc = normGo abs rest acc
normGo abs (".." :: rest) [] =
  if abs then normGo abs rest [] else normGo abs rest [".."]
normGo abs (".." :: rest) (top :: acc2) =
  if top == ".." then
    normGo abs rest (".." :: ".." :: acc2)
  else
    normGo abs rest acc2
normGo abs (s :: rest) acc = normGo abs rest (s :: acc)

-- ── Properties ───────────────────────────────────────────────────────────

prop "normalize is idempotent" (p : String) =
  normalize (normalize p) == normalize p

prop "joinPath then split recovers both non-empty segments" (a : String) (b : String) =
  if a == "" || b == "" || contains "/" a || contains "/" b then
    True
  else
    segments (joinPath a b) == [a, b]

prop "dirname ++ / ++ basename normalizes back to the original absolute path" (p : String) =
  if p == "" || not (isAbsolute p) then
    True
  else
    normalize (joinPath (dirname p) (basename p)) == normalize p
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "endsWith" false) (mem "contains" false) (mem "lastIndexOf" false) (mem "toChars" false))))
(DTypeSig true "dirname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirname" ((PVar "path")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "None") () (ELit (LString "."))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "head") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "head") (ELit (LString ""))) (ELit (LString "/")) (EVar "head")))))))
(DTypeSig true "basename" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "basename" ((PVar "path")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "None") () (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")))))
(DTypeSig true "extname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "extname" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "."))) (EVar "b")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "j")) () (EIf (EBinOp "==" (EVar "j") (ELit (LInt 0))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "j")) (EApp (EVar "stringLength") (EVar "b"))) (EVar "b"))))))))
(DTypeSig true "stem" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stem" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "b") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "b")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "b"))))))
(DTypeSig true "hasExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExtension" ((PVar "ext") (PVar "path")) (EBinOp "==" (EApp (EVar "normalizeExt") (EApp (EVar "extname") (EVar "path"))) (EApp (EVar "normalizeExt") (EVar "ext"))))
(DTypeSig false "normalizeExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeExt" ((PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "e")) (EBinOp "==" (EVar "e") (ELit (LString "")))) (EVar "e") (EBinOp "++" (ELit (LString ".")) (EVar "e"))))
(DTypeSig true "withExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withExtension" ((PVar "ext") (PVar "path")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoLet false false (PVar "newBase") (EBinOp "++" (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "base")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "base"))) (EApp (EVar "normalizeExt") (EVar "ext")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "path")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "path"))) (EVar "newBase")) (EVar "newBase")))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EVar "a") (ELit (LString ""))) (EVar "b") (EIf (EBinOp "==" (EVar "b") (ELit (LString ""))) (EVar "a") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "stripTrailingSlash") (EVar "a")))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "stripLeadingSlash") (EVar "b")))) (ELit (LString ""))))))
(DTypeSig false "stripTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EVar "s")) (EVar "s")))
(DTypeSig false "stripLeadingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripLeadingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "joinAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAll" ((PList)) (ELit (LString "")))
(DFunDef false "joinAll" ((PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EVar "s")) (EVar "rest")))
(DTypeSig false "joinAllGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinAllGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinAllGo" ((PVar "acc") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EApp (EApp (EVar "joinPath") (EVar "acc")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "segments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "segments" ((PVar "path")) (EApp (EVar "filterEmpty") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "path"))))
(DTypeSig false "filterEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterEmpty" ((PList)) (EListLit))
(DFunDef false "filterEmpty" ((PCons (PVar "s") (PVar "rest"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "filterEmpty") (EVar "rest")) (EBinOp "::" (EVar "s") (EApp (EVar "filterEmpty") (EVar "rest")))))
(DTypeSig true "matchGlob" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "matchGlob" ((PVar "pattern") (PVar "path")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "isAbsolute") (EVar "pattern")) (EApp (EVar "isAbsolute") (EVar "path"))) (EApp (EApp (EVar "matchSegments") (EApp (EVar "segments") (EVar "pattern"))) (EApp (EVar "segments") (EVar "path")))))
(DTypeSig false "matchSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "matchSegments" ((PList) (PList)) (EVar "True"))
(DFunDef false "matchSegments" ((PList) PWild) (EVar "False"))
(DFunDef false "matchSegments" ((PCons (PLit (LString "**")) (PVar "ps")) (PVar "xs")) (EBinOp "||" (EApp (EApp (EVar "matchSegments") (EVar "ps")) (EVar "xs")) (EApp (EApp (EVar "skipSegment") (EVar "ps")) (EVar "xs"))))
(DFunDef false "matchSegments" ((PCons PWild PWild) (PList)) (EVar "False"))
(DFunDef false "matchSegments" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EApp (EApp (EVar "matchChars") (EApp (EVar "toList") (EApp (EVar "toChars") (EVar "p")))) (EApp (EVar "toList") (EApp (EVar "toChars") (EVar "x")))) (EApp (EApp (EVar "matchSegments") (EVar "ps")) (EVar "xs"))))
(DTypeSig false "skipSegment" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "skipSegment" (PWild (PList)) (EVar "False"))
(DFunDef false "skipSegment" ((PVar "ps") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "matchSegments") (EBinOp "::" (ELit (LString "**")) (EVar "ps"))) (EVar "xs")))
(DTypeSig false "matchChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "Bool"))))
(DFunDef false "matchChars" ((PVar "pat") (PVar "cs")) (EApp (EApp (EVar "matchRun") (EApp (EVar "closeStars") (EListLit (EApp (EVar "collapseStars") (EVar "pat"))))) (EVar "cs")))
(DTypeSig false "collapseStars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))
(DFunDef false "collapseStars" ((PCons (PLit (LChar "*")) (PCons (PLit (LChar "*")) (PVar "ps")))) (EApp (EVar "collapseStars") (EBinOp "::" (ELit (LChar "*")) (EVar "ps"))))
(DFunDef false "collapseStars" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (EVar "p") (EApp (EVar "collapseStars") (EVar "ps"))))
(DFunDef false "collapseStars" ((PList)) (EListLit))
(DTypeSig false "matchRun" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "Bool"))))
(DFunDef false "matchRun" ((PList) PWild) (EVar "False"))
(DFunDef false "matchRun" ((PVar "states") (PList)) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EListLit)))) (EVar "states")))
(DFunDef false "matchRun" ((PVar "states") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "matchRun") (EApp (EVar "closeStars") (EApp (EApp (EVar "stepStates") (EVar "c")) (EVar "states")))) (EVar "cs")))
(DTypeSig false "closeStars" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "closeStars" ((PVar "states")) (EApp (EVar "dedupeRuns") (EApp (EApp (EVar "flatMap") (EVar "skipStar")) (EVar "states"))))
(DTypeSig false "skipStar" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "skipStar" ((PCons (PLit (LChar "*")) (PVar "rest"))) (EListLit (EBinOp "::" (ELit (LChar "*")) (EVar "rest")) (EVar "rest")))
(DFunDef false "skipStar" ((PVar "s")) (EListLit (EVar "s")))
(DTypeSig false "stepStates" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "stepStates" ((PVar "c") (PVar "states")) (EApp (EVar "dedupeRuns") (EApp (EApp (EVar "flatMap") (EApp (EVar "stepState") (EVar "c"))) (EVar "states"))))
(DTypeSig false "stepState" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "stepState" (PWild (PList)) (EListLit))
(DFunDef false "stepState" (PWild (PCons (PLit (LChar "*")) (PVar "rest"))) (EListLit (EBinOp "::" (ELit (LChar "*")) (EVar "rest"))))
(DFunDef false "stepState" (PWild (PCons (PLit (LChar "?")) (PVar "rest"))) (EListLit (EVar "rest")))
(DFunDef false "stepState" ((PVar "c") (PCons (PVar "p") (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "c")) (EListLit (EVar "rest")) (EListLit)))
(DTypeSig false "dedupeRuns" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "dedupeRuns" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dedupeRuns") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dedupeRuns") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DFunDef false "dedupeRuns" ((PVar "xs")) (EVar "xs"))
(DTypeSig true "isAbsolute" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAbsolute" ((PVar "path")) (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "path")) (EBlock (DoLet false false (PVar "plen") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "Some") (EVar "path")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path"))) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "path")) (EVar "plen")) (EApp (EVar "Some") (ELit (LString ""))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "plen")) (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EVar "path")) (ELit (LString "/"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path"))) (EVar "None"))))))))
(DTypeSig true "normalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalize" ((PVar "path")) (EBlock (DoLet false false (PVar "abs") (EApp (EVar "isAbsolute") (EVar "path"))) (DoLet false false (PVar "cleaned") (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EApp (EVar "segments") (EVar "path"))) (EListLit))) (DoLet false false (PVar "body") (EApp (EVar "joinAll") (EApp (EVar "reverse") (EVar "cleaned")))) (DoExpr (EIf (EVar "abs") (EBinOp "++" (ELit (LString "/")) (EVar "body")) (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (ELit (LString ".")) (EVar "body"))))))
(DTypeSig false "normGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "normGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString ".")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EVar "acc")))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PList)) (EIf (EVar "abs") (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EListLit)) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EListLit (ELit (LString ".."))))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PCons (PVar "top") (PVar "acc2"))) (EIf (EBinOp "==" (EVar "top") (ELit (LString ".."))) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EBinOp "::" (ELit (LString "..")) (EBinOp "::" (ELit (LString "..")) (EVar "acc2")))) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EVar "acc2"))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DProp false "normalize is idempotent" ((pp "p" (TyCon "String"))) (EBinOp "==" (EApp (EVar "normalize") (EApp (EVar "normalize") (EVar "p"))) (EApp (EVar "normalize") (EVar "p"))))
(DProp false "joinPath then split recovers both non-empty segments" ((pp "a" (TyCon "String")) (pp "b" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "a") (ELit (LString ""))) (EBinOp "==" (EVar "b") (ELit (LString "")))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "a"))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "b"))) (EVar "True") (EBinOp "==" (EApp (EVar "segments") (EApp (EApp (EVar "joinPath") (EVar "a")) (EVar "b"))) (EListLit (EVar "a") (EVar "b")))))
(DProp false "dirname ++ / ++ basename normalizes back to the original absolute path" ((pp "p" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EVar "not") (EApp (EVar "isAbsolute") (EVar "p")))) (EVar "True") (EBinOp "==" (EApp (EVar "normalize") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "p"))) (EApp (EVar "basename") (EVar "p")))) (EApp (EVar "normalize") (EVar "p")))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "endsWith" false) (mem "contains" false) (mem "lastIndexOf" false) (mem "toChars" false))))
(DTypeSig true "dirname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirname" ((PVar "path")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "None") () (ELit (LString "."))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "head") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "head") (ELit (LString ""))) (ELit (LString "/")) (EVar "head")))))))
(DTypeSig true "basename" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "basename" ((PVar "path")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "path")) (arm (PCon "None") () (EVar "path")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")))))
(DTypeSig true "extname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "extname" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "."))) (EVar "b")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "j")) () (EIf (EBinOp "==" (EVar "j") (ELit (LInt 0))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "j")) (EApp (EVar "stringLength") (EVar "b"))) (EVar "b"))))))))
(DTypeSig true "stem" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stem" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "b") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "b")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "b"))))))
(DTypeSig true "hasExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExtension" ((PVar "ext") (PVar "path")) (EBinOp "==" (EApp (EVar "normalizeExt") (EApp (EVar "extname") (EVar "path"))) (EApp (EVar "normalizeExt") (EVar "ext"))))
(DTypeSig false "normalizeExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeExt" ((PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "e")) (EBinOp "==" (EVar "e") (ELit (LString "")))) (EVar "e") (EBinOp "++" (ELit (LString ".")) (EVar "e"))))
(DTypeSig true "withExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withExtension" ((PVar "ext") (PVar "path")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoLet false false (PVar "newBase") (EBinOp "++" (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "base")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "base"))) (EApp (EVar "normalizeExt") (EVar "ext")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "path")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "path"))) (EVar "newBase")) (EVar "newBase")))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EVar "a") (ELit (LString ""))) (EVar "b") (EIf (EBinOp "==" (EVar "b") (ELit (LString ""))) (EVar "a") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "stripTrailingSlash") (EVar "a")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "stripLeadingSlash") (EVar "b")))) (ELit (LString ""))))))
(DTypeSig false "stripTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EVar "s")) (EVar "s")))
(DTypeSig false "stripLeadingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripLeadingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "joinAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAll" ((PList)) (ELit (LString "")))
(DFunDef false "joinAll" ((PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EVar "s")) (EVar "rest")))
(DTypeSig false "joinAllGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinAllGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinAllGo" ((PVar "acc") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EApp (EApp (EVar "joinPath") (EVar "acc")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "segments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "segments" ((PVar "path")) (EApp (EVar "filterEmpty") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "path"))))
(DTypeSig false "filterEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterEmpty" ((PList)) (EListLit))
(DFunDef false "filterEmpty" ((PCons (PVar "s") (PVar "rest"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "filterEmpty") (EVar "rest")) (EBinOp "::" (EVar "s") (EApp (EVar "filterEmpty") (EVar "rest")))))
(DTypeSig true "matchGlob" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "matchGlob" ((PVar "pattern") (PVar "path")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "isAbsolute") (EVar "pattern")) (EApp (EVar "isAbsolute") (EVar "path"))) (EApp (EApp (EVar "matchSegments") (EApp (EVar "segments") (EVar "pattern"))) (EApp (EVar "segments") (EVar "path")))))
(DTypeSig false "matchSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "matchSegments" ((PList) (PList)) (EVar "True"))
(DFunDef false "matchSegments" ((PList) PWild) (EVar "False"))
(DFunDef false "matchSegments" ((PCons (PLit (LString "**")) (PVar "ps")) (PVar "xs")) (EBinOp "||" (EApp (EApp (EVar "matchSegments") (EVar "ps")) (EVar "xs")) (EApp (EApp (EVar "skipSegment") (EVar "ps")) (EVar "xs"))))
(DFunDef false "matchSegments" ((PCons PWild PWild) (PList)) (EVar "False"))
(DFunDef false "matchSegments" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EApp (EApp (EVar "matchChars") (EApp (EMethodRef "toList") (EApp (EVar "toChars") (EVar "p")))) (EApp (EMethodRef "toList") (EApp (EVar "toChars") (EVar "x")))) (EApp (EApp (EVar "matchSegments") (EVar "ps")) (EVar "xs"))))
(DTypeSig false "skipSegment" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "skipSegment" (PWild (PList)) (EVar "False"))
(DFunDef false "skipSegment" ((PVar "ps") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "matchSegments") (EBinOp "::" (ELit (LString "**")) (EVar "ps"))) (EVar "xs")))
(DTypeSig false "matchChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "Bool"))))
(DFunDef false "matchChars" ((PVar "pat") (PVar "cs")) (EApp (EApp (EVar "matchRun") (EApp (EVar "closeStars") (EListLit (EApp (EVar "collapseStars") (EVar "pat"))))) (EVar "cs")))
(DTypeSig false "collapseStars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))
(DFunDef false "collapseStars" ((PCons (PLit (LChar "*")) (PCons (PLit (LChar "*")) (PVar "ps")))) (EApp (EVar "collapseStars") (EBinOp "::" (ELit (LChar "*")) (EVar "ps"))))
(DFunDef false "collapseStars" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (EVar "p") (EApp (EVar "collapseStars") (EVar "ps"))))
(DFunDef false "collapseStars" ((PList)) (EListLit))
(DTypeSig false "matchRun" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "Bool"))))
(DFunDef false "matchRun" ((PList) PWild) (EVar "False"))
(DFunDef false "matchRun" ((PVar "states") (PList)) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EListLit)))) (EVar "states")))
(DFunDef false "matchRun" ((PVar "states") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "matchRun") (EApp (EVar "closeStars") (EApp (EApp (EVar "stepStates") (EVar "c")) (EVar "states")))) (EVar "cs")))
(DTypeSig false "closeStars" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "closeStars" ((PVar "states")) (EApp (EVar "dedupeRuns") (EApp (EApp (EDictApp "flatMap") (EVar "skipStar")) (EVar "states"))))
(DTypeSig false "skipStar" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "skipStar" ((PCons (PLit (LChar "*")) (PVar "rest"))) (EListLit (EBinOp "::" (ELit (LChar "*")) (EVar "rest")) (EVar "rest")))
(DFunDef false "skipStar" ((PVar "s")) (EListLit (EVar "s")))
(DTypeSig false "stepStates" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "stepStates" ((PVar "c") (PVar "states")) (EApp (EVar "dedupeRuns") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "stepState") (EVar "c"))) (EVar "states"))))
(DTypeSig false "stepState" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "stepState" (PWild (PList)) (EListLit))
(DFunDef false "stepState" (PWild (PCons (PLit (LChar "*")) (PVar "rest"))) (EListLit (EBinOp "::" (ELit (LChar "*")) (EVar "rest"))))
(DFunDef false "stepState" (PWild (PCons (PLit (LChar "?")) (PVar "rest"))) (EListLit (EVar "rest")))
(DFunDef false "stepState" ((PVar "c") (PCons (PVar "p") (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "c")) (EListLit (EVar "rest")) (EListLit)))
(DTypeSig false "dedupeRuns" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "dedupeRuns" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dedupeRuns") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dedupeRuns") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DFunDef false "dedupeRuns" ((PVar "xs")) (EVar "xs"))
(DTypeSig true "isAbsolute" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAbsolute" ((PVar "path")) (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "path")) (EBlock (DoLet false false (PVar "plen") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "Some") (EVar "path")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path"))) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "path")) (EVar "plen")) (EApp (EVar "Some") (ELit (LString ""))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "plen")) (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EVar "path")) (ELit (LString "/"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path"))) (EVar "None"))))))))
(DTypeSig true "normalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalize" ((PVar "path")) (EBlock (DoLet false false (PVar "abs") (EApp (EVar "isAbsolute") (EVar "path"))) (DoLet false false (PVar "cleaned") (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EApp (EVar "segments") (EVar "path"))) (EListLit))) (DoLet false false (PVar "body") (EApp (EVar "joinAll") (EApp (EVar "reverse") (EVar "cleaned")))) (DoExpr (EIf (EMethodRef "abs") (EBinOp "++" (ELit (LString "/")) (EVar "body")) (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (ELit (LString ".")) (EVar "body"))))))
(DTypeSig false "normGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "normGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString ".")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EVar "acc")))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PList)) (EIf (EMethodRef "abs") (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EListLit)) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EListLit (ELit (LString ".."))))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PCons (PVar "top") (PVar "acc2"))) (EIf (EBinOp "==" (EVar "top") (ELit (LString ".."))) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EBinOp "::" (ELit (LString "..")) (EBinOp "::" (ELit (LString "..")) (EVar "acc2")))) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EVar "acc2"))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DProp false "normalize is idempotent" ((pp "p" (TyCon "String"))) (EBinOp "==" (EApp (EVar "normalize") (EApp (EVar "normalize") (EVar "p"))) (EApp (EVar "normalize") (EVar "p"))))
(DProp false "joinPath then split recovers both non-empty segments" ((pp "a" (TyCon "String")) (pp "b" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "a") (ELit (LString ""))) (EBinOp "==" (EVar "b") (ELit (LString "")))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "a"))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "b"))) (EVar "True") (EBinOp "==" (EApp (EVar "segments") (EApp (EApp (EVar "joinPath") (EVar "a")) (EVar "b"))) (EListLit (EVar "a") (EVar "b")))))
(DProp false "dirname ++ / ++ basename normalizes back to the original absolute path" ((pp "p" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EVar "not") (EApp (EVar "isAbsolute") (EVar "p")))) (EVar "True") (EBinOp "==" (EApp (EVar "normalize") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "p"))) (EApp (EVar "basename") (EVar "p")))) (EApp (EVar "normalize") (EVar "p")))))
