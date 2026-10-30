# META
source_lines=68
stages=DESUGAR,MARK
# SOURCE
-- Tests for the file primitives `stdlib/fs.mdk` builds on.

import fs.{isDir, mkdirAll, walkDir}
import path.{joinPath}
import test.{Expectation, expectEqual, expectErrContains, fail}
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
# DESUGAR
(DUse false (UseGroup ("fs") ((mem "isDir" false) (mem "mkdirAll" false) (mem "walkDir" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false))))
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
# MARK
(DUse false (UseGroup ("fs") ((mem "isDir" false) (mem "mkdirAll" false) (mem "walkDir" false))))
(DUse false (UseGroup ("path") ((mem "joinPath" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "fail" false))))
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
