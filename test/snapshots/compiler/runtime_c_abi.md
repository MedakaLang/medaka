# META
source_lines=62
stages=DESUGAR,MARK
# SOURCE
import backend.llvm_preamble.{RuntimeDecl(..)}
import support.util.{startsWith, contains}

public export data AbiType =
  | AbiWord
  | AbiInt32
  | AbiPointer
  | AbiDouble
  | AbiVoid
  deriving (Eq, Debug)

public export data RuntimeAbiRow = RuntimeAbiRow {
  name : String,
  result : AbiType,
  parameters : List AbiType,
  noReturn : Bool,
} deriving (Eq, Debug)

abiType : String -> Result String AbiType
abiType "i64" = Ok AbiWord
abiType "i32" = Ok AbiInt32
abiType "ptr" = Ok AbiPointer
abiType "double" = Ok AbiDouble
abiType "void" = Ok AbiVoid
abiType t = Err ("unknown ABI type: " ++ t)

parameterTypes : List String -> Result String (List AbiType)
parameterTypes [] = Ok []
parameterTypes (t :: ts) = match abiType t
  Err e => Err e
  Ok AbiVoid => Err "void parameter"
  Ok ty => map (ty :: _) (parameterTypes ts)

intrinsic : String -> Bool
intrinsic name = contains name [
  "llvm.sadd.with.overflow.i64",
  "llvm.ssub.with.overflow.i64",
  "llvm.smul.with.overflow.i64",
  "llvm.fptosi.sat.i64.f64",
  "llvm.arithmetic.fence.f64",
]

export
runtimeAbiRows : List RuntimeDecl -> Result String (List RuntimeAbiRow)
runtimeAbiRows [] = Ok []
runtimeAbiRows ((RuntimeDecl _ ret name params attrs) :: rest) =
  if intrinsic name then
    runtimeAbiRows rest
  else if startsWith "llvm." name then
    Err ("unclassified intrinsic: " ++ name)
  else match abiType ret
    Err e => Err "\{name}: \{e}"
    Ok result => match parameterTypes params
      Err e => Err "\{name}: \{e}"
      Ok parameters =>
        let row = RuntimeAbiRow {
          name = name,
          result = result,
          parameters = parameters,
          noReturn = attrs == " noreturn",
        }
        map (row :: _) (runtimeAbiRows rest)
