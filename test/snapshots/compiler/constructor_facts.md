# META
source_lines=188
stages=DESUGAR,MARK
# SOURCE
import list.{findMap}
import string as S
import ir.core_ir.{CProgram(..)}
import frontend.runtime_constructors.{
  RuntimeOwner(..), RuntimeCtorId(..), namedRuntimeCtor, runtimeCtorFact,
  runtimeRoster, runtimeCtorName, runtimeOwnerWord
}
import support.ordmap.{
  OrdMap, omEmpty, omLookup, omHasKey, omInsert, omFromPairs, omMapValues
}
import support.util.{reverseL}
import map.{entries}

public export data ConstructorFacts = ConstructorFacts {
  arities : OrdMap Int,
  owners : OrdMap String,
  rosters : OrdMap (List String),
  ordinals : OrdMap Int,
  typeOrder : List String,
}

export
planConstructors : CProgram -> ConstructorFacts
planConstructors (CProgram _ ars tys _ _ _) =
  let initial = ConstructorFacts {
    arities = omFromPairs (reverseL ars) omEmpty,
    owners = omEmpty,
    rosters = omEmpty,
    ordinals = omEmpty,
    typeOrder = [],
  }
  let facts = collectConstructors tys omEmpty initial
  { facts |
    rosters = omMapValues reverseL facts.rosters,
    typeOrder = reverseL facts.typeOrder,
  }

collectConstructors : List (String, String) ->
  OrdMap Int ->
  ConstructorFacts ->
  ConstructorFacts
collectConstructors [] _ facts = facts
collectConstructors ((ctor, ty) :: rest) counts facts =
  let position = optionOr 0 (omLookup ty counts)
  let firstType = not (omHasKey ty counts)
  let firstCtor = not (omHasKey ctor facts.owners)
  let next = { facts |
    owners = if firstCtor then omInsert ctor ty facts.owners else facts.owners,
    ordinals =
      if firstCtor then
        omInsert ctor position facts.ordinals
      else
        facts.ordinals,
    rosters =
      omInsert
        ty
        (ctor :: optionOr [] (omLookup ty facts.rosters))
        facts.rosters,
    typeOrder = if firstType then ty :: facts.typeOrder else facts.typeOrder,
  }
  collectConstructors rest (omInsert ty (position + 1) counts) next

export
declaredCtorArity : ConstructorFacts -> String -> Option Int
declaredCtorArity facts name = omLookup name facts.arities

export
declaredCtorOwner : ConstructorFacts -> String -> Option String
declaredCtorOwner facts name = omLookup name facts.owners

export
declaredCtorOrdinal : ConstructorFacts -> String -> Option Int
declaredCtorOrdinal facts name = omLookup name facts.ordinals

export
declaredTypeCtors : ConstructorFacts -> String -> List String
declaredTypeCtors facts name = optionOr [] (omLookup name facts.rosters)

export
validateConstructorFacts : CProgram -> ConstructorFacts -> List String
validateConstructorFacts cp facts =
  let expected = planConstructors cp
  let (CProgram _ ars tys _ _ _) = cp
  (if entries facts.arities == entries expected.arities then
      []
    else
      ["constructor-fact: arity projection disagrees with Core"])
    ++ (if entries facts.owners == entries expected.owners then
      []
    else
      ["constructor-fact: owner projection disagrees with Core"])
    ++ (if entries facts.rosters == entries expected.rosters then
      []
    else
      ["constructor-fact: roster projection disagrees with Core"])
    ++ (if entries facts.ordinals == entries expected.ordinals then
      []
    else
      ["constructor-fact: ordinal projection disagrees with Core"])
    ++ (if facts.typeOrder == expected.typeOrder then
      []
    else
      ["constructor-fact: type order disagrees with Core"])
    ++ flatMap
      ((name, arity) =>
        if arity < 0 then
          ["constructor-fact: negative arity for " ++ name]
        else
          [])
      ars
    ++ flatMap (validateRuntimeRoster expected) expected.typeOrder
    ++ flatMap validateRuntimeOwner tys
    ++ flatMap (validateRuntimeArity expected) ars
    ++ validateOwnerPositions expected expected.typeOrder omEmpty

