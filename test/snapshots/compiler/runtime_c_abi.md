# META
source_lines=74
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

public export data AbiError =
  | UnknownAbiType String String
  | VoidAbiParameter String
  | UnclassifiedIntrinsic String
  deriving (Eq, Debug, Display)

export
renderAbiError : AbiError -> String
renderAbiError (UnknownAbiType name ty) = "\{name}: unknown ABI type: \{ty}"
renderAbiError (VoidAbiParameter name) = "\{name}: void parameter"
renderAbiError (UnclassifiedIntrinsic name) = "unclassified intrinsic: " ++ name

abiType : String -> String -> Result AbiError AbiType
abiType _ "i64" = Ok AbiWord
abiType _ "i32" = Ok AbiInt32
abiType _ "ptr" = Ok AbiPointer
abiType _ "double" = Ok AbiDouble
abiType _ "void" = Ok AbiVoid
abiType name ty = Err (UnknownAbiType name ty)

parameterTypes : String -> List String -> Result AbiError (List AbiType)
parameterTypes _ [] = Ok []
parameterTypes name (t :: ts) = do
  ty <- abiType name t
  if ty == AbiVoid then
    Err (VoidAbiParameter name)
  else
    map (ty :: _) (parameterTypes name ts)

intrinsic : String -> Bool
intrinsic name = contains name [
  "llvm.sadd.with.overflow.i64",
  "llvm.ssub.with.overflow.i64",
  "llvm.smul.with.overflow.i64",
  "llvm.fptosi.sat.i64.f64",
  "llvm.arithmetic.fence.f64",
]

