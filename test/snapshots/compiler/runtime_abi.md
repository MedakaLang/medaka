# META
source_lines=76
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Decl(..), ExternDecl(..), Ty(..)}
import types.runtime_abi_types.{CallableShape(..)}
import types.runtime_abi_data.{runtimeAbiRows}
import types.runtime_grants.{runtimePathCount}
import types.repr.{ppTy}
import support.ordmap.{OrdMap, omEmpty, omFromPairs, omLookup}
import support.util.{listLen, escStr, joinWith}

export
runtimeAbiIndex : OrdMap CallableShape
runtimeAbiIndex = omFromPairs runtimeAbiRows omEmpty

export
runtimeAbi : String -> Option CallableShape
runtimeAbi name = omLookup name runtimeAbiIndex

export
signatureHeads : Ty -> (List String, String)
signatureHeads (TyConstrained _ t) = signatureHeads t
signatureHeads (TyEffect _ _ t) = signatureHeads t
signatureHeads (TyNamed _ t _) = signatureHeads t
signatureHeads (TyQual t _ _) = signatureHeads t
signatureHeads (TyFun arg rest) =
  let (args, ret) = signatureHeads rest
  (signatureHead arg :: args, ret)
signatureHeads t = ([], signatureHead t)

signatureHead : Ty -> String
signatureHead (TyCon { tyConName = name }) = name
signatureHead (TyVar name) = name
signatureHead (TyApp f _) = signatureHead f
signatureHead (TyConstrained _ t) = signatureHead t
signatureHead (TyEffect _ _ t) = signatureHead t
signatureHead (TyNamed _ t _) = signatureHead t
signatureHead (TyQual t _ _) = signatureHead t
signatureHead _ = ""

export
sourceShape : Ty -> CallableShape
sourceShape ty =
  let (params, ret) = signatureHeads ty
  let arity = listLen params
  CallableShape {
    writtenValueArity = arity,
    loweredCoreArity = arity,
    parameterHeads = params,
    resultHead = ret,
    canonicalSignature = "v1:" ++ ppTy ty,
  }

export
runtimeRowsFromSource : List Decl -> List (String, CallableShape)
runtimeRowsFromSource [] = []
runtimeRowsFromSource ((DExtern ed) :: rest) =
  let shape = sourceShape ed.edTy
  (
      ed.edName,
      { shape |
        loweredCoreArity = shape.writtenValueArity + runtimePathCount ed.edName,
      },
    )
    :: runtimeRowsFromSource rest
runtimeRowsFromSource ((DAttrib _ inner) :: rest) =
  runtimeRowsFromSource (inner :: rest)
runtimeRowsFromSource (_ :: rest) = runtimeRowsFromSource rest

export
renderRuntimeAbi : List (String, CallableShape) -> String
renderRuntimeAbi rows =
  "import types.runtime_abi_types.{CallableShape(..)}\n\nexport\nruntimeAbiRows : List (String, CallableShape)\nruntimeAbiRows = [\n"
    ++ joinWith "" (map renderRow rows)
    ++ "]\n"

renderRow : (String, CallableShape) -> String
renderRow (name, s) =
  "  (\{escStr name}, CallableShape { writtenValueArity = \{intToString s.writtenValueArity}, loweredCoreArity = \{intToString s.loweredCoreArity}, parameterHeads = [\{joinWith ", " (map escStr s.parameterHeads)}], resultHead = \{escStr s.resultHead}, canonicalSignature = \{escStr s.canonicalSignature} }),\n"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "runtimePathCount" false))))
