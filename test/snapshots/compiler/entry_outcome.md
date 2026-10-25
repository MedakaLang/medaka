# META
source_lines=119
stages=DESUGAR,MARK
# SOURCE
import types.invocation_basis.{frozenInvocationView}
import types.value_main.{mainUseSite, mainUsedMsg}
-- The checked main-shape facts published at the end of a typecheck drive.

import frontend.ast.{EvId, TyConOrigin(..), Decl(..), Expr(..), Ty(..), Loc}
import types.repr.{Mono(..), Scheme(..), normalize, IfaceRef(..)}
import types.tc_types.{
  GraphCtx(..), ModuleCtx(..), DriveOutputs(..), InvocationView(..)
}
import types.publish.{EntryOutcome(..), TcDiag(..)}

-- The head node of a left-spine type application.
mainHead : Mono -> Mono
mainHead t = match normalize t
  TApp a _ => mainHead a
  TQual a _ => mainHead a
  other => other

-- The stdlib `async` module's `Async` head by origin; a same-named user type is
-- an ordinary value main.
export
mainIsAsyncNow : GraphCtx -> Unit -> Bool
mainIsAsyncNow gctx _ = match gctx.mainSchemeRef.value
  Some (Forall _ _ _ _ _ t) => match mainHead t
    TCon "Async" (OriginModule "async") => True
    _ => False
  None => False

-- The entry driver takes `Async e Unit`; other payloads are diagnosed before its
-- rewrite rather than by driver unification.
export
mainAsyncPayloadIsUnitNow : GraphCtx -> Unit -> Bool
mainAsyncPayloadIsUnitNow gctx _ = match gctx.mainSchemeRef.value
  Some (Forall _ _ _ _ _ t) => match normalize t
    TApp _ payload => match normalize payload
      TCon "Unit" _ => True
      _ => False
    _ => False
  None => False

-- Unit-shaped includes an unconstrained result variable, which cannot produce a
-- printable value. A constrained variable remains ambiguous, so the caller
-- supplies whether the `main` binding has recorded obligations.
export
mainIsUnitNow : GraphCtx -> Bool -> Unit -> Bool
mainIsUnitNow gctx hasObligations _ = match gctx.mainSchemeRef.value
  Some (Forall _ _ _ _ _ t) => match normalize t
    TCon "Unit" _ => True
    TVar _ => not hasObligations
    _ => False
  None => False

-- The checked Float result survives a polymorphic HOF whose erased body shape
-- cannot tell an emitter which scalar formatter to use.
mainIsFloatNow : GraphCtx -> Unit -> Bool
mainIsFloatNow gctx _ = match gctx.mainSchemeRef.value
  Some (Forall _ _ _ _ _ t) => match normalize t
    TCon "Float" _ => True
    _ => False
  None => False

-- The drive's answers to the post-drive questions, read after the drain and the
-- auto-print verdict, when the graph's main scheme and obligation answer are final.
export
entryOutcomeNow : ModuleCtx -> Bool -> Option EvId -> EntryOutcome
entryOutcomeNow mctx hasObligations autoPrint = EntryOutcome {
  eoMainIsUnit = mainIsUnitNow mctx.mcGraph hasObligations (),
  eoMainIsFloat = mainIsFloatNow mctx.mcGraph (),
  eoMainIsAsync = mainIsAsyncNow mctx.mcGraph (),
  eoMainAsyncPayloadIsUnit = mainAsyncPayloadIsUnitNow mctx.mcGraph (),
  eoAutoPrint = autoPrint,
}

