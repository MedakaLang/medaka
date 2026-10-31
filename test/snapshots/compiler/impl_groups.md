# META
source_lines=73
stages=DESUGAR,MARK
# SOURCE
import ir.core_ir.{CImplEntry(..), CImplBody(..)}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup}
import support.util.{reverseL}

public export data ImplClauseGroup = ImplClauseGroup {
  method : String,
  key : String,
  indices : List Int,
}

entryKey : CImplBody -> String
entryKey (CImplTagged _ key _ _ _ _ _) = key
entryKey (CImplDefault _ _ key _ _ _ _) = key

collect : List CImplEntry ->
  Int ->
  OrdMap (OrdMap (List Int)) ->
  List (String, String) ->
  (OrdMap (OrdMap (List Int)), List (String, String))
collect [] _ groups order = (groups, order)
collect ((CImplEntry method _ _ body) :: rest) i groups order =
  let key = entryKey body
  let inner = match omLookup method groups
    Some m => m
    None => omEmpty
  let previous = omLookup key inner
  let indices = match previous
    Some xs => xs
    None => []
  let nextOrder = match previous
    Some _ => order
    None => (method, key) :: order
  collect
    rest
    (i + 1)
    (omInsert method (omInsert key (i :: indices) inner) groups)
    nextOrder

export
groupImplEntries : List CImplEntry -> List ImplClauseGroup
groupImplEntries entries =
  let (groups, order) = collect entries 0 omEmpty []
  map
    ((method, key) =>
      let indices = match omLookup method groups
        Some inner => match omLookup key inner
          Some xs => reverseL xs
          None => []
        None => []
      ImplClauseGroup { method = method, key = key, indices = indices })
    (reverseL order)

sameInts : List Int -> List Int -> Bool
sameInts [] [] = True
sameInts (a :: xs) (b :: ys) = a == b && sameInts xs ys
sameInts _ _ = False

sameGroups : List ImplClauseGroup -> List ImplClauseGroup -> Bool
sameGroups [] [] = True
sameGroups (a :: xs) (b :: ys) =
  (a : ImplClauseGroup).method == (b : ImplClauseGroup).method
    && (a : ImplClauseGroup).key == (b : ImplClauseGroup).key
    && sameInts (a : ImplClauseGroup).indices (b : ImplClauseGroup).indices
    && sameGroups xs ys
sameGroups _ _ = False

