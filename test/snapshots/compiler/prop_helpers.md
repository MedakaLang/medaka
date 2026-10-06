# META
source_lines=114
stages=DESUGAR,MARK
# SOURCE
-- Typed bridge bindings for custom `Arbitrary` property parameters.
--
-- Property plans retain a resolved carrier type and canonical instance-route
-- word.  The command layer elaborates these declarations with the program so
-- the ordinary typechecker chooses the matching Arbitrary dictionary; the
-- property runner then invokes the resulting bindings by their exact names.

import frontend.ast.{
  Decl(..),
  Expr(..),
  Pat(..),
  Lit(..),
  Ty(..),
  Loc(..),
  UsePath(..),
  tyConBuiltin,
  effAtomBare,
}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert, omKeys, omLookup}
import support.util.{reverseL}
import tools.prop_plan.{CustomPlan(..), GenPlan, PlanEnv, customPlansReachable}
import tools.prop_runner.{PropHelper(..)}

public export data PropHelpers = PropHelpers (List PropHelper) (List Decl)

-- One custom route may occur in several parameters and laws.  Index it once
-- by the canonical route word; `omKeys` gives a deterministic helper order.
export
propHelpersForPlans : PlanEnv -> List GenPlan -> PropHelpers
propHelpersForPlans env plans =
  let carriers = customCarrierMap (customPlansReachable env plans) omEmpty
  propHelpersFromWords (omKeys carriers) carriers 0 [] []

-- An alias-qualified method spelling is the ordinary typechecker route that
-- preserves the declaring interface identity.  In particular, it cannot be
-- redirected by a root-level standalone `arbitrary` or `shrink` binding.
coreAliasDecl : Decl
coreAliasDecl =
  DUse
    False
    (UseAlias ["core"] "$prop_core")
    (Loc "<property-helper:core>" 1 1 1 1)

customCarrierMap : List CustomPlan -> OrdMap CustomPlan -> OrdMap CustomPlan
customCarrierMap [] acc = acc
customCarrierMap ((custom@(CustomPlan _ _ word)) :: rest) acc
  | omHasKey word acc = customCarrierMap rest acc
  | otherwise = customCarrierMap rest (omInsert word custom acc)
customCarrierMap _ acc = acc

propHelpersFromWords : List String ->
  OrdMap CustomPlan ->
  Int ->
  List PropHelper ->
  List Decl ->
  PropHelpers
propHelpersFromWords [] _ _ [] _ = PropHelpers [] []
propHelpersFromWords [] _ _ helpers decls =
  PropHelpers (reverseL helpers) (coreAliasDecl :: reverseL decls)
propHelpersFromWords (word :: rest) carriers i helpers decls =
  match omLookup word carriers
    None => propHelpersFromWords rest carriers (i + 1) helpers decls
    Some custom =>
      propHelpersFromWords
        rest
        carriers
        (i + 1)
        (helperForCustom i custom :: helpers)
        (prependDecls (helperDecls i custom) decls)
propHelpersFromWords _ _ _ helpers decls =
  PropHelpers (reverseL helpers) (coreAliasDecl :: reverseL decls)

helperForCustom : Int -> CustomPlan -> PropHelper
helperForCustom i (CustomPlan _ _ word) =
  PropHelper word (generatorName i) (shrinkerName i)

helperDecls : Int -> CustomPlan -> List Decl
helperDecls i (CustomPlan _ carrier _) =
  let loc = helperLoc i
  let generator = generatorName i
  let shrinker = shrinkerName i
  let unitTy = tyConBuiltin "Unit" (Some loc)
  let listTy = tyConBuiltin "List" (Some loc)
  [
    DTypeSig
      False
      generator
      (TyFun unitTy (TyEffect [effAtomBare "Rand"] [] carrier)),
    DFunDef
      False
      generator
      [PLit LUnit]
      (ELoc loc (EApp (EVar "$prop_core.arbitrary") (ELit LUnit))),
    DTypeSig False shrinker (TyFun carrier (TyApp listTy carrier)),
    DFunDef
      False
      shrinker
      [PVar "$prop_value" loc]
      (ELoc loc (EApp (EVar "$prop_core.shrink") (EVar "$prop_value"))),
  ]