export
driveOutputsNow : ModuleCtx -> EntryOutcome -> DriveOutputs
driveOutputsNow mctx outcome = DriveOutputs {
  doManifestRequests = [],
  doManifests = [],
  doServedModules = 0,
  doEntryOutcome = outcome,
  doHadTypeErrors = mctx.mcGraph.typeErrorsSticky.value,
  doHadMatchWarnings = not (isEmpty mctx.mcCells.matchWarnings.value),
  doInvocationView = frozenInvocationView mctx.mcCells.invocationViewRef.value,
  doGrantsEnabled = isSome mctx.mcGraph.markSetsRef.value,
  doEffectDomains = mctx.mcGraph.effectDomains.value,
  doStickyDiags = mctx.mcGraph.typeErrorsStickyDiags.value,
  doIfaceExports = mctx.mcGraph.declEnvsRef.value.deMethods.meIfaceExports,
  doFfiAliases = mctx.mcGraph.declEnvsRef.value.deData.deAliases,
  doOrdIndex = mctx.mcGraph.declEnvsRef.value.deOrdIndex,
  doEffvarNext = mctx.mcGraph.graphRun.effvarCounter.value,
}

-- The interface of `println`'s one-predicate context (`Display a => …`).
export
printlnIface : List Decl -> Option IfaceRef
printlnIface [] = None
printlnIface ((DAttrib _ d) :: rest) = printlnIface (d :: rest)
printlnIface ((DTypeSig _ "println" (TyConstrained [c] _) _) :: _) =
  Some IfaceRef { irName = c.constraintHead, irOrigin = c.constraintOrigin }
printlnIface (_ :: rest) = printlnIface rest

-- The span of `main`'s body, or of the binding when the body carries none.
export
mainBodySpan : List Decl -> Option Loc
mainBodySpan [] = None
mainBodySpan ((DAttrib _ d) :: rest) = mainBodySpan (d :: rest)
mainBodySpan ((DFunDef _ "main" [] body site _) :: _) = match body
  ELoc l _ => Some l
  _ => Some site
mainBodySpan (_ :: rest) = mainBodySpan rest

-- Another binding's use of `main` is typed against the printing wrap's `main`
-- where run, build and test elaborate the wrapped program, so it is rejected.
export
mainUseDiags : Option Loc -> List Decl -> List TcDiag
mainUseDiags None _ = []
mainUseDiags (Some site) entry = match mainUseSite site entry
  Some at => [TcDiag "T-MAIN-USED" 1 (Some at) mainUsedMsg None None]
  None => []
