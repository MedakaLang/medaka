# META
source_lines=513
stages=DESUGAR,MARK
# SOURCE
-- Tests for the file primitives `stdlib/fs.mdk` builds on.

import fs.{
  editFile, glob, isDir, isFile, mkdirAll, stat, walkDir, walkFiles,
  walkFilesSkipping
}
import list.{sort}
import string.{contains, endsWith}
import path.{joinPath, matchGlob}
import test.{
  Expectation, expectEach, expectEqual, expectErrContains, fail, pass
}
import io.{runVerb}
import test_process.{scratchDir, withScratchDir}

-- `readFile` refuses a file that is not UTF-8 rather than decoding it lossily,
-- and its error names the path and the raw route.
test "readFile of a file that is not UTF-8 is an Err naming readFileBytes" =
  match scratchDir
    Err e => fail "no scratch directory: \{e}"
    Ok dir =>
      let path = joinPath dir "not-utf8.bin"
      let _ = writeFileBytes path [|0x61, 0xc0, 0xae|]
      expectErrContains
        "\{path}: not valid UTF-8 (use readFileBytes for raw bytes)"
        (readFile path)

-- A nested tree: two directories under the root, one of them holding a
-- directory of its own, several files in each.
buildTree : String -> <FileWrite> Result String Unit
buildTree root = do
  () <- mkdirAll (joinPath root "sub/deep")
  () <- mkdirAll (joinPath root "zed")
  () <- writeFile (joinPath root "a.txt") "a"
  () <- writeFile (joinPath root "sub/b.txt") "b"
  () <- writeFile (joinPath root "sub/c.txt") "c"
  () <- writeFile (joinPath root "sub/deep/d.txt") "d"
  () <- writeFile (joinPath root "zed/e.txt") "e"
  () <- writeFile (joinPath root "zed/f.txt") "f"
  () <- writeFile (joinPath root "g.txt") "g"
  Ok ()

-- The walk the spec describes, written without an accumulator: each entry of
-- `listDir` in turn, a subdirectory followed by its own contents. `walkDir`
-- must produce this order for any host `listDir` order.
expectedWalk : String -> <FileRead> Result String (List String)
expectedWalk dir = match listDir dir
  Err e => Err e
  Ok names => expectedEntries dir names

expectedEntries : String ->
  List String ->
  <FileRead> Result String (List String)
expectedEntries _ [] = Ok []
expectedEntries dir (name :: rest) =
  let full = joinPath dir name
  match isDir full
    Err e => Err e
    Ok False => map (full :: _) (expectedEntries dir rest)
    Ok True => do
      sub <- expectedWalk full
      tail <- expectedEntries dir rest
      Ok (full :: sub ++ tail)

walkOrderCheck : String -> <Exec, IO, FileRead, FileWrite> Expectation
walkOrderCheck dir = match buildTree dir
  Err e => fail "could not build the tree: \{e}"
  Ok _ => match (walkDir dir, expectedWalk dir)
    (Ok got, Ok want) => expectEqual want got
    (Err e, _) => fail "walkDir failed: \{e}"
    (_, Err e) => fail "the reference walk failed: \{e}"

-- `walkDir` lists a nested tree in document order: each directory is followed
-- by its contents, and a nested result stays in place.
test "walkDir lists a nested tree in document order, each directory before its contents" =
  withScratchDir walkOrderCheck

-- `n` empty files named `f1`..`fn` under `dir`.
writeEmptyFiles : String -> Int -> <FileWrite> Result String Unit
writeEmptyFiles dir n
  | n == 0 = Ok ()
  | otherwise = match writeFile (joinPath dir "f\{intToString n}") ""
    Err e => Err e
    Ok _ => writeEmptyFiles dir (n - 1)

-- `dirs` directories `d1`..`dn` of `files` empty files each under `root`.
buildWide : String -> Int -> Int -> <FileWrite> Result String Unit
buildWide root dirs files
  | dirs == 0 = Ok ()
  | otherwise =
    let dir = joinPath root "d\{intToString dirs}"
    match mkdirAll dir
      Err e => Err e
      Ok _ => match writeEmptyFiles dir files
        Err e => Err e
        Ok _ => buildWide root (dirs - 1) files

-- `walk` over a fresh tree of 30 directories of 1000 files: `count` results.
wideCheck : Int ->
  (String -> <FileRead> Result String (List String)) ->
  String ->
  <Exec, IO, FileRead, FileWrite> Expectation
wideCheck count walk dir = match buildWide dir 30 1000
  Err e => fail "could not build the tree: \{e}"
  Ok _ => expectEqual (Ok count) (map length (walk dir))

