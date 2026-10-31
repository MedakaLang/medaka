# META
source_lines=104
stages=DESUGAR,MARK
# SOURCE
public export data RuntimeOwner =
  | RuntimeList
  | RuntimeOption
  | RuntimeResult
  | RuntimeOrdering
  | RuntimeBool
  | RuntimeTuple Int
  deriving (Eq, Debug)

public export data RuntimeCtorId =
  | RuntimeCons
  | RuntimeNil
  | RuntimeSome
  | RuntimeNone
  | RuntimeOk
  | RuntimeErr
  | RuntimeLt
  | RuntimeEq
  | RuntimeGt
  | RuntimeFalse
  | RuntimeTrue
  | RuntimeTupleCtor Int
  deriving (Eq, Debug)

public export data RuntimeCtorFact = RuntimeCtorFact {
  owner : RuntimeOwner,
  ordinal : Int,
  arity : Int,
} deriving (Eq, Debug)

export
namedRuntimeCtor : String -> Option RuntimeCtorId
namedRuntimeCtor "Cons" = Some RuntimeCons
namedRuntimeCtor "Nil" = Some RuntimeNil
namedRuntimeCtor "Some" = Some RuntimeSome
namedRuntimeCtor "None" = Some RuntimeNone
namedRuntimeCtor "Ok" = Some RuntimeOk
namedRuntimeCtor "Err" = Some RuntimeErr
namedRuntimeCtor "Lt" = Some RuntimeLt
namedRuntimeCtor "Eq" = Some RuntimeEq
namedRuntimeCtor "Gt" = Some RuntimeGt
namedRuntimeCtor "False" = Some RuntimeFalse
namedRuntimeCtor "True" = Some RuntimeTrue
namedRuntimeCtor _ = None

export
runtimeCtorFact : RuntimeCtorId -> RuntimeCtorFact
runtimeCtorFact RuntimeCons =
  RuntimeCtorFact { owner = RuntimeList, ordinal = 0, arity = 2 }
runtimeCtorFact RuntimeNil =
  RuntimeCtorFact { owner = RuntimeList, ordinal = 1, arity = 0 }
runtimeCtorFact RuntimeSome =
  RuntimeCtorFact { owner = RuntimeOption, ordinal = 0, arity = 1 }
runtimeCtorFact RuntimeNone =
  RuntimeCtorFact { owner = RuntimeOption, ordinal = 1, arity = 0 }
runtimeCtorFact RuntimeOk =
  RuntimeCtorFact { owner = RuntimeResult, ordinal = 0, arity = 1 }
runtimeCtorFact RuntimeErr =
  RuntimeCtorFact { owner = RuntimeResult, ordinal = 1, arity = 1 }
runtimeCtorFact RuntimeLt =
  RuntimeCtorFact { owner = RuntimeOrdering, ordinal = 0, arity = 0 }
runtimeCtorFact RuntimeEq =
  RuntimeCtorFact { owner = RuntimeOrdering, ordinal = 1, arity = 0 }
runtimeCtorFact RuntimeGt =
  RuntimeCtorFact { owner = RuntimeOrdering, ordinal = 2, arity = 0 }
runtimeCtorFact RuntimeFalse =
  RuntimeCtorFact { owner = RuntimeBool, ordinal = 0, arity = 0 }
runtimeCtorFact RuntimeTrue =
  RuntimeCtorFact { owner = RuntimeBool, ordinal = 1, arity = 0 }
runtimeCtorFact (RuntimeTupleCtor n) =
  RuntimeCtorFact { owner = RuntimeTuple n, ordinal = 0, arity = n }

export
runtimeRoster : RuntimeOwner -> List RuntimeCtorId
runtimeRoster RuntimeList = [RuntimeCons, RuntimeNil]
runtimeRoster RuntimeOption = [RuntimeSome, RuntimeNone]
runtimeRoster RuntimeResult = [RuntimeOk, RuntimeErr]
runtimeRoster RuntimeOrdering = [RuntimeLt, RuntimeEq, RuntimeGt]
runtimeRoster RuntimeBool = [RuntimeFalse, RuntimeTrue]
runtimeRoster (RuntimeTuple n) = [RuntimeTupleCtor n]

