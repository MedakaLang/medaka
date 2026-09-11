# META
source_lines=159
stages=DESUGAR,MARK
# SOURCE
-- Nominal lexical scope storage for one typechecking graph.  Raw ScopeIds are
-- request-local: every lookup and ancestry query therefore receives the store
-- that minted the id.

import types.evidence.{EvidenceBinderId(..), ScopeId(..)}
import types.repr.{IfaceRef}

public export data DefaultBodyIdentity = DefaultBodyIdentity {
  dbiIface : IfaceRef,
  dbiMethod : String,
}

public export data ScopeOwner =
  | ModuleOwner
  | BindingOwner String
  | DefaultBodyOwner DefaultBodyIdentity
  | PropOwner String
  | TestOwner String

-- The named closed/open states preserve the inference gateway's distinct capture
-- and close misuse diagnostics; a plain Option would erase that contract.
-- lint-disable-next-line rule-clone-type
public export data ScopeCursor = ScopeClosed | ScopeOpen ScopeId

public export data ScopeFrame = ScopeFrame {
  sfId : ScopeId,
  sfParent : Option ScopeId,
  sfLevel : Int,
  sfModuleId : String,
  sfOwner : ScopeOwner,
}

-- Mutable storage stays abstract so ids cannot be looked up without their store
-- and copied graphs cannot accidentally share its counter or backing array.
export data ScopeStore = ScopeStore {
  ssFrames : Ref (Array (Option ScopeFrame)),
  ssNext : Ref Int,
}

export
freshScopeStore : Unit -> ScopeStore
freshScopeStore _ = ScopeStore {
  ssFrames = Ref (arrayMake 0 None),
  ssNext = Ref 0,
}

export
copyScopeStore : ScopeStore -> ScopeStore
copyScopeStore store = ScopeStore {
  ssFrames = Ref (arrayCopy store.ssFrames.value),
  ssNext = Ref store.ssNext.value,
}

scopeOrdinal : ScopeId -> Int
scopeOrdinal (ScopeId i) = i

export
scopeFrame : ScopeStore -> ScopeId -> ScopeFrame
scopeFrame store sid =
  let i = scopeOrdinal sid
  let frames = store.ssFrames.value
  if i < 0 || i >= arrayLength frames then
    panic "scope frame missing"
  else match arrayGetUnsafe i frames
    Some frame => frame
    None => panic "scope frame missing"

export
freshScope : ScopeStore ->
  Option ScopeId ->
  Int ->
  String ->
  ScopeOwner ->
  ScopeId
freshScope store parent level moduleId owner =
  let i = store.ssNext.value
  let sid = ScopeId i
  let arr0 = store.ssFrames.value
  let arr =
    if i < arrayLength arr0 then
      arr0
    else
      let grown = arrayMake (max 16 (2 * (i + 1))) None
      let _ = arrayBlit arr0 0 grown 0 (arrayLength arr0)
      store.ssFrames := grown
      grown
  let _ =
    arraySetUnsafe
      i
      (Some ScopeFrame {
        sfId = sid,
        sfParent = parent,
        sfLevel = level,
        sfModuleId = moduleId,
        sfOwner = owner,
      })
      arr
  store.ssNext := i + 1
  sid

export
givenVisibleFrom : ScopeStore -> ScopeId -> ScopeId -> Bool
givenVisibleFrom store useScope binderScope
  | useScope == binderScope = True
  | otherwise = match (scopeFrame store useScope).sfParent
    Some parent => givenVisibleFrom store parent binderScope
    None => False

export
enclosingDefaultBody : ScopeStore -> ScopeId -> Option DefaultBodyIdentity
enclosingDefaultBody store sid =
  let frame = scopeFrame store sid
  match frame.sfOwner
    DefaultBodyOwner owner => Some owner
    _ => match frame.sfParent
      Some parent => enclosingDefaultBody store parent
      None => None

export
binderAt : ScopeId -> Int -> EvidenceBinderId
binderAt sid ordinal = EvidenceBinderId sid ordinal

export
binderScope : EvidenceBinderId -> ScopeId
binderScope (EvidenceBinderId sid _) = sid

export
captureScopeCursor : ScopeCursor -> ScopeId
captureScopeCursor (ScopeOpen sid) = sid
captureScopeCursor ScopeClosed = panic "scope capture outside inference"

