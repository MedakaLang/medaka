# META
source_lines=35
stages=DESUGAR,MARK
# SOURCE
import support.ordmap.{OrdMap, omEmpty, omFromPairs}
import types.runtime_abi_data.{runtimeAbiRows}
import types.runtime_abi_types.{CallableShape(..)}

export
runtimePathCount : String -> Int
runtimePathCount "rename" = 2
runtimePathCount "readFile" = 1
runtimePathCount "readFileBytes" = 1
runtimePathCount "hashFile" = 1
runtimePathCount "writeFile" = 1
runtimePathCount "writeFileBytes" = 1
runtimePathCount "writeFileMode" = 1
runtimePathCount "appendFile" = 1
runtimePathCount "fileExists" = 1
runtimePathCount "fileMode" = 1
runtimePathCount "canonicalizePath" = 1
runtimePathCount "listDir" = 1
runtimePathCount "makeDir" = 1
runtimePathCount "removeFile" = 1
runtimePathCount "fsync" = 1
runtimePathCount "removeDir" = 1
runtimePathCount "statFile" = 1
runtimePathCount _ = 0

export
fileGrantExterns : OrdMap (Int, Int)
fileGrantExterns =
  omFromPairs
    (flatMap
      ((name, shape) =>
        let paths = runtimePathCount name
        if paths == 0 then [] else [(name, (shape.writtenValueArity, paths))])
      runtimeAbiRows)
    omEmpty
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DTypeSig true "runtimePathCount" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "runtimePathCount" ((PLit (LString "rename"))) (ELit (LInt 2)))
(DFunDef false "runtimePathCount" ((PLit (LString "readFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "readFileBytes"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "hashFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFileBytes"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFileMode"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "appendFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fileExists"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fileMode"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "canonicalizePath"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "listDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "makeDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "removeFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fsync"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "removeDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "statFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "fileGrantExterns" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fileGrantExterns" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "name") (PVar "shape"))) (EBlock (DoLet false false (PVar "paths") (EApp (EVar "runtimePathCount") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "paths") (ELit (LInt 0))) (EListLit) (EListLit (ETuple (EVar "name") (ETuple (EFieldAccess (EVar "shape") "writtenValueArity") (EVar "paths"))))))))) (EVar "runtimeAbiRows"))) (EVar "omEmpty")))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DTypeSig true "runtimePathCount" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "runtimePathCount" ((PLit (LString "rename"))) (ELit (LInt 2)))
(DFunDef false "runtimePathCount" ((PLit (LString "readFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "readFileBytes"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "hashFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFileBytes"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "writeFileMode"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "appendFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fileExists"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fileMode"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "canonicalizePath"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "listDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "makeDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "removeFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "fsync"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "removeDir"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" ((PLit (LString "statFile"))) (ELit (LInt 1)))
(DFunDef false "runtimePathCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "fileGrantExterns" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fileGrantExterns" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "name") (PVar "shape"))) (EBlock (DoLet false false (PVar "paths") (EApp (EVar "runtimePathCount") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "paths") (ELit (LInt 0))) (EListLit) (EListLit (ETuple (EVar "name") (ETuple (EFieldAccess (EVar "shape") "writtenValueArity") (EVar "paths"))))))))) (EVar "runtimeAbiRows"))) (EVar "omEmpty")))