runtimeOwner : String -> Option RuntimeOwner
runtimeOwner word =
  findMap
    (owner => if runtimeOwnerWord owner == Some word then Some owner else None)
    [RuntimeList, RuntimeOption, RuntimeResult, RuntimeOrdering, RuntimeBool]

validateRuntimeRoster : ConstructorFacts -> String -> List String
validateRuntimeRoster facts ty = match runtimeOwner ty
  None => []
  Some owner =>
    let roster = filterMap runtimeCtorName (runtimeRoster owner)
    if declaredTypeCtors facts ty == roster then
      []
    else
      ["constructor-fact: runtime roster disagrees for " ++ ty]

-- Mangling qualifies declared owners while exempt runtime constructor words stay
-- bare. Only a bare owner claims the runtime roster; physical tags stay reserved.
validateRuntimeOwner : (String, String) -> List String
validateRuntimeOwner (name, ty) = match namedRuntimeCtor name
  Some RuntimeCons => []
  Some RuntimeNil => []
  Some id =>
    if runtimeOwnerWord (runtimeCtorFact id).owner == Some ty
      || S.contains "." ty then
      []
    else
      ["constructor-fact: runtime owner disagrees for " ++ name]
  None => match runtimeOwner ty
    Some _ => ["constructor-fact: unknown runtime constructor " ++ name]
    None => []

validateRuntimeArity : ConstructorFacts -> (String, Int) -> List String
validateRuntimeArity facts (name, arity) = match namedRuntimeCtor name
  None => []
  Some id =>
    let builtin = match id
      RuntimeCons => declaredCtorOwner facts name == Some "List"
      RuntimeNil => declaredCtorOwner facts name == Some "List"
      _ => True
    if builtin && arity /= (runtimeCtorFact id).arity then
      ["constructor-fact: runtime arity disagrees for " ++ name]
    else
      []

-- A constructor in an earlier type's roster must agree with its first owner's
-- position; otherwise the table assigns two incompatible declaration orders.
validateOwnerPositions : ConstructorFacts ->
  List String ->
  OrdMap Unit ->
  List String
validateOwnerPositions _ [] _ = []
validateOwnerPositions facts (ty :: rest) seen =
  let (next, defects) =
    validateRosterPositions facts (declaredTypeCtors facts ty) 0 seen
  defects ++ validateOwnerPositions facts rest next

validateRosterPositions : ConstructorFacts ->
  List String ->
  Int ->
  OrdMap Unit ->
  (OrdMap Unit, List String)
validateRosterPositions _ [] _ seen = (seen, [])
validateRosterPositions facts (name :: rest) position seen =
  let first = not (omHasKey name seen)
  let bad =
    if first && declaredCtorOrdinal facts name /= Some position then
      ["constructor-fact: ambiguous owner ordinal for " ++ name]
    else
      []
  let (next, defects) =
    validateRosterPositions facts rest (position + 1) (omInsert name () seen)
  (next, bad ++ defects)
