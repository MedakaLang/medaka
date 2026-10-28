# META
source_lines=30
stages=DESUGAR,MARK
# SOURCE
-- Where an emitter wrote or used a physical symbol, and how a symbol defect
-- names that place.  Both emitters' symbol registries (backend/wasm_symbols.mdk,
-- backend/llvm_symbols.mdk) report their defects at a `SymbolOrigin`, and the
-- emit driver (driver/diagnostics.mdk) locates the diagnostic from it.

-- The source binding whose emission wrote or used the symbol, and that binding's
-- file, line and column ("" and 0 when it has none).  File and position are
-- independent absences and render differently: "" means the emit driver's own
-- file, and 0 means a placeholder span, which `placeOf` still prints as
-- `file:0:0` when a file is known.  One Option would merge those two.
public export data SymbolOrigin =
  SymbolOrigin String String Int Int
  deriving (Eq, Debug)

-- The file, line and column of [origin] ("" and 0 when it has none).
export
originPosition : SymbolOrigin -> (String, Int, Int)
originPosition (SymbolOrigin _ file line col) = (file, line, col)

-- The binding of [origin], quoted, as a defect message opens with it.
export
bindingOf : SymbolOrigin -> String
bindingOf (SymbolOrigin b _ _ _) = "`\{b}`"

-- The binding of [origin], quoted, with its position when it has one.
export
placeOf : SymbolOrigin -> String
placeOf (SymbolOrigin b "" _ _) = "`\{b}`"
placeOf (SymbolOrigin b file line col) =
  "`\{b}` (\{file}:\{intToString line}:\{intToString col})"
# DESUGAR
(DData Public "SymbolOrigin" () ((variant "SymbolOrigin" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "SymbolOrigin" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SymbolOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))))))))
(DTypeSig true "originPosition" (TyFun (TyCon "SymbolOrigin") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "originPosition" ((PCon "SymbolOrigin" PWild (PVar "file") (PVar "line") (PVar "col"))) (ETuple (EVar "file") (EVar "line") (EVar "col")))
(DTypeSig true "bindingOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "bindingOf" ((PCon "SymbolOrigin" (PVar "b") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DTypeSig true "placeOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PLit (LString "")) PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PVar "file") (PVar "line") (PVar "col"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "` ("))) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ")"))))
# MARK
(DData Public "SymbolOrigin" () ((variant "SymbolOrigin" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "SymbolOrigin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "SymbolOrigin" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "SymbolOrigin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SymbolOrigin" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SymbolOrigin ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))))))))
(DTypeSig true "originPosition" (TyFun (TyCon "SymbolOrigin") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "originPosition" ((PCon "SymbolOrigin" PWild (PVar "file") (PVar "line") (PVar "col"))) (ETuple (EVar "file") (EVar "line") (EVar "col")))
(DTypeSig true "bindingOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "bindingOf" ((PCon "SymbolOrigin" (PVar "b") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DTypeSig true "placeOf" (TyFun (TyCon "SymbolOrigin") (TyCon "String")))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PLit (LString "")) PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "placeOf" ((PCon "SymbolOrigin" (PVar "b") (PVar "file") (PVar "line") (PVar "col"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "` ("))) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ")"))))