(DUse false (UseGroup ("types" "repr") ((mem "ppTy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "escStr" false) (mem "joinWith" false))))
(DTypeSig true "runtimeAbiIndex" (TyApp (TyCon "OrdMap") (TyCon "CallableShape")))
(DFunDef false "runtimeAbiIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "runtimeAbiRows")) (EVar "omEmpty")))
(DTypeSig true "runtimeAbi" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CallableShape"))))
(DFunDef false "runtimeAbi" ((PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "runtimeAbiIndex")))
(DTypeSig true "signatureHeads" (TyFun (TyCon "Ty") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "signatureHeads" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyFun" (PVar "arg") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "args") (PVar "ret")) (EApp (EVar "signatureHeads") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "signatureHead") (EVar "arg")) (EVar "args")) (EVar "ret")))))
(DFunDef false "signatureHeads" ((PVar "t")) (ETuple (EListLit) (EApp (EVar "signatureHead") (EVar "t"))))
(DTypeSig false "signatureHead" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "signatureHead" ((PRec "TyCon" ((rf "tyConName" (PVar "name"))) false)) (EVar "name"))
(DFunDef false "signatureHead" ((PCon "TyVar" (PVar "name"))) (EVar "name"))
(DFunDef false "signatureHead" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "signatureHead") (EVar "f")))
(DFunDef false "signatureHead" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" (PWild) (ELit (LString "")))
(DTypeSig true "sourceShape" (TyFun (TyCon "Ty") (TyCon "CallableShape")))
(DFunDef false "sourceShape" ((PVar "ty")) (EBlock (DoLet false false (PTuple (PVar "params") (PVar "ret")) (EApp (EVar "signatureHeads") (EVar "ty"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "params"))) (DoExpr (ERecordCreate "CallableShape" ((fa "writtenValueArity" (EVar "arity")) (fa "loweredCoreArity" (EVar "arity")) (fa "parameterHeads" (EVar "params")) (fa "resultHead" (EVar "ret")) (fa "canonicalSignature" (EBinOp "++" (ELit (LString "v1:")) (EApp (EVar "ppTy") (EVar "ty")))))))))
(DTypeSig true "runtimeRowsFromSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape")))))
(DFunDef false "runtimeRowsFromSource" ((PList)) (EListLit))
(DFunDef false "runtimeRowsFromSource" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBlock (DoLet false false (PVar "shape") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))) (DoExpr (EBinOp "::" (ETuple (EFieldAccess (EVar "ed") "edName") (ERecordUpdate (EVar "shape") ((fa "loweredCoreArity" (EBinOp "+" (EFieldAccess (EVar "shape") "writtenValueArity") (EApp (EVar "runtimePathCount") (EFieldAccess (EVar "ed") "edName"))))))) (EApp (EVar "runtimeRowsFromSource") (EVar "rest"))))))
(DFunDef false "runtimeRowsFromSource" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "runtimeRowsFromSource") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "runtimeRowsFromSource" ((PCons PWild (PVar "rest"))) (EApp (EVar "runtimeRowsFromSource") (EVar "rest")))
(DTypeSig true "renderRuntimeAbi" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape"))) (TyCon "String")))
(DFunDef false "renderRuntimeAbi" ((PVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "import types.runtime_abi_types.{CallableShape(..)}\n\nexport\nruntimeAbiRows : List (String, CallableShape)\nruntimeAbiRows = [\n")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "renderRow")) (EVar "rows")))) (ELit (LString "]\n"))))
(DTypeSig false "renderRow" (TyFun (TyTuple (TyCon "String") (TyCon "CallableShape")) (TyCon "String")))
(DFunDef false "renderRow" ((PTuple (PVar "name") (PVar "s"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "name")))) (ELit (LString ", CallableShape { writtenValueArity = "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "s") "writtenValueArity")))) (ELit (LString ", loweredCoreArity = "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "s") "loweredCoreArity")))) (ELit (LString ", parameterHeads = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "escStr")) (EFieldAccess (EVar "s") "parameterHeads"))))) (ELit (LString "], resultHead = "))) (EApp (EVar "display") (EApp (EVar "escStr") (EFieldAccess (EVar "s") "resultHead")))) (ELit (LString ", canonicalSignature = "))) (EApp (EVar "display") (EApp (EVar "escStr") (EFieldAccess (EVar "s") "canonicalSignature")))) (ELit (LString " }),\n"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("types" "runtime_abi_data") ((mem "runtimeAbiRows" false))))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "runtimePathCount" false))))
(DUse false (UseGroup ("types" "repr") ((mem "ppTy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "escStr" false) (mem "joinWith" false))))
(DTypeSig true "runtimeAbiIndex" (TyApp (TyCon "OrdMap") (TyCon "CallableShape")))
(DFunDef false "runtimeAbiIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "runtimeAbiRows")) (EVar "omEmpty")))
(DTypeSig true "runtimeAbi" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CallableShape"))))
(DFunDef false "runtimeAbi" ((PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "runtimeAbiIndex")))
(DTypeSig true "signatureHeads" (TyFun (TyCon "Ty") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "signatureHeads" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "signatureHeads") (EVar "t")))
(DFunDef false "signatureHeads" ((PCon "TyFun" (PVar "arg") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "args") (PVar "ret")) (EApp (EVar "signatureHeads") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "signatureHead") (EVar "arg")) (EVar "args")) (EVar "ret")))))
(DFunDef false "signatureHeads" ((PVar "t")) (ETuple (EListLit) (EApp (EVar "signatureHead") (EVar "t"))))
(DTypeSig false "signatureHead" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "signatureHead" ((PRec "TyCon" ((rf "tyConName" (PVar "name"))) false)) (EVar "name"))
(DFunDef false "signatureHead" ((PCon "TyVar" (PVar "name"))) (EVar "name"))
(DFunDef false "signatureHead" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "signatureHead") (EVar "f")))
(DFunDef false "signatureHead" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "signatureHead") (EVar "t")))
(DFunDef false "signatureHead" (PWild) (ELit (LString "")))
(DTypeSig true "sourceShape" (TyFun (TyCon "Ty") (TyCon "CallableShape")))
(DFunDef false "sourceShape" ((PVar "ty")) (EBlock (DoLet false false (PTuple (PVar "params") (PVar "ret")) (EApp (EVar "signatureHeads") (EVar "ty"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "params"))) (DoExpr (ERecordCreate "CallableShape" ((fa "writtenValueArity" (EVar "arity")) (fa "loweredCoreArity" (EVar "arity")) (fa "parameterHeads" (EVar "params")) (fa "resultHead" (EVar "ret")) (fa "canonicalSignature" (EBinOp "++" (ELit (LString "v1:")) (EApp (EVar "ppTy") (EVar "ty")))))))))
(DTypeSig true "runtimeRowsFromSource" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape")))))
(DFunDef false "runtimeRowsFromSource" ((PList)) (EListLit))
(DFunDef false "runtimeRowsFromSource" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBlock (DoLet false false (PVar "shape") (EApp (EVar "sourceShape") (EFieldAccess (EVar "ed") "edTy"))) (DoExpr (EBinOp "::" (ETuple (EFieldAccess (EVar "ed") "edName") (ERecordUpdate (EVar "shape") ((fa "loweredCoreArity" (EBinOp "+" (EFieldAccess (EVar "shape") "writtenValueArity") (EApp (EVar "runtimePathCount") (EFieldAccess (EVar "ed") "edName"))))))) (EApp (EVar "runtimeRowsFromSource") (EVar "rest"))))))
(DFunDef false "runtimeRowsFromSource" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "runtimeRowsFromSource") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "runtimeRowsFromSource" ((PCons PWild (PVar "rest"))) (EApp (EVar "runtimeRowsFromSource") (EVar "rest")))
(DTypeSig true "renderRuntimeAbi" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CallableShape"))) (TyCon "String")))
(DFunDef false "renderRuntimeAbi" ((PVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "import types.runtime_abi_types.{CallableShape(..)}\n\nexport\nruntimeAbiRows : List (String, CallableShape)\nruntimeAbiRows = [\n")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "renderRow")) (EVar "rows")))) (ELit (LString "]\n"))))
(DTypeSig false "renderRow" (TyFun (TyTuple (TyCon "String") (TyCon "CallableShape")) (TyCon "String")))
(DFunDef false "renderRow" ((PTuple (PVar "name") (PVar "s"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "name")))) (ELit (LString ", CallableShape { writtenValueArity = "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "s") "writtenValueArity")))) (ELit (LString ", loweredCoreArity = "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "s") "loweredCoreArity")))) (ELit (LString ", parameterHeads = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EFieldAccess (EVar "s") "parameterHeads"))))) (ELit (LString "], resultHead = "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EFieldAccess (EVar "s") "resultHead")))) (ELit (LString ", canonicalSignature = "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EFieldAccess (EVar "s") "canonicalSignature")))) (ELit (LString " }),\n"))))
