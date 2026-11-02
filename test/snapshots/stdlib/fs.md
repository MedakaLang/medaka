# META
source_lines=539
stages=DESUGAR,MARK
# SOURCE
{- | Filesystem helpers built on the host file primitives.

   The primitives are in scope without an import: `readFile`, `writeFile`,
   `appendFile`, `readFileBytes`, `writeFileBytes`, `fileExists`, `listDir`,
   `makeDir`, `removeFile`, `rename`, `removeDir`, `statFile`, and
   `canonicalizePath`. This module adds a `FileStat` record over
   `statFile`'s tuple and the composed operations `copyFile`,
   `replaceDurably`, `mkdirAll`, `mkdirAllDurably`, `walkDir`, `walkFiles`, `walkFilesSkipping`,
   `glob`, `isDir`,
   `isFile`, and `fileSize`.

   Every operation returns `Result String a`, with the host's error message
   in `Err`.

   `medaka run`, `medaka test` and a built program touch the real filesystem.
   Only `medaka test --engines eval` and `medaka repl` do not bind the file
   primitives, so a doctest that reaches one is rejected there; see
   [ENGINES](ENGINES.md) for every engine. -}

import core.{Result(..)}
import io.{ownerOnlyMode}
import list.{sortOn}
import path.{dirname, globReaches, joinPath, matchGlob, segments}
import string.{contains, endsWith, indexOf, lastIndexOf, startsWith}

-- # Metadata

{- | What `stat` reports about a path: its size in bytes, whether it is a
   directory, whether it is a regular file, and its modification time in
   seconds since the Unix epoch. -}
public export data FileStat = FileStat {
  size : Int,
  isDir : Bool,
  isFile : Bool,
  mtime : Float,
} deriving (Eq, Debug)

{- | The metadata of a path as a `FileStat`, or `Err` when the path cannot
   be examined, for instance because it does not exist. -}
export
stat : (path : String) -> <FileRead path> Result String FileStat
stat p =
  map
    ((sz, d, f, m) => FileStat { size = sz, isDir = d, isFile = f, mtime = m })
    (statFile p)

{- | Whether a path exists and is a directory. -}
export
isDir : (path : String) -> <FileRead path> Result String Bool
isDir p = map (st => st.isDir) (stat p)

{- | Whether a path exists and is a regular file. -}
export
isFile : (path : String) -> <FileRead path> Result String Bool
isFile p = map (st => st.isFile) (stat p)

{- | The size of a file in bytes. -}
export
fileSize : (path : String) -> <FileRead path> Result String Int
fileSize p = map (st => st.size) (stat p)

-- # Operations

{- | Copies the bytes of `src` to `dst`, replacing any existing `dst`.

   A read failure is reported before anything is written. -}
export
copyFile : (src : String) ->
  (dst : String) ->
  <FileRead src, FileWrite dst> Result String Unit
copyFile src dst = match readFileBytes src
  Ok bytes => writeFileBytes dst bytes
  Err e => Err e

{- | Rewrites the file at `path` with the result of `f` applied to its text.

   `Err` from `f` writes nothing and is returned as `Err "<path>: <e>"`, as
   is a failure to read or to write. The file is written only when the new text differs
   from what was read, so an unchanged edit leaves the modification time
   alone. The write is a plain `writeFile`, not a durable replace. -}
export
editFile : (path : String) ->
  (String -> Result String String) ->
  <FileRead path, FileWrite path> Result String Unit
editFile path f = match readFile path
  Err e => Err (namePath path e)
  Ok text => match f text
    Err e => Err (namePath path e)
    Ok t =>
      if t == text then Ok () else mapErr (namePath path) (writeFile path t)

-- `e` led by `path: `, unless it already is.
namePath : String -> String -> String
namePath path e = if startsWith "\{path}: " e then e else "\{path}: \{e}"

{- | Replaces `target` with `content` so that a crash leaves either the
   old file or the new one, never a partial write.

   The content is written to `staged` at `io.ownerOnlyMode` (`0600`),
   `staged` is flushed, renamed onto `target`, and then the directory that
   holds `target` is flushed, in that order. The first step that fails
   returns its `Err` and the rest do not run. The mode is set before any
   byte is written, so neither the umask nor a leftover `staged` at a wider
   mode can widen it.

   `staged` must be on the same filesystem as `target`. A crash before the
   rename leaves `staged` behind, so a caller that stages into a directory
   it later lists must remove that residue itself. The directory holding
   `staged` is not flushed, and neither is the entry of `target`'s
   directory in its own parent; `mkdirAllDurably` covers that.

   > replaceDurably "stdlib/no-such-doctest-dir/r.tmp" "stdlib/no-such-doctest-dir/r" "v1"
   Err "No such file or directory" -}
export
replaceDurably : String -> String -> String -> <FileWrite> Result String Unit
replaceDurably staged target content = do
  () <- writeFileMode staged ownerOnlyMode content
  () <- fsync staged
  () <- rename staged target
  fsync (dirname target)

{- | Creates a directory and every missing parent, like `mkdir -p`.

   A directory that already exists is not an error. -}
export
mkdirAll : String -> <FileWrite> Result String Unit
mkdirAll path =
  if path == "" || path == "." || path == "/" then
    Ok ()
  else match mkdirAll (dirname path)
    Err e => Err e
    Ok _ => match makeDir path
      Ok _ => Ok ()
      -- EEXIST (strerror "File exists") is success; other errors propagate.
      Err e2 => if contains "exists" e2 then Ok () else Err e2

