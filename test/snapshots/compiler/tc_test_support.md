# META
source_lines=114
stages=DESUGAR,MARK
# SOURCE
-- tc_test_support: the fixtures the `tc_*_test` siblings of `compiler/types` share: a fresh
-- module record, the codes it has been given, the signatures of a parsed source, the
-- alias table and declared parameter kinds a source's declarations register, and the
-- interface reference and the monos of the probe module (`ifaceOf`, `intM`, `boolM`,
-- `varM`).  Test siblings import it and no production module does.  `aliasTableOf` and
-- `recordKindsOf` are the fixture-side twins of `tc_decls`' `graphAliasRow` and
-- `withDeclParamKinds`: a test of a module below `tc_decls` cannot import those, and its
-- fixtures need the same tables.

import list.{reverse}
import test.{Expectation, expectEqual}
import frontend.parser.{parse}
import frontend.ast.{Decl(..), TabKey, Ty(..), TyConOrigin(..)}
import types.repr.{IfaceRef(..), Mono(..), Tyvar(..)}
import types.tc_mono.{tconBuiltin}
import support.ordmap.{omInsert}
import types.publish.{tcCode}
import types.tc_env.{declParamKinds, tyTabKey}
import types.tc_state.{blankModuleCtx, probeGraphCtx, wAll}
import types.tc_types.{Kind(..), ModuleCtx(..)}

-- A module record named "probe", minted in a fresh graph record.
export
fresh : Unit -> ModuleCtx
fresh _ = blankModuleCtx (probeGraphCtx ()) "probe"

-- The codes of the diagnostics pushed to [m] so far, oldest first.
export
codesOf : ModuleCtx -> List String
codesOf m = reverse (map tcCode (wAll m.mcCells.typeErrors))

-- The type of every signature among [ds], in source order.
export
sigsOf : List Decl -> List Ty
sigsOf [] = []
sigsOf ((DTypeSig _ _ t _) :: rest) = t :: sigsOf rest
sigsOf (_ :: rest) = sigsOf rest

-- The type of the first signature of [src], or `None` when it declares none.
export
firstSig : String -> Option Ty
firstSig src = match sigsOf (parse src)
  t :: _ => Some t
  [] => None

-- [k] applied to the type of the first signature of [src]; a source with no signature
-- fails the test rather than reading as some placeholder type.
export
withFirstSig : String -> (Ty -> Expectation) -> Expectation
withFirstSig src k = match firstSig src
  Some t => k t
  None => expectEqual "a source with a signature" src

export
intTy : Ty
intTy =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginBuiltin }

-- An interface reference named [name], declared in the module "probe".
export
ifaceOf : String -> IfaceRef
ifaceOf name = IfaceRef { irName = name, irOrigin = OriginModule "probe" }

export
intM : Mono
intM = tconBuiltin "Int"

export
boolM : Mono
boolM = tconBuiltin "Bool"

-- A free type variable with id [id] at level 0.
export
varM : Int -> Mono
varM id = TVar (Ref (Unbound id 0))

-- The alias table of [ds]: each alias keyed by its identity, with its parameters and
-- right-hand side.
export
aliasTableOf : List Decl -> List (TabKey, (List String, Ty))
aliasTableOf [] = []
aliasTableOf ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasRhs = rhs, tyAliasOrigin = o }) :: rest) =
  (tyTabKey o n, (ps, rhs)) :: aliasTableOf rest
aliasTableOf (_ :: rest) = aliasTableOf rest

