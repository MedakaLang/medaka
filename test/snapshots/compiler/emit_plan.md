# META
source_lines=37
stages=DESUGAR,MARK
# SOURCE
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import ir.core_ir.{CProgram(..)}
import backend.core_validate.{Backend(..), backendName}
import support.ordmap.{OrdMap}
import backend.emit_support.{eagerReachMap, lazyGlobalNames}

-- `target` is the backend the plan was built for; the emitter asserts it is its own.
-- `lazyGlobals` are the value globals emitted as forced-on-first-use cells.
-- `eagerReach` maps each binding to the value globals it eagerly reaches; the
-- value-global init order is sorted by it.
public export data EmitPlan = EmitPlan {
  target : Backend,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
}

export
buildEmitPlan : Backend -> CProgram -> EmitPlan
buildEmitPlan target (CProgram groups _ _ _ _ _) = EmitPlan {
  target = target,
  lazyGlobals = lazyGlobalNames groups,
  eagerReach = eagerReachMap groups,
}

-- The backend a plan was built for, asserted to be the calling emitter's own: a
-- plan built for the other backend would pick the wrong dict-tag width.
export
planBackendFor : Backend -> EmitPlan -> Backend
planBackendFor expected plan =
  if backendName plan.target == backendName expected then
    plan.target
  else
    panic
      "internal error: emit plan was built for the \{backendName plan.target} backend but the \{backendName expected} emitter received it"
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild PWild)) (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))))))
(DTypeSig true "planBackendFor" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyCon "Backend"))))
(DFunDef false "planBackendFor" ((PVar "expected") (PVar "plan")) (EIf (EBinOp "==" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "expected"))) (EFieldAccess (EVar "plan") "target") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "expected")))) (ELit (LString " emitter received it"))))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild PWild)) (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))))))
(DTypeSig true "planBackendFor" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyCon "Backend"))))
(DFunDef false "planBackendFor" ((PVar "expected") (PVar "plan")) (EIf (EBinOp "==" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "expected"))) (EFieldAccess (EVar "plan") "target") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "expected")))) (ELit (LString " emitter received it"))))))
