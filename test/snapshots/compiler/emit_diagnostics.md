# META
source_lines=37
stages=DESUGAR,MARK
# SOURCE
import driver.diagnostics.{
  CheckJson(..),
  Diag,
  emitDiagExitCode,
  llvmSymbolDefectDiags,
  ppDiagCliLines,
  readFileSafe,
  srcLinesArr,
  symbolDefectDiags,
}
import driver.front_gate.{diagJsonPathOfEnv, writeDiagJson}
import backend.wasm_symbols.{SymbolDefect}
import backend.llvm_symbols as LlvmSymbols
import support.stage_count.{stageExit}

export
refuseSymbolDefects : String -> List SymbolDefect -> <IO> Unit
refuseSymbolDefects file ds = refusePhysical (symbolDefectDiags file ds)

export
refuseLlvmSymbolDefects : String -> List LlvmSymbols.SymbolDefect -> <IO> Unit
refuseLlvmSymbolDefects file ds = refusePhysical (llvmSymbolDefectDiags file ds)

refusePhysical : List (String, Diag) -> <IO> Unit
refusePhysical diags =
  let _ = match diagJsonPathOfEnv ()
    Some path =>
      let triples = map ((at, diag) => (at, readFileSafe at, [diag])) diags
      writeDiagJson path (CjParts "" triples)
    None =>
      let _ =
        map
          ((at, diag) =>
            ePutStrLn (ppDiagCliLines (srcLinesArr (readFileSafe at)) at diag))
          diags
      ()
  stageExit emitDiagExitCode
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "CheckJson" true) (mem "Diag" false) (mem "emitDiagExitCode" false) (mem "llvmSymbolDefectDiags" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false) (mem "symbolDefectDiags" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "diagJsonPathOfEnv" false) (mem "writeDiagJson" false))))
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "SymbolDefect" false))))
(DUse false (UseAlias ("backend" "llvm_symbols") "LlvmSymbols"))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DTypeSig true "refuseSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "symbolDefectDiags") (EVar "file")) (EVar "ds"))))
(DTypeSig true "refuseLlvmSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LlvmSymbols.SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseLlvmSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "llvmSymbolDefectDiags") (EVar "file")) (EVar "ds"))))
(DTypeSig false "refusePhysical" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "refusePhysical" ((PVar "diags")) (EBlock (DoLet false false PWild (EMatch (EApp (EVar "diagJsonPathOfEnv") (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (ETuple (EVar "at") (EApp (EVar "readFileSafe") (EVar "at")) (EListLit (EVar "diag"))))) (EVar "diags"))) (DoExpr (EApp (EApp (EVar "writeDiagJson") (EVar "path")) (EApp (EApp (EVar "CjParts") (ELit (LString ""))) (EVar "triples")))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "at")))) (EVar "at")) (EVar "diag"))))) (EVar "diags"))) (DoExpr (ELit LUnit)))))) (DoExpr (EApp (EVar "stageExit") (EVar "emitDiagExitCode")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "CheckJson" true) (mem "Diag" false) (mem "emitDiagExitCode" false) (mem "llvmSymbolDefectDiags" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false) (mem "symbolDefectDiags" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "diagJsonPathOfEnv" false) (mem "writeDiagJson" false))))
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "SymbolDefect" false))))
(DUse false (UseAlias ("backend" "llvm_symbols") "LlvmSymbols"))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DTypeSig true "refuseSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "symbolDefectDiags") (EVar "file")) (EVar "ds"))))
(DTypeSig true "refuseLlvmSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LlvmSymbols.SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseLlvmSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "llvmSymbolDefectDiags") (EVar "file")) (EVar "ds"))))
(DTypeSig false "refusePhysical" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "refusePhysical" ((PVar "diags")) (EBlock (DoLet false false PWild (EMatch (EApp (EVar "diagJsonPathOfEnv") (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (ETuple (EVar "at") (EApp (EVar "readFileSafe") (EVar "at")) (EListLit (EVar "diag"))))) (EVar "diags"))) (DoExpr (EApp (EApp (EVar "writeDiagJson") (EVar "path")) (EApp (EApp (EVar "CjParts") (ELit (LString ""))) (EVar "triples")))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "at")))) (EVar "at")) (EVar "diag"))))) (EVar "diags"))) (DoExpr (ELit LUnit)))))) (DoExpr (EApp (EVar "stageExit") (EVar "emitDiagExitCode")))))