# DESUGAR
(DUse false (UseGroup ("types" "invocation_basis") ((mem "frozenInvocationView" false))))
(DUse false (UseGroup ("types" "value_main") ((mem "mainUseSite" false) (mem "mainUsedMsg" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Ty" true) (mem "Loc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "ModuleCtx" true) (mem "DriveOutputs" true) (mem "InvocationView" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" true) (mem "TcDiag" true))))
(DTypeSig false "mainHead" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "mainHead" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "mainHead") (EVar "a"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "mainHead") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "mainIsAsyncNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainIsAsyncNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "mainHead") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Async")) (PCon "OriginModule" (PLit (LString "async")))) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "mainAsyncPayloadIsUnitNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainAsyncPayloadIsUnitNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" PWild (PVar "payload")) () (EMatch (EApp (EVar "normalize") (EVar "payload")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "mainIsUnitNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Unit") (TyCon "Bool")))))
(DFunDef false "mainIsUnitNow" ((PVar "gctx") (PVar "hasObligations") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (EVar "True")) (arm (PCon "TVar" PWild) () (EApp (EVar "not") (EVar "hasObligations"))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "mainIsFloatNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainIsFloatNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "entryOutcomeNow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "EntryOutcome")))))
(DFunDef false "entryOutcomeNow" ((PVar "mctx") (PVar "hasObligations") (PVar "autoPrint")) (ERecordCreate "EntryOutcome" ((fa "eoMainIsUnit" (EApp (EApp (EApp (EVar "mainIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "hasObligations")) (ELit LUnit))) (fa "eoMainIsFloat" (EApp (EApp (EVar "mainIsFloatNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoMainIsAsync" (EApp (EApp (EVar "mainIsAsyncNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoMainAsyncPayloadIsUnit" (EApp (EApp (EVar "mainAsyncPayloadIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoAutoPrint" (EVar "autoPrint")))))
(DTypeSig true "driveOutputsNow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EntryOutcome") (TyCon "DriveOutputs"))))
(DFunDef false "driveOutputsNow" ((PVar "mctx") (PVar "outcome")) (ERecordCreate "DriveOutputs" ((fa "doManifestRequests" (EListLit)) (fa "doManifests" (EListLit)) (fa "doServedModules" (ELit (LInt 0))) (fa "doEntryOutcome" (EVar "outcome")) (fa "doHadTypeErrors" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (fa "doHadMatchWarnings" (EApp (EVar "not") (EApp (EVar "isEmpty") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")))) (fa "doInvocationView" (EApp (EVar "frozenInvocationView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value"))) (fa "doGrantsEnabled" (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value"))) (fa "doEffectDomains" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "effectDomains") "value")) (fa "doStickyDiags" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (fa "doIfaceExports" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deMethods") "meIfaceExports")) (fa "doFfiAliases" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deData") "deAliases")) (fa "doOrdIndex" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deOrdIndex")) (fa "doEffvarNext" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "effvarCounter") "value")))))
(DTypeSig true "printlnIface" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "IfaceRef"))))
(DFunDef false "printlnIface" ((PList)) (EVar "None"))
(DFunDef false "printlnIface" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "printlnIface") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "printlnIface" ((PCons (PCon "DTypeSig" PWild (PLit (LString "println")) (PCon "TyConstrained" (PList (PVar "c")) PWild) PWild) PWild)) (EApp (EVar "Some") (ERecordCreate "IfaceRef" ((fa "irName" (EFieldAccess (EVar "c") "constraintHead")) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))))
(DFunDef false "printlnIface" ((PCons PWild (PVar "rest"))) (EApp (EVar "printlnIface") (EVar "rest")))
(DTypeSig true "mainBodySpan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodySpan" ((PList)) (EVar "None"))
(DFunDef false "mainBodySpan" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainBodySpan") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainBodySpan" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") (PVar "site") PWild) PWild)) (EMatch (EVar "body") (arm (PCon "ELoc" (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EApp (EVar "Some") (EVar "site")))))
(DFunDef false "mainBodySpan" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainBodySpan") (EVar "rest")))
(DTypeSig true "mainUseDiags" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "mainUseDiags" ((PCon "None") PWild) (EListLit))
(DFunDef false "mainUseDiags" ((PCon "Some" (PVar "site")) (PVar "entry")) (EMatch (EApp (EApp (EVar "mainUseSite") (EVar "site")) (EVar "entry")) (arm (PCon "Some" (PVar "at")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MAIN-USED"))) (ELit (LInt 1))) (EApp (EVar "Some") (EVar "at"))) (EVar "mainUsedMsg")) (EVar "None")) (EVar "None")))) (arm (PCon "None") () (EListLit))))
# MARK
(DUse false (UseGroup ("types" "invocation_basis") ((mem "frozenInvocationView" false))))
(DUse false (UseGroup ("types" "value_main") ((mem "mainUseSite" false) (mem "mainUsedMsg" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Ty" true) (mem "Loc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "ModuleCtx" true) (mem "DriveOutputs" true) (mem "InvocationView" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" true) (mem "TcDiag" true))))
(DTypeSig false "mainHead" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "mainHead" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "mainHead") (EVar "a"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "mainHead") (EVar "a"))) (arm (PVar "other") () (EVar "other"))))
(DTypeSig true "mainIsAsyncNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainIsAsyncNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "mainHead") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Async")) (PCon "OriginModule" (PLit (LString "async")))) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "mainAsyncPayloadIsUnitNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainAsyncPayloadIsUnitNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" PWild (PVar "payload")) () (EMatch (EApp (EVar "normalize") (EVar "payload")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "mainIsUnitNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Unit") (TyCon "Bool")))))
(DFunDef false "mainIsUnitNow" ((PVar "gctx") (PVar "hasObligations") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (EVar "True")) (arm (PCon "TVar" PWild) () (EApp (EVar "not") (EVar "hasObligations"))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "mainIsFloatNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "mainIsFloatNow" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EVar "gctx") "mainSchemeRef") "value") (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "entryOutcomeNow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "EntryOutcome")))))
(DFunDef false "entryOutcomeNow" ((PVar "mctx") (PVar "hasObligations") (PVar "autoPrint")) (ERecordCreate "EntryOutcome" ((fa "eoMainIsUnit" (EApp (EApp (EApp (EVar "mainIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "hasObligations")) (ELit LUnit))) (fa "eoMainIsFloat" (EApp (EApp (EVar "mainIsFloatNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoMainIsAsync" (EApp (EApp (EVar "mainIsAsyncNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoMainAsyncPayloadIsUnit" (EApp (EApp (EVar "mainAsyncPayloadIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (fa "eoAutoPrint" (EVar "autoPrint")))))
(DTypeSig true "driveOutputsNow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EntryOutcome") (TyCon "DriveOutputs"))))
(DFunDef false "driveOutputsNow" ((PVar "mctx") (PVar "outcome")) (ERecordCreate "DriveOutputs" ((fa "doManifestRequests" (EListLit)) (fa "doManifests" (EListLit)) (fa "doServedModules" (ELit (LInt 0))) (fa "doEntryOutcome" (EVar "outcome")) (fa "doHadTypeErrors" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (fa "doHadMatchWarnings" (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")))) (fa "doInvocationView" (EApp (EVar "frozenInvocationView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value"))) (fa "doGrantsEnabled" (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value"))) (fa "doEffectDomains" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "effectDomains") "value")) (fa "doStickyDiags" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (fa "doIfaceExports" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deMethods") "meIfaceExports")) (fa "doFfiAliases" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deData") "deAliases")) (fa "doOrdIndex" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deOrdIndex")) (fa "doEffvarNext" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "effvarCounter") "value")))))
(DTypeSig true "printlnIface" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "IfaceRef"))))
(DFunDef false "printlnIface" ((PList)) (EVar "None"))
(DFunDef false "printlnIface" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "printlnIface") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "printlnIface" ((PCons (PCon "DTypeSig" PWild (PLit (LString "println")) (PCon "TyConstrained" (PList (PVar "c")) PWild) PWild) PWild)) (EApp (EVar "Some") (ERecordCreate "IfaceRef" ((fa "irName" (EFieldAccess (EVar "c") "constraintHead")) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))))
(DFunDef false "printlnIface" ((PCons PWild (PVar "rest"))) (EApp (EVar "printlnIface") (EVar "rest")))
(DTypeSig true "mainBodySpan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodySpan" ((PList)) (EVar "None"))
(DFunDef false "mainBodySpan" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainBodySpan") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainBodySpan" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") (PVar "site") PWild) PWild)) (EMatch (EVar "body") (arm (PCon "ELoc" (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EApp (EVar "Some") (EVar "site")))))
(DFunDef false "mainBodySpan" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainBodySpan") (EVar "rest")))
(DTypeSig true "mainUseDiags" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "mainUseDiags" ((PCon "None") PWild) (EListLit))
(DFunDef false "mainUseDiags" ((PCon "Some" (PVar "site")) (PVar "entry")) (EMatch (EApp (EApp (EVar "mainUseSite") (EVar "site")) (EVar "entry")) (arm (PCon "Some" (PVar "at")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MAIN-USED"))) (ELit (LInt 1))) (EApp (EVar "Some") (EVar "at"))) (EVar "mainUsedMsg")) (EVar "None")) (EVar "None")))) (arm (PCon "None") () (EListLit))))
