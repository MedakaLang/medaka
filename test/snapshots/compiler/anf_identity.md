# META
source_lines=86
stages=DESUGAR,MARK
# SOURCE
-- X-A preparatory identity substrate (#1400).
--
-- This is deliberately not ANF, CallableId, or AP.  It validates only the
-- stable source-node/role component that X-A will later use after V exists.
-- No shipping emitter may import this module.

import support.util.{splitOnChar, startsWith}

public export data StableGeneratedRole =
  | RoleLiftedLambda
  | RoleWrapper
  | RoleEtaAdapter
  | RolePapEntry
  deriving (Eq, Ord, Debug)

public export data StableNodeIdInput =
  | StableNodeIdInput String Int Int Int Int (List Int) StableGeneratedRole

public export data StableNodeIdError =
  | EmptyProjectPath
  | AbsoluteProjectPath
  | ParentProjectPath
  | NonCanonicalProjectPath
  | InvalidSourceSpan
  | NegativeStructuralIndex
  deriving (Eq, Debug)

-- The constructor remains module-private: every StableNodeId passed to a later
-- X-A lowering has passed the path/span/structural validation below.
export data StableNodeId =
  | StableNodeId String Int Int Int Int (List Int) StableGeneratedRole
  deriving (Eq, Ord)

allNonNegative : List Int -> Bool
allNonNegative [] = True
allNonNegative (n :: ns) = n >= 0 && allNonNegative ns

canonicalPathComponents : List String -> Bool
canonicalPathComponents [] = False
canonicalPathComponents (component :: rest) =
  component /= ""
    && component /= "."
    && component /= ".."
    && canonicalPathComponentsGo rest

canonicalPathComponentsGo : List String -> Bool
canonicalPathComponentsGo [] = True
canonicalPathComponentsGo (component :: rest) =
  component /= ""
    && component /= "."
    && component /= ".."
    && canonicalPathComponentsGo rest

canonicalProjectPath : String -> Bool
canonicalProjectPath path = canonicalPathComponents (splitOnChar '/' path)

validSpan : Int -> Int -> Int -> Int -> Bool
validSpan startLine startCol endLine endCol =
  startLine >= 1
    && startCol >= 0
    && endLine >= 1
    && endLine >= startLine
    && endCol >= 0
    && (endLine /= startLine || endCol >= startCol)

export
mintStableNodeId : StableNodeIdInput -> Result StableNodeIdError StableNodeId
mintStableNodeId (StableNodeIdInput path startLine startCol endLine endCol childPath role)
  | path == "" = Err EmptyProjectPath
  | startsWith "/" path = Err AbsoluteProjectPath
  | startsWith "../" path = Err ParentProjectPath
  | not (canonicalProjectPath path) = Err NonCanonicalProjectPath
  | not (validSpan startLine startCol endLine endCol) = Err InvalidSourceSpan
  | not (allNonNegative childPath) = Err NegativeStructuralIndex
  | otherwise =
    Ok (StableNodeId path startLine startCol endLine endCol childPath role)

-- A serializer may inspect an already-validated ID, but clients cannot forge
-- one through this fold.  The structured value, not its rendered form, is the
-- identity used by future planning maps.
export
foldStableNodeId : (String -> Int -> Int -> Int -> Int -> List Int -> StableGeneratedRole -> a) ->
  StableNodeId ->
  a
foldStableNodeId f (StableNodeId path startLine startCol endLine endCol childPath role) =
  f path startLine startCol endLine endCol childPath role
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "StableGeneratedRole" () ((variant "RoleLiftedLambda" (ConPos)) (variant "RoleWrapper" (ConPos)) (variant "RoleEtaAdapter" (ConPos)) (variant "RolePapEntry" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StableGeneratedRole")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleLiftedLambda")) () (EVar "True")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleWrapper")) () (EVar "True")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleEtaAdapter")) () (EVar "True")) (arm (PTuple (PCon "RolePapEntry") (PCon "RolePapEntry")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "StableGeneratedRole")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleLiftedLambda")) () (EVar "Eq")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleWrapper")) () (EVar "Lt")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleEtaAdapter")) () (EVar "Lt")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleWrapper")) () (EVar "Eq")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleEtaAdapter")) () (EVar "Lt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleWrapper")) () (EVar "Gt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleEtaAdapter")) () (EVar "Eq")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleWrapper")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleEtaAdapter")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RolePapEntry")) () (EVar "Eq"))))))
(DImpl true "Debug" ((TyCon "StableGeneratedRole")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RoleLiftedLambda") () (ELit (LString "RoleLiftedLambda"))) (arm (PCon "RoleWrapper") () (ELit (LString "RoleWrapper"))) (arm (PCon "RoleEtaAdapter") () (ELit (LString "RoleEtaAdapter"))) (arm (PCon "RolePapEntry") () (ELit (LString "RolePapEntry")))))))
(DData Public "StableNodeIdInput" () ((variant "StableNodeIdInput" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "StableGeneratedRole")))) ())
(DData Public "StableNodeIdError" () ((variant "EmptyProjectPath" (ConPos)) (variant "AbsoluteProjectPath" (ConPos)) (variant "ParentProjectPath" (ConPos)) (variant "NonCanonicalProjectPath" (ConPos)) (variant "InvalidSourceSpan" (ConPos)) (variant "NegativeStructuralIndex" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StableNodeIdError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EmptyProjectPath") (PCon "EmptyProjectPath")) () (EVar "True")) (arm (PTuple (PCon "AbsoluteProjectPath") (PCon "AbsoluteProjectPath")) () (EVar "True")) (arm (PTuple (PCon "ParentProjectPath") (PCon "ParentProjectPath")) () (EVar "True")) (arm (PTuple (PCon "NonCanonicalProjectPath") (PCon "NonCanonicalProjectPath")) () (EVar "True")) (arm (PTuple (PCon "InvalidSourceSpan") (PCon "InvalidSourceSpan")) () (EVar "True")) (arm (PTuple (PCon "NegativeStructuralIndex") (PCon "NegativeStructuralIndex")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "StableNodeIdError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EmptyProjectPath") () (ELit (LString "EmptyProjectPath"))) (arm (PCon "AbsoluteProjectPath") () (ELit (LString "AbsoluteProjectPath"))) (arm (PCon "ParentProjectPath") () (ELit (LString "ParentProjectPath"))) (arm (PCon "NonCanonicalProjectPath") () (ELit (LString "NonCanonicalProjectPath"))) (arm (PCon "InvalidSourceSpan") () (ELit (LString "InvalidSourceSpan"))) (arm (PCon "NegativeStructuralIndex") () (ELit (LString "NegativeStructuralIndex")))))))
(DData Abstract "StableNodeId" () ((variant "StableNodeId" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "StableGeneratedRole")))) ())
(DImpl true "Eq" ((TyCon "StableNodeId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "StableNodeId" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) (PCon "StableNodeId" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4") (PVar "__b5") (PVar "__b6"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EVar "eq") (EVar "__a6")) (EVar "__b6"))))))))
(DImpl true "Ord" ((TyCon "StableNodeId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "StableNodeId" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) (PCon "StableNodeId" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4") (PVar "__b5") (PVar "__b6"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a2")) (EVar "__b2")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a3")) (EVar "__b3")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a4")) (EVar "__b4")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a5")) (EVar "__b5")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a6")) (EVar "__b6"))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c"))))))))
(DTypeSig false "allNonNegative" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "allNonNegative" ((PList)) (EVar "True"))
(DFunDef false "allNonNegative" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "allNonNegative") (EVar "ns"))))
(DTypeSig false "canonicalPathComponents" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "canonicalPathComponents" ((PList)) (EVar "False"))
(DFunDef false "canonicalPathComponents" ((PCons (PVar "component") (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "component") (ELit (LString ""))) (EBinOp "/=" (EVar "component") (ELit (LString ".")))) (EBinOp "/=" (EVar "component") (ELit (LString "..")))) (EApp (EVar "canonicalPathComponentsGo") (EVar "rest"))))
(DTypeSig false "canonicalPathComponentsGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "canonicalPathComponentsGo" ((PList)) (EVar "True"))
(DFunDef false "canonicalPathComponentsGo" ((PCons (PVar "component") (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "component") (ELit (LString ""))) (EBinOp "/=" (EVar "component") (ELit (LString ".")))) (EBinOp "/=" (EVar "component") (ELit (LString "..")))) (EApp (EVar "canonicalPathComponentsGo") (EVar "rest"))))
(DTypeSig false "canonicalProjectPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "canonicalProjectPath" ((PVar "path")) (EApp (EVar "canonicalPathComponents") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig false "validSpan" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "validSpan" ((PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "startLine") (ELit (LInt 1))) (EBinOp ">=" (EVar "startCol") (ELit (LInt 0)))) (EBinOp ">=" (EVar "endLine") (ELit (LInt 1)))) (EBinOp ">=" (EVar "endLine") (EVar "startLine"))) (EBinOp ">=" (EVar "endCol") (ELit (LInt 0)))) (EBinOp "||" (EBinOp "/=" (EVar "endLine") (EVar "startLine")) (EBinOp ">=" (EVar "endCol") (EVar "startCol")))))
(DTypeSig true "mintStableNodeId" (TyFun (TyCon "StableNodeIdInput") (TyApp (TyApp (TyCon "Result") (TyCon "StableNodeIdError")) (TyCon "StableNodeId"))))
(DFunDef false "mintStableNodeId" ((PCon "StableNodeIdInput" (PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role"))) (EIf (EBinOp "==" (EVar "path") (ELit (LString ""))) (EApp (EVar "Err") (EVar "EmptyProjectPath")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")) (EApp (EVar "Err") (EVar "AbsoluteProjectPath")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "../"))) (EVar "path")) (EApp (EVar "Err") (EVar "ParentProjectPath")) (EIf (EApp (EVar "not") (EApp (EVar "canonicalProjectPath") (EVar "path"))) (EApp (EVar "Err") (EVar "NonCanonicalProjectPath")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "validSpan") (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol"))) (EApp (EVar "Err") (EVar "InvalidSourceSpan")) (EIf (EApp (EVar "not") (EApp (EVar "allNonNegative") (EVar "childPath"))) (EApp (EVar "Err") (EVar "NegativeStructuralIndex")) (EIf (EVar "otherwise") (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "StableNodeId") (EVar "path")) (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol")) (EVar "childPath")) (EVar "role"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "foldStableNodeId" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "StableGeneratedRole") (TyVar "a")))))))) (TyFun (TyCon "StableNodeId") (TyVar "a"))))
(DFunDef false "foldStableNodeId" ((PVar "f") (PCon "StableNodeId" (PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "path")) (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol")) (EVar "childPath")) (EVar "role")))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "StableGeneratedRole" () ((variant "RoleLiftedLambda" (ConPos)) (variant "RoleWrapper" (ConPos)) (variant "RoleEtaAdapter" (ConPos)) (variant "RolePapEntry" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StableGeneratedRole")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleLiftedLambda")) () (EVar "True")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleWrapper")) () (EVar "True")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleEtaAdapter")) () (EVar "True")) (arm (PTuple (PCon "RolePapEntry") (PCon "RolePapEntry")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "StableGeneratedRole")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleLiftedLambda")) () (EVar "Eq")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleWrapper")) () (EVar "Lt")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RoleEtaAdapter")) () (EVar "Lt")) (arm (PTuple (PCon "RoleLiftedLambda") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleWrapper")) () (EVar "Eq")) (arm (PTuple (PCon "RoleWrapper") (PCon "RoleEtaAdapter")) () (EVar "Lt")) (arm (PTuple (PCon "RoleWrapper") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleWrapper")) () (EVar "Gt")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RoleEtaAdapter")) () (EVar "Eq")) (arm (PTuple (PCon "RoleEtaAdapter") (PCon "RolePapEntry")) () (EVar "Lt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleLiftedLambda")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleWrapper")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RoleEtaAdapter")) () (EVar "Gt")) (arm (PTuple (PCon "RolePapEntry") (PCon "RolePapEntry")) () (EVar "Eq"))))))
(DImpl true "Debug" ((TyCon "StableGeneratedRole")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RoleLiftedLambda") () (ELit (LString "RoleLiftedLambda"))) (arm (PCon "RoleWrapper") () (ELit (LString "RoleWrapper"))) (arm (PCon "RoleEtaAdapter") () (ELit (LString "RoleEtaAdapter"))) (arm (PCon "RolePapEntry") () (ELit (LString "RolePapEntry")))))))
(DData Public "StableNodeIdInput" () ((variant "StableNodeIdInput" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "StableGeneratedRole")))) ())
(DData Public "StableNodeIdError" () ((variant "EmptyProjectPath" (ConPos)) (variant "AbsoluteProjectPath" (ConPos)) (variant "ParentProjectPath" (ConPos)) (variant "NonCanonicalProjectPath" (ConPos)) (variant "InvalidSourceSpan" (ConPos)) (variant "NegativeStructuralIndex" (ConPos))) ())
(DImpl true "Eq" ((TyCon "StableNodeIdError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EmptyProjectPath") (PCon "EmptyProjectPath")) () (EVar "True")) (arm (PTuple (PCon "AbsoluteProjectPath") (PCon "AbsoluteProjectPath")) () (EVar "True")) (arm (PTuple (PCon "ParentProjectPath") (PCon "ParentProjectPath")) () (EVar "True")) (arm (PTuple (PCon "NonCanonicalProjectPath") (PCon "NonCanonicalProjectPath")) () (EVar "True")) (arm (PTuple (PCon "InvalidSourceSpan") (PCon "InvalidSourceSpan")) () (EVar "True")) (arm (PTuple (PCon "NegativeStructuralIndex") (PCon "NegativeStructuralIndex")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "StableNodeIdError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EmptyProjectPath") () (ELit (LString "EmptyProjectPath"))) (arm (PCon "AbsoluteProjectPath") () (ELit (LString "AbsoluteProjectPath"))) (arm (PCon "ParentProjectPath") () (ELit (LString "ParentProjectPath"))) (arm (PCon "NonCanonicalProjectPath") () (ELit (LString "NonCanonicalProjectPath"))) (arm (PCon "InvalidSourceSpan") () (ELit (LString "InvalidSourceSpan"))) (arm (PCon "NegativeStructuralIndex") () (ELit (LString "NegativeStructuralIndex")))))))
(DData Abstract "StableNodeId" () ((variant "StableNodeId" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "StableGeneratedRole")))) ())
(DImpl true "Eq" ((TyCon "StableNodeId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "StableNodeId" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) (PCon "StableNodeId" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4") (PVar "__b5") (PVar "__b6"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EMethodRef "eq") (EVar "__a6")) (EVar "__b6"))))))))
(DImpl true "Ord" ((TyCon "StableNodeId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "StableNodeId" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3") (PVar "__a4") (PVar "__a5") (PVar "__a6")) (PCon "StableNodeId" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3") (PVar "__b4") (PVar "__b5") (PVar "__b6"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a2")) (EVar "__b2")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a3")) (EVar "__b3")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a4")) (EVar "__b4")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a5")) (EVar "__b5")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a6")) (EVar "__b6"))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c"))))))))
(DTypeSig false "allNonNegative" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "allNonNegative" ((PList)) (EVar "True"))
(DFunDef false "allNonNegative" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "allNonNegative") (EVar "ns"))))
(DTypeSig false "canonicalPathComponents" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "canonicalPathComponents" ((PList)) (EVar "False"))
(DFunDef false "canonicalPathComponents" ((PCons (PVar "component") (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "component") (ELit (LString ""))) (EBinOp "/=" (EVar "component") (ELit (LString ".")))) (EBinOp "/=" (EVar "component") (ELit (LString "..")))) (EApp (EVar "canonicalPathComponentsGo") (EVar "rest"))))
(DTypeSig false "canonicalPathComponentsGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "canonicalPathComponentsGo" ((PList)) (EVar "True"))
(DFunDef false "canonicalPathComponentsGo" ((PCons (PVar "component") (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "component") (ELit (LString ""))) (EBinOp "/=" (EVar "component") (ELit (LString ".")))) (EBinOp "/=" (EVar "component") (ELit (LString "..")))) (EApp (EVar "canonicalPathComponentsGo") (EVar "rest"))))
(DTypeSig false "canonicalProjectPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "canonicalProjectPath" ((PVar "path")) (EApp (EVar "canonicalPathComponents") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig false "validSpan" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "validSpan" ((PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "startLine") (ELit (LInt 1))) (EBinOp ">=" (EVar "startCol") (ELit (LInt 0)))) (EBinOp ">=" (EVar "endLine") (ELit (LInt 1)))) (EBinOp ">=" (EVar "endLine") (EVar "startLine"))) (EBinOp ">=" (EVar "endCol") (ELit (LInt 0)))) (EBinOp "||" (EBinOp "/=" (EVar "endLine") (EVar "startLine")) (EBinOp ">=" (EVar "endCol") (EVar "startCol")))))
(DTypeSig true "mintStableNodeId" (TyFun (TyCon "StableNodeIdInput") (TyApp (TyApp (TyCon "Result") (TyCon "StableNodeIdError")) (TyCon "StableNodeId"))))
(DFunDef false "mintStableNodeId" ((PCon "StableNodeIdInput" (PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role"))) (EIf (EBinOp "==" (EVar "path") (ELit (LString ""))) (EApp (EVar "Err") (EVar "EmptyProjectPath")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")) (EApp (EVar "Err") (EVar "AbsoluteProjectPath")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "../"))) (EVar "path")) (EApp (EVar "Err") (EVar "ParentProjectPath")) (EIf (EApp (EVar "not") (EApp (EVar "canonicalProjectPath") (EVar "path"))) (EApp (EVar "Err") (EVar "NonCanonicalProjectPath")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "validSpan") (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol"))) (EApp (EVar "Err") (EVar "InvalidSourceSpan")) (EIf (EApp (EVar "not") (EApp (EVar "allNonNegative") (EVar "childPath"))) (EApp (EVar "Err") (EVar "NegativeStructuralIndex")) (EIf (EVar "otherwise") (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "StableNodeId") (EVar "path")) (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol")) (EVar "childPath")) (EVar "role"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "foldStableNodeId" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "StableGeneratedRole") (TyVar "a")))))))) (TyFun (TyCon "StableNodeId") (TyVar "a"))))
(DFunDef false "foldStableNodeId" ((PVar "f") (PCon "StableNodeId" (PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "path")) (EVar "startLine")) (EVar "startCol")) (EVar "endLine")) (EVar "endCol")) (EVar "childPath")) (EVar "role")))