-- The examples use absolute paths: a relative one resolves against the directory the doctests run from, and would create directories there.
{- | Creates a directory and every missing parent, like `mkdirAll`, and
   makes each directory it creates durable by flushing that directory's
   parent right after creating it.

   A path that already exists is left alone and nothing is flushed, so a
   call on an existing directory costs one existence check.

   Known limit: a directory that already exists is taken to be durable.
   That is false for a directory whose creator stopped between creating it
   and flushing its parent. A later call finds it present and skips the
   flush, so a crash after that can still lose it. Closing the gap would
   mean flushing the parent on every call.

   > mkdirAllDurably "/dev/null"
   Ok ()
   > mkdirAllDurably "/dev/null/sub"
   Err "Not a directory" -}
export
mkdirAllDurably : String -> <FileRead, FileWrite> Result String Unit
mkdirAllDurably path =
  if path == "" || path == "." || path == "/" || fileExists path then
    Ok ()
  else do
    () <- mkdirAllDurably (dirname path)
    () <- mkdirAll path
    fsync (dirname path)

{- | Every path under a directory, files and subdirectories both, depth
   first.

   Each result is the full path, joined onto `root`. `Err` on the first
   directory that cannot be read or entry that cannot be examined. -}
export
walkDir : String -> <FileRead> Result String (List String)
walkDir root = match listDir root
  Err e => Err e
  Ok entries => walkEntries root entries

-- Each directory's result is built forward, so no pass is as deep as the
-- tree's total entry count: `run` has no tail calls, and a depth-limited
-- evaluator would otherwise overflow on a large tree.  The explicit `match`
-- chain, not a `do` block, keeps the per-entry frame count of a flat directory
-- at its current limit.
walkEntries : String -> List String -> <FileRead> Result String (List String)
walkEntries _ [] = Ok []
-- lint-disable-next-line rule-bind-chain-to-do
walkEntries root (name :: rest) =
  let full = joinPath root name
  match stat full
    Err e => Err e
    Ok st =>
      if st.isDir then match listDir full
        Err e => Err e
        Ok subs => match walkEntries full subs
          Err e => Err e
          Ok inner =>
            map (after => full :: inner ++ after) (walkEntries root rest)
      else
        map (full :: _) (walkEntries root rest)

{- | Every regular file under `root`, in plain string order.

   Each result is the full path, joined onto `root`; directories are not
   listed, and `Ok []` means there are no files. `Err` on the first
   directory that cannot be read or entry that cannot be examined. The order
   does not depend on the host's `listDir` order, so the result is stable.
   Symbolic links are followed through `stat`, as `walkDir` does, so a link
   to a directory is walked and a link loop reports an `Err`. An `Err` names
   the path that failed, as `"<path>: <e>"`.

   > walkFiles "stdlib/no-such-walk-doctest-dir"
   Err "stdlib/no-such-walk-doctest-dir: No such file or directory" -}
export
walkFiles : String -> <FileRead> Result String (List String)
walkFiles root = walkFilesSkipping (_ => False) root

{- | `walkFiles`, but a directory whose path satisfies `skip` is not entered.

   The path the predicate sees is the one `walkFiles` would report for that
   directory, joined onto `root`. `root` itself is never tested, so a
   predicate that holds for it still walks it.

   > walkFilesSkipping (_ => True) "stdlib/no-such-walk-doctest-dir"
   Err "stdlib/no-such-walk-doctest-dir: No such file or directory" -}
export
walkFilesSkipping : (String -> Bool) ->
  String ->
  <FileRead> Result String (List String)
walkFilesSkipping skip root = walkFilesTo FilesOnly (-1) skip root

-- What a walk reports: only the files, or the directories as well.
data WalkKind = FilesOnly | FilesAndDirs

listsDirs : WalkKind -> Bool
listsDirs FilesOnly = False
listsDirs FilesAndDirs = True

-- The walk of `walkFilesSkipping`, descending at most `levels` directories
-- below `root` when `levels` is positive and without limit when it is
-- negative. Files in `root` are one level down, so a bound of 1 stats only
-- `root`'s own entries. With `FilesAndDirs`, the result lists directories (each as
-- its path plus a `/`, ahead of its contents) instead of files, and a
-- directory at the last level is listed without being entered.
walkFilesTo : WalkKind ->
  Int ->
  (String -> Bool) ->
  String ->
  <FileRead> Result String (List String)
walkFilesTo kind levels skip root = match listDir root
  Err e => Err (namePath root e)
  Ok names => walkDirSorted kind levels skip root names

-- A directory's entries, kept when a file or a directory not skipped, each as
-- (sort key, full path, is a directory). A directory's key ends in `/`, so
-- ordering the entries by key orders every path beneath them as plain
-- strings: no name contains `/`.
type WalkEntry = (String, String, Bool)

-- Sorting each directory's entries, rather than the whole result, keeps every
-- pass as deep as one directory is wide: `run` has no tail calls, and a sort
-- of the full result would overflow on a large tree.  Each directory's result
-- is built forward by explicit `match` chains, as in `walkEntries`.
collectEntries : WalkKind ->
  Int ->
  (String -> Bool) ->
  String ->
  List String ->
  <FileRead> Result String (List WalkEntry)
collectEntries _ _ _ _ [] = Ok []
-- lint-disable-next-line rule-bind-chain-to-do
collectEntries kind levels skip root (name :: rest) =
  let full = joinPath root name
  match stat full
    Err e => Err (namePath full e)
    Ok st =>
      if st.isDir then
        if skip full || levels == 1 && not (listsDirs kind) then
          collectEntries kind levels skip root rest
        else
          map
            (("\{name}/", full, True) :: _)
            (collectEntries kind levels skip root rest)
      else if st.isFile then
        map
          ((name, full, False) :: _)
          (collectEntries kind levels skip root rest)
      else
        collectEntries kind levels skip root rest