export
runtimeAbiRows : List RuntimeDecl -> Result AbiError (List RuntimeAbiRow)
runtimeAbiRows [] = Ok []
runtimeAbiRows ((RuntimeDecl _ ret name params attrs) :: rest) =
  if intrinsic name then
    runtimeAbiRows rest
  else if startsWith "llvm." name then
    Err (UnclassifiedIntrinsic name)
  else do
    result <- abiType name ret
    parameters <- parameterTypes name params
    let row = RuntimeAbiRow {
      name = name,
      result = result,
      parameters = parameters,
      noReturn = attrs == " noreturn",
    }
    map (row :: _) (runtimeAbiRows rest)
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("backend" "llvm_preamble") ((mem "RuntimeDecl" true))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false) (mem "contains" false))))
(DData Public "AbiType" () ((variant "AbiWord" (ConPos)) (variant "AbiInt32" (ConPos)) (variant "AbiPointer" (ConPos)) (variant "AbiDouble" (ConPos)) (variant "AbiVoid" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbiType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AbiWord") (PCon "AbiWord")) () (EVar "True")) (arm (PTuple (PCon "AbiInt32") (PCon "AbiInt32")) () (EVar "True")) (arm (PTuple (PCon "AbiPointer") (PCon "AbiPointer")) () (EVar "True")) (arm (PTuple (PCon "AbiDouble") (PCon "AbiDouble")) () (EVar "True")) (arm (PTuple (PCon "AbiVoid") (PCon "AbiVoid")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AbiWord") () (ELit (LString "AbiWord"))) (arm (PCon "AbiInt32") () (ELit (LString "AbiInt32"))) (arm (PCon "AbiPointer") () (ELit (LString "AbiPointer"))) (arm (PCon "AbiDouble") () (ELit (LString "AbiDouble"))) (arm (PCon "AbiVoid") () (ELit (LString "AbiVoid")))))))
(DData Public "RuntimeAbiRow" () ((variant "RuntimeAbiRow" (ConNamed (field "name" (TyCon "String")) (field "result" (TyCon "AbiType")) (field "parameters" (TyApp (TyCon "List") (TyCon "AbiType"))) (field "noReturn" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeAbiRow")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) (PRec "RuntimeAbiRow" ((rf "name" (PVar "__b0")) (rf "result" (PVar "__b1")) (rf "parameters" (PVar "__b2")) (rf "noReturn" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "$core.eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "RuntimeAbiRow")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeAbiRow {")) (ELit (LString " name = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", result = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString ", parameters = "))) (EApp (EVar "$core.debug") (EVar "__a2"))) (ELit (LString ", noReturn = "))) (EApp (EVar "$core.debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "AbiError" () ((variant "UnknownAbiType" (ConPos (TyCon "String") (TyCon "String"))) (variant "VoidAbiParameter" (ConPos (TyCon "String"))) (variant "UnclassifiedIntrinsic" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "AbiError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) (PCon "UnknownAbiType" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "VoidAbiParameter" (PVar "__a0")) (PCon "VoidAbiParameter" (PVar "__b0"))) () (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnclassifiedIntrinsic" (PVar "__a0")) (PCon "UnclassifiedIntrinsic" (PVar "__b0"))) () (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UnknownAbiType ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1"))))) (arm (PCon "VoidAbiParameter" (PVar "__a0")) () (EBinOp "++" (ELit (LString "VoidAbiParameter ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0"))))) (arm (PCon "UnclassifiedIntrinsic" (PVar "__a0")) () (EBinOp "++" (ELit (LString "UnclassifiedIntrinsic ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "AbiError")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UnknownAbiType ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a1"))))) (arm (PCon "VoidAbiParameter" (PVar "__a0")) () (EBinOp "++" (ELit (LString "VoidAbiParameter ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a0"))))) (arm (PCon "UnclassifiedIntrinsic" (PVar "__a0")) () (EBinOp "++" (ELit (LString "UnclassifiedIntrinsic ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.display") (EVar "__a0")))))))))
(DTypeSig true "renderAbiError" (TyFun (TyCon "AbiError") (TyCon "String")))
(DFunDef false "renderAbiError" ((PCon "UnknownAbiType" (PVar "name") (PVar "ty"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString ": unknown ABI type: "))) (EApp (EVar "$core.display") (EVar "ty"))) (ELit (LString ""))))
(DFunDef false "renderAbiError" ((PCon "VoidAbiParameter" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString ": void parameter"))))
(DFunDef false "renderAbiError" ((PCon "UnclassifiedIntrinsic" (PVar "name"))) (EBinOp "++" (ELit (LString "unclassified intrinsic: ")) (EVar "name")))
(DTypeSig false "abiType" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyCon "AbiType")))))
(DFunDef false "abiType" (PWild (PLit (LString "i64"))) (EApp (EVar "Ok") (EVar "AbiWord")))
(DFunDef false "abiType" (PWild (PLit (LString "i32"))) (EApp (EVar "Ok") (EVar "AbiInt32")))
(DFunDef false "abiType" (PWild (PLit (LString "ptr"))) (EApp (EVar "Ok") (EVar "AbiPointer")))
(DFunDef false "abiType" (PWild (PLit (LString "double"))) (EApp (EVar "Ok") (EVar "AbiDouble")))
(DFunDef false "abiType" (PWild (PLit (LString "void"))) (EApp (EVar "Ok") (EVar "AbiVoid")))
(DFunDef false "abiType" ((PVar "name") (PVar "ty")) (EApp (EVar "Err") (EApp (EApp (EVar "UnknownAbiType") (EVar "name")) (EVar "ty"))))
(DTypeSig false "parameterTypes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyApp (TyCon "List") (TyCon "AbiType"))))))
(DFunDef false "parameterTypes" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parameterTypes" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "abiType") (EVar "name")) (EVar "t"))) (ELam ((PVar "ty")) (EIf (EBinOp "==" (EVar "ty") (EVar "AbiVoid")) (EApp (EVar "Err") (EApp (EVar "VoidAbiParameter") (EVar "name"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "ty") (EVar "_s")))) (EApp (EApp (EVar "parameterTypes") (EVar "name")) (EVar "ts")))))))
(DTypeSig false "intrinsic" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "intrinsic" ((PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EListLit (ELit (LString "llvm.sadd.with.overflow.i64")) (ELit (LString "llvm.ssub.with.overflow.i64")) (ELit (LString "llvm.smul.with.overflow.i64")) (ELit (LString "llvm.fptosi.sat.i64.f64")) (ELit (LString "llvm.arithmetic.fence.f64")))))
(DTypeSig true "runtimeAbiRows" (TyFun (TyApp (TyCon "List") (TyCon "RuntimeDecl")) (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyApp (TyCon "List") (TyCon "RuntimeAbiRow")))))
(DFunDef false "runtimeAbiRows" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "runtimeAbiRows" ((PCons (PCon "RuntimeDecl" PWild (PVar "ret") (PVar "name") (PVar "params") (PVar "attrs")) (PVar "rest"))) (EIf (EApp (EVar "intrinsic") (EVar "name")) (EApp (EVar "runtimeAbiRows") (EVar "rest")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "llvm."))) (EVar "name")) (EApp (EVar "Err") (EApp (EVar "UnclassifiedIntrinsic") (EVar "name"))) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "abiType") (EVar "name")) (EVar "ret"))) (ELam ((PVar "result")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "parameterTypes") (EVar "name")) (EVar "params"))) (ELam ((PVar "parameters")) (ELet false (PVar "row") (ERecordCreate "RuntimeAbiRow" ((fa "name" (EVar "name")) (fa "result" (EVar "result")) (fa "parameters" (EVar "parameters")) (fa "noReturn" (EBinOp "==" (EVar "attrs") (ELit (LString " noreturn")))))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "row") (EVar "_s")))) (EApp (EVar "runtimeAbiRows") (EVar "rest")))))))))))
# MARK
(DUse false (UseGroup ("backend" "llvm_preamble") ((mem "RuntimeDecl" true))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false) (mem "contains" false))))
(DData Public "AbiType" () ((variant "AbiWord" (ConPos)) (variant "AbiInt32" (ConPos)) (variant "AbiPointer" (ConPos)) (variant "AbiDouble" (ConPos)) (variant "AbiVoid" (ConPos))) ())
(DImpl true "Eq" ((TyCon "AbiType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AbiWord") (PCon "AbiWord")) () (EVar "True")) (arm (PTuple (PCon "AbiInt32") (PCon "AbiInt32")) () (EVar "True")) (arm (PTuple (PCon "AbiPointer") (PCon "AbiPointer")) () (EVar "True")) (arm (PTuple (PCon "AbiDouble") (PCon "AbiDouble")) () (EVar "True")) (arm (PTuple (PCon "AbiVoid") (PCon "AbiVoid")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AbiWord") () (ELit (LString "AbiWord"))) (arm (PCon "AbiInt32") () (ELit (LString "AbiInt32"))) (arm (PCon "AbiPointer") () (ELit (LString "AbiPointer"))) (arm (PCon "AbiDouble") () (ELit (LString "AbiDouble"))) (arm (PCon "AbiVoid") () (ELit (LString "AbiVoid")))))))
(DData Public "RuntimeAbiRow" () ((variant "RuntimeAbiRow" (ConNamed (field "name" (TyCon "String")) (field "result" (TyCon "AbiType")) (field "parameters" (TyApp (TyCon "List") (TyCon "AbiType"))) (field "noReturn" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeAbiRow")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) (PRec "RuntimeAbiRow" ((rf "name" (PVar "__b0")) (rf "result" (PVar "__b1")) (rf "parameters" (PVar "__b2")) (rf "noReturn" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "RuntimeAbiRow")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeAbiRow" ((rf "name" (PVar "__a0")) (rf "result" (PVar "__a1")) (rf "parameters" (PVar "__a2")) (rf "noReturn" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeAbiRow {")) (ELit (LString " name = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", result = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", parameters = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", noReturn = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "AbiError" () ((variant "UnknownAbiType" (ConPos (TyCon "String") (TyCon "String"))) (variant "VoidAbiParameter" (ConPos (TyCon "String"))) (variant "UnclassifiedIntrinsic" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "AbiError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) (PCon "UnknownAbiType" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "VoidAbiParameter" (PVar "__a0")) (PCon "VoidAbiParameter" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnclassifiedIntrinsic" (PVar "__a0")) (PCon "UnclassifiedIntrinsic" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "AbiError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UnknownAbiType ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "VoidAbiParameter" (PVar "__a0")) () (EBinOp "++" (ELit (LString "VoidAbiParameter ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "UnclassifiedIntrinsic" (PVar "__a0")) () (EBinOp "++" (ELit (LString "UnclassifiedIntrinsic ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "AbiError")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnknownAbiType" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "UnknownAbiType ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1"))))) (arm (PCon "VoidAbiParameter" (PVar "__a0")) () (EBinOp "++" (ELit (LString "VoidAbiParameter ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "UnclassifiedIntrinsic" (PVar "__a0")) () (EBinOp "++" (ELit (LString "UnclassifiedIntrinsic ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))))))))
(DTypeSig true "renderAbiError" (TyFun (TyCon "AbiError") (TyCon "String")))
(DFunDef false "renderAbiError" ((PCon "UnknownAbiType" (PVar "name") (PVar "ty"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": unknown ABI type: "))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ""))))
(DFunDef false "renderAbiError" ((PCon "VoidAbiParameter" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": void parameter"))))
(DFunDef false "renderAbiError" ((PCon "UnclassifiedIntrinsic" (PVar "name"))) (EBinOp "++" (ELit (LString "unclassified intrinsic: ")) (EVar "name")))
(DTypeSig false "abiType" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyCon "AbiType")))))
(DFunDef false "abiType" (PWild (PLit (LString "i64"))) (EApp (EVar "Ok") (EVar "AbiWord")))
(DFunDef false "abiType" (PWild (PLit (LString "i32"))) (EApp (EVar "Ok") (EVar "AbiInt32")))
(DFunDef false "abiType" (PWild (PLit (LString "ptr"))) (EApp (EVar "Ok") (EVar "AbiPointer")))
(DFunDef false "abiType" (PWild (PLit (LString "double"))) (EApp (EVar "Ok") (EVar "AbiDouble")))
(DFunDef false "abiType" (PWild (PLit (LString "void"))) (EApp (EVar "Ok") (EVar "AbiVoid")))
(DFunDef false "abiType" ((PVar "name") (PVar "ty")) (EApp (EVar "Err") (EApp (EApp (EVar "UnknownAbiType") (EVar "name")) (EVar "ty"))))
(DTypeSig false "parameterTypes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyApp (TyCon "List") (TyCon "AbiType"))))))
(DFunDef false "parameterTypes" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parameterTypes" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "abiType") (EVar "name")) (EVar "t"))) (ELam ((PVar "ty")) (EIf (EBinOp "==" (EVar "ty") (EVar "AbiVoid")) (EApp (EVar "Err") (EApp (EVar "VoidAbiParameter") (EVar "name"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "ty") (EVar "_s")))) (EApp (EApp (EVar "parameterTypes") (EVar "name")) (EVar "ts")))))))
(DTypeSig false "intrinsic" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "intrinsic" ((PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EListLit (ELit (LString "llvm.sadd.with.overflow.i64")) (ELit (LString "llvm.ssub.with.overflow.i64")) (ELit (LString "llvm.smul.with.overflow.i64")) (ELit (LString "llvm.fptosi.sat.i64.f64")) (ELit (LString "llvm.arithmetic.fence.f64")))))
(DTypeSig true "runtimeAbiRows" (TyFun (TyApp (TyCon "List") (TyCon "RuntimeDecl")) (TyApp (TyApp (TyCon "Result") (TyCon "AbiError")) (TyApp (TyCon "List") (TyCon "RuntimeAbiRow")))))
(DFunDef false "runtimeAbiRows" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "runtimeAbiRows" ((PCons (PCon "RuntimeDecl" PWild (PVar "ret") (PVar "name") (PVar "params") (PVar "attrs")) (PVar "rest"))) (EIf (EApp (EVar "intrinsic") (EVar "name")) (EApp (EVar "runtimeAbiRows") (EVar "rest")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "llvm."))) (EVar "name")) (EApp (EVar "Err") (EApp (EVar "UnclassifiedIntrinsic") (EVar "name"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "abiType") (EVar "name")) (EVar "ret"))) (ELam ((PVar "result")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parameterTypes") (EVar "name")) (EVar "params"))) (ELam ((PVar "parameters")) (ELet false (PVar "row") (ERecordCreate "RuntimeAbiRow" ((fa "name" (EVar "name")) (fa "result" (EVar "result")) (fa "parameters" (EVar "parameters")) (fa "noReturn" (EBinOp "==" (EVar "attrs") (ELit (LString " noreturn")))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "row") (EVar "_s")))) (EApp (EVar "runtimeAbiRows") (EVar "rest")))))))))))
