# META
source_lines=82
stages=DESUGAR,MARK
# SOURCE
-- Tests for the array-of-tables readers in `stdlib/toml.mdk`.

import toml.{
  Toml(..), TomlValue(..), parse, tableCount, tableEntry, tableEntries,
  getString
}
import test.{expectEqual, expectOkThen}

multi : String
multi =
  "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n"

load : String -> Toml
load src = match parse src
  Ok doc => doc
  Err e => panic e

entriesByIndex : String -> Toml -> List (Option Toml)
entriesByIndex name doc =
  map (i => tableEntry name i doc) [0..tableCount name doc]

test "tableEntries equals tableEntry at every index, on a multi-table document" =
  let doc = load multi
  expectOkThen
    (es => expectEqual (map Some es) (entriesByIndex "gate" doc))
    (tableEntries "gate" doc)

test "tableEntries agrees with tableEntry for a second table in the same document" =
  let doc = load multi
  expectOkThen
    (es => expectEqual (map Some es) (entriesByIndex "other" doc))
    (tableEntries "other" doc)

test "tableEntries keeps document order" =
  expectOkThen
    (es =>
      expectEqual [Some "a", Some "b", Some "c"] (map (getString "name") es))
    (tableEntries "gate" (load multi))

test "tableEntries entries carry unqualified keys" =
  expectOkThen
    (es => expectEqual [Some "1"] (map (getString "name") es))
    (tableEntries "gate" (load "[[gate]]\nname = \"1\""))

test "tableEntries is empty when there are no entries" =
  expectOkThen
    (es => expectEqual 0 (length es))
    (tableEntries "gate" (load "[package]\nname = \"p\""))

test "tableEntries does not take a longer table name for a prefix" =
  expectOkThen
    (es => expectEqual 1 (length es))
    (tableEntries
      "gate"
      (load "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))

test "tableEntries refuses an index past the limit, naming the table and the index" =
  expectEqual
    (Err "too many [[gate]] entries: index 5000000 is past the limit of 100000")
    (tableEntries "gate" (load "[gate.5000000]\nname = \"x\""))

test "tableEntries refuses the first index past the limit" =
  expectEqual
    (Err "too many [[gate]] entries: index 100000 is past the limit of 100000")
    (tableEntries "gate" (load "[gate.100000]\nname = \"x\""))

test "tableEntry of a negative index is None" =
  expectEqual None (tableEntry "gate" (0 - 1) (load multi))

test "tableEntry one past the last entry is None" =
  expectEqual None (tableEntry "gate" 3 (load multi))

test "tableEntry of the last entry is present" =
  expectEqual
    (Some "c")
    (tableEntry "gate" 2 (load multi) |> flatMap (getString "name"))

test "a key followed by a no-break space keeps it in the key" =
  expectEqual (Ok (Toml [("key ", TInt 1)])) (parse "key = 1\n")

test "a table header with a no-break space inside the brackets keeps it" =
  expectEqual (Ok (Toml [("a .k", TString "v")])) (parse "[a ]\nk = \"v\"\n")
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectOkThen" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\""))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EVar "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\""))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EVar "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))))))
(DTest false "tableEntries refuses an index past the limit, naming the table and the index" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 5000000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.5000000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the first index past the limit" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 100000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.100000]\nname = \"x\""))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EVar "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
(DTest false "a key followed by a no-break space keeps it in the key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "key ")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "key = 1\n")))))
(DTest false "a table header with a no-break space inside the brackets keeps it" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "a .k")) (EApp (EVar "TString") (ELit (LString "v")))))))) (EApp (EVar "parse") (ELit (LString "[a ]\nk = \"v\"\n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectOkThen" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\""))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\""))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))))))
(DTest false "tableEntries refuses an index past the limit, naming the table and the index" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 5000000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.5000000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the first index past the limit" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 100000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.100000]\nname = \"x\""))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EDictApp "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
(DTest false "a key followed by a no-break space keeps it in the key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "key ")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "key = 1\n")))))
(DTest false "a table header with a no-break space inside the brackets keeps it" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "a .k")) (EApp (EVar "TString") (ELit (LString "v")))))))) (EApp (EVar "parse") (ELit (LString "[a ]\nk = \"v\"\n")))))
