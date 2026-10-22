# META
source_lines=68
stages=DESUGAR,MARK
# SOURCE
-- The checked main-shape facts published at the end of a typecheck drive.

import frontend.ast.{EvId, TyConOrigin(..)}
import types.repr.{Mono(..), Scheme(..), normalize}
import types.tc_types.{GraphCtx(..), ModuleCtx(..)}
import types.publish.{EntryOutcome(..)}

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "ModuleCtx" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" true))))
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
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Scheme" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "ModuleCtx" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" true))))
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