-- A `do` chain would cost more frames per entry than the explicit `match`
-- chains here, lowering the widest directory `run` can walk; the pass-through
-- `Err` arms stay for that reason.
walkDirSorted : WalkKind ->
  Int ->
  (String -> Bool) ->
  String ->
  List String ->
  <FileRead> Result String (List String)
-- lint-disable-next-line rule-bind-chain-to-do
walkDirSorted kind levels skip root names =
  match collectEntries kind levels skip root names
    Err e => Err e
    Ok entries =>
      walkSorted kind levels skip (sortOn ((key, _, _) => key) entries)

walkSorted : WalkKind ->
  Int ->
  (String -> Bool) ->
  List WalkEntry ->
  <FileRead> Result String (List String)
walkSorted _ _ _ [] = Ok []
-- A `do` chain per entry would cost more frames per entry than this `match`
-- chain, lowering the widest directory `run` can walk.
-- lint-disable-next-line rule-bind-chain-to-do
walkSorted kind levels skip ((_, full, isDirectory) :: rest) =
  if isDirectory then
    if listsDirs kind && levels == 1 then
      map ("\{full}/" :: _) (walkSorted kind levels skip rest)
    else match listDir full
      Err e => Err (namePath full e)
      Ok subs => match walkDirSorted kind (belowLevel levels) skip full subs
        Err e => Err e
        Ok inner =>
          let here = if listsDirs kind then "\{full}/" :: inner else inner
          map (here ++ _) (walkSorted kind levels skip rest)
  else if listsDirs kind then
    walkSorted kind levels skip rest
  else
    map (full :: _) (walkSorted kind levels skip rest)

belowLevel : Int -> Int
belowLevel levels = if levels < 0 then levels else levels - 1

{- | The files whose paths match the glob `pattern`, in plain string order.

   The pattern is read as by `path.matchGlob`. The walk starts at the
   longest directory prefix of the pattern that has no `*` or `?`, and a
   result reads as the pattern does: `*.mdk` finds `a.mdk`, not `./a.mdk`.
   A pattern with no wildcard names one path, which is returned when it is a
   file and is otherwise `Ok []`. A prefix directory that is missing or
   cannot be read is an `Err` naming it, unlike Python's `glob`, which returns
   `[]`. Unless the pattern has a `**` segment the walk goes no deeper than
   the pattern's segments, so entries below that depth are never examined.

   A pattern ending in `/` finds directories instead of files, each reported
   with a trailing `/` as Python does, and the prefix directory itself is
   included when the pattern matches it, so `src/**/` finds `src/`. `*`
   and `?` match dot names, but `**` does not pass through a dot directory
   and the walk does not enter one the pattern cannot reach; a literal
   segment such as `.git` does. The result is what `path.matchGlob` accepts
   among all the files (or directories) under the prefix.

   > glob "stdlib/no-such-glob-doctest-dir/*.mdk"
   Err "stdlib/no-such-glob-doctest-dir: No such file or directory"
   > glob "no-such-glob-doctest-file"
   Ok [] -}
export
glob : String -> <FileRead> Result String (List String)
glob pattern =
  let dirs = endsWith "/" pattern
  match wildcardIndex pattern
    None => match stat pattern
      Ok st =>
        Ok (if (if dirs then st.isDir else st.isFile) then [pattern] else [])
      Err _ => Ok []
    Some i =>
      let prefix = dirPrefix (stringSlice 0 i pattern)
      let prefixDir = if prefix == "/" then "/" else "\{prefix}/"
      let own =
        if dirs && prefix /= "" && matchGlob pattern prefixDir then
          [prefixDir]
        else
          []
      map
        (paths =>
          own ++ filter (matchGlob pattern) (map (dropDotSlash prefix) paths))
        (walkFilesTo
          (if dirs then FilesAndDirs else FilesOnly)
          (globLevels prefix pattern)
          (globSkip dirs prefix pattern)
          (if prefix == "" then "." else prefix))

-- How many directory levels below the prefix a match can lie: the pattern's
-- segments past the prefix's, or unbounded (-1) when a segment is `**`.
globLevels : String -> String -> Int
globLevels prefix pattern =
  if any (== "**") (segments pattern) then
    -1
  else
    length (segments pattern) - length (segments prefix)

-- A dot directory is left unentered when nothing below it can match, and,
-- for a directory pattern, when it does not match itself.
globSkip : Bool -> String -> String -> String -> Bool
globSkip dirs prefix pattern full =
  let rel = dropDotSlash prefix full
  isDotName (segments rel)
    && not (globReaches pattern rel)
    && not (dirs && matchGlob pattern "\{rel}/")

isDotName : List String -> Bool
isDotName [] = False
isDotName [s] = startsWith "." s
isDotName (_ :: rest) = isDotName rest

wildcardIndex : String -> Option Int
wildcardIndex s = match (indexOf "*" s, indexOf "?" s)
  (Some a, Some b) => Some (min a b)
  (Some a, None) => Some a
  (None, b) => b

-- The directory part of a wildcard-free head: up to its last `/`, `"/"` when
-- that `/` is the first character, and `""` when there is none.
dirPrefix : String -> String
dirPrefix head = match lastIndexOf "/" head
  None => ""
  Some 0 => "/"
  Some j => stringSlice 0 j head

-- A walk from `"."` reports `./a`; the pattern reads `a`.
dropDotSlash : String -> String -> String
dropDotSlash prefix p =
  if prefix == "" && startsWith "./" p then
    stringSlice 2 (stringLength p) p
  else
    p

filesOnly : List String -> <FileRead> Result String (List String)
filesOnly [] = Ok []
filesOnly (p :: rest) = match isFile p
  Err e => Err e
  Ok True => map (p :: _) (filesOnly rest)
  Ok False => filesOnly rest