# DESUGAR
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("frontend" "runtime_constructors") ((mem "RuntimeOwner" true) (mem "RuntimeCtorId" true) (mem "namedRuntimeCtor" false) (mem "runtimeCtorFact" false) (mem "runtimeRoster" false) (mem "runtimeCtorName" false) (mem "runtimeOwnerWord" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omFromPairs" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DData Public "ConstructorFacts" () ((variant "ConstructorFacts" (ConNamed (field "arities" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "owners" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "rosters" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "ordinals" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "typeOrder" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "planConstructors" (TyFun (TyCon "CProgram") (TyCon "ConstructorFacts")))
(DFunDef false "planConstructors" ((PCon "CProgram" PWild (PVar "ars") (PVar "tys") PWild PWild PWild)) (EBlock (DoLet false false (PVar "initial") (ERecordCreate "ConstructorFacts" ((fa "arities" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ars"))) (EVar "omEmpty"))) (fa "owners" (EVar "omEmpty")) (fa "rosters" (EVar "omEmpty")) (fa "ordinals" (EVar "omEmpty")) (fa "typeOrder" (EListLit))))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "collectConstructors") (EVar "tys")) (EVar "omEmpty")) (EVar "initial"))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "rosters" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "facts") "rosters"))) (fa "typeOrder" (EApp (EVar "reverseL") (EFieldAccess (EVar "facts") "typeOrder"))))))))
(DTypeSig false "collectConstructors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ConstructorFacts") (TyCon "ConstructorFacts")))))
(DFunDef false "collectConstructors" ((PList) PWild (PVar "facts")) (EVar "facts"))
(DFunDef false "collectConstructors" ((PCons (PTuple (PVar "ctor") (PVar "ty")) (PVar "rest")) (PVar "counts") (PVar "facts")) (EBlock (DoLet false false (PVar "position") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "counts")))) (DoLet false false (PVar "firstType") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "ty")) (EVar "counts")))) (DoLet false false (PVar "firstCtor") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "ctor")) (EFieldAccess (EVar "facts") "owners")))) (DoLet false false (PVar "next") (ERecordUpdate (EVar "facts") ((fa "owners" (EIf (EVar "firstCtor") (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (EVar "ty")) (EFieldAccess (EVar "facts") "owners")) (EFieldAccess (EVar "facts") "owners"))) (fa "ordinals" (EIf (EVar "firstCtor") (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (EVar "position")) (EFieldAccess (EVar "facts") "ordinals")) (EFieldAccess (EVar "facts") "ordinals"))) (fa "rosters" (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EBinOp "::" (EVar "ctor") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "ty")) (EFieldAccess (EVar "facts") "rosters"))))) (EFieldAccess (EVar "facts") "rosters"))) (fa "typeOrder" (EIf (EVar "firstType") (EBinOp "::" (EVar "ty") (EFieldAccess (EVar "facts") "typeOrder")) (EFieldAccess (EVar "facts") "typeOrder")))))) (DoExpr (EApp (EApp (EApp (EVar "collectConstructors") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EBinOp "+" (EVar "position") (ELit (LInt 1)))) (EVar "counts"))) (EVar "next")))))
(DTypeSig true "declaredCtorArity" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredCtorArity" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "arities")))
(DTypeSig true "declaredCtorOwner" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "declaredCtorOwner" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "owners")))
(DTypeSig true "declaredCtorOrdinal" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredCtorOrdinal" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "ordinals")))
(DTypeSig true "declaredTypeCtors" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declaredTypeCtors" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "rosters"))))
(DTypeSig true "validateConstructorFacts" (TyFun (TyCon "CProgram") (TyFun (TyCon "ConstructorFacts") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateConstructorFacts" ((PVar "cp") (PVar "facts")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "planConstructors") (EVar "cp"))) (DoLet false false (PCon "CProgram" PWild (PVar "ars") (PVar "tys") PWild PWild PWild) (EVar "cp")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "arities")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "arities"))) (EListLit) (EListLit (ELit (LString "constructor-fact: arity projection disagrees with Core")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "owners")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "owners"))) (EListLit) (EListLit (ELit (LString "constructor-fact: owner projection disagrees with Core"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "rosters")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "rosters"))) (EListLit) (EListLit (ELit (LString "constructor-fact: roster projection disagrees with Core"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "ordinals")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "ordinals"))) (EListLit) (EListLit (ELit (LString "constructor-fact: ordinal projection disagrees with Core"))))) (EIf (EBinOp "==" (EFieldAccess (EVar "facts") "typeOrder") (EFieldAccess (EVar "expected") "typeOrder")) (EListLit) (EListLit (ELit (LString "constructor-fact: type order disagrees with Core"))))) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "name") (PVar "arity"))) (EIf (EBinOp "<" (EVar "arity") (ELit (LInt 0))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: negative arity for ")) (EVar "name"))) (EListLit)))) (EVar "ars"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "validateRuntimeRoster") (EVar "expected"))) (EFieldAccess (EVar "expected") "typeOrder"))) (EApp (EApp (EVar "flatMap") (EVar "validateRuntimeOwner")) (EVar "tys"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "validateRuntimeArity") (EVar "expected"))) (EVar "ars"))) (EApp (EApp (EApp (EVar "validateOwnerPositions") (EVar "expected")) (EFieldAccess (EVar "expected") "typeOrder")) (EVar "omEmpty"))))))
(DTypeSig false "runtimeOwner" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeOwner"))))
(DFunDef false "runtimeOwner" ((PVar "word")) (EApp (EApp (EVar "findMap") (ELam ((PVar "owner")) (EIf (EBinOp "==" (EApp (EVar "runtimeOwnerWord") (EVar "owner")) (EApp (EVar "Some") (EVar "word"))) (EApp (EVar "Some") (EVar "owner")) (EVar "None")))) (EListLit (EVar "RuntimeList") (EVar "RuntimeOption") (EVar "RuntimeResult") (EVar "RuntimeOrdering") (EVar "RuntimeBool"))))
(DTypeSig false "validateRuntimeRoster" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRuntimeRoster" ((PVar "facts") (PVar "ty")) (EMatch (EApp (EVar "runtimeOwner") (EVar "ty")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "owner")) () (EBlock (DoLet false false (PVar "roster") (EApp (EApp (EVar "filterMap") (EVar "runtimeCtorName")) (EApp (EVar "runtimeRoster") (EVar "owner")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "declaredTypeCtors") (EVar "facts")) (EVar "ty")) (EVar "roster")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime roster disagrees for ")) (EVar "ty")))))))))
(DTypeSig false "validateRuntimeOwner" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRuntimeOwner" ((PTuple (PVar "name") (PVar "ty"))) (EMatch (EApp (EVar "namedRuntimeCtor") (EVar "name")) (arm (PCon "Some" (PCon "RuntimeCons")) () (EListLit)) (arm (PCon "Some" (PCon "RuntimeNil")) () (EListLit)) (arm (PCon "Some" (PVar "id")) () (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "runtimeOwnerWord") (EFieldAccess (EApp (EVar "runtimeCtorFact") (EVar "id")) "owner")) (EApp (EVar "Some") (EVar "ty"))) (EApp (EApp (EVar "S.contains") (ELit (LString "."))) (EVar "ty"))) (EListLit) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime owner disagrees for ")) (EVar "name"))))) (arm (PCon "None") () (EMatch (EApp (EVar "runtimeOwner") (EVar "ty")) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (ELit (LString "constructor-fact: unknown runtime constructor ")) (EVar "name")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "validateRuntimeArity" (TyFun (TyCon "ConstructorFacts") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRuntimeArity" ((PVar "facts") (PTuple (PVar "name") (PVar "arity"))) (EMatch (EApp (EVar "namedRuntimeCtor") (EVar "name")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "id")) () (EBlock (DoLet false false (PVar "builtin") (EMatch (EVar "id") (arm (PCon "RuntimeCons") () (EBinOp "==" (EApp (EApp (EVar "declaredCtorOwner") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (ELit (LString "List"))))) (arm (PCon "RuntimeNil") () (EBinOp "==" (EApp (EApp (EVar "declaredCtorOwner") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (ELit (LString "List"))))) (arm PWild () (EVar "True")))) (DoExpr (EIf (EBinOp "&&" (EVar "builtin") (EBinOp "/=" (EVar "arity") (EFieldAccess (EApp (EVar "runtimeCtorFact") (EVar "id")) "arity"))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime arity disagrees for ")) (EVar "name"))) (EListLit)))))))
(DTypeSig false "validateOwnerPositions" (TyFun (TyCon "ConstructorFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateOwnerPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "validateOwnerPositions" ((PVar "facts") (PCons (PVar "ty") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PTuple (PVar "next") (PVar "defects")) (EApp (EApp (EApp (EApp (EVar "validateRosterPositions") (EVar "facts")) (EApp (EApp (EVar "declaredTypeCtors") (EVar "facts")) (EVar "ty"))) (ELit (LInt 0))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "defects") (EApp (EApp (EApp (EVar "validateOwnerPositions") (EVar "facts")) (EVar "rest")) (EVar "next"))))))
(DTypeSig false "validateRosterPositions" (TyFun (TyCon "ConstructorFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "validateRosterPositions" (PWild (PList) PWild (PVar "seen")) (ETuple (EVar "seen") (EListLit)))
(DFunDef false "validateRosterPositions" ((PVar "facts") (PCons (PVar "name") (PVar "rest")) (PVar "position") (PVar "seen")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")))) (DoLet false false (PVar "bad") (EIf (EBinOp "&&" (EVar "first") (EBinOp "/=" (EApp (EApp (EVar "declaredCtorOrdinal") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (EVar "position")))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: ambiguous owner ordinal for ")) (EVar "name"))) (EListLit))) (DoLet false false (PTuple (PVar "next") (PVar "defects")) (EApp (EApp (EApp (EApp (EVar "validateRosterPositions") (EVar "facts")) (EVar "rest")) (EBinOp "+" (EVar "position") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))) (DoExpr (ETuple (EVar "next") (EBinOp "++" (EVar "bad") (EVar "defects"))))))
# MARK
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("frontend" "runtime_constructors") ((mem "RuntimeOwner" true) (mem "RuntimeCtorId" true) (mem "namedRuntimeCtor" false) (mem "runtimeCtorFact" false) (mem "runtimeRoster" false) (mem "runtimeCtorName" false) (mem "runtimeOwnerWord" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omFromPairs" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("map") ((mem "entries" false))))
(DData Public "ConstructorFacts" () ((variant "ConstructorFacts" (ConNamed (field "arities" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "owners" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "rosters" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "ordinals" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "typeOrder" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "planConstructors" (TyFun (TyCon "CProgram") (TyCon "ConstructorFacts")))
(DFunDef false "planConstructors" ((PCon "CProgram" PWild (PVar "ars") (PVar "tys") PWild PWild PWild)) (EBlock (DoLet false false (PVar "initial") (ERecordCreate "ConstructorFacts" ((fa "arities" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ars"))) (EVar "omEmpty"))) (fa "owners" (EVar "omEmpty")) (fa "rosters" (EVar "omEmpty")) (fa "ordinals" (EVar "omEmpty")) (fa "typeOrder" (EListLit))))) (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "collectConstructors") (EVar "tys")) (EVar "omEmpty")) (EVar "initial"))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "rosters" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "facts") "rosters"))) (fa "typeOrder" (EApp (EVar "reverseL") (EFieldAccess (EVar "facts") "typeOrder"))))))))
(DTypeSig false "collectConstructors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ConstructorFacts") (TyCon "ConstructorFacts")))))
(DFunDef false "collectConstructors" ((PList) PWild (PVar "facts")) (EVar "facts"))
(DFunDef false "collectConstructors" ((PCons (PTuple (PVar "ctor") (PVar "ty")) (PVar "rest")) (PVar "counts") (PVar "facts")) (EBlock (DoLet false false (PVar "position") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "counts")))) (DoLet false false (PVar "firstType") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "ty")) (EVar "counts")))) (DoLet false false (PVar "firstCtor") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "ctor")) (EFieldAccess (EVar "facts") "owners")))) (DoLet false false (PVar "next") (ERecordUpdate (EVar "facts") ((fa "owners" (EIf (EVar "firstCtor") (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (EVar "ty")) (EFieldAccess (EVar "facts") "owners")) (EFieldAccess (EVar "facts") "owners"))) (fa "ordinals" (EIf (EVar "firstCtor") (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (EVar "position")) (EFieldAccess (EVar "facts") "ordinals")) (EFieldAccess (EVar "facts") "ordinals"))) (fa "rosters" (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EBinOp "::" (EVar "ctor") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "ty")) (EFieldAccess (EVar "facts") "rosters"))))) (EFieldAccess (EVar "facts") "rosters"))) (fa "typeOrder" (EIf (EVar "firstType") (EBinOp "::" (EVar "ty") (EFieldAccess (EVar "facts") "typeOrder")) (EFieldAccess (EVar "facts") "typeOrder")))))) (DoExpr (EApp (EApp (EApp (EVar "collectConstructors") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EBinOp "+" (EVar "position") (ELit (LInt 1)))) (EVar "counts"))) (EVar "next")))))
(DTypeSig true "declaredCtorArity" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredCtorArity" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "arities")))
(DTypeSig true "declaredCtorOwner" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "declaredCtorOwner" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "owners")))
(DTypeSig true "declaredCtorOrdinal" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "declaredCtorOrdinal" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "ordinals")))
(DTypeSig true "declaredTypeCtors" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declaredTypeCtors" ((PVar "facts") (PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "facts") "rosters"))))
(DTypeSig true "validateConstructorFacts" (TyFun (TyCon "CProgram") (TyFun (TyCon "ConstructorFacts") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateConstructorFacts" ((PVar "cp") (PVar "facts")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "planConstructors") (EVar "cp"))) (DoLet false false (PCon "CProgram" PWild (PVar "ars") (PVar "tys") PWild PWild PWild) (EVar "cp")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "arities")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "arities"))) (EListLit) (EListLit (ELit (LString "constructor-fact: arity projection disagrees with Core")))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "owners")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "owners"))) (EListLit) (EListLit (ELit (LString "constructor-fact: owner projection disagrees with Core"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "rosters")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "rosters"))) (EListLit) (EListLit (ELit (LString "constructor-fact: roster projection disagrees with Core"))))) (EIf (EBinOp "==" (EApp (EVar "entries") (EFieldAccess (EVar "facts") "ordinals")) (EApp (EVar "entries") (EFieldAccess (EVar "expected") "ordinals"))) (EListLit) (EListLit (ELit (LString "constructor-fact: ordinal projection disagrees with Core"))))) (EIf (EBinOp "==" (EFieldAccess (EVar "facts") "typeOrder") (EFieldAccess (EVar "expected") "typeOrder")) (EListLit) (EListLit (ELit (LString "constructor-fact: type order disagrees with Core"))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "name") (PVar "arity"))) (EIf (EBinOp "<" (EVar "arity") (ELit (LInt 0))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: negative arity for ")) (EVar "name"))) (EListLit)))) (EVar "ars"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "validateRuntimeRoster") (EVar "expected"))) (EFieldAccess (EVar "expected") "typeOrder"))) (EApp (EApp (EDictApp "flatMap") (EVar "validateRuntimeOwner")) (EVar "tys"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "validateRuntimeArity") (EVar "expected"))) (EVar "ars"))) (EApp (EApp (EApp (EVar "validateOwnerPositions") (EVar "expected")) (EFieldAccess (EVar "expected") "typeOrder")) (EVar "omEmpty"))))))
(DTypeSig false "runtimeOwner" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeOwner"))))
(DFunDef false "runtimeOwner" ((PVar "word")) (EApp (EApp (EVar "findMap") (ELam ((PVar "owner")) (EIf (EBinOp "==" (EApp (EVar "runtimeOwnerWord") (EVar "owner")) (EApp (EVar "Some") (EVar "word"))) (EApp (EVar "Some") (EVar "owner")) (EVar "None")))) (EListLit (EVar "RuntimeList") (EVar "RuntimeOption") (EVar "RuntimeResult") (EVar "RuntimeOrdering") (EVar "RuntimeBool"))))
(DTypeSig false "validateRuntimeRoster" (TyFun (TyCon "ConstructorFacts") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRuntimeRoster" ((PVar "facts") (PVar "ty")) (EMatch (EApp (EVar "runtimeOwner") (EVar "ty")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "owner")) () (EBlock (DoLet false false (PVar "roster") (EApp (EApp (EMethodRef "filterMap") (EVar "runtimeCtorName")) (EApp (EVar "runtimeRoster") (EVar "owner")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "declaredTypeCtors") (EVar "facts")) (EVar "ty")) (EVar "roster")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime roster disagrees for ")) (EVar "ty")))))))))
(DTypeSig false "validateRuntimeOwner" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRuntimeOwner" ((PTuple (PVar "name") (PVar "ty"))) (EMatch (EApp (EVar "namedRuntimeCtor") (EVar "name")) (arm (PCon "Some" (PCon "RuntimeCons")) () (EListLit)) (arm (PCon "Some" (PCon "RuntimeNil")) () (EListLit)) (arm (PCon "Some" (PVar "id")) () (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "runtimeOwnerWord") (EFieldAccess (EApp (EVar "runtimeCtorFact") (EVar "id")) "owner")) (EApp (EVar "Some") (EVar "ty"))) (EApp (EApp (EVar "S.contains") (ELit (LString "."))) (EVar "ty"))) (EListLit) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime owner disagrees for ")) (EVar "name"))))) (arm (PCon "None") () (EMatch (EApp (EVar "runtimeOwner") (EVar "ty")) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (ELit (LString "constructor-fact: unknown runtime constructor ")) (EVar "name")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "validateRuntimeArity" (TyFun (TyCon "ConstructorFacts") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRuntimeArity" ((PVar "facts") (PTuple (PVar "name") (PVar "arity"))) (EMatch (EApp (EVar "namedRuntimeCtor") (EVar "name")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "id")) () (EBlock (DoLet false false (PVar "builtin") (EMatch (EVar "id") (arm (PCon "RuntimeCons") () (EBinOp "==" (EApp (EApp (EVar "declaredCtorOwner") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (ELit (LString "List"))))) (arm (PCon "RuntimeNil") () (EBinOp "==" (EApp (EApp (EVar "declaredCtorOwner") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (ELit (LString "List"))))) (arm PWild () (EVar "True")))) (DoExpr (EIf (EBinOp "&&" (EVar "builtin") (EBinOp "/=" (EVar "arity") (EFieldAccess (EApp (EVar "runtimeCtorFact") (EVar "id")) "arity"))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: runtime arity disagrees for ")) (EVar "name"))) (EListLit)))))))
(DTypeSig false "validateOwnerPositions" (TyFun (TyCon "ConstructorFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validateOwnerPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "validateOwnerPositions" ((PVar "facts") (PCons (PVar "ty") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PTuple (PVar "next") (PVar "defects")) (EApp (EApp (EApp (EApp (EVar "validateRosterPositions") (EVar "facts")) (EApp (EApp (EVar "declaredTypeCtors") (EVar "facts")) (EVar "ty"))) (ELit (LInt 0))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "defects") (EApp (EApp (EApp (EVar "validateOwnerPositions") (EVar "facts")) (EVar "rest")) (EVar "next"))))))
(DTypeSig false "validateRosterPositions" (TyFun (TyCon "ConstructorFacts") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "validateRosterPositions" (PWild (PList) PWild (PVar "seen")) (ETuple (EVar "seen") (EListLit)))
(DFunDef false "validateRosterPositions" ((PVar "facts") (PCons (PVar "name") (PVar "rest")) (PVar "position") (PVar "seen")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")))) (DoLet false false (PVar "bad") (EIf (EBinOp "&&" (EVar "first") (EBinOp "/=" (EApp (EApp (EVar "declaredCtorOrdinal") (EVar "facts")) (EVar "name")) (EApp (EVar "Some") (EVar "position")))) (EListLit (EBinOp "++" (ELit (LString "constructor-fact: ambiguous owner ordinal for ")) (EVar "name"))) (EListLit))) (DoLet false false (PTuple (PVar "next") (PVar "defects")) (EApp (EApp (EApp (EApp (EVar "validateRosterPositions") (EVar "facts")) (EVar "rest")) (EBinOp "+" (EVar "position") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))) (DoExpr (ETuple (EVar "next") (EBinOp "++" (EVar "bad") (EVar "defects"))))))
