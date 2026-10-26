# META
source_lines=22
stages=DESUGAR,MARK
# SOURCE
public export data WasmRepr = WBoxEq | WInt63 | WBool64 | WUnit64

public export data WasmValue = WasmValue WasmRepr (List String)

public export data LocalSlot = LocalSlot Int WasmRepr

export
valueRepr : WasmValue -> WasmRepr
valueRepr (WasmValue repr _) = repr

export
valueLines : WasmValue -> List String
valueLines (WasmValue _ lines) = lines

export
slotIndex : LocalSlot -> Int
slotIndex (LocalSlot index _) = index

export
physicalType : WasmRepr -> String
physicalType WBoxEq = "(ref eq)"
physicalType _ = "i64"
# DESUGAR
(DData Public "WasmRepr" () ((variant "WBoxEq" (ConPos)) (variant "WInt63" (ConPos)) (variant "WBool64" (ConPos)) (variant "WUnit64" (ConPos))) ())
(DData Public "WasmValue" () ((variant "WasmValue" (ConPos (TyCon "WasmRepr") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "LocalSlot" () ((variant "LocalSlot" (ConPos (TyCon "Int") (TyCon "WasmRepr")))) ())
(DTypeSig true "valueRepr" (TyFun (TyCon "WasmValue") (TyCon "WasmRepr")))
(DFunDef false "valueRepr" ((PCon "WasmValue" (PVar "repr") PWild)) (EVar "repr"))
(DTypeSig true "valueLines" (TyFun (TyCon "WasmValue") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueLines" ((PCon "WasmValue" PWild (PVar "lines"))) (EVar "lines"))
(DTypeSig true "slotIndex" (TyFun (TyCon "LocalSlot") (TyCon "Int")))
(DFunDef false "slotIndex" ((PCon "LocalSlot" (PVar "index") PWild)) (EVar "index"))
(DTypeSig true "physicalType" (TyFun (TyCon "WasmRepr") (TyCon "String")))
(DFunDef false "physicalType" ((PCon "WBoxEq")) (ELit (LString "(ref eq)")))
(DFunDef false "physicalType" (PWild) (ELit (LString "i64")))
# MARK
(DData Public "WasmRepr" () ((variant "WBoxEq" (ConPos)) (variant "WInt63" (ConPos)) (variant "WBool64" (ConPos)) (variant "WUnit64" (ConPos))) ())
(DData Public "WasmValue" () ((variant "WasmValue" (ConPos (TyCon "WasmRepr") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "LocalSlot" () ((variant "LocalSlot" (ConPos (TyCon "Int") (TyCon "WasmRepr")))) ())
(DTypeSig true "valueRepr" (TyFun (TyCon "WasmValue") (TyCon "WasmRepr")))
(DFunDef false "valueRepr" ((PCon "WasmValue" (PVar "repr") PWild)) (EVar "repr"))
(DTypeSig true "valueLines" (TyFun (TyCon "WasmValue") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueLines" ((PCon "WasmValue" PWild (PVar "lines"))) (EVar "lines"))
(DTypeSig true "slotIndex" (TyFun (TyCon "LocalSlot") (TyCon "Int")))
(DFunDef false "slotIndex" ((PCon "LocalSlot" (PVar "index") PWild)) (EMethodRef "index"))
(DTypeSig true "physicalType" (TyFun (TyCon "WasmRepr") (TyCon "String")))
(DFunDef false "physicalType" ((PCon "WBoxEq")) (ELit (LString "(ref eq)")))
(DFunDef false "physicalType" (PWild) (ELit (LString "i64")))
