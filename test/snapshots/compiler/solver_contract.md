# META
source_lines=126
stages=DESUGAR,MARK
# SOURCE
-- Request-local contracts for scoped class solving and qualified-scheme
-- instantiation.  This module owns no inference state and imports no private
-- typechecker operation.  The substitution representation stays opaque behind
-- `InstantiationServices`, allowing the production adapter to preserve the HM
-- kernel's existing variance-sensitive body substitution.

import frontend.ast.{EvId, Ident, Loc}
import types.evidence.{
  EvidenceBinderId,
  GoalId,
  RequestInstanceId,
  ScopeId,
  SolverEvidence,
}
import types.repr.{IfaceRef, Mono, Scheme(..)}

public export data ClassPredicate = ClassPredicate {
  predicateInterface : IfaceRef,
  predicateArguments : List Mono,
}

-- Predicate order is dictionary-parameter order.  Keeping the formal binder in
-- the same record makes the correspondence indivisible during instantiation.
public export data Qualifier = Qualifier {
  predicate : ClassPredicate,
  formal : EvidenceBinderId,
}

public export data QualifiedScheme = QualifiedScheme {
  hm : Scheme,
  qualifiers : List Qualifier,
}

public export data GoalOrigin = GoalOrigin {
  location : Option Loc,
  moduleId : String,
  binding : Option Ident,
}

public export data Wanted = Wanted {
  id : GoalId,
  predicate : ClassPredicate,
  origin : GoalOrigin,
  scope : ScopeId,
  destination : EvId,
}

public export data InstantiationArgument = InstantiationArgument {
  formal : EvidenceBinderId,
  wanted : Wanted,
}

public export data Instantiation = Instantiation {
  body : Mono,
  arguments : List InstantiationArgument,
}

public export data InstantiationServices subst = InstantiationServices {
  makeSubstitution : List Int -> List Int -> subst,
  substituteBody : subst -> Mono -> Mono,
  substituteArgument : subst -> Mono -> Mono,
  freshGoal : GoalOrigin -> ScopeId -> GoalId,
  freshDestination : GoalOrigin -> ScopeId -> EvId,
}

-- The deferred form preserves the original wanted and classifies why it cannot
-- yet be decided.  Whole-graph finalization is explicit rather than encoded as
-- an empty blocker list.
public export data SolverBlocker =
  | BlockingTypeVariable Int
  | BlockingEffectVariable Int
  | BlockingScope ScopeId
  | BlockingFinalization

public export data SolverFailure =
  | MissingInstance
  | AmbiguousInstances (List RequestInstanceId)
  | ResolutionCycle (List GoalId)

public export data SolverOutcome =
  | Solved SolverEvidence
  | Deferred Wanted (List SolverBlocker)
  | Insoluble Wanted SolverFailure

substitutePredicate : InstantiationServices subst ->
  subst ->
  ClassPredicate ->
  ClassPredicate
substitutePredicate services subst pred = ClassPredicate {
  predicateInterface = pred.predicateInterface,
  predicateArguments =
    map (services.substituteArgument subst) pred.predicateArguments,
}

instantiateQualifiers : InstantiationServices subst ->
  subst ->
  ScopeId ->
  GoalOrigin ->
  List Qualifier ->
  List InstantiationArgument
instantiateQualifiers _ _ _ _ [] = []
instantiateQualifiers services subst scope origin (qualifier :: rest) =
  let wanted = Wanted {
    id = services.freshGoal origin scope,
    predicate = substitutePredicate services subst qualifier.predicate,
    origin = origin,
    scope = scope,
    destination = services.freshDestination origin scope,
  }
  InstantiationArgument { formal = qualifier.formal, wanted = wanted }
    :: instantiateQualifiers services subst scope origin rest

export
instantiateQualified : InstantiationServices subst ->
  ScopeId ->
  GoalOrigin ->
  QualifiedScheme ->
  Instantiation
