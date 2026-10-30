# META
source_lines=68
stages=DESUGAR,MARK
# SOURCE
import support.symbol_encoding.{encodeComponent}

public export data GeneratedFamily =
  | GenString
  | GenTrap
  | GenLambda
  | GenMethodValue
  | GenDictValue
  | GenNamedPap
  | GenIndirectPap
  | GenDictCell
  | GenCtorCell
  | GenEta
  | GenCtorPap
  | GenCtorEta
  | GenExternEta
  | GenU64
  | GenI64
  | GenGlobalName

public export data LlvmName =
  | LUserFunction String
  | LUserGlobal String
  | LGlobalState String
  | LGlobalForcer String
  | LRawWorker String
  | LFloatWorker String
  | LImplMethod String String
  | LDefaultMethod String String String
  | LDispatcher String String Int Int Int
  | LConstructor String
  | LGeneratedName GeneratedFamily String String Int

familyTag : GeneratedFamily -> String
familyTag GenString = "string"
familyTag GenTrap = "trap"
familyTag GenLambda = "lambda"
familyTag GenMethodValue = "methodvalue"
familyTag GenDictValue = "dictvalue"
familyTag GenNamedPap = "namedpap"
familyTag GenIndirectPap = "indirectpap"
familyTag GenDictCell = "dictcell"
familyTag GenCtorCell = "ctorcell"
familyTag GenEta = "eta"
familyTag GenCtorPap = "ctorpap"
familyTag GenCtorEta = "ctoreta"
familyTag GenExternEta = "externeta"
familyTag GenU64 = "u64"
familyTag GenI64 = "i64"
familyTag GenGlobalName = "globalname"

export
llvmName : LlvmName -> String
llvmName (LUserFunction name) = "mdk.user." ++ encodeComponent name
llvmName (LUserGlobal name) = "mdk.global." ++ encodeComponent name
llvmName (LGlobalState name) = "mdk.state." ++ encodeComponent name
llvmName (LGlobalForcer name) = "mdk.force." ++ encodeComponent name
llvmName (LRawWorker name) = "mdk.worker.raw." ++ encodeComponent name
llvmName (LFloatWorker name) = "mdk.worker.float." ++ encodeComponent name
llvmName (LImplMethod tag method) =
  "mdk.impl.\{encodeComponent tag}.\{encodeComponent method}"
llvmName (LDefaultMethod iface method key) =
  "mdk.default.\{encodeComponent iface}.\{encodeComponent method}.\{encodeComponent key}"
llvmName (LDispatcher iface method dicts args arity) =
  "mdk.dispatch.\{encodeComponent iface}.\{encodeComponent method}.\{intToString dicts}.\{intToString args}.\{intToString arity}"
llvmName (LConstructor name) = "mdk.ctor." ++ encodeComponent name
llvmName (LGeneratedName family scope subject ordinal) =
  "mdk.gen.\{familyTag family}.\{encodeComponent scope}.\{encodeComponent subject}.\{intToString ordinal}"
