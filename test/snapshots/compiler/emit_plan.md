# META
source_lines=26
stages=DESUGAR,MARK
# SOURCE
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import ir.core_ir.{CProgram(..)}
import ir.core_ir_lower.{EmitTarget(..)}
import support.ordmap.{OrdMap}
import backend.emit_support.{eagerReachMap, lazyGlobalNames}

-- `target` is the lowering's own discriminator, carried as-is.
-- `lazyGlobals` are the value globals emitted as forced-on-first-use cells.
-- `eagerReach` maps each binding to the value globals it eagerly reaches; the
-- value-global init order is sorted by it.
public export data EmitPlan = EmitPlan {
  target : EmitTarget,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
}

export
buildEmitPlan : EmitTarget -> CProgram -> EmitPlan
buildEmitPlan target (CProgram groups _ _ _ _ _) = EmitPlan {
  target = target,
  lazyGlobals = lazyGlobalNames groups,
  eagerReach = eagerReachMap groups,
}
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "EmitTarget" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "EmitTarget")) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "EmitTarget") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild PWild)) (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "EmitTarget" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "EmitTarget")) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "EmitTarget") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PCon "CProgram" (PVar "groups") PWild PWild PWild PWild PWild)) (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))))))