instantiateQualified services scope origin qualified = match qualified.hm
  Forall typeVariables effectVariables schemeBody =>
    let subst = services.makeSubstitution typeVariables effectVariables
    Instantiation {
      body = services.substituteBody subst schemeBody,
      arguments =
        instantiateQualifiers services subst scope origin qualified.qualifiers,
    }
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "Ident" false) (mem "Loc" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" false) (mem "GoalId" false) (mem "RequestInstanceId" false) (mem "ScopeId" false) (mem "SolverEvidence" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "Mono" false) (mem "Scheme" true))))
(DData Public "ClassPredicate" () ((variant "ClassPredicate" (ConNamed (field "predicateInterface" (TyCon "IfaceRef")) (field "predicateArguments" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "Qualifier" () ((variant "Qualifier" (ConNamed (field "predicate" (TyCon "ClassPredicate")) (field "formal" (TyCon "EvidenceBinderId"))))) ())
(DData Public "QualifiedScheme" () ((variant "QualifiedScheme" (ConNamed (field "hm" (TyCon "Scheme")) (field "qualifiers" (TyApp (TyCon "List") (TyCon "Qualifier")))))) ())
(DData Public "GoalOrigin" () ((variant "GoalOrigin" (ConNamed (field "location" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "moduleId" (TyCon "String")) (field "binding" (TyApp (TyCon "Option") (TyCon "Ident")))))) ())
(DData Public "Wanted" () ((variant "Wanted" (ConNamed (field "id" (TyCon "GoalId")) (field "predicate" (TyCon "ClassPredicate")) (field "origin" (TyCon "GoalOrigin")) (field "scope" (TyCon "ScopeId")) (field "destination" (TyCon "EvId"))))) ())
(DData Public "InstantiationArgument" () ((variant "InstantiationArgument" (ConNamed (field "formal" (TyCon "EvidenceBinderId")) (field "wanted" (TyCon "Wanted"))))) ())
(DData Public "Instantiation" () ((variant "Instantiation" (ConNamed (field "body" (TyCon "Mono")) (field "arguments" (TyApp (TyCon "List") (TyCon "InstantiationArgument")))))) ())
(DData Public "InstantiationServices" ("subst") ((variant "InstantiationServices" (ConNamed (field "makeSubstitution" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyVar "subst")))) (field "substituteBody" (TyFun (TyVar "subst") (TyFun (TyCon "Mono") (TyCon "Mono")))) (field "substituteArgument" (TyFun (TyVar "subst") (TyFun (TyCon "Mono") (TyCon "Mono")))) (field "freshGoal" (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "ScopeId") (TyCon "GoalId")))) (field "freshDestination" (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "ScopeId") (TyCon "EvId"))))))) ())
(DData Public "SolverBlocker" () ((variant "BlockingTypeVariable" (ConPos (TyCon "Int"))) (variant "BlockingEffectVariable" (ConPos (TyCon "Int"))) (variant "BlockingScope" (ConPos (TyCon "ScopeId"))) (variant "BlockingFinalization" (ConPos))) ())
(DData Public "SolverFailure" () ((variant "MissingInstance" (ConPos)) (variant "AmbiguousInstances" (ConPos (TyApp (TyCon "List") (TyCon "RequestInstanceId")))) (variant "ResolutionCycle" (ConPos (TyApp (TyCon "List") (TyCon "GoalId"))))) ())
(DData Public "SolverOutcome" () ((variant "Solved" (ConPos (TyCon "SolverEvidence"))) (variant "Deferred" (ConPos (TyCon "Wanted") (TyApp (TyCon "List") (TyCon "SolverBlocker")))) (variant "Insoluble" (ConPos (TyCon "Wanted") (TyCon "SolverFailure")))) ())
(DTypeSig false "substitutePredicate" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyVar "subst") (TyFun (TyCon "ClassPredicate") (TyCon "ClassPredicate")))))
(DFunDef false "substitutePredicate" ((PVar "services") (PVar "subst") (PVar "pred")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "pred") "predicateInterface")) (fa "predicateArguments" (EApp (EApp (EVar "map") (EApp (EFieldAccess (EVar "services") "substituteArgument") (EVar "subst"))) (EFieldAccess (EVar "pred") "predicateArguments"))))))
(DTypeSig false "instantiateQualifiers" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyVar "subst") (TyFun (TyCon "ScopeId") (TyFun (TyCon "GoalOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Qualifier")) (TyApp (TyCon "List") (TyCon "InstantiationArgument"))))))))
(DFunDef false "instantiateQualifiers" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "instantiateQualifiers" ((PVar "services") (PVar "subst") (PVar "scope") (PVar "origin") (PCons (PVar "qualifier") (PVar "rest"))) (EBlock (DoLet false false (PVar "wanted") (ERecordCreate "Wanted" ((fa "id" (EApp (EApp (EFieldAccess (EVar "services") "freshGoal") (EVar "origin")) (EVar "scope"))) (fa "predicate" (EApp (EApp (EApp (EVar "substitutePredicate") (EVar "services")) (EVar "subst")) (EFieldAccess (EVar "qualifier") "predicate"))) (fa "origin" (EVar "origin")) (fa "scope" (EVar "scope")) (fa "destination" (EApp (EApp (EFieldAccess (EVar "services") "freshDestination") (EVar "origin")) (EVar "scope")))))) (DoExpr (EBinOp "::" (ERecordCreate "InstantiationArgument" ((fa "formal" (EFieldAccess (EVar "qualifier") "formal")) (fa "wanted" (EVar "wanted")))) (EApp (EApp (EApp (EApp (EApp (EVar "instantiateQualifiers") (EVar "services")) (EVar "subst")) (EVar "scope")) (EVar "origin")) (EVar "rest"))))))
(DTypeSig true "instantiateQualified" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyCon "ScopeId") (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "QualifiedScheme") (TyCon "Instantiation"))))))
(DFunDef false "instantiateQualified" ((PVar "services") (PVar "scope") (PVar "origin") (PVar "qualified")) (EMatch (EFieldAccess (EVar "qualified") "hm") (arm (PCon "Forall" (PVar "typeVariables") (PVar "effectVariables") (PVar "schemeBody")) () (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EFieldAccess (EVar "services") "makeSubstitution") (EVar "typeVariables")) (EVar "effectVariables"))) (DoExpr (ERecordCreate "Instantiation" ((fa "body" (EApp (EApp (EFieldAccess (EVar "services") "substituteBody") (EVar "subst")) (EVar "schemeBody"))) (fa "arguments" (EApp (EApp (EApp (EApp (EApp (EVar "instantiateQualifiers") (EVar "services")) (EVar "subst")) (EVar "scope")) (EVar "origin")) (EFieldAccess (EVar "qualified") "qualifiers"))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "Ident" false) (mem "Loc" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" false) (mem "GoalId" false) (mem "RequestInstanceId" false) (mem "ScopeId" false) (mem "SolverEvidence" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "Mono" false) (mem "Scheme" true))))
(DData Public "ClassPredicate" () ((variant "ClassPredicate" (ConNamed (field "predicateInterface" (TyCon "IfaceRef")) (field "predicateArguments" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DData Public "Qualifier" () ((variant "Qualifier" (ConNamed (field "predicate" (TyCon "ClassPredicate")) (field "formal" (TyCon "EvidenceBinderId"))))) ())
(DData Public "QualifiedScheme" () ((variant "QualifiedScheme" (ConNamed (field "hm" (TyCon "Scheme")) (field "qualifiers" (TyApp (TyCon "List") (TyCon "Qualifier")))))) ())
(DData Public "GoalOrigin" () ((variant "GoalOrigin" (ConNamed (field "location" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "moduleId" (TyCon "String")) (field "binding" (TyApp (TyCon "Option") (TyCon "Ident")))))) ())
(DData Public "Wanted" () ((variant "Wanted" (ConNamed (field "id" (TyCon "GoalId")) (field "predicate" (TyCon "ClassPredicate")) (field "origin" (TyCon "GoalOrigin")) (field "scope" (TyCon "ScopeId")) (field "destination" (TyCon "EvId"))))) ())
(DData Public "InstantiationArgument" () ((variant "InstantiationArgument" (ConNamed (field "formal" (TyCon "EvidenceBinderId")) (field "wanted" (TyCon "Wanted"))))) ())
(DData Public "Instantiation" () ((variant "Instantiation" (ConNamed (field "body" (TyCon "Mono")) (field "arguments" (TyApp (TyCon "List") (TyCon "InstantiationArgument")))))) ())
(DData Public "InstantiationServices" ("subst") ((variant "InstantiationServices" (ConNamed (field "makeSubstitution" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyVar "subst")))) (field "substituteBody" (TyFun (TyVar "subst") (TyFun (TyCon "Mono") (TyCon "Mono")))) (field "substituteArgument" (TyFun (TyVar "subst") (TyFun (TyCon "Mono") (TyCon "Mono")))) (field "freshGoal" (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "ScopeId") (TyCon "GoalId")))) (field "freshDestination" (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "ScopeId") (TyCon "EvId"))))))) ())
(DData Public "SolverBlocker" () ((variant "BlockingTypeVariable" (ConPos (TyCon "Int"))) (variant "BlockingEffectVariable" (ConPos (TyCon "Int"))) (variant "BlockingScope" (ConPos (TyCon "ScopeId"))) (variant "BlockingFinalization" (ConPos))) ())
(DData Public "SolverFailure" () ((variant "MissingInstance" (ConPos)) (variant "AmbiguousInstances" (ConPos (TyApp (TyCon "List") (TyCon "RequestInstanceId")))) (variant "ResolutionCycle" (ConPos (TyApp (TyCon "List") (TyCon "GoalId"))))) ())
(DData Public "SolverOutcome" () ((variant "Solved" (ConPos (TyCon "SolverEvidence"))) (variant "Deferred" (ConPos (TyCon "Wanted") (TyApp (TyCon "List") (TyCon "SolverBlocker")))) (variant "Insoluble" (ConPos (TyCon "Wanted") (TyCon "SolverFailure")))) ())
(DTypeSig false "substitutePredicate" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyVar "subst") (TyFun (TyCon "ClassPredicate") (TyCon "ClassPredicate")))))
(DFunDef false "substitutePredicate" ((PVar "services") (PVar "subst") (PVar "pred")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "pred") "predicateInterface")) (fa "predicateArguments" (EApp (EApp (EMethodRef "map") (EApp (EFieldAccess (EVar "services") "substituteArgument") (EVar "subst"))) (EFieldAccess (EVar "pred") "predicateArguments"))))))
(DTypeSig false "instantiateQualifiers" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyVar "subst") (TyFun (TyCon "ScopeId") (TyFun (TyCon "GoalOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Qualifier")) (TyApp (TyCon "List") (TyCon "InstantiationArgument"))))))))
(DFunDef false "instantiateQualifiers" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "instantiateQualifiers" ((PVar "services") (PVar "subst") (PVar "scope") (PVar "origin") (PCons (PVar "qualifier") (PVar "rest"))) (EBlock (DoLet false false (PVar "wanted") (ERecordCreate "Wanted" ((fa "id" (EApp (EApp (EFieldAccess (EVar "services") "freshGoal") (EVar "origin")) (EVar "scope"))) (fa "predicate" (EApp (EApp (EApp (EVar "substitutePredicate") (EVar "services")) (EVar "subst")) (EFieldAccess (EVar "qualifier") "predicate"))) (fa "origin" (EVar "origin")) (fa "scope" (EVar "scope")) (fa "destination" (EApp (EApp (EFieldAccess (EVar "services") "freshDestination") (EVar "origin")) (EVar "scope")))))) (DoExpr (EBinOp "::" (ERecordCreate "InstantiationArgument" ((fa "formal" (EFieldAccess (EVar "qualifier") "formal")) (fa "wanted" (EVar "wanted")))) (EApp (EApp (EApp (EApp (EApp (EVar "instantiateQualifiers") (EVar "services")) (EVar "subst")) (EVar "scope")) (EVar "origin")) (EVar "rest"))))))
(DTypeSig true "instantiateQualified" (TyFun (TyApp (TyCon "InstantiationServices") (TyVar "subst")) (TyFun (TyCon "ScopeId") (TyFun (TyCon "GoalOrigin") (TyFun (TyCon "QualifiedScheme") (TyCon "Instantiation"))))))
(DFunDef false "instantiateQualified" ((PVar "services") (PVar "scope") (PVar "origin") (PVar "qualified")) (EMatch (EFieldAccess (EVar "qualified") "hm") (arm (PCon "Forall" (PVar "typeVariables") (PVar "effectVariables") (PVar "schemeBody")) () (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EFieldAccess (EVar "services") "makeSubstitution") (EVar "typeVariables")) (EVar "effectVariables"))) (DoExpr (ERecordCreate "Instantiation" ((fa "body" (EApp (EApp (EFieldAccess (EVar "services") "substituteBody") (EVar "subst")) (EVar "schemeBody"))) (fa "arguments" (EApp (EApp (EApp (EApp (EApp (EVar "instantiateQualifiers") (EVar "services")) (EVar "subst")) (EVar "scope")) (EVar "origin")) (EFieldAccess (EVar "qualified") "qualifiers"))))))))))