prependDecls : List Decl -> List Decl -> List Decl
prependDecls [] acc = acc
prependDecls (decl :: rest) acc = prependDecls rest (decl :: acc)
prependDecls _ acc = acc

helperLoc : Int -> Loc
helperLoc i = Loc "<property-helper:\{intToString i}>" 1 1 1 1

generatorName : Int -> String
generatorName i = "$prop_gen_\{intToString i}"

shrinkerName : Int -> String
shrinkerName i = "$prop_shrink_\{intToString i}"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Ty" true) (mem "Loc" true) (mem "UsePath" true) (mem "tyConBuiltin" false) (mem "effAtomBare" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "CustomPlan" true) (mem "GenPlan" false) (mem "PlanEnv" false) (mem "customPlansReachable" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropHelper" true))))
(DData Public "PropHelpers" () ((variant "PropHelpers" (ConPos (TyApp (TyCon "List") (TyCon "PropHelper")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig true "propHelpersForPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "PropHelpers"))))
(DFunDef false "propHelpersForPlans" ((PVar "env") (PVar "plans")) (EBlock (DoLet false false (PVar "carriers") (EApp (EApp (EVar "customCarrierMap") (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EApp (EVar "omKeys") (EVar "carriers"))) (EVar "carriers")) (ELit (LInt 0))) (EListLit)) (EListLit)))))
(DTypeSig false "coreAliasDecl" (TyCon "Decl"))
(DFunDef false "coreAliasDecl" () (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseAlias") (EListLit (ELit (LString "core")))) (ELit (LString "$prop_core")))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString "<property-helper:core>"))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1)))))
(DTypeSig false "customCarrierMap" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")) (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")))))
(DFunDef false "customCarrierMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "customCarrierMap" ((PCons (PAs "custom" (PCon "CustomPlan" PWild PWild (PVar "word"))) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "acc")) (EApp (EApp (EVar "customCarrierMap") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "customCarrierMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "custom")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "customCarrierMap" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "propHelpersFromWords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PropHelpers")))))))
(DFunDef false "propHelpersFromWords" ((PList) PWild PWild (PList) PWild) (EApp (EApp (EVar "PropHelpers") (EListLit)) (EListLit)))
(DFunDef false "propHelpersFromWords" ((PList) PWild PWild (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "PropHelpers") (EApp (EVar "reverseL") (EVar "helpers"))) (EBinOp "::" (EVar "coreAliasDecl") (EApp (EVar "reverseL") (EVar "decls")))))
(DFunDef false "propHelpersFromWords" ((PCons (PVar "word") (PVar "rest")) (PVar "carriers") (PVar "i") (PVar "helpers") (PVar "decls")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "carriers")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EVar "rest")) (EVar "carriers")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "helpers")) (EVar "decls"))) (arm (PCon "Some" (PVar "custom")) () (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EVar "rest")) (EVar "carriers")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "helperForCustom") (EVar "i")) (EVar "custom")) (EVar "helpers"))) (EApp (EApp (EVar "prependDecls") (EApp (EApp (EVar "helperDecls") (EVar "i")) (EVar "custom"))) (EVar "decls"))))))
(DFunDef false "propHelpersFromWords" (PWild PWild PWild (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "PropHelpers") (EApp (EVar "reverseL") (EVar "helpers"))) (EBinOp "::" (EVar "coreAliasDecl") (EApp (EVar "reverseL") (EVar "decls")))))
(DTypeSig false "helperForCustom" (TyFun (TyCon "Int") (TyFun (TyCon "CustomPlan") (TyCon "PropHelper"))))
(DFunDef false "helperForCustom" ((PVar "i") (PCon "CustomPlan" PWild PWild (PVar "word"))) (EApp (EApp (EApp (EVar "PropHelper") (EVar "word")) (EApp (EVar "generatorName") (EVar "i"))) (EApp (EVar "shrinkerName") (EVar "i"))))
(DTypeSig false "helperDecls" (TyFun (TyCon "Int") (TyFun (TyCon "CustomPlan") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "helperDecls" ((PVar "i") (PCon "CustomPlan" PWild (PVar "carrier") PWild)) (EBlock (DoLet false false (PVar "loc") (EApp (EVar "helperLoc") (EVar "i"))) (DoLet false false (PVar "generator") (EApp (EVar "generatorName") (EVar "i"))) (DoLet false false (PVar "shrinker") (EApp (EVar "shrinkerName") (EVar "i"))) (DoLet false false (PVar "unitTy") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EApp (EVar "Some") (EVar "loc")))) (DoLet false false (PVar "listTy") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "List"))) (EApp (EVar "Some") (EVar "loc")))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (EVar "generator")) (EApp (EApp (EVar "TyFun") (EVar "unitTy")) (EApp (EApp (EApp (EVar "TyEffect") (EListLit (EApp (EVar "effAtomBare") (ELit (LString "Rand"))))) (EListLit)) (EVar "carrier")))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "generator")) (EListLit (EApp (EVar "PLit") (EVar "LUnit")))) (EApp (EApp (EVar "ELoc") (EVar "loc")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "$prop_core.arbitrary")))) (EApp (EVar "ELit") (EVar "LUnit"))))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (EVar "shrinker")) (EApp (EApp (EVar "TyFun") (EVar "carrier")) (EApp (EApp (EVar "TyApp") (EVar "listTy")) (EVar "carrier")))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "shrinker")) (EListLit (EApp (EApp (EVar "PVar") (ELit (LString "$prop_value"))) (EVar "loc")))) (EApp (EApp (EVar "ELoc") (EVar "loc")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "$prop_core.shrink")))) (EApp (EVar "EVar") (ELit (LString "$prop_value"))))))))))
(DTypeSig false "prependDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "prependDecls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDecls" ((PCons (PVar "decl") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "prependDecls") (EVar "rest")) (EBinOp "::" (EVar "decl") (EVar "acc"))))
(DFunDef false "prependDecls" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "helperLoc" (TyFun (TyCon "Int") (TyCon "Loc")))
(DFunDef false "helperLoc" ((PVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EBinOp "++" (EBinOp "++" (ELit (LString "<property-helper:")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ">")))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))))
(DTypeSig false "generatorName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "generatorName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "$prop_gen_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "shrinkerName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "shrinkerName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "$prop_shrink_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Ty" true) (mem "Loc" true) (mem "UsePath" true) (mem "tyConBuiltin" false) (mem "effAtomBare" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "CustomPlan" true) (mem "GenPlan" false) (mem "PlanEnv" false) (mem "customPlansReachable" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropHelper" true))))
(DData Public "PropHelpers" () ((variant "PropHelpers" (ConPos (TyApp (TyCon "List") (TyCon "PropHelper")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig true "propHelpersForPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "PropHelpers"))))
(DFunDef false "propHelpersForPlans" ((PVar "env") (PVar "plans")) (EBlock (DoLet false false (PVar "carriers") (EApp (EApp (EVar "customCarrierMap") (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EApp (EVar "omKeys") (EVar "carriers"))) (EVar "carriers")) (ELit (LInt 0))) (EListLit)) (EListLit)))))
(DTypeSig false "coreAliasDecl" (TyCon "Decl"))
(DFunDef false "coreAliasDecl" () (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseAlias") (EListLit (ELit (LString "core")))) (ELit (LString "$prop_core")))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString "<property-helper:core>"))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1)))))
(DTypeSig false "customCarrierMap" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")) (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")))))
(DFunDef false "customCarrierMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "customCarrierMap" ((PCons (PAs "custom" (PCon "CustomPlan" PWild PWild (PVar "word"))) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "acc")) (EApp (EApp (EVar "customCarrierMap") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "customCarrierMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "custom")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "customCarrierMap" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "propHelpersFromWords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "CustomPlan")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PropHelpers")))))))
(DFunDef false "propHelpersFromWords" ((PList) PWild PWild (PList) PWild) (EApp (EApp (EVar "PropHelpers") (EListLit)) (EListLit)))
(DFunDef false "propHelpersFromWords" ((PList) PWild PWild (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "PropHelpers") (EApp (EVar "reverseL") (EVar "helpers"))) (EBinOp "::" (EVar "coreAliasDecl") (EApp (EVar "reverseL") (EVar "decls")))))
(DFunDef false "propHelpersFromWords" ((PCons (PVar "word") (PVar "rest")) (PVar "carriers") (PVar "i") (PVar "helpers") (PVar "decls")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "carriers")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EVar "rest")) (EVar "carriers")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "helpers")) (EVar "decls"))) (arm (PCon "Some" (PVar "custom")) () (EApp (EApp (EApp (EApp (EApp (EVar "propHelpersFromWords") (EVar "rest")) (EVar "carriers")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "helperForCustom") (EVar "i")) (EVar "custom")) (EVar "helpers"))) (EApp (EApp (EVar "prependDecls") (EApp (EApp (EVar "helperDecls") (EVar "i")) (EVar "custom"))) (EVar "decls"))))))
(DFunDef false "propHelpersFromWords" (PWild PWild PWild (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "PropHelpers") (EApp (EVar "reverseL") (EVar "helpers"))) (EBinOp "::" (EVar "coreAliasDecl") (EApp (EVar "reverseL") (EVar "decls")))))
(DTypeSig false "helperForCustom" (TyFun (TyCon "Int") (TyFun (TyCon "CustomPlan") (TyCon "PropHelper"))))
(DFunDef false "helperForCustom" ((PVar "i") (PCon "CustomPlan" PWild PWild (PVar "word"))) (EApp (EApp (EApp (EVar "PropHelper") (EVar "word")) (EApp (EVar "generatorName") (EVar "i"))) (EApp (EVar "shrinkerName") (EVar "i"))))
(DTypeSig false "helperDecls" (TyFun (TyCon "Int") (TyFun (TyCon "CustomPlan") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "helperDecls" ((PVar "i") (PCon "CustomPlan" PWild (PVar "carrier") PWild)) (EBlock (DoLet false false (PVar "loc") (EApp (EVar "helperLoc") (EVar "i"))) (DoLet false false (PVar "generator") (EApp (EVar "generatorName") (EVar "i"))) (DoLet false false (PVar "shrinker") (EApp (EVar "shrinkerName") (EVar "i"))) (DoLet false false (PVar "unitTy") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EApp (EVar "Some") (EVar "loc")))) (DoLet false false (PVar "listTy") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "List"))) (EApp (EVar "Some") (EVar "loc")))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (EVar "generator")) (EApp (EApp (EVar "TyFun") (EVar "unitTy")) (EApp (EApp (EApp (EVar "TyEffect") (EListLit (EApp (EVar "effAtomBare") (ELit (LString "Rand"))))) (EListLit)) (EVar "carrier")))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "generator")) (EListLit (EApp (EVar "PLit") (EVar "LUnit")))) (EApp (EApp (EVar "ELoc") (EVar "loc")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "$prop_core.arbitrary")))) (EApp (EVar "ELit") (EVar "LUnit"))))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "False")) (EVar "shrinker")) (EApp (EApp (EVar "TyFun") (EVar "carrier")) (EApp (EApp (EVar "TyApp") (EVar "listTy")) (EVar "carrier")))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "shrinker")) (EListLit (EApp (EApp (EVar "PVar") (ELit (LString "$prop_value"))) (EVar "loc")))) (EApp (EApp (EVar "ELoc") (EVar "loc")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "$prop_core.shrink")))) (EApp (EVar "EVar") (ELit (LString "$prop_value"))))))))))
(DTypeSig false "prependDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "prependDecls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDecls" ((PCons (PVar "decl") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "prependDecls") (EVar "rest")) (EBinOp "::" (EVar "decl") (EVar "acc"))))
(DFunDef false "prependDecls" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "helperLoc" (TyFun (TyCon "Int") (TyCon "Loc")))
(DFunDef false "helperLoc" ((PVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EBinOp "++" (EBinOp "++" (ELit (LString "<property-helper:")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ">")))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))))
(DTypeSig false "generatorName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "generatorName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "$prop_gen_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "shrinkerName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "shrinkerName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "$prop_shrink_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