# DESUGAR
(DUse false (UseGroup ("backend" "llvm_preamble") ((mem "RuntimeDecl" true))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false) (mem "contains" false))))
(DData Public "AbiType" () ((variant "AbiWord" (ConPos)) (variant "AbiInt32" (ConPos)) (variant "AbiPointer" (ConPos)) (variant "AbiDouble" (ConPos)) (variant "AbiVoid" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbiType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AbiWord") (PCon "AbiWord")) () (EVar "True")) (arm (PTuple (PCon "AbiInt32") (PCon "AbiInt32")) () (EVar "True")) (arm (PTuple (PCon "AbiPointer") (PCon "AbiPointer")) () (EVar "True")) (arm (PTuple (PCon "AbiDouble") (PCon "AbiDouble")) () (EVar "True")) (arm (PTuple (PCon "AbiVoid") (PCon "AbiVoid")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AbiWord") () (ELit (LString "AbiWord"))) (arm (PCon "AbiInt32") () (ELit (LString "AbiInt32"))) (arm (PCon "AbiPointer") () (ELit (LString "AbiPointer"))) (arm (PCon "AbiDouble") () (ELit (LString "AbiDouble"))) (arm (PCon "AbiVoid") () (ELit (LString "AbiVoid")))))))
(DData Public "RuntimeAbiRow" () ((variant "RuntimeAbiRow" (ConNamed (field "name" (TyCon "String")) (field "result" (TyCon "AbiType")) (field "parameters" (TyApp (TyCon "List") (TyCon "AbiType"))) (field "noReturn" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeAbiRow")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) (PRec "RuntimeAbiRow" ((rf "name" (PVar "__b0")) (rf "result" (PVar "__b1")) (rf "parameters" (PVar "__b2")) (rf "noReturn" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "RuntimeAbiRow")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeAbiRow {")) (ELit (LString " name = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", result = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", parameters = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", noReturn = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig false "abiType" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "AbiType"))))
(DFunDef false "abiType" ((PLit (LString "i64"))) (EApp (EVar "Ok") (EVar "AbiWord")))
(DFunDef false "abiType" ((PLit (LString "i32"))) (EApp (EVar "Ok") (EVar "AbiInt32")))
(DFunDef false "abiType" ((PLit (LString "ptr"))) (EApp (EVar "Ok") (EVar "AbiPointer")))
(DFunDef false "abiType" ((PLit (LString "double"))) (EApp (EVar "Ok") (EVar "AbiDouble")))
(DFunDef false "abiType" ((PLit (LString "void"))) (EApp (EVar "Ok") (EVar "AbiVoid")))
(DFunDef false "abiType" ((PVar "t")) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "unknown ABI type: ")) (EVar "t"))))
(DTypeSig false "parameterTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "AbiType")))))
(DFunDef false "parameterTypes" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parameterTypes" ((PCons (PVar "t") (PVar "ts"))) (EMatch (EApp (EVar "abiType") (EVar "t")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "AbiVoid")) () (EApp (EVar "Err") (ELit (LString "void parameter")))) (arm (PCon "Ok" (PVar "ty")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "ty") (EVar "_s")))) (EApp (EVar "parameterTypes") (EVar "ts"))))))
(DTypeSig false "intrinsic" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "intrinsic" ((PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EListLit (ELit (LString "llvm.sadd.with.overflow.i64")) (ELit (LString "llvm.ssub.with.overflow.i64")) (ELit (LString "llvm.smul.with.overflow.i64")) (ELit (LString "llvm.fptosi.sat.i64.f64")) (ELit (LString "llvm.arithmetic.fence.f64")))))
(DTypeSig true "runtimeAbiRows" (TyFun (TyApp (TyCon "List") (TyCon "RuntimeDecl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RuntimeAbiRow")))))
(DFunDef false "runtimeAbiRows" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "runtimeAbiRows" ((PCons (PCon "RuntimeDecl" PWild (PVar "ret") (PVar "name") (PVar "params") (PVar "attrs")) (PVar "rest"))) (EIf (EApp (EVar "intrinsic") (EVar "name")) (EApp (EVar "runtimeAbiRows") (EVar "rest")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "llvm."))) (EVar "name")) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "unclassified intrinsic: ")) (EVar "name"))) (EMatch (EApp (EVar "abiType") (EVar "ret")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "result")) () (EMatch (EApp (EVar "parameterTypes") (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "parameters")) () (EBlock (DoLet false false (PVar "row") (ERecordCreate "RuntimeAbiRow" ((fa "name" (EVar "name")) (fa "result" (EVar "result")) (fa "parameters" (EVar "parameters")) (fa "noReturn" (EBinOp "==" (EVar "attrs") (ELit (LString " noreturn"))))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "row") (EVar "_s")))) (EApp (EVar "runtimeAbiRows") (EVar "rest"))))))))))))
# MARK
(DUse false (UseGroup ("backend" "llvm_preamble") ((mem "RuntimeDecl" true))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false) (mem "contains" false))))
(DData Public "AbiType" () ((variant "AbiWord" (ConPos)) (variant "AbiInt32" (ConPos)) (variant "AbiPointer" (ConPos)) (variant "AbiDouble" (ConPos)) (variant "AbiVoid" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbiType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AbiWord") (PCon "AbiWord")) () (EVar "True")) (arm (PTuple (PCon "AbiInt32") (PCon "AbiInt32")) () (EVar "True")) (arm (PTuple (PCon "AbiPointer") (PCon "AbiPointer")) () (EVar "True")) (arm (PTuple (PCon "AbiDouble") (PCon "AbiDouble")) () (EVar "True")) (arm (PTuple (PCon "AbiVoid") (PCon "AbiVoid")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AbiWord") () (ELit (LString "AbiWord"))) (arm (PCon "AbiInt32") () (ELit (LString "AbiInt32"))) (arm (PCon "AbiPointer") () (ELit (LString "AbiPointer"))) (arm (PCon "AbiDouble") () (ELit (LString "AbiDouble"))) (arm (PCon "AbiVoid") () (ELit (LString "AbiVoid")))))))
(DData Public "RuntimeAbiRow" () ((variant "RuntimeAbiRow" (ConNamed (field "name" (TyCon "String")) (field "result" (TyCon "AbiType")) (field "parameters" (TyApp (TyCon "List") (TyCon "AbiType"))) (field "noReturn" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeAbiRow")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) (PRec "RuntimeAbiRow" ((rf "name" (PVar "__b0")) (rf "result" (PVar "__b1")) (rf "parameters" (PVar "__b2")) (rf "noReturn" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "RuntimeAbiRow")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeAbiRow {")) (ELit (LString " name = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", result = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", parameters = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", noReturn = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig false "abiType" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "AbiType"))))
(DFunDef false "abiType" ((PLit (LString "i64"))) (EApp (EVar "Ok") (EVar "AbiWord")))
(DFunDef false "abiType" ((PLit (LString "i32"))) (EApp (EVar "Ok") (EVar "AbiInt32")))
(DFunDef false "abiType" ((PLit (LString "ptr"))) (EApp (EVar "Ok") (EVar "AbiPointer")))
(DFunDef false "abiType" ((PLit (LString "double"))) (EApp (EVar "Ok") (EVar "AbiDouble")))
(DFunDef false "abiType" ((PLit (LString "void"))) (EApp (EVar "Ok") (EVar "AbiVoid")))
(DFunDef false "abiType" ((PVar "t")) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "unknown ABI type: ")) (EVar "t"))))
(DTypeSig false "parameterTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "AbiType")))))
(DFunDef false "parameterTypes" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parameterTypes" ((PCons (PVar "t") (PVar "ts"))) (EMatch (EApp (EVar "abiType") (EVar "t")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PCon "AbiVoid")) () (EApp (EVar "Err") (ELit (LString "void parameter")))) (arm (PCon "Ok" (PVar "ty")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "ty") (EVar "_s")))) (EApp (EVar "parameterTypes") (EVar "ts"))))))
(DTypeSig false "intrinsic" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "intrinsic" ((PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EListLit (ELit (LString "llvm.sadd.with.overflow.i64")) (ELit (LString "llvm.ssub.with.overflow.i64")) (ELit (LString "llvm.smul.with.overflow.i64")) (ELit (LString "llvm.fptosi.sat.i64.f64")) (ELit (LString "llvm.arithmetic.fence.f64")))))
(DTypeSig true "runtimeAbiRows" (TyFun (TyApp (TyCon "List") (TyCon "RuntimeDecl")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RuntimeAbiRow")))))
(DFunDef false "runtimeAbiRows" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "runtimeAbiRows" ((PCons (PCon "RuntimeDecl" PWild (PVar "ret") (PVar "name") (PVar "params") (PVar "attrs")) (PVar "rest"))) (EIf (EApp (EVar "intrinsic") (EVar "name")) (EApp (EVar "runtimeAbiRows") (EVar "rest")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "llvm."))) (EVar "name")) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "unclassified intrinsic: ")) (EVar "name"))) (EMatch (EApp (EVar "abiType") (EVar "ret")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "result")) () (EMatch (EApp (EVar "parameterTypes") (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "parameters")) () (EBlock (DoLet false false (PVar "row") (ERecordCreate "RuntimeAbiRow" ((fa "name" (EVar "name")) (fa "result" (EVar "result")) (fa "parameters" (EVar "parameters")) (fa "noReturn" (EBinOp "==" (EVar "attrs") (ELit (LString " noreturn"))))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "row") (EVar "_s")))) (EApp (EVar "runtimeAbiRows") (EVar "rest"))))))))))))