{- | Every regular file under `root`, depth first, or `Err` when there are
   none.

   `walkDir` with directories filtered out. A directory that reads cleanly
   but holds no files is an `Err`, so a test that iterates over a fixture
   directory cannot pass by iterating over nothing. Every result is a path
   under `root`.

   > fixtureFiles "stdlib/no-such-fixture-doctest-dir"
   Err "No such file or directory"
   > map (all (contains "/effect_set_fixtures/")) (fixtureFiles "test/effect_set_fixtures")
   Ok True -}
export
fixtureFiles : String -> <FileRead> Result String (List String)
fixtureFiles root = match walkDir root
  Err e => Err e
  Ok paths => match filesOnly paths
    Err e => Err e
    Ok [] => Err "\{root}: no fixture files found"
    Ok fs => Ok fs

dirsOnly : List String -> <FileRead> Result String (List String)
dirsOnly [] = Ok []
dirsOnly (p :: rest) = match isDir p
  Err e => Err e
  Ok True => map (p :: _) (dirsOnly rest)
  Ok False => dirsOnly rest

{- | Every top-level subdirectory of `root`, or `Err` when there are none.

   Not recursive. For a corpus where each fixture is a whole directory
   rather than a single file; `fixtureFiles` filters directories out. A
   directory with no subdirectories is an `Err`, as for `fixtureFiles`.
   Every result is a path under `root`.

   > fixtureDirs "stdlib/no-such-fixture-doctest-dir"
   Err "No such file or directory"
   > map (all (contains "/import_order_fixtures/")) (fixtureDirs "test/import_order_fixtures")
   Ok True -}
export
fixtureDirs : String -> <FileRead> Result String (List String)
fixtureDirs root = match listDir root
  Err e => Err e
  Ok names => match dirsOnly (map (joinPath root) names)
    Err e => Err e
    Ok [] => Err "\{root}: no fixture directories found"
    Ok ds => Ok ds

{- | `Ok` when `units` has exactly `want` elements, otherwise an `Err`
   naming both counts.

   A floor for a corpus with no roster to check against: it catches a
   corpus that grew or shrank, but not which unit changed. When a roster
   exists, `test_process.unrosteredUnits` and `test_process.missingUnits`
   say which.

   > expectUnitCount 2 ["a", "b"]
   Ok ()
   > expectUnitCount 3 ["a", "b"]
   Err "expected 3 units, found 2" -}
export
expectUnitCount : Int -> List a -> Result String Unit
expectUnitCount want units =
  let got = length units
  if got == want then
    Ok ()
  else
    Err "expected \{intToString want} units, found \{intToString got}"

-- ── Instance laws ────────────────────────────────────────────────────────────
-- `FileStat` is a plain record of four immutable fields, so derived `Eq` is
-- field-wise structural equality.  The externs above do not run under the
-- interpreter, so the laws are stated over hand-built records rather than over
-- a real `stat` call.

-- LAW: derived `Eq FileStat` is reflexive and discriminates on EVERY field --
-- a derived instance that silently ignored a field would still be reflexive,
-- so both halves are needed.
-- The prop pins the result of `==` itself (the `== False` form is the subject); a `not` or `/=` rewrite would exercise another path.
-- lint-disable-next-line rule-bool-simplify
prop "Eq FileStat is reflexive and field-discriminating" (n : Int) (b : Bool) =
  let base = FileStat {
    size = n,
    isDir = b,
    isFile = not b,
    mtime = intToFloat n,
  }
  base == base
    && base == FileStat { base | size = n + 1 } == False
    && base == FileStat { base | isDir = not b } == False
    && base == FileStat { base | isFile = b } == False
    && base == FileStat { base | mtime = intToFloat n + 1.0 } == False