export
openScopeCursor : ScopeId -> ScopeCursor
openScopeCursor sid = ScopeOpen sid

export
closeScopeCursor : ScopeStore -> ScopeCursor -> ScopeCursor
closeScopeCursor _ ScopeClosed = panic "scope close outside inference"
closeScopeCursor store (ScopeOpen sid) = match (scopeFrame store sid).sfParent
  Some parent => ScopeOpen parent
  None => ScopeClosed

export
scopeOwnerLabel : ScopeOwner -> String
scopeOwnerLabel ModuleOwner = "module"
scopeOwnerLabel (BindingOwner name) = "binding:" ++ name
scopeOwnerLabel (DefaultBodyOwner owner) = "default:" ++ owner.dbiMethod
scopeOwnerLabel (PropOwner name) = "prop:" ++ name
scopeOwnerLabel (TestOwner name) = "test:" ++ name

export
scopeTraceContext : ScopeStore -> ScopeId -> (String, String)
scopeTraceContext store sid =
  let frame = scopeFrame store sid
  (frame.sfModuleId, scopeOwnerLabel frame.sfOwner)

export
scopeFrameStats : ScopeStore -> (Int, Int)
scopeFrameStats store = (store.ssNext.value, arrayLength store.ssFrames.value)
# DESUGAR
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false))))
(DData Public "DefaultBodyIdentity" () ((variant "DefaultBodyIdentity" (ConNamed (field "dbiIface" (TyCon "IfaceRef")) (field "dbiMethod" (TyCon "String"))))) ())
(DData Public "ScopeOwner" () ((variant "ModuleOwner" (ConPos)) (variant "BindingOwner" (ConPos (TyCon "String"))) (variant "DefaultBodyOwner" (ConPos (TyCon "DefaultBodyIdentity"))) (variant "PropOwner" (ConPos (TyCon "String"))) (variant "TestOwner" (ConPos (TyCon "String")))) ())
(DData Public "ScopeCursor" () ((variant "ScopeClosed" (ConPos)) (variant "ScopeOpen" (ConPos (TyCon "ScopeId")))) ())
(DData Public "ScopeFrame" () ((variant "ScopeFrame" (ConNamed (field "sfId" (TyCon "ScopeId")) (field "sfParent" (TyApp (TyCon "Option") (TyCon "ScopeId"))) (field "sfLevel" (TyCon "Int")) (field "sfModuleId" (TyCon "String")) (field "sfOwner" (TyCon "ScopeOwner"))))) ())
(DData Abstract "ScopeStore" () ((variant "ScopeStore" (ConNamed (field "ssFrames" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "ScopeFrame"))))) (field "ssNext" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "freshScopeStore" (TyFun (TyCon "Unit") (TyCon "ScopeStore")))
(DFunDef false "freshScopeStore" (PWild) (ERecordCreate "ScopeStore" ((fa "ssFrames" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "ssNext" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "copyScopeStore" (TyFun (TyCon "ScopeStore") (TyCon "ScopeStore")))
(DFunDef false "copyScopeStore" ((PVar "store")) (ERecordCreate "ScopeStore" ((fa "ssFrames" (EApp (EVar "Ref") (EApp (EVar "arrayCopy") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")))) (fa "ssNext" (EApp (EVar "Ref") (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value"))))))
(DTypeSig false "scopeOrdinal" (TyFun (TyCon "ScopeId") (TyCon "Int")))
(DFunDef false "scopeOrdinal" ((PCon "ScopeId" (PVar "i"))) (EVar "i"))
(DTypeSig true "scopeFrame" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyCon "ScopeFrame"))))
(DFunDef false "scopeFrame" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "scopeOrdinal") (EVar "sid"))) (DoLet false false (PVar "frames") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "frames")))) (EApp (EVar "panic") (ELit (LString "scope frame missing"))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "frames")) (arm (PCon "Some" (PVar "frame")) () (EVar "frame")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "scope frame missing")))))))))
(DTypeSig true "freshScope" (TyFun (TyCon "ScopeStore") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ScopeOwner") (TyCon "ScopeId")))))))
(DFunDef false "freshScope" ((PVar "store") (PVar "parent") (PVar "level") (PVar "moduleId") (PVar "owner")) (EBlock (DoLet false false (PVar "i") (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value")) (DoLet false false (PVar "sid") (EApp (EVar "ScopeId") (EVar "i"))) (DoLet false false (PVar "arr0") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")) (DoLet false false (PVar "arr") (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr0"))) (EVar "arr0") (EBlock (DoLet false false (PVar "grown") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EVar "max") (ELit (LInt 16))) (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr0")) (ELit (LInt 0))) (EVar "grown")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr0")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "store") "ssFrames")) (EVar "grown"))) (DoExpr (EVar "grown"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ERecordCreate "ScopeFrame" ((fa "sfId" (EVar "sid")) (fa "sfParent" (EVar "parent")) (fa "sfLevel" (EVar "level")) (fa "sfModuleId" (EVar "moduleId")) (fa "sfOwner" (EVar "owner")))))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "store") "ssNext")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EVar "sid"))))
(DTypeSig true "givenVisibleFrom" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyFun (TyCon "ScopeId") (TyCon "Bool")))))
(DFunDef false "givenVisibleFrom" ((PVar "store") (PVar "useScope") (PVar "binderScope")) (EIf (EBinOp "==" (EVar "useScope") (EVar "binderScope")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "useScope")) "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EApp (EVar "givenVisibleFrom") (EVar "store")) (EVar "parent")) (EVar "binderScope"))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "enclosingDefaultBody" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "DefaultBodyIdentity")))))
(DFunDef false "enclosingDefaultBody" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid"))) (DoExpr (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "DefaultBodyOwner" (PVar "owner")) () (EApp (EVar "Some") (EVar "owner"))) (arm PWild () (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "enclosingDefaultBody") (EVar "store")) (EVar "parent"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig true "binderAt" (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyCon "EvidenceBinderId"))))
(DFunDef false "binderAt" ((PVar "sid") (PVar "ordinal")) (EApp (EApp (EVar "EvidenceBinderId") (EVar "sid")) (EVar "ordinal")))
(DTypeSig true "binderScope" (TyFun (TyCon "EvidenceBinderId") (TyCon "ScopeId")))
(DFunDef false "binderScope" ((PCon "EvidenceBinderId" (PVar "sid") PWild)) (EVar "sid"))
(DTypeSig true "captureScopeCursor" (TyFun (TyCon "ScopeCursor") (TyCon "ScopeId")))
(DFunDef false "captureScopeCursor" ((PCon "ScopeOpen" (PVar "sid"))) (EVar "sid"))
(DFunDef false "captureScopeCursor" ((PCon "ScopeClosed")) (EApp (EVar "panic") (ELit (LString "scope capture outside inference"))))
(DTypeSig true "openScopeCursor" (TyFun (TyCon "ScopeId") (TyCon "ScopeCursor")))
(DFunDef false "openScopeCursor" ((PVar "sid")) (EApp (EVar "ScopeOpen") (EVar "sid")))
(DTypeSig true "closeScopeCursor" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeCursor") (TyCon "ScopeCursor"))))
(DFunDef false "closeScopeCursor" (PWild (PCon "ScopeClosed")) (EApp (EVar "panic") (ELit (LString "scope close outside inference"))))
(DFunDef false "closeScopeCursor" ((PVar "store") (PCon "ScopeOpen" (PVar "sid"))) (EMatch (EFieldAccess (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid")) "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EVar "ScopeOpen") (EVar "parent"))) (arm (PCon "None") () (EVar "ScopeClosed"))))
(DTypeSig true "scopeOwnerLabel" (TyFun (TyCon "ScopeOwner") (TyCon "String")))
(DFunDef false "scopeOwnerLabel" ((PCon "ModuleOwner")) (ELit (LString "module")))
(DFunDef false "scopeOwnerLabel" ((PCon "BindingOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "binding:")) (EVar "name")))
(DFunDef false "scopeOwnerLabel" ((PCon "DefaultBodyOwner" (PVar "owner"))) (EBinOp "++" (ELit (LString "default:")) (EFieldAccess (EVar "owner") "dbiMethod")))
(DFunDef false "scopeOwnerLabel" ((PCon "PropOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "prop:")) (EVar "name")))
(DFunDef false "scopeOwnerLabel" ((PCon "TestOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "test:")) (EVar "name")))
(DTypeSig true "scopeTraceContext" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "scopeTraceContext" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid"))) (DoExpr (ETuple (EFieldAccess (EVar "frame") "sfModuleId") (EApp (EVar "scopeOwnerLabel") (EFieldAccess (EVar "frame") "sfOwner"))))))
(DTypeSig true "scopeFrameStats" (TyFun (TyCon "ScopeStore") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "scopeFrameStats" ((PVar "store")) (ETuple (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value") (EApp (EVar "arrayLength") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value"))))
# MARK
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false))))
(DData Public "DefaultBodyIdentity" () ((variant "DefaultBodyIdentity" (ConNamed (field "dbiIface" (TyCon "IfaceRef")) (field "dbiMethod" (TyCon "String"))))) ())
(DData Public "ScopeOwner" () ((variant "ModuleOwner" (ConPos)) (variant "BindingOwner" (ConPos (TyCon "String"))) (variant "DefaultBodyOwner" (ConPos (TyCon "DefaultBodyIdentity"))) (variant "PropOwner" (ConPos (TyCon "String"))) (variant "TestOwner" (ConPos (TyCon "String")))) ())
(DData Public "ScopeCursor" () ((variant "ScopeClosed" (ConPos)) (variant "ScopeOpen" (ConPos (TyCon "ScopeId")))) ())
(DData Public "ScopeFrame" () ((variant "ScopeFrame" (ConNamed (field "sfId" (TyCon "ScopeId")) (field "sfParent" (TyApp (TyCon "Option") (TyCon "ScopeId"))) (field "sfLevel" (TyCon "Int")) (field "sfModuleId" (TyCon "String")) (field "sfOwner" (TyCon "ScopeOwner"))))) ())
(DData Abstract "ScopeStore" () ((variant "ScopeStore" (ConNamed (field "ssFrames" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "ScopeFrame"))))) (field "ssNext" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig true "freshScopeStore" (TyFun (TyCon "Unit") (TyCon "ScopeStore")))
(DFunDef false "freshScopeStore" (PWild) (ERecordCreate "ScopeStore" ((fa "ssFrames" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "ssNext" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "copyScopeStore" (TyFun (TyCon "ScopeStore") (TyCon "ScopeStore")))
(DFunDef false "copyScopeStore" ((PVar "store")) (ERecordCreate "ScopeStore" ((fa "ssFrames" (EApp (EVar "Ref") (EApp (EVar "arrayCopy") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")))) (fa "ssNext" (EApp (EVar "Ref") (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value"))))))
(DTypeSig false "scopeOrdinal" (TyFun (TyCon "ScopeId") (TyCon "Int")))
(DFunDef false "scopeOrdinal" ((PCon "ScopeId" (PVar "i"))) (EVar "i"))
(DTypeSig true "scopeFrame" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyCon "ScopeFrame"))))
(DFunDef false "scopeFrame" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "i") (EApp (EVar "scopeOrdinal") (EVar "sid"))) (DoLet false false (PVar "frames") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "frames")))) (EApp (EVar "panic") (ELit (LString "scope frame missing"))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "frames")) (arm (PCon "Some" (PVar "frame")) () (EVar "frame")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "scope frame missing")))))))))
(DTypeSig true "freshScope" (TyFun (TyCon "ScopeStore") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ScopeOwner") (TyCon "ScopeId")))))))
(DFunDef false "freshScope" ((PVar "store") (PVar "parent") (PVar "level") (PVar "moduleId") (PVar "owner")) (EBlock (DoLet false false (PVar "i") (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value")) (DoLet false false (PVar "sid") (EApp (EVar "ScopeId") (EVar "i"))) (DoLet false false (PVar "arr0") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value")) (DoLet false false (PVar "arr") (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr0"))) (EVar "arr0") (EBlock (DoLet false false (PVar "grown") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EMethodRef "max") (ELit (LInt 16))) (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr0")) (ELit (LInt 0))) (EVar "grown")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr0")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "store") "ssFrames")) (EVar "grown"))) (DoExpr (EVar "grown"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ERecordCreate "ScopeFrame" ((fa "sfId" (EVar "sid")) (fa "sfParent" (EVar "parent")) (fa "sfLevel" (EVar "level")) (fa "sfModuleId" (EVar "moduleId")) (fa "sfOwner" (EVar "owner")))))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "store") "ssNext")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EVar "sid"))))
(DTypeSig true "givenVisibleFrom" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyFun (TyCon "ScopeId") (TyCon "Bool")))))
(DFunDef false "givenVisibleFrom" ((PVar "store") (PVar "useScope") (PVar "binderScope")) (EIf (EBinOp "==" (EVar "useScope") (EVar "binderScope")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "useScope")) "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EApp (EVar "givenVisibleFrom") (EVar "store")) (EVar "parent")) (EVar "binderScope"))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "enclosingDefaultBody" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "DefaultBodyIdentity")))))
(DFunDef false "enclosingDefaultBody" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid"))) (DoExpr (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "DefaultBodyOwner" (PVar "owner")) () (EApp (EVar "Some") (EVar "owner"))) (arm PWild () (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "enclosingDefaultBody") (EVar "store")) (EVar "parent"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig true "binderAt" (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyCon "EvidenceBinderId"))))
(DFunDef false "binderAt" ((PVar "sid") (PVar "ordinal")) (EApp (EApp (EVar "EvidenceBinderId") (EVar "sid")) (EVar "ordinal")))
(DTypeSig true "binderScope" (TyFun (TyCon "EvidenceBinderId") (TyCon "ScopeId")))
(DFunDef false "binderScope" ((PCon "EvidenceBinderId" (PVar "sid") PWild)) (EVar "sid"))
(DTypeSig true "captureScopeCursor" (TyFun (TyCon "ScopeCursor") (TyCon "ScopeId")))
(DFunDef false "captureScopeCursor" ((PCon "ScopeOpen" (PVar "sid"))) (EVar "sid"))
(DFunDef false "captureScopeCursor" ((PCon "ScopeClosed")) (EApp (EVar "panic") (ELit (LString "scope capture outside inference"))))
(DTypeSig true "openScopeCursor" (TyFun (TyCon "ScopeId") (TyCon "ScopeCursor")))
(DFunDef false "openScopeCursor" ((PVar "sid")) (EApp (EVar "ScopeOpen") (EVar "sid")))
(DTypeSig true "closeScopeCursor" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeCursor") (TyCon "ScopeCursor"))))
(DFunDef false "closeScopeCursor" (PWild (PCon "ScopeClosed")) (EApp (EVar "panic") (ELit (LString "scope close outside inference"))))
(DFunDef false "closeScopeCursor" ((PVar "store") (PCon "ScopeOpen" (PVar "sid"))) (EMatch (EFieldAccess (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid")) "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EVar "ScopeOpen") (EVar "parent"))) (arm (PCon "None") () (EVar "ScopeClosed"))))
(DTypeSig true "scopeOwnerLabel" (TyFun (TyCon "ScopeOwner") (TyCon "String")))
(DFunDef false "scopeOwnerLabel" ((PCon "ModuleOwner")) (ELit (LString "module")))
(DFunDef false "scopeOwnerLabel" ((PCon "BindingOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "binding:")) (EVar "name")))
(DFunDef false "scopeOwnerLabel" ((PCon "DefaultBodyOwner" (PVar "owner"))) (EBinOp "++" (ELit (LString "default:")) (EFieldAccess (EVar "owner") "dbiMethod")))
(DFunDef false "scopeOwnerLabel" ((PCon "PropOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "prop:")) (EVar "name")))
(DFunDef false "scopeOwnerLabel" ((PCon "TestOwner" (PVar "name"))) (EBinOp "++" (ELit (LString "test:")) (EVar "name")))
(DTypeSig true "scopeTraceContext" (TyFun (TyCon "ScopeStore") (TyFun (TyCon "ScopeId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "scopeTraceContext" ((PVar "store") (PVar "sid")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "scopeFrame") (EVar "store")) (EVar "sid"))) (DoExpr (ETuple (EFieldAccess (EVar "frame") "sfModuleId") (EApp (EVar "scopeOwnerLabel") (EFieldAccess (EVar "frame") "sfOwner"))))))
(DTypeSig true "scopeFrameStats" (TyFun (TyCon "ScopeStore") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "scopeFrameStats" ((PVar "store")) (ETuple (EFieldAccess (EFieldAccess (EVar "store") "ssNext") "value") (EApp (EVar "arrayLength") (EFieldAccess (EFieldAccess (EVar "store") "ssFrames") "value"))))
