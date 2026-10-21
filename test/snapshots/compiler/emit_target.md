# META
source_lines=20
stages=DESUGAR,MARK
# SOURCE
import types.target_profile.{TargetProfile}
import types.target_profile as TP

-- A column of the extern catalog: the two emitters, and the interpreter that
-- `medaka run` evaluates with.
public export data Backend = LlvmBackend | WasmBackend | EvalBackend

export
backendName : Backend -> String
backendName LlvmBackend = "llvm"
backendName WasmBackend = "wasm"
backendName EvalBackend = "eval"

-- The column a profile's programs run on.
export
profileColumn : TargetProfile -> Backend
profileColumn p = match TP.profileBackend p
  TP.BackendLlvm => LlvmBackend
  TP.BackendWasmgc => WasmBackend
  TP.BackendEval => EvalBackend
# DESUGAR
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false))))
(DUse false (UseAlias ("types" "target_profile") "TP"))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos)) (variant "EvalBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DFunDef false "backendName" ((PCon "EvalBackend")) (ELit (LString "eval")))
(DTypeSig true "profileColumn" (TyFun (TyCon "TargetProfile") (TyCon "Backend")))
(DFunDef false "profileColumn" ((PVar "p")) (EMatch (EApp (EVar "TP.profileBackend") (EVar "p")) (arm (PCon "TP.BackendLlvm") () (EVar "LlvmBackend")) (arm (PCon "TP.BackendWasmgc") () (EVar "WasmBackend")) (arm (PCon "TP.BackendEval") () (EVar "EvalBackend"))))
# MARK
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false))))
(DUse false (UseAlias ("types" "target_profile") "TP"))
(DData Public "Backend" () ((variant "LlvmBackend" (ConPos)) (variant "WasmBackend" (ConPos)) (variant "EvalBackend" (ConPos))) ())
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "LlvmBackend")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "WasmBackend")) (ELit (LString "wasm")))
(DFunDef false "backendName" ((PCon "EvalBackend")) (ELit (LString "eval")))
(DTypeSig true "profileColumn" (TyFun (TyCon "TargetProfile") (TyCon "Backend")))
(DFunDef false "profileColumn" ((PVar "p")) (EMatch (EApp (EVar "TP.profileBackend") (EVar "p")) (arm (PCon "TP.BackendLlvm") () (EVar "LlvmBackend")) (arm (PCon "TP.BackendWasmgc") () (EVar "WasmBackend")) (arm (PCon "TP.BackendEval") () (EVar "EvalBackend"))))