-- Records in [m] the parameter kinds each data, newtype or alias head of [ds] declares.
-- A head whose parameters are all of kind `Type` has no entry, as it has none at a real
-- registration.
export
recordKindsOf : ModuleCtx -> List Decl -> Unit
recordKindsOf _ [] = ()
recordKindsOf m ((DData { dataName = n, dataParams = ps, dataParamKinds = anns, dataOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m ((DNewtype { newtypeName = n, newtypeParams = ps, newtypeParamKinds = anns, newtypeOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasParamKinds = anns, tyAliasOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m (_ :: rest) = recordKindsOf m rest

recordKinds : ModuleCtx -> TyConOrigin -> String -> List Kind -> Unit
recordKinds m o n kinds
  | any kindIsDeclared kinds =
    m.mcCells.dataParamKindsRef :=
      (tyTabKey o n, kinds) :: m.mcCells.dataParamKindsRef.value
    m.mcCells.dataParamNameIndexRef :=
      omInsert n () m.mcCells.dataParamNameIndexRef.value
  | otherwise = ()

kindIsDeclared : Kind -> Bool
kindIsDeclared KType = False
kindIsDeclared _ = True
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declParamKinds" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "Kind" true) (mem "ModuleCtx" true))))
(DTypeSig true "fresh" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "fresh" (PWild) (EApp (EApp (EVar "blankModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (ELit (LString "probe"))))
(DTypeSig true "codesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "codesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EVar "tcCode")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild PWild (PVar "t") PWild) (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig true "firstSig" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "firstSig" ((PVar "src")) (EMatch (EApp (EVar "sigsOf") (EApp (EVar "parse") (EVar "src"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "withFirstSig" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Ty") (TyCon "Expectation")) (TyCon "Expectation"))))
(DFunDef false "withFirstSig" ((PVar "src") (PVar "k")) (EMatch (EApp (EVar "firstSig") (EVar "src")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "k") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source with a signature"))) (EVar "src")))))
(DTypeSig true "intTy" (TyCon "Ty"))
(DFunDef false "intTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "ifaceOf" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceOf" ((PVar "name")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "probe")))))))
(DTypeSig true "intM" (TyCon "Mono"))
(DFunDef false "intM" () (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DTypeSig true "boolM" (TyCon "Mono"))
(DFunDef false "boolM" () (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DTypeSig true "varM" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "varM" ((PVar "id")) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (ELit (LInt 0))))))
(DTypeSig true "aliasTableOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "aliasTableOf" ((PList)) (EListLit))
(DFunDef false "aliasTableOf" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs"))) (EApp (EVar "aliasTableOf") (EVar "rest"))))
(DFunDef false "aliasTableOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasTableOf") (EVar "rest")))
(DTypeSig true "recordKindsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "recordKindsOf" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))
(DTypeSig false "recordKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordKinds" ((PVar "m") (PVar "o") (PVar "n") (PVar "kinds")) (EIf (EApp (EApp (EVar "any") (EVar "kindIsDeclared")) (EVar "kinds")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EVar "kinds")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef") "value"))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "kindIsDeclared" (TyFun (TyCon "Kind") (TyCon "Bool")))
(DFunDef false "kindIsDeclared" ((PCon "KType")) (EVar "False"))
(DFunDef false "kindIsDeclared" (PWild) (EVar "True"))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declParamKinds" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "Kind" true) (mem "ModuleCtx" true))))
(DTypeSig true "fresh" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "fresh" (PWild) (EApp (EApp (EVar "blankModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (ELit (LString "probe"))))
(DTypeSig true "codesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "codesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EVar "tcCode")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild PWild (PVar "t") PWild) (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig true "firstSig" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "firstSig" ((PVar "src")) (EMatch (EApp (EVar "sigsOf") (EApp (EVar "parse") (EVar "src"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "withFirstSig" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Ty") (TyCon "Expectation")) (TyCon "Expectation"))))
(DFunDef false "withFirstSig" ((PVar "src") (PVar "k")) (EMatch (EApp (EVar "firstSig") (EVar "src")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "k") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source with a signature"))) (EVar "src")))))
(DTypeSig true "intTy" (TyCon "Ty"))
(DFunDef false "intTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "ifaceOf" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceOf" ((PVar "name")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "probe")))))))
(DTypeSig true "intM" (TyCon "Mono"))
(DFunDef false "intM" () (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DTypeSig true "boolM" (TyCon "Mono"))
(DFunDef false "boolM" () (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DTypeSig true "varM" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "varM" ((PVar "id")) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (ELit (LInt 0))))))
(DTypeSig true "aliasTableOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "aliasTableOf" ((PList)) (EListLit))
(DFunDef false "aliasTableOf" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs"))) (EApp (EVar "aliasTableOf") (EVar "rest"))))
(DFunDef false "aliasTableOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasTableOf") (EVar "rest")))
(DTypeSig true "recordKindsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "recordKindsOf" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))
(DTypeSig false "recordKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordKinds" ((PVar "m") (PVar "o") (PVar "n") (PVar "kinds")) (EIf (EApp (EApp (EDictApp "any") (EVar "kindIsDeclared")) (EVar "kinds")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EVar "kinds")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef") "value"))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "kindIsDeclared" (TyFun (TyCon "Kind") (TyCon "Bool")))
(DFunDef false "kindIsDeclared" ((PCon "KType")) (EVar "False"))
(DFunDef false "kindIsDeclared" (PWild) (EVar "True"))
