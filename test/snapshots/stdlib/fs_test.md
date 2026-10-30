# META
source_lines=148
stages=DESUGAR,MARK
# SOURCE
-- Tests for the file primitives `stdlib/fs.mdk` builds on.

import fs.{editFile, isDir, mkdirAll, stat, walkDir}
import path.{joinPath}
import test.{Expectation, expectEqual, expectErrContains, fail}
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

wideWalkCheck : String -> <Exec, IO, FileRead, FileWrite> Expectation
wideWalkCheck dir = match buildWide dir 30 1000
  Err e => fail "could not build the tree: \{e}"
  Ok _ => expectEqual (Ok 30030) (map length (walkDir dir))

-- A result wider than the interpreter's recursion cap (25000): under `medaka
-- run`, which has no tail calls, any pass whose depth is the entry count
-- overflows.  This test runs natively, so it pins only the count.
test "walkDir returns every entry of a tree of 30030 entries" =
  withScratchDir wideWalkCheck

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

test "editFile on a missing file is an Err naming the path" = withScratchDir
  (dir =>
    expectErrContains
      (joinPath dir "absent.txt")
      (editFile (joinPath dir "absent.txt") Ok))
# DESUGAR
(DUse false (UseGroup ("fs") ((mem "editFile" false) (mem "isDir" false) (mem "mkdirAll" false) (mem "stat" false) (mem "walkDir" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false))))
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
(DTypeSig false "wideWalkCheck" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "wideWalkCheck" ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "buildWide") (EVar "dir")) (ELit (LInt 30))) (ELit (LInt 1000))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (ELit (LInt 30030)))) (EApp (EApp (EVar "map") (EVar "length")) (EApp (EVar "walkDir") (EVar "dir")))))))
(DTest false "walkDir returns every entry of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EVar "wideWalkCheck")))
(DTypeSig false "fileState" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Float"))))))
(DFunDef false "fileState" ((PVar "path")) (EApp (EApp (EVar "andThen") (EApp (EVar "readFile") (EVar "path"))) (ELam ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "stat") (EVar "path"))) (ELam ((PVar "st")) (EApp (EVar "Ok") (ETuple (EVar "text") (EFieldAccess (EVar "st") "mtime"))))))))
(DTypeSig false "editOutcome" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyTuple (TyCon "String") (TyCon "Float")) (TyTuple (TyCon "String") (TyCon "Float")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "editOutcome" ((PVar "dir") (PVar "before") (PVar "edit")) (ELet false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "before"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s0")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "sleep"))) (EListLit (ELit (LString "1.1"))))) (ELam (PWild) (ELet false (PVar "r") (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "edit")) (EApp (EApp (EVar "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s1")) (EApp (EVar "Ok") (ETuple (EVar "s0") (EVar "s1") (EVar "r"))))))))))))))))
(DTest false "editFile on an Err from the function writes nothing and prefixes the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam (PWild) (EApp (EVar "Err") (ELit (LString "nope"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))))) (ELit (LString ": nope")))))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile with an Ok that changes nothing leaves text and mtime alone" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (EVar "Ok")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile writes when the text changes" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam ((PVar "s")) (EApp (EVar "Ok") (EBinOp "++" (EVar "s") (ELit (LString "d")))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PTuple (PVar "t0") (PVar "m0")) (PTuple (PVar "t1") (PVar "m1")) (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abcd")) (EVar "True") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "t0") (EVar "t1") (EBinOp ">" (EVar "m1") (EVar "m0")) (EVar "r"))))))))
(DTest false "editFile on a missing file is an Err naming the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EApp (EApp (EVar "editFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EVar "Ok"))))))
# MARK
(DUse false (UseGroup ("fs") ((mem "editFile" false) (mem "isDir" false) (mem "mkdirAll" false) (mem "stat" false) (mem "walkDir" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false))))
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
(DTypeSig false "wideWalkCheck" (TyFun (TyCon "String") (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyCon "Expectation"))))
(DFunDef false "wideWalkCheck" ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "buildWide") (EVar "dir")) (ELit (LInt 30))) (ELit (LInt 1000))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "could not build the tree: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (ELit (LInt 30030)))) (EApp (EApp (EMethodRef "map") (EMethodRef "length")) (EApp (EVar "walkDir") (EVar "dir")))))))
(DTest false "walkDir returns every entry of a tree of 30030 entries" (EApp (EVar "withScratchDir") (EVar "wideWalkCheck")))
(DTypeSig false "fileState" (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Float"))))))
(DFunDef false "fileState" ((PVar "path")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readFile") (EVar "path"))) (ELam ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "stat") (EVar "path"))) (ELam ((PVar "st")) (EApp (EVar "Ok") (ETuple (EVar "text") (EFieldAccess (EVar "st") "mtime"))))))))
(DTypeSig false "editOutcome" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))) (TyEffect ("Exec" "IO" "FileRead" "FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyTuple (TyCon "String") (TyCon "Float")) (TyTuple (TyCon "String") (TyCon "Float")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "editOutcome" ((PVar "dir") (PVar "before") (PVar "edit")) (ELet false (PVar "path") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "before"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s0")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "runVerb") (ELit (LString "sleep"))) (EListLit (ELit (LString "1.1"))))) (ELam (PWild) (ELet false (PVar "r") (EApp (EApp (EVar "editFile") (EVar "path")) (EVar "edit")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "fileState") (EVar "path"))) (ELam ((PVar "s1")) (EApp (EVar "Ok") (ETuple (EVar "s0") (EVar "s1") (EVar "r"))))))))))))))))
(DTest false "editFile on an Err from the function writes nothing and prefixes the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam (PWild) (EApp (EVar "Err") (ELit (LString "nope"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "target.txt"))))) (ELit (LString ": nope")))))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile with an Ok that changes nothing leaves text and mtime alone" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (EVar "Ok")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "s0") (PVar "s1") (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (EVar "s0") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "s1") (EVar "r"))))))))
(DTest false "editFile writes when the text changes" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EMatch (EApp (EApp (EApp (EVar "editOutcome") (EVar "dir")) (ELit (LString "abc"))) (ELam ((PVar "s")) (EApp (EVar "Ok") (EBinOp "++" (EVar "s") (ELit (LString "d")))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "fail") (EBinOp "++" (EBinOp "++" (ELit (LString "setup failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PTuple (PVar "t0") (PVar "m0")) (PTuple (PVar "t1") (PVar "m1")) (PVar "r"))) () (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abcd")) (EVar "True") (EApp (EVar "Ok") (ELit LUnit)))) (ETuple (EVar "t0") (EVar "t1") (EBinOp ">" (EVar "m1") (EVar "m0")) (EVar "r"))))))))
(DTest false "editFile on a missing file is an Err naming the path" (EApp (EVar "withScratchDir") (ELam ((PVar "dir")) (EApp (EApp (EVar "expectErrContains") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EApp (EApp (EVar "editFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "absent.txt")))) (EVar "Ok"))))))