# DESUGAR
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DData Public "GeneratedFamily" () ((variant "GenString" (ConPos)) (variant "GenTrap" (ConPos)) (variant "GenLambda" (ConPos)) (variant "GenMethodValue" (ConPos)) (variant "GenDictValue" (ConPos)) (variant "GenNamedPap" (ConPos)) (variant "GenIndirectPap" (ConPos)) (variant "GenDictCell" (ConPos)) (variant "GenCtorCell" (ConPos)) (variant "GenEta" (ConPos)) (variant "GenCtorPap" (ConPos)) (variant "GenCtorEta" (ConPos)) (variant "GenExternEta" (ConPos)) (variant "GenU64" (ConPos)) (variant "GenI64" (ConPos)) (variant "GenGlobalName" (ConPos))) ())
(DData Public "LlvmName" () ((variant "LUserFunction" (ConPos (TyCon "String"))) (variant "LUserGlobal" (ConPos (TyCon "String"))) (variant "LGlobalState" (ConPos (TyCon "String"))) (variant "LGlobalForcer" (ConPos (TyCon "String"))) (variant "LRawWorker" (ConPos (TyCon "String"))) (variant "LFloatWorker" (ConPos (TyCon "String"))) (variant "LImplMethod" (ConPos (TyCon "String") (TyCon "String"))) (variant "LDefaultMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "LDispatcher" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "LConstructor" (ConPos (TyCon "String"))) (variant "LGeneratedName" (ConPos (TyCon "GeneratedFamily") (TyCon "String") (TyCon "String") (TyCon "Int")))) ())
(DTypeSig false "familyTag" (TyFun (TyCon "GeneratedFamily") (TyCon "String")))
(DFunDef false "familyTag" ((PCon "GenString")) (ELit (LString "string")))
(DFunDef false "familyTag" ((PCon "GenTrap")) (ELit (LString "trap")))
(DFunDef false "familyTag" ((PCon "GenLambda")) (ELit (LString "lambda")))
(DFunDef false "familyTag" ((PCon "GenMethodValue")) (ELit (LString "methodvalue")))
(DFunDef false "familyTag" ((PCon "GenDictValue")) (ELit (LString "dictvalue")))
(DFunDef false "familyTag" ((PCon "GenNamedPap")) (ELit (LString "namedpap")))
(DFunDef false "familyTag" ((PCon "GenIndirectPap")) (ELit (LString "indirectpap")))
(DFunDef false "familyTag" ((PCon "GenDictCell")) (ELit (LString "dictcell")))
(DFunDef false "familyTag" ((PCon "GenCtorCell")) (ELit (LString "ctorcell")))
(DFunDef false "familyTag" ((PCon "GenEta")) (ELit (LString "eta")))
(DFunDef false "familyTag" ((PCon "GenCtorPap")) (ELit (LString "ctorpap")))
(DFunDef false "familyTag" ((PCon "GenCtorEta")) (ELit (LString "ctoreta")))
(DFunDef false "familyTag" ((PCon "GenExternEta")) (ELit (LString "externeta")))
(DFunDef false "familyTag" ((PCon "GenU64")) (ELit (LString "u64")))
(DFunDef false "familyTag" ((PCon "GenI64")) (ELit (LString "i64")))
(DFunDef false "familyTag" ((PCon "GenGlobalName")) (ELit (LString "globalname")))
(DTypeSig true "llvmName" (TyFun (TyCon "LlvmName") (TyCon "String")))
(DFunDef false "llvmName" ((PCon "LUserFunction" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LUserGlobal" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.global.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGlobalState" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.state.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGlobalForcer" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.force.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LRawWorker" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.worker.raw.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LFloatWorker" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.worker.float.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LImplMethod" (PVar "tag") (PVar "method"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.impl.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "tag")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LDefaultMethod" (PVar "iface") (PVar "method") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.default.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "key")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LDispatcher" (PVar "iface") (PVar "method") (PVar "dicts") (PVar "args") (PVar "arity"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.dispatch.")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "dicts")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "args")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "arity")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LConstructor" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.ctor.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGeneratedName" (PVar "family") (PVar "scope") (PVar "subject") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.gen.")) (EApp (EVar "display") (EApp (EVar "familyTag") (EVar "family")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "scope")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "subject")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodeComponent" false))))
(DData Public "GeneratedFamily" () ((variant "GenString" (ConPos)) (variant "GenTrap" (ConPos)) (variant "GenLambda" (ConPos)) (variant "GenMethodValue" (ConPos)) (variant "GenDictValue" (ConPos)) (variant "GenNamedPap" (ConPos)) (variant "GenIndirectPap" (ConPos)) (variant "GenDictCell" (ConPos)) (variant "GenCtorCell" (ConPos)) (variant "GenEta" (ConPos)) (variant "GenCtorPap" (ConPos)) (variant "GenCtorEta" (ConPos)) (variant "GenExternEta" (ConPos)) (variant "GenU64" (ConPos)) (variant "GenI64" (ConPos)) (variant "GenGlobalName" (ConPos))) ())
(DData Public "LlvmName" () ((variant "LUserFunction" (ConPos (TyCon "String"))) (variant "LUserGlobal" (ConPos (TyCon "String"))) (variant "LGlobalState" (ConPos (TyCon "String"))) (variant "LGlobalForcer" (ConPos (TyCon "String"))) (variant "LRawWorker" (ConPos (TyCon "String"))) (variant "LFloatWorker" (ConPos (TyCon "String"))) (variant "LImplMethod" (ConPos (TyCon "String") (TyCon "String"))) (variant "LDefaultMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "LDispatcher" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "LConstructor" (ConPos (TyCon "String"))) (variant "LGeneratedName" (ConPos (TyCon "GeneratedFamily") (TyCon "String") (TyCon "String") (TyCon "Int")))) ())
(DTypeSig false "familyTag" (TyFun (TyCon "GeneratedFamily") (TyCon "String")))
(DFunDef false "familyTag" ((PCon "GenString")) (ELit (LString "string")))
(DFunDef false "familyTag" ((PCon "GenTrap")) (ELit (LString "trap")))
(DFunDef false "familyTag" ((PCon "GenLambda")) (ELit (LString "lambda")))
(DFunDef false "familyTag" ((PCon "GenMethodValue")) (ELit (LString "methodvalue")))
(DFunDef false "familyTag" ((PCon "GenDictValue")) (ELit (LString "dictvalue")))
(DFunDef false "familyTag" ((PCon "GenNamedPap")) (ELit (LString "namedpap")))
(DFunDef false "familyTag" ((PCon "GenIndirectPap")) (ELit (LString "indirectpap")))
(DFunDef false "familyTag" ((PCon "GenDictCell")) (ELit (LString "dictcell")))
(DFunDef false "familyTag" ((PCon "GenCtorCell")) (ELit (LString "ctorcell")))
(DFunDef false "familyTag" ((PCon "GenEta")) (ELit (LString "eta")))
(DFunDef false "familyTag" ((PCon "GenCtorPap")) (ELit (LString "ctorpap")))
(DFunDef false "familyTag" ((PCon "GenCtorEta")) (ELit (LString "ctoreta")))
(DFunDef false "familyTag" ((PCon "GenExternEta")) (ELit (LString "externeta")))
(DFunDef false "familyTag" ((PCon "GenU64")) (ELit (LString "u64")))
(DFunDef false "familyTag" ((PCon "GenI64")) (ELit (LString "i64")))
(DFunDef false "familyTag" ((PCon "GenGlobalName")) (ELit (LString "globalname")))
(DTypeSig true "llvmName" (TyFun (TyCon "LlvmName") (TyCon "String")))
(DFunDef false "llvmName" ((PCon "LUserFunction" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.user.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LUserGlobal" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.global.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGlobalState" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.state.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGlobalForcer" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.force.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LRawWorker" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.worker.raw.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LFloatWorker" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.worker.float.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LImplMethod" (PVar "tag") (PVar "method"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.impl.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "tag")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LDefaultMethod" (PVar "iface") (PVar "method") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.default.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "key")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LDispatcher" (PVar "iface") (PVar "method") (PVar "dicts") (PVar "args") (PVar "arity"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.dispatch.")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "iface")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "method")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "dicts")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "args")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "arity")))) (ELit (LString ""))))
(DFunDef false "llvmName" ((PCon "LConstructor" (PVar "name"))) (EBinOp "++" (ELit (LString "mdk.ctor.")) (EApp (EVar "encodeComponent") (EVar "name"))))
(DFunDef false "llvmName" ((PCon "LGeneratedName" (PVar "family") (PVar "scope") (PVar "subject") (PVar "ordinal"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk.gen.")) (EApp (EMethodRef "display") (EApp (EVar "familyTag") (EVar "family")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "scope")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "subject")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ordinal")))) (ELit (LString ""))))