export
validateImplGroups : List CImplEntry -> List ImplClauseGroup -> List String
validateImplGroups entries groups =
  if sameGroups (groupImplEntries entries) groups then
    []
  else
    ["impl groups: emit plan partition disagrees with Core"]
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "ImplClauseGroup" () ((variant "ImplClauseGroup" (ConNamed (field "method" (TyCon "String")) (field "key" (TyCon "String")) (field "indices" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig false "entryKey" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "entryKey" ((PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild PWild PWild)) (EVar "key"))
(DFunDef false "entryKey" ((PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild PWild PWild)) (EVar "key"))
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "collect" ((PList) PWild (PVar "groups") (PVar "order")) (ETuple (EVar "groups") (EVar "order")))
(DFunDef false "collect" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "i") (PVar "groups") (PVar "order")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "entryKey") (EVar "body"))) (DoLet false false (PVar "inner") (EMatch (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "groups")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (EVar "omEmpty")))) (DoLet false false (PVar "previous") (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "inner"))) (DoLet false false (PVar "indices") (EMatch (EVar "previous") (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "nextOrder") (EMatch (EVar "previous") (arm (PCon "Some" PWild) () (EVar "order")) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "method") (EVar "key")) (EVar "order"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "method")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "i") (EVar "indices"))) (EVar "inner"))) (EVar "groups"))) (EVar "nextOrder")))))
(DTypeSig true "groupImplEntries" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "ImplClauseGroup"))))
(DFunDef false "groupImplEntries" ((PVar "entries")) (EBlock (DoLet false false (PTuple (PVar "groups") (PVar "order")) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "entries")) (ELit (LInt 0))) (EVar "omEmpty")) (EListLit))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "method") (PVar "key"))) (EBlock (DoLet false false (PVar "indices") (EMatch (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "groups")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "inner")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "reverseL") (EVar "xs"))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))) (DoExpr (ERecordCreate "ImplClauseGroup" ((fa "method" (EVar "method")) (fa "key" (EVar "key")) (fa "indices" (EVar "indices")))))))) (EApp (EVar "reverseL") (EVar "order"))))))
(DTypeSig false "sameInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "sameInts" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameInts" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "sameInts") (EVar "xs")) (EVar "ys"))))
(DFunDef false "sameInts" (PWild PWild) (EVar "False"))
(DTypeSig false "sameGroups" (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyCon "Bool"))))
(DFunDef false "sameGroups" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameGroups" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "method") (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "method")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "key") (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "key"))) (EApp (EApp (EVar "sameInts") (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "indices")) (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "indices"))) (EApp (EApp (EVar "sameGroups") (EVar "xs")) (EVar "ys"))))
(DFunDef false "sameGroups" (PWild PWild) (EVar "False"))
(DTypeSig true "validateImplGroups" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateImplGroups" ((PVar "entries") (PVar "groups")) (EIf (EApp (EApp (EVar "sameGroups") (EApp (EVar "groupImplEntries") (EVar "entries"))) (EVar "groups")) (EListLit) (EListLit (ELit (LString "impl groups: emit plan partition disagrees with Core")))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "ImplClauseGroup" () ((variant "ImplClauseGroup" (ConNamed (field "method" (TyCon "String")) (field "key" (TyCon "String")) (field "indices" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig false "entryKey" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "entryKey" ((PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild PWild PWild)) (EVar "key"))
(DFunDef false "entryKey" ((PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild PWild PWild)) (EVar "key"))
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "collect" ((PList) PWild (PVar "groups") (PVar "order")) (ETuple (EVar "groups") (EVar "order")))
(DFunDef false "collect" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "i") (PVar "groups") (PVar "order")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "entryKey") (EVar "body"))) (DoLet false false (PVar "inner") (EMatch (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "groups")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (EVar "omEmpty")))) (DoLet false false (PVar "previous") (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "inner"))) (DoLet false false (PVar "indices") (EMatch (EVar "previous") (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "nextOrder") (EMatch (EVar "previous") (arm (PCon "Some" PWild) () (EVar "order")) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "method") (EVar "key")) (EVar "order"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "collect") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "method")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "i") (EVar "indices"))) (EVar "inner"))) (EVar "groups"))) (EVar "nextOrder")))))
(DTypeSig true "groupImplEntries" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "ImplClauseGroup"))))
(DFunDef false "groupImplEntries" ((PVar "entries")) (EBlock (DoLet false false (PTuple (PVar "groups") (PVar "order")) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "entries")) (ELit (LInt 0))) (EVar "omEmpty")) (EListLit))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "method") (PVar "key"))) (EBlock (DoLet false false (PVar "indices") (EMatch (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "groups")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "inner")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "reverseL") (EVar "xs"))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))) (DoExpr (ERecordCreate "ImplClauseGroup" ((fa "method" (EVar "method")) (fa "key" (EVar "key")) (fa "indices" (EVar "indices")))))))) (EApp (EVar "reverseL") (EVar "order"))))))
(DTypeSig false "sameInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "sameInts" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameInts" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "sameInts") (EVar "xs")) (EVar "ys"))))
(DFunDef false "sameInts" (PWild PWild) (EVar "False"))
(DTypeSig false "sameGroups" (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyCon "Bool"))))
(DFunDef false "sameGroups" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameGroups" ((PCons (PVar "a") (PVar "xs")) (PCons (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "method") (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "method")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "key") (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "key"))) (EApp (EApp (EVar "sameInts") (EFieldAccess (EAnnot (EVar "a") (TyCon "ImplClauseGroup")) "indices")) (EFieldAccess (EAnnot (EVar "b") (TyCon "ImplClauseGroup")) "indices"))) (EApp (EApp (EVar "sameGroups") (EVar "xs")) (EVar "ys"))))
(DFunDef false "sameGroups" (PWild PWild) (EVar "False"))
(DTypeSig true "validateImplGroups" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateImplGroups" ((PVar "entries") (PVar "groups")) (EIf (EApp (EApp (EVar "sameGroups") (EApp (EVar "groupImplEntries") (EVar "entries"))) (EVar "groups")) (EListLit) (EListLit (ELit (LString "impl groups: emit plan partition disagrees with Core")))))
