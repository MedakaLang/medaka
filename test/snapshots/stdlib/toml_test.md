# META
source_lines=59
stages=DESUGAR,MARK
# SOURCE
-- Tests for the array-of-tables readers in `stdlib/toml.mdk`.

import toml.{Toml, parse, tableCount, tableEntry, tableEntries, getString}
import test.{expectEqual}

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
  expectEqual (map Some (tableEntries "gate" doc)) (entriesByIndex "gate" doc)

test "tableEntries agrees with tableEntry for a second table in the same document" =
  let doc = load multi
  expectEqual (map Some (tableEntries "other" doc)) (entriesByIndex "other" doc)

test "tableEntries keeps document order" =
  expectEqual
    [Some "a", Some "b", Some "c"]
    (map (getString "name") (tableEntries "gate" (load multi)))

test "tableEntries entries carry unqualified keys" =
  expectEqual
    [Some "1"]
    (map
      (getString "name")
      (tableEntries "gate" (load "[[gate]]\nname = \"1\"")))

test "tableEntries is empty when there are no entries" =
  expectEqual 0 (length (tableEntries "gate" (load "[package]\nname = \"p\"")))

test "tableEntries does not take a longer table name for a prefix" =
  expectEqual
    1
    (length
      (tableEntries
        "gate"
        (load "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\"")))

test "tableEntry of a negative index is None" =
  expectEqual None (tableEntry "gate" (0 - 1) (load multi))

test "tableEntry one past the last entry is None" =
  expectEqual None (tableEntry "gate" 3 (load multi))

test "tableEntry of the last entry is present" =
  expectEqual
    (Some "c")
    (tableEntry "gate" 2 (load multi) |> flatMap (getString "name"))
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc")))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc")))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi"))))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\"")))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EVar "length") (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\"")))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EVar "length") (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\"")))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EVar "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc")))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc")))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi"))))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\"")))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EMethodRef "length") (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\"")))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EMethodRef "length") (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\"")))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EDictApp "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