export
runtimeCtorName : RuntimeCtorId -> Option String
runtimeCtorName RuntimeCons = Some "Cons"
runtimeCtorName RuntimeNil = Some "Nil"
runtimeCtorName RuntimeSome = Some "Some"
runtimeCtorName RuntimeNone = Some "None"
runtimeCtorName RuntimeOk = Some "Ok"
runtimeCtorName RuntimeErr = Some "Err"
runtimeCtorName RuntimeLt = Some "Lt"
runtimeCtorName RuntimeEq = Some "Eq"
runtimeCtorName RuntimeGt = Some "Gt"
runtimeCtorName RuntimeFalse = Some "False"
runtimeCtorName RuntimeTrue = Some "True"
runtimeCtorName (RuntimeTupleCtor _) = None

export
runtimeOwnerWord : RuntimeOwner -> Option String
runtimeOwnerWord RuntimeList = Some "List"
runtimeOwnerWord RuntimeOption = Some "Option"
runtimeOwnerWord RuntimeResult = Some "Result"
runtimeOwnerWord RuntimeOrdering = Some "Ordering"
runtimeOwnerWord RuntimeBool = Some "Bool"
runtimeOwnerWord (RuntimeTuple _) = None
# DESUGAR
(DData Public "RuntimeOwner" () ((variant "RuntimeList" (ConPos)) (variant "RuntimeOption" (ConPos)) (variant "RuntimeResult" (ConPos)) (variant "RuntimeOrdering" (ConPos)) (variant "RuntimeBool" (ConPos)) (variant "RuntimeTuple" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RuntimeOwner")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeList") (PCon "RuntimeList")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOption") (PCon "RuntimeOption")) () (EVar "True")) (arm (PTuple (PCon "RuntimeResult") (PCon "RuntimeResult")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOrdering") (PCon "RuntimeOrdering")) () (EVar "True")) (arm (PTuple (PCon "RuntimeBool") (PCon "RuntimeBool")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTuple" (PVar "__a0")) (PCon "RuntimeTuple" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeOwner")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeList") () (ELit (LString "RuntimeList"))) (arm (PCon "RuntimeOption") () (ELit (LString "RuntimeOption"))) (arm (PCon "RuntimeResult") () (ELit (LString "RuntimeResult"))) (arm (PCon "RuntimeOrdering") () (ELit (LString "RuntimeOrdering"))) (arm (PCon "RuntimeBool") () (ELit (LString "RuntimeBool"))) (arm (PCon "RuntimeTuple" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeTuple ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "RuntimeCtorId" () ((variant "RuntimeCons" (ConPos)) (variant "RuntimeNil" (ConPos)) (variant "RuntimeSome" (ConPos)) (variant "RuntimeNone" (ConPos)) (variant "RuntimeOk" (ConPos)) (variant "RuntimeErr" (ConPos)) (variant "RuntimeLt" (ConPos)) (variant "RuntimeEq" (ConPos)) (variant "RuntimeGt" (ConPos)) (variant "RuntimeFalse" (ConPos)) (variant "RuntimeTrue" (ConPos)) (variant "RuntimeTupleCtor" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RuntimeCtorId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeCons") (PCon "RuntimeCons")) () (EVar "True")) (arm (PTuple (PCon "RuntimeNil") (PCon "RuntimeNil")) () (EVar "True")) (arm (PTuple (PCon "RuntimeSome") (PCon "RuntimeSome")) () (EVar "True")) (arm (PTuple (PCon "RuntimeNone") (PCon "RuntimeNone")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOk") (PCon "RuntimeOk")) () (EVar "True")) (arm (PTuple (PCon "RuntimeErr") (PCon "RuntimeErr")) () (EVar "True")) (arm (PTuple (PCon "RuntimeLt") (PCon "RuntimeLt")) () (EVar "True")) (arm (PTuple (PCon "RuntimeEq") (PCon "RuntimeEq")) () (EVar "True")) (arm (PTuple (PCon "RuntimeGt") (PCon "RuntimeGt")) () (EVar "True")) (arm (PTuple (PCon "RuntimeFalse") (PCon "RuntimeFalse")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTrue") (PCon "RuntimeTrue")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTupleCtor" (PVar "__a0")) (PCon "RuntimeTupleCtor" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeCtorId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeCons") () (ELit (LString "RuntimeCons"))) (arm (PCon "RuntimeNil") () (ELit (LString "RuntimeNil"))) (arm (PCon "RuntimeSome") () (ELit (LString "RuntimeSome"))) (arm (PCon "RuntimeNone") () (ELit (LString "RuntimeNone"))) (arm (PCon "RuntimeOk") () (ELit (LString "RuntimeOk"))) (arm (PCon "RuntimeErr") () (ELit (LString "RuntimeErr"))) (arm (PCon "RuntimeLt") () (ELit (LString "RuntimeLt"))) (arm (PCon "RuntimeEq") () (ELit (LString "RuntimeEq"))) (arm (PCon "RuntimeGt") () (ELit (LString "RuntimeGt"))) (arm (PCon "RuntimeFalse") () (ELit (LString "RuntimeFalse"))) (arm (PCon "RuntimeTrue") () (ELit (LString "RuntimeTrue"))) (arm (PCon "RuntimeTupleCtor" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeTupleCtor ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "RuntimeCtorFact" () ((variant "RuntimeCtorFact" (ConNamed (field "owner" (TyCon "RuntimeOwner")) (field "ordinal" (TyCon "Int")) (field "arity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeCtorFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__a0")) (rf "ordinal" (PVar "__a1")) (rf "arity" (PVar "__a2"))) false) (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__b0")) (rf "ordinal" (PVar "__b1")) (rf "arity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "RuntimeCtorFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__a0")) (rf "ordinal" (PVar "__a1")) (rf "arity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeCtorFact {")) (ELit (LString " owner = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", ordinal = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", arity = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "namedRuntimeCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeCtorId"))))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Cons"))) (EApp (EVar "Some") (EVar "RuntimeCons")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Nil"))) (EApp (EVar "Some") (EVar "RuntimeNil")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Some"))) (EApp (EVar "Some") (EVar "RuntimeSome")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "None"))) (EApp (EVar "Some") (EVar "RuntimeNone")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Ok"))) (EApp (EVar "Some") (EVar "RuntimeOk")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Err"))) (EApp (EVar "Some") (EVar "RuntimeErr")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Lt"))) (EApp (EVar "Some") (EVar "RuntimeLt")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Eq"))) (EApp (EVar "Some") (EVar "RuntimeEq")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Gt"))) (EApp (EVar "Some") (EVar "RuntimeGt")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "False"))) (EApp (EVar "Some") (EVar "RuntimeFalse")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "True"))) (EApp (EVar "Some") (EVar "RuntimeTrue")))
(DFunDef false "namedRuntimeCtor" (PWild) (EVar "None"))
(DTypeSig true "runtimeCtorFact" (TyFun (TyCon "RuntimeCtorId") (TyCon "RuntimeCtorFact")))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeCons")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeList")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 2))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeNil")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeList")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeSome")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOption")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeNone")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOption")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeOk")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeResult")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeErr")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeResult")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeLt")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeEq")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeGt")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 2))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeFalse")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeBool")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeTrue")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeBool")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeTupleCtor" (PVar "n"))) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EApp (EVar "RuntimeTuple") (EVar "n"))) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (EVar "n")))))
(DTypeSig true "runtimeRoster" (TyFun (TyCon "RuntimeOwner") (TyApp (TyCon "List") (TyCon "RuntimeCtorId"))))
(DFunDef false "runtimeRoster" ((PCon "RuntimeList")) (EListLit (EVar "RuntimeCons") (EVar "RuntimeNil")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeOption")) (EListLit (EVar "RuntimeSome") (EVar "RuntimeNone")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeResult")) (EListLit (EVar "RuntimeOk") (EVar "RuntimeErr")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeOrdering")) (EListLit (EVar "RuntimeLt") (EVar "RuntimeEq") (EVar "RuntimeGt")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeBool")) (EListLit (EVar "RuntimeFalse") (EVar "RuntimeTrue")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeTuple" (PVar "n"))) (EListLit (EApp (EVar "RuntimeTupleCtor") (EVar "n"))))
(DTypeSig true "runtimeCtorName" (TyFun (TyCon "RuntimeCtorId") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeCons")) (EApp (EVar "Some") (ELit (LString "Cons"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeNil")) (EApp (EVar "Some") (ELit (LString "Nil"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeSome")) (EApp (EVar "Some") (ELit (LString "Some"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeNone")) (EApp (EVar "Some") (ELit (LString "None"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeOk")) (EApp (EVar "Some") (ELit (LString "Ok"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeErr")) (EApp (EVar "Some") (ELit (LString "Err"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeLt")) (EApp (EVar "Some") (ELit (LString "Lt"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeEq")) (EApp (EVar "Some") (ELit (LString "Eq"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeGt")) (EApp (EVar "Some") (ELit (LString "Gt"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeFalse")) (EApp (EVar "Some") (ELit (LString "False"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeTrue")) (EApp (EVar "Some") (ELit (LString "True"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeTupleCtor" PWild)) (EVar "None"))
(DTypeSig true "runtimeOwnerWord" (TyFun (TyCon "RuntimeOwner") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeList")) (EApp (EVar "Some") (ELit (LString "List"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeOption")) (EApp (EVar "Some") (ELit (LString "Option"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeResult")) (EApp (EVar "Some") (ELit (LString "Result"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeOrdering")) (EApp (EVar "Some") (ELit (LString "Ordering"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeBool")) (EApp (EVar "Some") (ELit (LString "Bool"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeTuple" PWild)) (EVar "None"))
# MARK
(DData Public "RuntimeOwner" () ((variant "RuntimeList" (ConPos)) (variant "RuntimeOption" (ConPos)) (variant "RuntimeResult" (ConPos)) (variant "RuntimeOrdering" (ConPos)) (variant "RuntimeBool" (ConPos)) (variant "RuntimeTuple" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RuntimeOwner")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeList") (PCon "RuntimeList")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOption") (PCon "RuntimeOption")) () (EVar "True")) (arm (PTuple (PCon "RuntimeResult") (PCon "RuntimeResult")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOrdering") (PCon "RuntimeOrdering")) () (EVar "True")) (arm (PTuple (PCon "RuntimeBool") (PCon "RuntimeBool")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTuple" (PVar "__a0")) (PCon "RuntimeTuple" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeOwner")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeList") () (ELit (LString "RuntimeList"))) (arm (PCon "RuntimeOption") () (ELit (LString "RuntimeOption"))) (arm (PCon "RuntimeResult") () (ELit (LString "RuntimeResult"))) (arm (PCon "RuntimeOrdering") () (ELit (LString "RuntimeOrdering"))) (arm (PCon "RuntimeBool") () (ELit (LString "RuntimeBool"))) (arm (PCon "RuntimeTuple" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeTuple ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "RuntimeCtorId" () ((variant "RuntimeCons" (ConPos)) (variant "RuntimeNil" (ConPos)) (variant "RuntimeSome" (ConPos)) (variant "RuntimeNone" (ConPos)) (variant "RuntimeOk" (ConPos)) (variant "RuntimeErr" (ConPos)) (variant "RuntimeLt" (ConPos)) (variant "RuntimeEq" (ConPos)) (variant "RuntimeGt" (ConPos)) (variant "RuntimeFalse" (ConPos)) (variant "RuntimeTrue" (ConPos)) (variant "RuntimeTupleCtor" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RuntimeCtorId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RuntimeCons") (PCon "RuntimeCons")) () (EVar "True")) (arm (PTuple (PCon "RuntimeNil") (PCon "RuntimeNil")) () (EVar "True")) (arm (PTuple (PCon "RuntimeSome") (PCon "RuntimeSome")) () (EVar "True")) (arm (PTuple (PCon "RuntimeNone") (PCon "RuntimeNone")) () (EVar "True")) (arm (PTuple (PCon "RuntimeOk") (PCon "RuntimeOk")) () (EVar "True")) (arm (PTuple (PCon "RuntimeErr") (PCon "RuntimeErr")) () (EVar "True")) (arm (PTuple (PCon "RuntimeLt") (PCon "RuntimeLt")) () (EVar "True")) (arm (PTuple (PCon "RuntimeEq") (PCon "RuntimeEq")) () (EVar "True")) (arm (PTuple (PCon "RuntimeGt") (PCon "RuntimeGt")) () (EVar "True")) (arm (PTuple (PCon "RuntimeFalse") (PCon "RuntimeFalse")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTrue") (PCon "RuntimeTrue")) () (EVar "True")) (arm (PTuple (PCon "RuntimeTupleCtor" (PVar "__a0")) (PCon "RuntimeTupleCtor" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeCtorId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RuntimeCons") () (ELit (LString "RuntimeCons"))) (arm (PCon "RuntimeNil") () (ELit (LString "RuntimeNil"))) (arm (PCon "RuntimeSome") () (ELit (LString "RuntimeSome"))) (arm (PCon "RuntimeNone") () (ELit (LString "RuntimeNone"))) (arm (PCon "RuntimeOk") () (ELit (LString "RuntimeOk"))) (arm (PCon "RuntimeErr") () (ELit (LString "RuntimeErr"))) (arm (PCon "RuntimeLt") () (ELit (LString "RuntimeLt"))) (arm (PCon "RuntimeEq") () (ELit (LString "RuntimeEq"))) (arm (PCon "RuntimeGt") () (ELit (LString "RuntimeGt"))) (arm (PCon "RuntimeFalse") () (ELit (LString "RuntimeFalse"))) (arm (PCon "RuntimeTrue") () (ELit (LString "RuntimeTrue"))) (arm (PCon "RuntimeTupleCtor" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RuntimeTupleCtor ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "RuntimeCtorFact" () ((variant "RuntimeCtorFact" (ConNamed (field "owner" (TyCon "RuntimeOwner")) (field "ordinal" (TyCon "Int")) (field "arity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RuntimeCtorFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__a0")) (rf "ordinal" (PVar "__a1")) (rf "arity" (PVar "__a2"))) false) (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__b0")) (rf "ordinal" (PVar "__b1")) (rf "arity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "RuntimeCtorFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RuntimeCtorFact" ((rf "owner" (PVar "__a0")) (rf "ordinal" (PVar "__a1")) (rf "arity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RuntimeCtorFact {")) (ELit (LString " owner = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", ordinal = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", arity = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "namedRuntimeCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeCtorId"))))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Cons"))) (EApp (EVar "Some") (EVar "RuntimeCons")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Nil"))) (EApp (EVar "Some") (EVar "RuntimeNil")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Some"))) (EApp (EVar "Some") (EVar "RuntimeSome")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "None"))) (EApp (EVar "Some") (EVar "RuntimeNone")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Ok"))) (EApp (EVar "Some") (EVar "RuntimeOk")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Err"))) (EApp (EVar "Some") (EVar "RuntimeErr")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Lt"))) (EApp (EVar "Some") (EVar "RuntimeLt")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Eq"))) (EApp (EVar "Some") (EVar "RuntimeEq")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "Gt"))) (EApp (EVar "Some") (EVar "RuntimeGt")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "False"))) (EApp (EVar "Some") (EVar "RuntimeFalse")))
(DFunDef false "namedRuntimeCtor" ((PLit (LString "True"))) (EApp (EVar "Some") (EVar "RuntimeTrue")))
(DFunDef false "namedRuntimeCtor" (PWild) (EVar "None"))
(DTypeSig true "runtimeCtorFact" (TyFun (TyCon "RuntimeCtorId") (TyCon "RuntimeCtorFact")))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeCons")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeList")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 2))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeNil")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeList")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeSome")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOption")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeNone")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOption")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeOk")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeResult")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeErr")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeResult")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 1))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeLt")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeEq")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeGt")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeOrdering")) (fa "ordinal" (ELit (LInt 2))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeFalse")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeBool")) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeTrue")) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EVar "RuntimeBool")) (fa "ordinal" (ELit (LInt 1))) (fa "arity" (ELit (LInt 0))))))
(DFunDef false "runtimeCtorFact" ((PCon "RuntimeTupleCtor" (PVar "n"))) (ERecordCreate "RuntimeCtorFact" ((fa "owner" (EApp (EVar "RuntimeTuple") (EVar "n"))) (fa "ordinal" (ELit (LInt 0))) (fa "arity" (EVar "n")))))
(DTypeSig true "runtimeRoster" (TyFun (TyCon "RuntimeOwner") (TyApp (TyCon "List") (TyCon "RuntimeCtorId"))))
(DFunDef false "runtimeRoster" ((PCon "RuntimeList")) (EListLit (EVar "RuntimeCons") (EVar "RuntimeNil")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeOption")) (EListLit (EVar "RuntimeSome") (EVar "RuntimeNone")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeResult")) (EListLit (EVar "RuntimeOk") (EVar "RuntimeErr")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeOrdering")) (EListLit (EVar "RuntimeLt") (EVar "RuntimeEq") (EVar "RuntimeGt")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeBool")) (EListLit (EVar "RuntimeFalse") (EVar "RuntimeTrue")))
(DFunDef false "runtimeRoster" ((PCon "RuntimeTuple" (PVar "n"))) (EListLit (EApp (EVar "RuntimeTupleCtor") (EVar "n"))))
(DTypeSig true "runtimeCtorName" (TyFun (TyCon "RuntimeCtorId") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeCons")) (EApp (EVar "Some") (ELit (LString "Cons"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeNil")) (EApp (EVar "Some") (ELit (LString "Nil"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeSome")) (EApp (EVar "Some") (ELit (LString "Some"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeNone")) (EApp (EVar "Some") (ELit (LString "None"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeOk")) (EApp (EVar "Some") (ELit (LString "Ok"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeErr")) (EApp (EVar "Some") (ELit (LString "Err"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeLt")) (EApp (EVar "Some") (ELit (LString "Lt"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeEq")) (EApp (EVar "Some") (ELit (LString "Eq"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeGt")) (EApp (EVar "Some") (ELit (LString "Gt"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeFalse")) (EApp (EVar "Some") (ELit (LString "False"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeTrue")) (EApp (EVar "Some") (ELit (LString "True"))))
(DFunDef false "runtimeCtorName" ((PCon "RuntimeTupleCtor" PWild)) (EVar "None"))
(DTypeSig true "runtimeOwnerWord" (TyFun (TyCon "RuntimeOwner") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeList")) (EApp (EVar "Some") (ELit (LString "List"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeOption")) (EApp (EVar "Some") (ELit (LString "Option"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeResult")) (EApp (EVar "Some") (ELit (LString "Result"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeOrdering")) (EApp (EVar "Some") (ELit (LString "Ordering"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeBool")) (EApp (EVar "Some") (ELit (LString "Bool"))))
(DFunDef false "runtimeOwnerWord" ((PCon "RuntimeTuple" PWild)) (EVar "None"))