-- A result wider than the interpreter's recursion cap (25000): under `medaka
-- run`, which has no tail calls, any pass whose depth is the entry count
-- overflows.  This test runs natively, so it pins only the count.
test "walkDir returns every entry of a tree of 30030 entries" =
  withScratchDir (wideCheck 30030 walkDir)

-- # editFile

-- The text and modification time of a file, as one value to compare.
fileState : String -> <FileRead> Result String (String, Float)
fileState path = do
  text <- readFile path
  st <- stat path
  Ok (text, st.mtime)

-- Writes `before` to a fresh file, waits long enough for a rewrite to move the
-- modification time (`stat` reports whole seconds), then runs `edit` on it and reports the file's state
-- before and after together with the edit's own result.
editOutcome : String ->
  String ->
  (String -> Result String String) ->
  <Exec, IO, FileRead, FileWrite> Result String ((String, Float), (String, Float), Result String Unit)
editOutcome dir before edit = do
  let path = joinPath dir "target.txt"
  () <- writeFile path before
  s0 <- fileState path
  _ <- runVerb "sleep" ["1.1"]
  let r = editFile path edit
  s1 <- fileState path
  Ok (s0, s1, r)

test "editFile on an Err from the function writes nothing and prefixes the path" = withScratchDir
  (dir => match editOutcome dir "abc" (_ => Err "nope")
    Err e => fail "setup failed: \{e}"
    Ok (s0, s1, r) =>
      expectEqual (s0, Err "\{joinPath dir "target.txt"}: nope") (s1, r))

test "editFile with an Ok that changes nothing leaves text and mtime alone" = withScratchDir
  (dir => match editOutcome dir "abc" Ok
    Err e => fail "setup failed: \{e}"
    Ok (s0, s1, r) => expectEqual (s0, Ok ()) (s1, r))

test "editFile writes when the text changes" = withScratchDir
  (dir => match editOutcome dir "abc" (s => Ok (s ++ "d"))
    Err e => fail "setup failed: \{e}"
    Ok ((t0, m0), (t1, m1), r) =>
      expectEqual ("abc", "abcd", True, Ok ()) (t0, t1, m1 > m0, r))

test "editFile of a file that is not UTF-8 names the path once" = withScratchDir
  (dir =>
    let path = joinPath dir "not-utf8.bin"
    let _ = writeFileBytes path [|0x61, 0xc0, 0xae|]
    expectEqual (map (_ => ()) (readFile path)) (editFile path Ok))

-- A read-only file refuses the write open, except for root, which ignores
-- the mode, so the test passes without asserting when it runs as root. The
-- write extern discards some other write failures, which are not testable.
test "editFile on a write failure names the path" = withScratchDir (dir =>
  let path = joinPath dir "readonly.txt"
  match (
    writeFile path "abc",
    runVerb "chmod" ["444", path],
    runVerb "id" ["-u"],
  )
    (Ok _, Ok _, Ok (0, uid, _)) =>
      if uid == "0\n" then
        pass
      else
        expectErrContains "\{path}: " (editFile path (_ => Ok "x"))
    _ => fail "setup failed")

test "editFile on a missing file is an Err naming the path" = withScratchDir
  (dir =>
    expectErrContains
      (joinPath dir "absent.txt")
      (editFile (joinPath dir "absent.txt") Ok))

-- # walkFiles, walkFilesSkipping, glob

-- Files `a.txt`, `m.mdk`, `sub/b.txt`, `sub/x.mdk`, `sub/deep/d.mdk`,
-- `zed/e.txt`, and an `empty/inner` directory holding no file.
buildGlobTree : String -> <FileWrite> Result String Unit
buildGlobTree root = do
  () <- mkdirAll (joinPath root "sub/deep")
  () <- mkdirAll (joinPath root "zed")
  () <- mkdirAll (joinPath root "empty/inner")
  () <- writeFile (joinPath root "zed/e.txt") "e"
  () <- writeFile (joinPath root "sub/deep/d.mdk") "d"
  () <- writeFile (joinPath root "sub/x.mdk") "x"
  () <- writeFile (joinPath root "sub/b.txt") "b"
  () <- writeFile (joinPath root "m.mdk") "m"
  () <- writeFile (joinPath root "a.txt") "a"
  Ok ()

-- Runs `check` on a fresh tree under a scratch directory.
withGlobTree : (String -> <Exec, IO, FileRead, FileWrite> Expectation) ->
  <Exec, IO, FileRead, FileWrite> Expectation
withGlobTree check = withScratchDir (dir => match buildGlobTree dir
  Err e => fail "could not build the tree: \{e}"
  Ok _ => check dir)

rooted : String -> List String -> List String
rooted dir names = map (joinPath dir) names

test "walkFiles lists only files, in sorted order" = withGlobTree (dir =>
  expectEqual
    (Ok
      (rooted dir [
        "a.txt", "m.mdk", "sub/b.txt", "sub/deep/d.mdk", "sub/x.mdk",
        "zed/e.txt"
      ]))
    (walkFiles dir))

test "walkFiles of a directory with no files is Ok []" =
  withGlobTree (dir => expectEqual (Ok []) (walkFiles (joinPath dir "empty")))

test "walkFiles of a missing root is an Err naming the root and the host's message" = withGlobTree
  (dir =>
    let root = joinPath dir "absent"
    expectErrContains "\{root}: " (walkFiles root))

test "walkFilesSkipping of a missing root is an Err naming the root" = withGlobTree
  (dir =>
    let root = joinPath dir "absent"
    expectErrContains "\{root}: " (walkFilesSkipping (_ => False) root))

test "walkFilesSkipping does not enter a directory the predicate accepts" = withGlobTree
  (dir =>
    expectEqual
      (Ok (rooted dir ["a.txt", "m.mdk", "zed/e.txt"]))
      (walkFilesSkipping (contains "/sub") dir))

test "walkFilesSkipping never tests the root itself" = withGlobTree (dir =>
  let sub = joinPath dir "sub"
  expectEqual
    (Ok (rooted dir ["sub/b.txt", "sub/deep/d.mdk", "sub/x.mdk"]))
    (walkFilesSkipping (== sub) sub))

test "glob matches within one directory with *" = withGlobTree (dir =>
  expectEqual (Ok (rooted dir ["m.mdk"])) (glob (joinPath dir "*.mdk")))

test "glob with ** crosses directories, zero included" = withGlobTree (dir =>
  expectEqual
    (Ok (rooted dir ["sub/deep/d.mdk", "sub/x.mdk"]))
    (glob (joinPath dir "sub/**/*.mdk")))

test "glob of a path without a wildcard names that file" = withGlobTree (dir =>
  expectEqual (Ok [joinPath dir "m.mdk"]) (glob (joinPath dir "m.mdk")))

test "glob of a missing path without a wildcard is Ok []" =
  withGlobTree (dir => expectEqual (Ok []) (glob (joinPath dir "nope.mdk")))

test "glob of a directory path without a wildcard is Ok []" =
  withGlobTree (dir => expectEqual (Ok []) (glob (joinPath dir "sub")))

test "glob under a missing prefix directory is an Err naming it" = withGlobTree
  (dir =>
    let prefix = joinPath dir "absent"
    expectErrContains "\{prefix}: " (glob (joinPath prefix "*.mdk")))

-- `dang/top.txt`, and `dang/deep/broken`, a link to a file that does not exist.
buildDangling : String -> <Exec, IO, FileRead, FileWrite> Result String Unit
buildDangling root = do
  () <- mkdirAll (joinPath root "dang/deep")
  () <- writeFile (joinPath root "dang/top.txt") "t"
  _ <- runVerb "ln" ["-s", "nowhere", joinPath root "dang/deep/broken"]
  Ok ()

withDangling : (String -> <Exec, IO, FileRead, FileWrite> Expectation) ->
  <Exec, IO, FileRead, FileWrite> Expectation
withDangling check = withScratchDir (dir => match buildDangling dir
  Err e => fail "could not build the tree: \{e}"
  Ok _ => check dir)

-- The dangling link lies below the depth the pattern can reach, so a walk
-- that examined it would be an `Err`.
test "glob does not examine entries below the depth its pattern reaches" = withDangling
  (dir =>
    expectEqual
      (Ok [joinPath dir "dang/top.txt"])
      (glob (joinPath dir "dang/*.txt")))

test "glob with a ** segment walks the whole tree and meets the dangling link" = withDangling
  (dir =>
    expectErrContains
      (joinPath dir "dang/deep/broken: ")
      (glob (joinPath dir "dang/**/*.txt")))

test "walkFiles names the entry that failed" = withDangling (dir =>
  expectErrContains (joinPath dir "dang/deep/broken: ") (walkFiles dir))

test "glob of two segments reaches exactly two levels" = withGlobTree (dir =>
  expectEqual (Ok (rooted dir ["sub/b.txt"])) (glob (joinPath dir "sub/*.txt")))

-- The files of `dir` by name, sorted: the answer `glob "*"` must read as.
topFiles : List String -> <FileRead> Result String (List String)
topFiles [] = Ok []
topFiles (n :: rest) = match isFile n
  Err e => Err e
  Ok True => map (n :: _) (topFiles rest)
  Ok False => topFiles rest

test "glob with an empty prefix reads as the pattern does, without ./" =
  match listDir "."
    Err e => fail "listDir failed: \{e}"
    Ok names => expectEqual (map sort (topFiles names)) (glob "*")

test "walkFiles returns every file of a tree of 30030 entries" =
  withScratchDir (wideCheck 30000 walkFiles)

-- A name that sorts before `/` ("a b", "a-d", "a.c") comes before the contents
-- of the directory `a`, as plain string order on the full paths says.
test "walkFiles orders by whole path when a name sorts before the slash" = withScratchDir
  (dir => match buildTricky dir
    Err e => fail "setup failed: \{e}"
    Ok _ =>
      expectEqual
        (Ok (rooted dir ["a b", "a-d", "a.c", "a/x"]))
        (walkFiles dir))

buildTricky : String -> <FileWrite> Result String Unit
buildTricky dir = do
  () <- mkdirAll (joinPath dir "a")
  () <- writeFile (joinPath dir "a/x") ""
  () <- writeFile (joinPath dir "a b") ""
  () <- writeFile (joinPath dir "a-d") ""
  () <- writeFile (joinPath dir "a.c") ""
  Ok ()

-- # glob and dot directories

-- Files `.env`, `a.mdk`, `.git/config`, `.git/objects/x`, `.git/.hidden/y`,
-- `.venv/lib/z.mdk`, `sub/b.mdk`, `sub/inner/c.mdk`, `sub/inner/.hid`,
-- `sub/.dot/d.mdk`, and the directory `empty/nested`, which holds no file.
buildDotTree : String -> <FileWrite> Result String Unit
buildDotTree root = do
  () <- mkdirAll (joinPath root ".git/objects")
  () <- mkdirAll (joinPath root ".git/.hidden")
  () <- mkdirAll (joinPath root ".venv/lib")
  () <- mkdirAll (joinPath root "sub/inner")
  () <- mkdirAll (joinPath root "sub/.dot")
  () <- mkdirAll (joinPath root "empty/nested")
  () <- writeFile (joinPath root ".env") "e"
  () <- writeFile (joinPath root "a.mdk") "a"
  () <- writeFile (joinPath root ".git/config") "c"
  () <- writeFile (joinPath root ".git/objects/x") "x"
  () <- writeFile (joinPath root ".git/.hidden/y") "y"
  () <- writeFile (joinPath root ".venv/lib/z.mdk") "z"
  () <- writeFile (joinPath root "sub/b.mdk") "b"
  () <- writeFile (joinPath root "sub/inner/c.mdk") "c"
  () <- writeFile (joinPath root "sub/inner/.hid") "h"
  () <- writeFile (joinPath root "sub/.dot/d.mdk") "d"
  Ok ()

withDotTree : (String -> <Exec, IO, FileRead, FileWrite> Expectation) ->
  <Exec, IO, FileRead, FileWrite> Expectation
withDotTree check = withScratchDir (dir => match buildDotTree dir
  Err e => fail "could not build the tree: \{e}"
  Ok _ => check dir)

-- Every file and every directory under `root` (a directory with a trailing
-- slash, `root` itself included), as the unpruned walk of `walkDir`.
everyCandidate : String -> <FileRead> Result String (List String)
everyCandidate root = match walkDir root
  Err e => Err e
  Ok paths => map ("\{root}/" :: _) (slashDirs paths)

slashDirs : List String -> <FileRead> Result String (List String)
slashDirs [] = Ok []
slashDirs (p :: rest) = match isDir p
  Err e => Err e
  Ok d =>
    let marked = if d then "\{p}/" else p
    map (marked :: _) (slashDirs rest)

-- The answer `glob` must give: the candidates `matchGlob` accepts, files for
-- a pattern without a trailing slash and directories for one with.
oracle : String -> String -> <FileRead> Result String (List String)
oracle dir pattern =
  map
    (cs =>
      sort
        (filter
          (c => matchGlob pattern c && endsWith "/" c == endsWith "/" pattern)
          cs))
    (everyCandidate dir)

globAgrees : String -> String -> <FileRead> (String, Expectation)
globAgrees dir pattern =
  let full = joinPath dir pattern
  (pattern, expectEqual (oracle dir full) (glob full))

test "glob equals the unpruned matchGlob filter on every pattern" = withDotTree
  (dir =>
    expectEach
      (map (globAgrees dir) [
        "**/*", "**/*.mdk", "*", ".git/**", "sub/*/", "**/", ".*/", ".git/**/",
        "**/.*", "sub/**/*.mdk", "**/x", ".venv/**/*.mdk", "*/config", "sub/*",
        "empty/**/"
      ]))

test "glob with ** skips dot directories but reaches dotfiles" = withDotTree
  (dir => expectEach [
    (
      "**/*",
      expectEqual
        (Ok
          (rooted dir [
            ".env", "a.mdk", "sub/b.mdk", "sub/inner/.hid", "sub/inner/c.mdk"
          ]))
        (glob (joinPath dir "**/*")),
    ),
    (
      "**/*.mdk",
      expectEqual
        (Ok (rooted dir ["a.mdk", "sub/b.mdk", "sub/inner/c.mdk"]))
        (glob (joinPath dir "**/*.mdk")),
    ),
    (
      "**/.*",
      expectEqual
        (Ok (rooted dir [".env", "sub/inner/.hid"]))
        (glob (joinPath dir "**/.*")),
    ),
    ("**/x", expectEqual (Ok []) (glob (joinPath dir "**/x"))),
    (
      "sub/**/*.mdk",
      expectEqual
        (Ok (rooted dir ["sub/b.mdk", "sub/inner/c.mdk"]))
        (glob (joinPath dir "sub/**/*.mdk")),
    ),
  ])

test "glob with * matches dot names, and a literal dot directory is entered" = withDotTree
  (dir => expectEach [
    (
      "*",
      expectEqual (Ok (rooted dir [".env", "a.mdk"])) (glob (joinPath dir "*")),
    ),
    (
      ".git/**",
      expectEqual
        (Ok (rooted dir [".git/config", ".git/objects/x"]))
        (glob (joinPath dir ".git/**")),
    ),
    (
      "*/config",
      expectEqual
        (Ok (rooted dir [".git/config"]))
        (glob (joinPath dir "*/config")),
    ),
    (
      ".venv/**/*.mdk",
      expectEqual
        (Ok (rooted dir [".venv/lib/z.mdk"]))
        (glob (joinPath dir ".venv/**/*.mdk")),
    ),
  ])

test "glob with a trailing slash finds directories, written with the slash" = withDotTree
  (dir => expectEach [
    (
      "sub/*/",
      expectEqual
        (Ok (rooted dir ["sub/.dot/", "sub/inner/"]))
        (glob (joinPath dir "sub/*/")),
    ),
    (
      "**/",
      expectEqual
        (Ok
          ("\{dir}/"
            :: rooted dir ["empty/", "empty/nested/", "sub/", "sub/inner/"]))
        (glob (joinPath dir "**/")),
    ),
    (
      ".*/",
      expectEqual
        (Ok (rooted dir [".git/", ".venv/"]))
        (glob (joinPath dir ".*/")),
    ),
    (
      ".git/**/",
      expectEqual
        (Ok (rooted dir [".git/", ".git/objects/"]))
        (glob (joinPath dir ".git/**/")),
    ),
    (
      "sub/",
      expectEqual (Ok [joinPath dir "sub/"]) (glob (joinPath dir "sub/")),
    ),
    ("a.mdk/", expectEqual (Ok []) (glob (joinPath dir "a.mdk/"))),
  ])

test "glob of a trailing-slash pattern under a missing prefix is an Err" = withDotTree
  (dir =>
    let prefix = joinPath dir "absent"
    expectErrContains "\{prefix}: " (glob (joinPath prefix "*/")))

-- The dangling link sits inside a dot directory the pattern cannot reach, so
-- a walk that entered it would report an `Err`.
test "glob does not enter a dot directory its pattern cannot reach" = withDangling
  (dir =>
    let _ = runVerb "mv" [joinPath dir "dang/deep", joinPath dir "dang/.deep"]
    expectEqual
      (Ok [joinPath dir "dang/top.txt"])
      (glob (joinPath dir "dang/**/*.txt")))
# DESUGAR
(DUse false (UseGroup ("fs") ((mem "editFile" false) (mem "glob" false) (mem "isDir" false) (mem "isFile" false) (mem "mkdirAll" false) (mem "stat" false) (mem "walkDir" false) (mem "walkFiles" false) (mem "walkFilesSkipping" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false) (mem "matchGlob" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEach" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false) (mem "pass" false))))
(DUse false (UseGroup ("io") ((mem "runVerb" false))))
(DUse false (UseGroup ("test_process") ((mem "scratchDir" false) (mem "withScratchDir" false))))
(DTest false "readFile of a file that is not UTF-8 is an Err naming readFileBytes" (EMatch (EVar "scratchDir") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "no scratch directory: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "dir")) () (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "not-utf8.bin")))) (DoLet false false PWild (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EArrayLit (ELit (LInt 97)) (ELit (LInt 192)) (ELit (LInt 174))))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": not valid UTF-8 (use readFileBytes for raw bytes)")))) (EApp (EVar "readFile") (EVar "path"))))))))
(DTypeSig false "buildTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildTree" ((PVar "root")) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.txt")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.txt")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/c.txt")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep/d.txt")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/e.txt")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/f.txt")))) (ELit (LString "f")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "g.txt")))) (ELit (LString "g")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))
(DTypeSig false "expectedWalk" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expectedWalk" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "names")))))
(DTypeSig false "expectedEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "expectedEntries" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "expectedEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "isDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "False")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "rest")))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "andThen") (EApp (EVar "expectedWalk") (EVar "full"))) (ELam ((PVar "sub")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "rest"))) (ELam ((PVar "tail")) (EApp (EVar "Ok") (EBinOp "::" (EVar "full") (EBinOp "++" (EVar "sub") (EVar "tail")))))))))))))
(DTypeSig false "walkOrderCheck" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "walkOrderCheck" ((PVar "dir")) (EMatch (EApp (EVar "buildTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (ETuple (EApp (EVar "walkDir") (EVar "dir")) (EApp (EVar "expectedWalk") (EVar "dir"))) (arm (PTuple (PCon "Ok" (PVar "got")) (PCon "Ok" (PVar "want"))) () (EApp (EApp (EVar "expectEqual") (EVar "want")) (EVar "got"))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "walkDir failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "the reference walk failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))))))
(DTest false "walkDir lists a nested tree in document order, each directory before its contents" (EApp (EVar "withScratchDir") (EVar "walkOrderCheck")))
(DTypeSig false "writeEmptyFiles" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeEmptyFiles" ((PVar "dir") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EBinOp "++" (EBinOp "++" (ELit (LString "f")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))))) (ELit (LString ""))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "writeEmptyFiles") (EVar "dir")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildWide" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "buildWide" ((PVar "root") (PVar "dirs") (PVar "files")) (EIf (EBinOp "==" (EVar "dirs") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "dir") (EApp (EApp (EVar "joinPath") (EVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "d")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "dirs")))) (ELit (LString ""))))) (DoExpr (EMatch (EApp (EVar "mkdirAll") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeEmptyFiles") (EVar "dir")) (EVar "files")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "buildWide") (EVar "root")) (EBinOp "-" (EVar "dirs") (ELit (LInt 1)))) (EVar "files")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wideCheck" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))))
(DFunDef false "wideCheck" ((PVar "count") (PVar "walk") (PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "buildWide") (EVar "dir")) (ELit (LInt 30))) (ELit (LInt 1000))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "count"))) (EApp (EApp (EVar "map") (EVar "length")) (EApp (EVar "walk") (EVar "dir")))))))
(DTest false "walkDir returns every entry of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EApp (EApp (EVar "wideCheck") (ELit (LInt 30030))) (EVar "walkDir"))))
(DTypeSig false "fileState" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Float"))))))
(DFunDef false "fileState" ((PVar "path")) (EApp (EApp (EVar "andThen") (EApp (EVar "readFile") (EVar "path"))) (ELam ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "stat") (EVar "path"))) (ELam ((PVar "st")) (EApp (EVar "Ok") (ETuple (EVar "text") (EFieldAccess (EVar "st") "mtime"))))))))
(DTypeSig false "editOutcome" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyTuple (TyCon "String") (TyCon "Float")) (TyTuple (TyCon "String") (TyCon "Float")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "editOutcome" ((PVar "dir") (PVar "before") (PVar "edit")) (ELet false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "before"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s0")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "sleep"))) (EListLit (ELit (LString "1.1"))))) (ELam (PWild) (ELet false (PVar "r") (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "edit")) (EApp (EApp (EVar "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s1")) (EApp (EVar "Ok") (ETuple (EVar "s0") (EVar "s1") (EVar "r"))))))))))))))))
(DTest false "editFile on an Err from the function writes nothing and prefixes the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam (PWild) (EApp (EVar "Err") (ELit (LString "nope"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))))) (ELit (LString ": nope")))))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile with an Ok that changes nothing leaves text and mtime alone" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (EVar "Ok")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile writes when the text changes" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam ((PVar "s")) (EApp (EVar "Ok") (EBinOp "++" (EVar "s") (ELit (LString "d")))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PTuple (PVar "t0") (PVar "m0")) (PTuple (PVar "t1") (PVar "m1")) (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abcd")) (EVar "True") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "t0") (EVar "t1") (EBinOp ">" (EVar "m1") (EVar "m0")) (EVar "r"))))))))
(DTest false "editFile of a file that is not UTF-8 names the path once" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "not-utf8.bin")))) (DoLet false false PWild (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EArrayLit (ELit (LInt 97)) (ELit (LInt 192)) (ELit (LInt 174))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (ELam (PWild) (ELit LUnit))) (EApp (EVar "readFile") (EVar "path")))) (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "Ok"))))))))
(DTest false "editFile on a write failure names the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "readonly.txt")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "writeFile") (EVar "path")) (ELit (LString "abc"))) (EApp (EApp (EVar "runVerb") (ELit (LString "chmod"))) (EListLit (ELit (LString "444")) (EVar "path"))) (EApp (EApp (EVar "runVerb") (ELit (LString "id"))) (EListLit (ELit (LString "-u"))))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "uid") PWild))) () (EIf (EBinOp "==" (EVar "uid") (ELit (LString "0\n"))) (EVar "pass") (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": ")))) (EApp (EApp (EVar "editFile") (EVar "path")) (ELam (PWild) (EApp (EVar "Ok") (ELit (LString "x")))))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "setup failed"))))))))))
(DTest false "editFile on a missing file is an Err naming the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EApp (EApp (EVar "editFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EVar "Ok"))))))
(DTypeSig false "buildGlobTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildGlobTree" ((PVar "root")) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "empty/inner"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/e.txt")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep/d.mdk")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/x.mdk")))) (ELit (LString "x")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.txt")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "m.mdk")))) (ELit (LString "m")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.txt")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))
(DTypeSig false "withGlobTree" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withGlobTree" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildGlobTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTypeSig false "rooted" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rooted" ((PVar "dir") (PVar "names")) (EApp (EApp (EVar "map") (EApp (EVar "joinPath") (EVar "dir"))) (EVar "names")))
(DTest false "walkFiles lists only files, in sorted order" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.txt")) (ELit (LString "m.mdk")) (ELit (LString "sub/b.txt")) (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")) (ELit (LString "zed/e.txt")))))) (EApp (EVar "walkFiles") (EVar "dir"))))))
(DTest false "walkFiles of a directory with no files is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "walkFiles") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "empty"))))))))
(DTest false "walkFiles of a missing root is an Err naming the root and the host's message" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ": ")))) (EApp (EVar "walkFiles") (EVar "root"))))))))
(DTest false "walkFilesSkipping of a missing root is an Err naming the root" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ": ")))) (EApp (EApp (EVar "walkFilesSkipping") (ELam (PWild) (EVar "False"))) (EVar "root"))))))))
(DTest false "walkFilesSkipping does not enter a directory the predicate accepts" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.txt")) (ELit (LString "m.mdk")) (ELit (LString "zed/e.txt")))))) (EApp (EApp (EVar "walkFilesSkipping") (EApp (EVar "contains") (ELit (LString "/sub")))) (EVar "dir"))))))
(DTest false "walkFilesSkipping never tests the root itself" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "sub") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub")))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.txt")) (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")))))) (EApp (EApp (EVar "walkFilesSkipping") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "sub")))) (EVar "sub"))))))))
(DTest false "glob matches within one directory with *" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "m.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*.mdk"))))))))
(DTest false "glob with ** crosses directories, zero included" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/**/*.mdk"))))))))
(DTest false "glob of a path without a wildcard names that file" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "m.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "m.mdk"))))))))
(DTest false "glob of a missing path without a wildcard is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "nope.mdk"))))))))
(DTest false "glob of a directory path without a wildcard is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub"))))))))
(DTest false "glob under a missing prefix directory is an Err naming it" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ": ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "*.mdk"))))))))))
(DTypeSig false "buildDangling" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildDangling" ((PVar "root")) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/top.txt")))) (ELit (LString "t")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "ln"))) (EListLit (ELit (LString "-s")) (ELit (LString "nowhere")) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/deep/broken")))))) (ELam (PWild) (EApp (EVar "Ok") (ELit LUnit)))))))))))))
(DTypeSig false "withDangling" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withDangling" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildDangling") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTest false "glob does not examine entries below the depth its pattern reaches" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/top.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/*.txt"))))))))
(DTest false "glob with a ** segment walks the whole tree and meets the dangling link" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep/broken: ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/**/*.txt"))))))))
(DTest false "walkFiles names the entry that failed" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep/broken: ")))) (EApp (EVar "walkFiles") (EVar "dir"))))))
(DTest false "glob of two segments reaches exactly two levels" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/*.txt"))))))))
(DTypeSig false "topFiles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "topFiles" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "topFiles" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "isFile") (EVar "n")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "n") (EVar "_s")))) (EApp (EVar "topFiles") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "topFiles") (EVar "rest")))))
(DTest false "glob with an empty prefix reads as the pattern does, without ./" (EMatch (EApp (EVar "listDir") (ELit (LString "."))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "listDir failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "sort")) (EApp (EVar "topFiles") (EVar "names")))) (EApp (EVar "glob") (ELit (LString "*")))))))
(DTest false "walkFiles returns every file of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EApp (EApp (EVar "wideCheck") (ELit (LInt 30000))) (EVar "walkFiles"))))
(DTest false "walkFiles orders by whole path when a name sorts before the slash" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildTricky") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a b")) (ELit (LString "a-d")) (ELit (LString "a.c")) (ELit (LString "a/x")))))) (EApp (EVar "walkFiles") (EVar "dir"))))))))
(DTypeSig false "buildTricky" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildTricky" ((PVar "dir")) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a/x")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a b")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a-d")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a.c")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))
(DTypeSig false "buildDotTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildDotTree" ((PVar "root")) (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/objects"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/.hidden"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".venv/lib"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/.dot"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "empty/nested"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".env")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.mdk")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/config")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/objects/x")))) (ELit (LString "x")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/.hidden/y")))) (ELit (LString "y")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".venv/lib/z.mdk")))) (ELit (LString "z")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.mdk")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner/c.mdk")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner/.hid")))) (ELit (LString "h")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/.dot/d.mdk")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DTypeSig false "withDotTree" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withDotTree" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildDotTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTypeSig false "everyCandidate" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "everyCandidate" ((PVar "root")) (EMatch (EApp (EVar "walkDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "paths")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/"))) (EVar "_s")))) (EApp (EVar "slashDirs") (EVar "paths"))))))
(DTypeSig false "slashDirs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "slashDirs" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "slashDirs" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isDir") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "d")) () (EBlock (DoLet false false (PVar "marked") (EIf (EVar "d") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "/"))) (EVar "p"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "marked") (EVar "_s")))) (EApp (EVar "slashDirs") (EVar "rest"))))))))
(DTypeSig false "oracle" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oracle" ((PVar "dir") (PVar "pattern")) (EApp (EApp (EVar "map") (ELam ((PVar "cs")) (EApp (EVar "sort") (EApp (EApp (EVar "filter") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EVar "c")) (EBinOp "==" (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "c")) (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "pattern")))))) (EVar "cs"))))) (EApp (EVar "everyCandidate") (EVar "dir"))))
(DTypeSig false "globAgrees" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyTuple (TyCon "String") (TyCon "Expectation"))))))
(DFunDef false "globAgrees" ((PVar "dir") (PVar "pattern")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "pattern"))) (DoExpr (ETuple (EVar "pattern") (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "oracle") (EVar "dir")) (EVar "full"))) (EApp (EVar "glob") (EVar "full")))))))
(DTest false "glob equals the unpruned matchGlob filter on every pattern" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EApp (EApp (EVar "map") (EApp (EVar "globAgrees") (EVar "dir"))) (EListLit (ELit (LString "**/*")) (ELit (LString "**/*.mdk")) (ELit (LString "*")) (ELit (LString ".git/**")) (ELit (LString "sub/*/")) (ELit (LString "**/")) (ELit (LString ".*/")) (ELit (LString ".git/**/")) (ELit (LString "**/.*")) (ELit (LString "sub/**/*.mdk")) (ELit (LString "**/x")) (ELit (LString ".venv/**/*.mdk")) (ELit (LString "*/config")) (ELit (LString "sub/*")) (ELit (LString "empty/**/"))))))))
(DTest false "glob with ** skips dot directories but reaches dotfiles" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "**/*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "a.mdk")) (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/.hid")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/*")))))) (ETuple (ELit (LString "**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.mdk")) (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/*.mdk")))))) (ETuple (ELit (LString "**/.*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "sub/inner/.hid")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/.*")))))) (ETuple (ELit (LString "**/x")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/x")))))) (ETuple (ELit (LString "sub/**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/**/*.mdk")))))))))))
(DTest false "glob with * matches dot names, and a literal dot directory is entered" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "a.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*")))))) (ETuple (ELit (LString ".git/**")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/config")) (ELit (LString ".git/objects/x")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".git/**")))))) (ETuple (ELit (LString "*/config")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/config")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*/config")))))) (ETuple (ELit (LString ".venv/**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".venv/lib/z.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".venv/**/*.mdk")))))))))))
(DTest false "glob with a trailing slash finds directories, written with the slash" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "sub/*/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/.dot/")) (ELit (LString "sub/inner/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/*/")))))) (ETuple (ELit (LString "**/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "empty/")) (ELit (LString "empty/nested/")) (ELit (LString "sub/")) (ELit (LString "sub/inner/"))))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/")))))) (ETuple (ELit (LString ".*/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/")) (ELit (LString ".venv/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".*/")))))) (ETuple (ELit (LString ".git/**/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/")) (ELit (LString ".git/objects/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".git/**/")))))) (ETuple (ELit (LString "sub/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/")))))) (ETuple (ELit (LString "a.mdk/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a.mdk/")))))))))))
(DTest false "glob of a trailing-slash pattern under a missing prefix is an Err" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ": ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "*/"))))))))))
(DTest false "glob does not enter a dot directory its pattern cannot reach" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "runVerb") (ELit (LString "mv"))) (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep"))) (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/.deep")))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/top.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/**/*.txt"))))))))))
# MARK
(DUse false (UseGroup ("fs") ((mem "editFile" false) (mem "glob" false) (mem "isDir" false) (mem "isFile" false) (mem "mkdirAll" false) (mem "stat" false) (mem "walkDir" false) (mem "walkFiles" false) (mem "walkFilesSkipping" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false) (mem "matchGlob" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEach" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false) (mem "pass" false))))
(DUse false (UseGroup ("io") ((mem "runVerb" false))))
(DUse false (UseGroup ("test_process") ((mem "scratchDir" false) (mem "withScratchDir" false))))
(DTest false "readFile of a file that is not UTF-8 is an Err naming readFileBytes" (EMatch (EVar "scratchDir") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "no scratch directory: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "dir")) () (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "not-utf8.bin")))) (DoLet false false PWild (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EArrayLit (ELit (LInt 97)) (ELit (LInt 192)) (ELit (LInt 174))))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": not valid UTF-8 (use readFileBytes for raw bytes)")))) (EApp (EVar "readFile") (EVar "path"))))))))
(DTypeSig false "buildTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildTree" ((PVar "root")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.txt")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.txt")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/c.txt")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep/d.txt")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/e.txt")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/f.txt")))) (ELit (LString "f")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "g.txt")))) (ELit (LString "g")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))
(DTypeSig false "expectedWalk" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expectedWalk" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "names")))))
(DTypeSig false "expectedEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "expectedEntries" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "expectedEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "isDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "False")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "full") (EVar "_s")))) (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "rest")))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectedWalk") (EVar "full"))) (ELam ((PVar "sub")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectedEntries") (EVar "dir")) (EVar "rest"))) (ELam ((PVar "tail")) (EApp (EVar "Ok") (EBinOp "::" (EVar "full") (EBinOp "++" (EMethodRef "sub") (EVar "tail")))))))))))))
(DTypeSig false "walkOrderCheck" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "walkOrderCheck" ((PVar "dir")) (EMatch (EApp (EVar "buildTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (ETuple (EApp (EVar "walkDir") (EVar "dir")) (EApp (EVar "expectedWalk") (EVar "dir"))) (arm (PTuple (PCon "Ok" (PVar "got")) (PCon "Ok" (PVar "want"))) () (EApp (EApp (EVar "expectEqual") (EVar "want")) (EVar "got"))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "walkDir failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "the reference walk failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))))))
(DTest false "walkDir lists a nested tree in document order, each directory before its contents" (EApp (EVar "withScratchDir") (EVar "walkOrderCheck")))
(DTypeSig false "writeEmptyFiles" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeEmptyFiles" ((PVar "dir") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EBinOp "++" (EBinOp "++" (ELit (LString "f")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))))) (ELit (LString ""))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "writeEmptyFiles") (EVar "dir")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildWide" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "buildWide" ((PVar "root") (PVar "dirs") (PVar "files")) (EIf (EBinOp "==" (EVar "dirs") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "dir") (EApp (EApp (EVar "joinPath") (EVar "root")) (EBinOp "++" (EBinOp "++" (ELit (LString "d")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "dirs")))) (ELit (LString ""))))) (DoExpr (EMatch (EApp (EVar "mkdirAll") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeEmptyFiles") (EVar "dir")) (EVar "files")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EVar "buildWide") (EVar "root")) (EBinOp "-" (EVar "dirs") (ELit (LInt 1)))) (EVar "files")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wideCheck" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))))
(DFunDef false "wideCheck" ((PVar "count") (PVar "walk") (PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "buildWide") (EVar "dir")) (ELit (LInt 30))) (ELit (LInt 1000))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EDictApp "count"))) (EApp (EApp (EMethodRef "map") (EMethodRef "length")) (EApp (EVar "walk") (EVar "dir")))))))
(DTest false "walkDir returns every entry of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EApp (EApp (EVar "wideCheck") (ELit (LInt 30030))) (EVar "walkDir"))))
(DTypeSig false "fileState" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Float"))))))
(DFunDef false "fileState" ((PVar "path")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readFile") (EVar "path"))) (ELam ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "stat") (EVar "path"))) (ELam ((PVar "st")) (EApp (EVar "Ok") (ETuple (EVar "text") (EFieldAccess (EVar "st") "mtime"))))))))
(DTypeSig false "editOutcome" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyTuple (TyCon "String") (TyCon "Float")) (TyTuple (TyCon "String") (TyCon "Float")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "editOutcome" ((PVar "dir") (PVar "before") (PVar "edit")) (ELet false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "before"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s0")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "sleep"))) (EListLit (ELit (LString "1.1"))))) (ELam (PWild) (ELet false (PVar "r") (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "edit")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s1")) (EApp (EVar "Ok") (ETuple (EVar "s0") (EVar "s1") (EVar "r"))))))))))))))))
(DTest false "editFile on an Err from the function writes nothing and prefixes the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam (PWild) (EApp (EVar "Err") (ELit (LString "nope"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))))) (ELit (LString ": nope")))))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile with an Ok that changes nothing leaves text and mtime alone" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (EVar "Ok")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile writes when the text changes" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam ((PVar "s")) (EApp (EVar "Ok") (EBinOp "++" (EVar "s") (ELit (LString "d")))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PTuple (PVar "t0") (PVar "m0")) (PTuple (PVar "t1") (PVar "m1")) (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abcd")) (EVar "True") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "t0") (EVar "t1") (EBinOp ">" (EVar "m1") (EVar "m0")) (EVar "r"))))))))
(DTest false "editFile of a file that is not UTF-8 names the path once" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "not-utf8.bin")))) (DoLet false false PWild (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EArrayLit (ELit (LInt 97)) (ELit (LInt 192)) (ELit (LInt 174))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (ELam (PWild) (ELit LUnit))) (EApp (EVar "readFile") (EVar "path")))) (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "Ok"))))))))
(DTest false "editFile on a write failure names the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "readonly.txt")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "writeFile") (EVar "path")) (ELit (LString "abc"))) (EApp (EApp (EVar "runVerb") (ELit (LString "chmod"))) (EListLit (ELit (LString "444")) (EVar "path"))) (EApp (EApp (EVar "runVerb") (ELit (LString "id"))) (EListLit (ELit (LString "-u"))))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild) (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "uid") PWild))) () (EIf (EBinOp "==" (EVar "uid") (ELit (LString "0\n"))) (EVar "pass") (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": ")))) (EApp (EApp (EVar "editFile") (EVar "path")) (ELam (PWild) (EApp (EVar "Ok") (ELit (LString "x")))))))) (arm PWild () (EApp (EVar "fail") (ELit (LString "setup failed"))))))))))
(DTest false "editFile on a missing file is an Err naming the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EApp (EApp (EVar "editFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EVar "Ok"))))))
(DTypeSig false "buildGlobTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildGlobTree" ((PVar "root")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "empty/inner"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "zed/e.txt")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/deep/d.mdk")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/x.mdk")))) (ELit (LString "x")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.txt")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "m.mdk")))) (ELit (LString "m")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.txt")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))
(DTypeSig false "withGlobTree" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withGlobTree" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildGlobTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTypeSig false "rooted" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rooted" ((PVar "dir") (PVar "names")) (EApp (EApp (EMethodRef "map") (EApp (EVar "joinPath") (EVar "dir"))) (EVar "names")))
(DTest false "walkFiles lists only files, in sorted order" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.txt")) (ELit (LString "m.mdk")) (ELit (LString "sub/b.txt")) (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")) (ELit (LString "zed/e.txt")))))) (EApp (EVar "walkFiles") (EVar "dir"))))))
(DTest false "walkFiles of a directory with no files is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "walkFiles") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "empty"))))))))
(DTest false "walkFiles of a missing root is an Err naming the root and the host's message" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ": ")))) (EApp (EVar "walkFiles") (EVar "root"))))))))
(DTest false "walkFilesSkipping of a missing root is an Err naming the root" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ": ")))) (EApp (EApp (EVar "walkFilesSkipping") (ELam (PWild) (EVar "False"))) (EVar "root"))))))))
(DTest false "walkFilesSkipping does not enter a directory the predicate accepts" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.txt")) (ELit (LString "m.mdk")) (ELit (LString "zed/e.txt")))))) (EApp (EApp (EVar "walkFilesSkipping") (EApp (EVar "contains") (ELit (LString "/sub")))) (EVar "dir"))))))
(DTest false "walkFilesSkipping never tests the root itself" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "sub") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub")))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.txt")) (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")))))) (EApp (EApp (EVar "walkFilesSkipping") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EMethodRef "sub")))) (EMethodRef "sub"))))))))
(DTest false "glob matches within one directory with *" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "m.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*.mdk"))))))))
(DTest false "glob with ** crosses directories, zero included" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/deep/d.mdk")) (ELit (LString "sub/x.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/**/*.mdk"))))))))
(DTest false "glob of a path without a wildcard names that file" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "m.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "m.mdk"))))))))
(DTest false "glob of a missing path without a wildcard is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "nope.mdk"))))))))
(DTest false "glob of a directory path without a wildcard is Ok []" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub"))))))))
(DTest false "glob under a missing prefix directory is an Err naming it" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ": ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "*.mdk"))))))))))
(DTypeSig false "buildDangling" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildDangling" ((PVar "root")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/deep"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/top.txt")))) (ELit (LString "t")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "ln"))) (EListLit (ELit (LString "-s")) (ELit (LString "nowhere")) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "dang/deep/broken")))))) (ELam (PWild) (EApp (EVar "Ok") (ELit LUnit)))))))))))))
(DTypeSig false "withDangling" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withDangling" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildDangling") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTest false "glob does not examine entries below the depth its pattern reaches" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/top.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/*.txt"))))))))
(DTest false "glob with a ** segment walks the whole tree and meets the dangling link" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep/broken: ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/**/*.txt"))))))))
(DTest false "walkFiles names the entry that failed" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep/broken: ")))) (EApp (EVar "walkFiles") (EVar "dir"))))))
(DTest false "glob of two segments reaches exactly two levels" (EApp (EVar "withGlobTree") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/*.txt"))))))))
(DTypeSig false "topFiles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "topFiles" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "topFiles" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "isFile") (EVar "n")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "n") (EVar "_s")))) (EApp (EVar "topFiles") (EVar "rest")))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "topFiles") (EVar "rest")))))
(DTest false "glob with an empty prefix reads as the pattern does, without ./" (EMatch (EApp (EVar "listDir") (ELit (LString "."))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "listDir failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "sort")) (EApp (EVar "topFiles") (EVar "names")))) (EApp (EVar "glob") (ELit (LString "*")))))))
(DTest false "walkFiles returns every file of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EApp (EApp (EVar "wideCheck") (ELit (LInt 30000))) (EVar "walkFiles"))))
(DTest false "walkFiles orders by whole path when a name sorts before the slash" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildTricky") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a b")) (ELit (LString "a-d")) (ELit (LString "a.c")) (ELit (LString "a/x")))))) (EApp (EVar "walkFiles") (EVar "dir"))))))))
(DTypeSig false "buildTricky" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildTricky" ((PVar "dir")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a/x")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a b")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a-d")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a.c")))) (ELit (LString "")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))
(DTypeSig false "buildDotTree" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "buildDotTree" ((PVar "root")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/objects"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/.hidden"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".venv/lib"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/.dot"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "mkdirAll") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "empty/nested"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".env")))) (ELit (LString "e")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "a.mdk")))) (ELit (LString "a")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/config")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/objects/x")))) (ELit (LString "x")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".git/.hidden/y")))) (ELit (LString "y")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString ".venv/lib/z.mdk")))) (ELit (LString "z")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/b.mdk")))) (ELit (LString "b")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner/c.mdk")))) (ELit (LString "c")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/inner/.hid")))) (ELit (LString "h")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "sub/.dot/d.mdk")))) (ELit (LString "d")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (ELit LUnit)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DTypeSig false "withDotTree" (TyFun (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "withDotTree" ((PVar "check")) (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EVar "buildDotTree") (EVar "dir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "check") (EVar "dir")))))))
(DTypeSig false "everyCandidate" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "everyCandidate" ((PVar "root")) (EMatch (EApp (EVar "walkDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "paths")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/"))) (EVar "_s")))) (EApp (EVar "slashDirs") (EVar "paths"))))))
(DTypeSig false "slashDirs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "slashDirs" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "slashDirs" ((PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "isDir") (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "d")) () (EBlock (DoLet false false (PVar "marked") (EIf (EVar "d") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "/"))) (EVar "p"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "marked") (EVar "_s")))) (EApp (EVar "slashDirs") (EVar "rest"))))))))
(DTypeSig false "oracle" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oracle" ((PVar "dir") (PVar "pattern")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "cs")) (EApp (EVar "sort") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EApp (EVar "matchGlob") (EVar "pattern")) (EVar "c")) (EBinOp "==" (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "c")) (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "pattern")))))) (EVar "cs"))))) (EApp (EVar "everyCandidate") (EVar "dir"))))
(DTypeSig false "globAgrees" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyTuple (TyCon "String") (TyCon "Expectation"))))))
(DFunDef false "globAgrees" ((PVar "dir") (PVar "pattern")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "pattern"))) (DoExpr (ETuple (EVar "pattern") (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "oracle") (EVar "dir")) (EVar "full"))) (EApp (EVar "glob") (EVar "full")))))))
(DTest false "glob equals the unpruned matchGlob filter on every pattern" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EApp (EApp (EMethodRef "map") (EApp (EVar "globAgrees") (EVar "dir"))) (EListLit (ELit (LString "**/*")) (ELit (LString "**/*.mdk")) (ELit (LString "*")) (ELit (LString ".git/**")) (ELit (LString "sub/*/")) (ELit (LString "**/")) (ELit (LString ".*/")) (ELit (LString ".git/**/")) (ELit (LString "**/.*")) (ELit (LString "sub/**/*.mdk")) (ELit (LString "**/x")) (ELit (LString ".venv/**/*.mdk")) (ELit (LString "*/config")) (ELit (LString "sub/*")) (ELit (LString "empty/**/"))))))))
(DTest false "glob with ** skips dot directories but reaches dotfiles" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "**/*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "a.mdk")) (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/.hid")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/*")))))) (ETuple (ELit (LString "**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "a.mdk")) (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/*.mdk")))))) (ETuple (ELit (LString "**/.*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "sub/inner/.hid")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/.*")))))) (ETuple (ELit (LString "**/x")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/x")))))) (ETuple (ELit (LString "sub/**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/b.mdk")) (ELit (LString "sub/inner/c.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/**/*.mdk")))))))))))
(DTest false "glob with * matches dot names, and a literal dot directory is entered" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "*")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".env")) (ELit (LString "a.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*")))))) (ETuple (ELit (LString ".git/**")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/config")) (ELit (LString ".git/objects/x")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".git/**")))))) (ETuple (ELit (LString "*/config")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/config")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "*/config")))))) (ETuple (ELit (LString ".venv/**/*.mdk")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".venv/lib/z.mdk")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".venv/**/*.mdk")))))))))))
(DTest false "glob with a trailing slash finds directories, written with the slash" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "sub/*/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "sub/.dot/")) (ELit (LString "sub/inner/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/*/")))))) (ETuple (ELit (LString "**/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString "empty/")) (ELit (LString "empty/nested/")) (ELit (LString "sub/")) (ELit (LString "sub/inner/"))))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "**/")))))) (ETuple (ELit (LString ".*/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/")) (ELit (LString ".venv/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".*/")))))) (ETuple (ELit (LString ".git/**/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EApp (EVar "rooted") (EVar "dir")) (EListLit (ELit (LString ".git/")) (ELit (LString ".git/objects/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString ".git/**/")))))) (ETuple (ELit (LString "sub/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "sub/")))))) (ETuple (ELit (LString "a.mdk/")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "a.mdk/")))))))))))
(DTest false "glob of a trailing-slash pattern under a missing prefix is an Err" (EApp (EVar "withDotTree") (ELam ((PVar "dir")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent")))) (DoExpr (EApp (EApp (EVar "expectErrContains") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ": ")))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "*/"))))))))))
(DTest false "glob does not enter a dot directory its pattern cannot reach" (EApp (EVar "withDangling") (ELam ((PVar "dir")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "runVerb") (ELit (LString "mv"))) (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/deep"))) (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/.deep")))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/top.txt")))))) (EApp (EVar "glob") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "dang/**/*.txt"))))))))))