-- LAW: derived `Debug FileStat` renders every field, so two records that
-- differ anywhere render differently (and equal records render identically).
-- The prop pins the result of `==` itself (the `== False` form is the subject); a `not` or `/=` rewrite would exercise another path.
-- lint-disable-next-line rule-bool-simplify
prop "Debug FileStat separates records that Eq separates" (n : Int) (b : Bool) =
  let x = FileStat { size = n, isDir = b, isFile = not b, mtime = intToFloat n }
  let y = FileStat { x | size = n + 1 }
  debug x
      == debug FileStat {
        size = n,
        isDir = b,
        isFile = not b,
        mtime = intToFloat n,
      }
    && debug x == debug y == False
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" true))))
(DUse false (UseGroup ("io") ((mem "ownerOnlyMode" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "globReaches" false) (mem "joinPath" false) (mem "matchGlob" false) (mem "segments" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "startsWith" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "FileStat")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) (PRec "FileStat" ((rf "size" (PVar "__b0")) (rf "isDir" (PVar "__b1")) (rf "isFile" (PVar "__b2")) (rf "mtime" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FileStat")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FileStat {")) (ELit (LString " size = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", isDir = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", isFile = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", mtime = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig true "stat" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "isDir" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyNamed "src" (TyCon "String")) (TyFun (TyNamed "dst" (TyCon "String")) (TyEffect ((atom "FileRead" (name "src")) (atom "FileWrite" (name "dst"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "editFile" (TyFun (TyNamed "path" (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ((atom "FileRead" (name "path")) (atom "FileWrite" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "editFile" ((PVar "path") (PVar "f")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "f") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "t")) () (EIf (EBinOp "==" (EVar "t") (EVar "text")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EApp (EVar "mapErr") (EApp (EVar "namePath") (EVar "path"))) (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "t")))))))))
(DTypeSig false "namePath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "namePath" ((PVar "path") (PVar "e")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": ")))) (EVar "e")) (EVar "e") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))
(DTypeSig true "replaceDurably" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "replaceDurably" ((PVar "staged") (PVar "target") (PVar "content")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "writeFileMode") (EVar "staged")) (EVar "ownerOnlyMode")) (EVar "content"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "fsync") (EVar "staged"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "rename") (EVar "staged")) (EVar "target"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "fsync") (EApp (EVar "dirname") (EVar "target"))))))))))))))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "mkdirAllDurably" (TyFun (TyCon "String") (TyEffect ("FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAllDurably" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "fileExists") (EVar "path"))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAllDurably") (EApp (EVar "dirname") (EVar "path")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EVar "path"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "fsync") (EApp (EVar "dirname") (EVar "path")))))))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "walkEntries" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "subs")) () (EMatch (EApp (EApp (EVar "walkEntries") (EVar "full")) (EVar "subs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "inner")) () (EApp (EApp (EVar "map") (ELam ((PVar "after")) (EBinOp "::" (EVar "full") (EBinOp "++" (EVar "inner") (EVar "after"))))) (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest"))))))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")))))))))
(DTypeSig true "walkFiles" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkFiles" ((PVar "root")) (EApp (EApp (EVar "walkFilesSkipping") (ELam (PWild) (EVar "False"))) (EVar "root")))
(DTypeSig true "walkFilesSkipping" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "walkFilesSkipping" ((PVar "skip") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "walkFilesTo") (EVar "FilesOnly")) (EUnOp "-" (ELit (LInt 1)))) (EVar "skip")) (EVar "root")))
(DData Private "WalkKind" () ((variant "FilesOnly" (ConPos)) (variant "FilesAndDirs" (ConPos))) ())
(DTypeSig false "listsDirs" (TyFun (TyCon "WalkKind") (TyCon "Bool")))
(DFunDef false "listsDirs" ((PCon "FilesOnly")) (EVar "False"))
(DFunDef false "listsDirs" ((PCon "FilesAndDirs")) (EVar "True"))
(DTypeSig false "walkFilesTo" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "walkFilesTo" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "root")) (EVar "e")))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EApp (EApp (EApp (EVar "walkDirSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "names")))))
(DTypeAlias false "WalkEntry" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "collectEntries" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "WalkEntry"))))))))))
(DFunDef false "collectEntries" (PWild PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "collectEntries" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "full")) (EVar "e")))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EIf (EBinOp "||" (EApp (EVar "skip") (EVar "full")) (EBinOp "&&" (EBinOp "==" (EVar "levels") (ELit (LInt 1))) (EApp (EVar "not") (EApp (EVar "listsDirs") (EVar "kind"))))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "/"))) (EVar "full") (EVar "True")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")))) (EIf (EFieldAccess (EVar "st") "isFile") (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "name") (EVar "full") (EVar "False")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")))))))))
(DTypeSig false "walkDirSorted" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "walkDirSorted" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root") (PVar "names")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "names")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EApp (EApp (EVar "sortOn") (ELam ((PTuple (PVar "key") PWild PWild)) (EVar "key"))) (EVar "entries"))))))
(DTypeSig false "walkSorted" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "WalkEntry")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "walkSorted" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "walkSorted" ((PVar "kind") (PVar "levels") (PVar "skip") (PCons (PTuple PWild (PVar "full") (PVar "isDirectory")) (PVar "rest"))) (EIf (EVar "isDirectory") (EIf (EBinOp "&&" (EApp (EVar "listsDirs") (EVar "kind")) (EBinOp "==" (EVar "levels") (ELit (LInt 1)))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "full"))) (ELit (LString "/"))) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest"))) (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "full")) (EVar "e")))) (arm (PCon "Ok" (PVar "subs")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "walkDirSorted") (EVar "kind")) (EApp (EVar "belowLevel") (EVar "levels"))) (EVar "skip")) (EVar "full")) (EVar "subs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "inner")) () (EBlock (DoLet false false (PVar "here") (EIf (EApp (EVar "listsDirs") (EVar "kind")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "full"))) (ELit (LString "/"))) (EVar "inner")) (EVar "inner"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "here") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest")))))))))) (EIf (EApp (EVar "listsDirs") (EVar "kind")) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest"))))))
(DTypeSig false "belowLevel" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "belowLevel" ((PVar "levels")) (EIf (EBinOp "<" (EVar "levels") (ELit (LInt 0))) (EVar "levels") (EBinOp "-" (EVar "levels") (ELit (LInt 1)))))
(DTypeSig true "glob" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "glob" ((PVar "pattern")) (EBlock (DoLet false false (PVar "dirs") (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "pattern"))) (DoExpr (EMatch (EApp (EVar "wildcardIndex") (EVar "pattern")) (arm (PCon "None") () (EMatch (EApp (EVar "stat") (EVar "pattern")) (arm (PCon "Ok" (PVar "st")) () (EApp (EVar "Ok") (EIf (EIf (EVar "dirs") (EFieldAccess (EVar "st") "isDir") (EFieldAccess (EVar "st") "isFile")) (EListLit (EVar "pattern")) (EListLit)))) (arm (PCon "Err" PWild) () (EApp (EVar "Ok") (EListLit))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "dirPrefix") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "pattern")))) (DoLet false false (PVar "prefixDir") (EIf (EBinOp "==" (EVar "prefix") (ELit (LString "/"))) (ELit (LString "/")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString "/"))))) (DoLet false false (PVar "own") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "dirs") (EBinOp "/=" (EVar "prefix") (ELit (LString "")))) (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EVar "prefixDir"))) (EListLit (EVar "prefixDir")) (EListLit))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "paths")) (EBinOp "++" (EVar "own") (EApp (EApp (EVar "filter") (EApp (EVar "matchGlob") (EVar "pattern"))) (EApp (EApp (EVar "map") (EApp (EVar "dropDotSlash") (EVar "prefix"))) (EVar "paths")))))) (EApp (EApp (EApp (EApp (EVar "walkFilesTo") (EIf (EVar "dirs") (EVar "FilesAndDirs") (EVar "FilesOnly"))) (EApp (EApp (EVar "globLevels") (EVar "prefix")) (EVar "pattern"))) (EApp (EApp (EApp (EVar "globSkip") (EVar "dirs")) (EVar "prefix")) (EVar "pattern"))) (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (ELit (LString ".")) (EVar "prefix")))))))))))
(DTypeSig false "globLevels" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "globLevels" ((PVar "prefix") (PVar "pattern")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "**"))))) (EApp (EVar "segments") (EVar "pattern"))) (EUnOp "-" (ELit (LInt 1))) (EBinOp "-" (EApp (EVar "length") (EApp (EVar "segments") (EVar "pattern"))) (EApp (EVar "length") (EApp (EVar "segments") (EVar "prefix"))))))
(DTypeSig false "globSkip" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "globSkip" ((PVar "dirs") (PVar "prefix") (PVar "pattern") (PVar "full")) (EBlock (DoLet false false (PVar "rel") (EApp (EApp (EVar "dropDotSlash") (EVar "prefix")) (EVar "full"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isDotName") (EApp (EVar "segments") (EVar "rel"))) (EApp (EVar "not") (EApp (EApp (EVar "globReaches") (EVar "pattern")) (EVar "rel")))) (EApp (EVar "not") (EBinOp "&&" (EVar "dirs") (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "rel"))) (ELit (LString "/"))))))))))
(DTypeSig false "isDotName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isDotName" ((PList)) (EVar "False"))
(DFunDef false "isDotName" ((PList (PVar "s"))) (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "s")))
(DFunDef false "isDotName" ((PCons PWild (PVar "rest"))) (EApp (EVar "isDotName") (EVar "rest")))
(DTypeSig false "wildcardIndex" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "wildcardIndex" ((PVar "s")) (EMatch (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "*"))) (EVar "s")) (EApp (EApp (EVar "indexOf") (ELit (LString "?"))) (EVar "s"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "min") (EVar "a")) (EVar "b")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "None")) () (EApp (EVar "Some") (EVar "a"))) (arm (PTuple (PCon "None") (PVar "b")) () (EVar "b"))))
(DTypeSig false "dirPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirPrefix" ((PVar "head")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "head")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PLit (LInt 0))) () (ELit (LString "/"))) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "head")))))
(DTypeSig false "dropDotSlash" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropDotSlash" ((PVar "prefix") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "p"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))
(DTypeSig false "filesOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "filesOnly" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "filesOnly" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isFile") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "p") (EVar "_s")))) (EApp (EVar "filesOnly") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "filesOnly") (EVar "rest")))))
(DTypeSig true "fixtureFiles" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fixtureFiles" ((PVar "root")) (EMatch (EApp (EVar "walkDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "paths")) () (EMatch (EApp (EVar "filesOnly") (EVar "paths")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ": no fixture files found"))))) (arm (PCon "Ok" (PVar "fs")) () (EApp (EVar "Ok") (EVar "fs")))))))
(DTypeSig false "dirsOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dirsOnly" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "dirsOnly" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isDir") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "p") (EVar "_s")))) (EApp (EVar "dirsOnly") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "dirsOnly") (EVar "rest")))))
(DTypeSig true "fixtureDirs" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fixtureDirs" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "names")) () (EMatch (EApp (EVar "dirsOnly") (EApp (EApp (EVar "map") (EApp (EVar "joinPath") (EVar "root"))) (EVar "names"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ": no fixture directories found"))))) (arm (PCon "Ok" (PVar "ds")) () (EApp (EVar "Ok") (EVar "ds")))))))
(DTypeSig true "expectUnitCount" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "expectUnitCount" ((PVar "want") (PVar "units")) (EBlock (DoLet false false (PVar "got") (EApp (EVar "length") (EVar "units"))) (DoExpr (EIf (EBinOp "==" (EVar "got") (EVar "want")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "want")))) (ELit (LString " units, found "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "got")))) (ELit (LString ""))))))))
(DProp false "Eq FileStat is reflexive and field-discriminating" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (EVar "base")) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isDir" (EApp (EVar "not") (EVar "b")))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isFile" (EVar "b"))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "mtime" (EBinOp "+" (EApp (EVar "intToFloat") (EVar "n")) (ELit (LFloat 1.0))))))) (EVar "False"))))))
(DProp false "Debug FileStat separates records that Eq separates" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "x") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoLet false false (PVar "y") (EVariantUpdate "FileStat" (EVar "x") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EVar "x")) (EApp (EVar "debug") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n"))))))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EVar "x")) (EApp (EVar "debug") (EVar "y"))) (EVar "False"))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" true))))
(DUse false (UseGroup ("io") ((mem "ownerOnlyMode" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "globReaches" false) (mem "joinPath" false) (mem "matchGlob" false) (mem "segments" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "startsWith" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "FileStat")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) (PRec "FileStat" ((rf "size" (PVar "__b0")) (rf "isDir" (PVar "__b1")) (rf "isFile" (PVar "__b2")) (rf "mtime" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FileStat")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FileStat {")) (ELit (LString " size = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", isDir = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", isFile = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", mtime = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig true "stat" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "isDir" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyNamed "path" (TyCon "String")) (TyEffect ((atom "FileRead" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyNamed "src" (TyCon "String")) (TyFun (TyNamed "dst" (TyCon "String")) (TyEffect ((atom "FileRead" (name "src")) (atom "FileWrite" (name "dst"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "editFile" (TyFun (TyNamed "path" (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ((atom "FileRead" (name "path")) (atom "FileWrite" (name "path"))) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "editFile" ((PVar "path") (PVar "f")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "f") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "t")) () (EIf (EBinOp "==" (EVar "t") (EVar "text")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EApp (EVar "mapErr") (EApp (EVar "namePath") (EVar "path"))) (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "t")))))))))
(DTypeSig false "namePath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "namePath" ((PVar "path") (PVar "e")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": ")))) (EVar "e")) (EVar "e") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))
(DTypeSig true "replaceDurably" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "replaceDurably" ((PVar "staged") (PVar "target") (PVar "content")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "writeFileMode") (EVar "staged")) (EVar "ownerOnlyMode")) (EVar "content"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "fsync") (EVar "staged"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "rename") (EVar "staged")) (EVar "target"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "fsync") (EApp (EVar "dirname") (EVar "target"))))))))))))))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "mkdirAllDurably" (TyFun (TyCon "String") (TyEffect ("FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAllDurably" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "fileExists") (EVar "path"))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAllDurably") (EApp (EVar "dirname") (EVar "path")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EVar "path"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "fsync") (EApp (EVar "dirname") (EVar "path")))))))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "walkEntries" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "subs")) () (EMatch (EApp (EApp (EVar "walkEntries") (EVar "full")) (EVar "subs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "inner")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "after")) (EBinOp "::" (EVar "full") (EBinOp "++" (EVar "inner") (EVar "after"))))) (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest"))))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")))))))))
(DTypeSig true "walkFiles" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkFiles" ((PVar "root")) (EApp (EApp (EVar "walkFilesSkipping") (ELam (PWild) (EVar "False"))) (EVar "root")))
(DTypeSig true "walkFilesSkipping" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "walkFilesSkipping" ((PVar "skip") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "walkFilesTo") (EVar "FilesOnly")) (EUnOp "-" (ELit (LInt 1)))) (EVar "skip")) (EVar "root")))
(DData Private "WalkKind" () ((variant "FilesOnly" (ConPos)) (variant "FilesAndDirs" (ConPos))) ())
(DTypeSig false "listsDirs" (TyFun (TyCon "WalkKind") (TyCon "Bool")))
(DFunDef false "listsDirs" ((PCon "FilesOnly")) (EVar "False"))
(DFunDef false "listsDirs" ((PCon "FilesAndDirs")) (EVar "True"))
(DTypeSig false "walkFilesTo" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "walkFilesTo" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "root")) (EVar "e")))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EApp (EApp (EApp (EVar "walkDirSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "names")))))
(DTypeAlias false "WalkEntry" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "collectEntries" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "WalkEntry"))))))))))
(DFunDef false "collectEntries" (PWild PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "collectEntries" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "full")) (EVar "e")))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EIf (EBinOp "||" (EApp (EVar "skip") (EVar "full")) (EBinOp "&&" (EBinOp "==" (EVar "levels") (ELit (LInt 1))) (EApp (EVar "not") (EApp (EVar "listsDirs") (EVar "kind"))))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "/"))) (EVar "full") (EVar "True")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")))) (EIf (EFieldAccess (EVar "st") "isFile") (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "name") (EVar "full") (EVar "False")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "rest")))))))))
(DTypeSig false "walkDirSorted" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "walkDirSorted" ((PVar "kind") (PVar "levels") (PVar "skip") (PVar "root") (PVar "names")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "collectEntries") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "root")) (EVar "names")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EApp (EApp (EVar "sortOn") (ELam ((PTuple (PVar "key") PWild PWild)) (EVar "key"))) (EVar "entries"))))))
(DTypeSig false "walkSorted" (TyFun (TyCon "WalkKind") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "WalkEntry")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "walkSorted" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "walkSorted" ((PVar "kind") (PVar "levels") (PVar "skip") (PCons (PTuple PWild (PVar "full") (PVar "isDirectory")) (PVar "rest"))) (EIf (EVar "isDirectory") (EIf (EBinOp "&&" (EApp (EVar "listsDirs") (EVar "kind")) (EBinOp "==" (EVar "levels") (ELit (LInt 1)))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "full"))) (ELit (LString "/"))) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest"))) (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EVar "namePath") (EVar "full")) (EVar "e")))) (arm (PCon "Ok" (PVar "subs")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "walkDirSorted") (EVar "kind")) (EApp (EVar "belowLevel") (EVar "levels"))) (EVar "skip")) (EVar "full")) (EVar "subs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "inner")) () (EBlock (DoLet false false (PVar "here") (EIf (EApp (EVar "listsDirs") (EVar "kind")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "full"))) (ELit (LString "/"))) (EVar "inner")) (EVar "inner"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "here") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest")))))))))) (EIf (EApp (EVar "listsDirs") (EVar "kind")) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "walkSorted") (EVar "kind")) (EVar "levels")) (EVar "skip")) (EVar "rest"))))))
(DTypeSig false "belowLevel" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "belowLevel" ((PVar "levels")) (EIf (EBinOp "<" (EVar "levels") (ELit (LInt 0))) (EVar "levels") (EBinOp "-" (EVar "levels") (ELit (LInt 1)))))
(DTypeSig true "glob" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "glob" ((PVar "pattern")) (EBlock (DoLet false false (PVar "dirs") (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "pattern"))) (DoExpr (EMatch (EApp (EVar "wildcardIndex") (EVar "pattern")) (arm (PCon "None") () (EMatch (EApp (EVar "stat") (EVar "pattern")) (arm (PCon "Ok" (PVar "st")) () (EApp (EVar "Ok") (EIf (EIf (EVar "dirs") (EFieldAccess (EVar "st") "isDir") (EFieldAccess (EVar "st") "isFile")) (EListLit (EVar "pattern")) (EListLit)))) (arm (PCon "Err" PWild) () (EApp (EVar "Ok") (EListLit))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "dirPrefix") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "pattern")))) (DoLet false false (PVar "prefixDir") (EIf (EBinOp "==" (EVar "prefix") (ELit (LString "/"))) (ELit (LString "/")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString "/"))))) (DoLet false false (PVar "own") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "dirs") (EBinOp "/=" (EVar "prefix") (ELit (LString "")))) (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EVar "prefixDir"))) (EListLit (EVar "prefixDir")) (EListLit))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "paths")) (EBinOp "++" (EVar "own") (EApp (EApp (EMethodRef "filter") (EApp (EVar "matchGlob") (EVar "pattern"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "dropDotSlash") (EVar "prefix"))) (EVar "paths")))))) (EApp (EApp (EApp (EApp (EVar "walkFilesTo") (EIf (EVar "dirs") (EVar "FilesAndDirs") (EVar "FilesOnly"))) (EApp (EApp (EVar "globLevels") (EVar "prefix")) (EVar "pattern"))) (EApp (EApp (EApp (EVar "globSkip") (EVar "dirs")) (EVar "prefix")) (EVar "pattern"))) (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (ELit (LString ".")) (EVar "prefix")))))))))))
(DTypeSig false "globLevels" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "globLevels" ((PVar "prefix") (PVar "pattern")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "**"))))) (EApp (EVar "segments") (EVar "pattern"))) (EUnOp "-" (ELit (LInt 1))) (EBinOp "-" (EApp (EMethodRef "length") (EApp (EVar "segments") (EVar "pattern"))) (EApp (EMethodRef "length") (EApp (EVar "segments") (EVar "prefix"))))))
(DTypeSig false "globSkip" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "globSkip" ((PVar "dirs") (PVar "prefix") (PVar "pattern") (PVar "full")) (EBlock (DoLet false false (PVar "rel") (EApp (EApp (EVar "dropDotSlash") (EVar "prefix")) (EVar "full"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isDotName") (EApp (EVar "segments") (EVar "rel"))) (EApp (EVar "not") (EApp (EApp (EVar "globReaches") (EVar "pattern")) (EVar "rel")))) (EApp (EVar "not") (EBinOp "&&" (EVar "dirs") (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "rel"))) (ELit (LString "/"))))))))))
(DTypeSig false "isDotName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isDotName" ((PList)) (EVar "False"))
(DFunDef false "isDotName" ((PList (PVar "s"))) (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "s")))
(DFunDef false "isDotName" ((PCons PWild (PVar "rest"))) (EApp (EVar "isDotName") (EVar "rest")))
(DTypeSig false "wildcardIndex" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "wildcardIndex" ((PVar "s")) (EMatch (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "*"))) (EVar "s")) (EApp (EApp (EVar "indexOf") (ELit (LString "?"))) (EVar "s"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EMethodRef "min") (EVar "a")) (EVar "b")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "None")) () (EApp (EVar "Some") (EVar "a"))) (arm (PTuple (PCon "None") (PVar "b")) () (EVar "b"))))
(DTypeSig false "dirPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirPrefix" ((PVar "head")) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "/"))) (EVar "head")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PLit (LInt 0))) () (ELit (LString "/"))) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "head")))))
(DTypeSig false "dropDotSlash" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropDotSlash" ((PVar "prefix") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "p"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))
(DTypeSig false "filesOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "filesOnly" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "filesOnly" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isFile") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "p") (EVar "_s")))) (EApp (EVar "filesOnly") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "filesOnly") (EVar "rest")))))
(DTypeSig true "fixtureFiles" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fixtureFiles" ((PVar "root")) (EMatch (EApp (EVar "walkDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "paths")) () (EMatch (EApp (EVar "filesOnly") (EVar "paths")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ": no fixture files found"))))) (arm (PCon "Ok" (PVar "fs")) () (EApp (EVar "Ok") (EVar "fs")))))))
(DTypeSig false "dirsOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dirsOnly" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "dirsOnly" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isDir") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "p") (EVar "_s")))) (EApp (EVar "dirsOnly") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "dirsOnly") (EVar "rest")))))
(DTypeSig true "fixtureDirs" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fixtureDirs" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "names")) () (EMatch (EApp (EVar "dirsOnly") (EApp (EApp (EMethodRef "map") (EApp (EVar "joinPath") (EVar "root"))) (EVar "names"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ": no fixture directories found"))))) (arm (PCon "Ok" (PVar "ds")) () (EApp (EVar "Ok") (EVar "ds")))))))
(DTypeSig true "expectUnitCount" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "expectUnitCount" ((PVar "want") (PVar "units")) (EBlock (DoLet false false (PVar "got") (EApp (EMethodRef "length") (EVar "units"))) (DoExpr (EIf (EBinOp "==" (EVar "got") (EVar "want")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "want")))) (ELit (LString " units, found "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "got")))) (ELit (LString ""))))))))
(DProp false "Eq FileStat is reflexive and field-discriminating" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (EVar "base")) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isDir" (EApp (EVar "not") (EVar "b")))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isFile" (EVar "b"))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "mtime" (EBinOp "+" (EApp (EVar "intToFloat") (EVar "n")) (ELit (LFloat 1.0))))))) (EVar "False"))))))
(DProp false "Debug FileStat separates records that Eq separates" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "x") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoLet false false (PVar "y") (EVariantUpdate "FileStat" (EVar "x") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "x")) (EApp (EMethodRef "debug") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n"))))))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "x")) (EApp (EMethodRef "debug") (EVar "y"))) (EVar "False"))))))
