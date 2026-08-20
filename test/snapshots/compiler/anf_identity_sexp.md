# META
source_lines=34
stages=DESUGAR,MARK
# SOURCE
-- Stable, lossless rendering for X-A's preparatory StableNodeId substrate.

import ir.anf_identity.{
  StableGeneratedRole(..),
  StableNodeId,
  StableNodeIdError(..),
  foldStableNodeId,
}
import ir.sexp.{node, slist}
import support.util.{escStr}

roleSexp : StableGeneratedRole -> String
roleSexp RoleLiftedLambda = "lifted-lambda"
roleSexp RoleWrapper = "wrapper"
roleSexp RoleEtaAdapter = "eta-adapter"
roleSexp RolePapEntry = "pap-entry"

errorSexp : StableNodeIdError -> String
errorSexp EmptyProjectPath = "empty-project-path"
errorSexp AbsoluteProjectPath = "absolute-project-path"
errorSexp ParentProjectPath = "parent-project-path"
errorSexp NonCanonicalProjectPath = "noncanonical-project-path"
errorSexp InvalidSourceSpan = "invalid-source-span"
errorSexp NegativeStructuralIndex = "negative-structural-index"

export
stableNodeIdToSexp : StableNodeId -> String
stableNodeIdToSexp nodeId = foldStableNodeId
  (path startLine startCol endLine endCol childPath role => node "stable-node-id" [escStr path, node "span" [intToString startLine, intToString startCol, intToString endLine, intToString endCol], node "child-path" [slist (map intToString childPath)], roleSexp role])
  nodeId

export
stableNodeIdErrorToSexp : StableNodeIdError -> String
stableNodeIdErrorToSexp err = node "stable-node-id-error" [errorSexp err]
# DESUGAR
(DUse false (UseGroup ("ir" "anf_identity") ((mem "StableGeneratedRole" true) (mem "StableNodeId" false) (mem "StableNodeIdError" true) (mem "foldStableNodeId" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "node" false) (mem "slist" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false))))
(DTypeSig false "roleSexp" (TyFun (TyCon "StableGeneratedRole") (TyCon "String")))
(DFunDef false "roleSexp" ((PCon "RoleLiftedLambda")) (ELit (LString "lifted-lambda")))
(DFunDef false "roleSexp" ((PCon "RoleWrapper")) (ELit (LString "wrapper")))
(DFunDef false "roleSexp" ((PCon "RoleEtaAdapter")) (ELit (LString "eta-adapter")))
(DFunDef false "roleSexp" ((PCon "RolePapEntry")) (ELit (LString "pap-entry")))
(DTypeSig false "errorSexp" (TyFun (TyCon "StableNodeIdError") (TyCon "String")))
(DFunDef false "errorSexp" ((PCon "EmptyProjectPath")) (ELit (LString "empty-project-path")))
(DFunDef false "errorSexp" ((PCon "AbsoluteProjectPath")) (ELit (LString "absolute-project-path")))
(DFunDef false "errorSexp" ((PCon "ParentProjectPath")) (ELit (LString "parent-project-path")))
(DFunDef false "errorSexp" ((PCon "NonCanonicalProjectPath")) (ELit (LString "noncanonical-project-path")))
(DFunDef false "errorSexp" ((PCon "InvalidSourceSpan")) (ELit (LString "invalid-source-span")))
(DFunDef false "errorSexp" ((PCon "NegativeStructuralIndex")) (ELit (LString "negative-structural-index")))
(DTypeSig true "stableNodeIdToSexp" (TyFun (TyCon "StableNodeId") (TyCon "String")))
(DFunDef false "stableNodeIdToSexp" ((PVar "nodeId")) (EApp (EApp (EVar "foldStableNodeId") (ELam ((PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role")) (EApp (EApp (EVar "node") (ELit (LString "stable-node-id"))) (EListLit (EApp (EVar "escStr") (EVar "path")) (EApp (EApp (EVar "node") (ELit (LString "span"))) (EListLit (EApp (EVar "intToString") (EVar "startLine")) (EApp (EVar "intToString") (EVar "startCol")) (EApp (EVar "intToString") (EVar "endLine")) (EApp (EVar "intToString") (EVar "endCol")))) (EApp (EApp (EVar "node") (ELit (LString "child-path"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "childPath"))))) (EApp (EVar "roleSexp") (EVar "role")))))) (EVar "nodeId")))
(DTypeSig true "stableNodeIdErrorToSexp" (TyFun (TyCon "StableNodeIdError") (TyCon "String")))
(DFunDef false "stableNodeIdErrorToSexp" ((PVar "err")) (EApp (EApp (EVar "node") (ELit (LString "stable-node-id-error"))) (EListLit (EApp (EVar "errorSexp") (EVar "err")))))
# MARK
(DUse false (UseGroup ("ir" "anf_identity") ((mem "StableGeneratedRole" true) (mem "StableNodeId" false) (mem "StableNodeIdError" true) (mem "foldStableNodeId" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "node" false) (mem "slist" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false))))
(DTypeSig false "roleSexp" (TyFun (TyCon "StableGeneratedRole") (TyCon "String")))
(DFunDef false "roleSexp" ((PCon "RoleLiftedLambda")) (ELit (LString "lifted-lambda")))
(DFunDef false "roleSexp" ((PCon "RoleWrapper")) (ELit (LString "wrapper")))
(DFunDef false "roleSexp" ((PCon "RoleEtaAdapter")) (ELit (LString "eta-adapter")))
(DFunDef false "roleSexp" ((PCon "RolePapEntry")) (ELit (LString "pap-entry")))
(DTypeSig false "errorSexp" (TyFun (TyCon "StableNodeIdError") (TyCon "String")))
(DFunDef false "errorSexp" ((PCon "EmptyProjectPath")) (ELit (LString "empty-project-path")))
(DFunDef false "errorSexp" ((PCon "AbsoluteProjectPath")) (ELit (LString "absolute-project-path")))
(DFunDef false "errorSexp" ((PCon "ParentProjectPath")) (ELit (LString "parent-project-path")))
(DFunDef false "errorSexp" ((PCon "NonCanonicalProjectPath")) (ELit (LString "noncanonical-project-path")))
(DFunDef false "errorSexp" ((PCon "InvalidSourceSpan")) (ELit (LString "invalid-source-span")))
(DFunDef false "errorSexp" ((PCon "NegativeStructuralIndex")) (ELit (LString "negative-structural-index")))
(DTypeSig true "stableNodeIdToSexp" (TyFun (TyCon "StableNodeId") (TyCon "String")))
(DFunDef false "stableNodeIdToSexp" ((PVar "nodeId")) (EApp (EApp (EVar "foldStableNodeId") (ELam ((PVar "path") (PVar "startLine") (PVar "startCol") (PVar "endLine") (PVar "endCol") (PVar "childPath") (PVar "role")) (EApp (EApp (EVar "node") (ELit (LString "stable-node-id"))) (EListLit (EApp (EVar "escStr") (EVar "path")) (EApp (EApp (EVar "node") (ELit (LString "span"))) (EListLit (EApp (EVar "intToString") (EVar "startLine")) (EApp (EVar "intToString") (EVar "startCol")) (EApp (EVar "intToString") (EVar "endLine")) (EApp (EVar "intToString") (EVar "endCol")))) (EApp (EApp (EVar "node") (ELit (LString "child-path"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "childPath"))))) (EApp (EVar "roleSexp") (EVar "role")))))) (EVar "nodeId")))
(DTypeSig true "stableNodeIdErrorToSexp" (TyFun (TyCon "StableNodeIdError") (TyCon "String")))
(DFunDef false "stableNodeIdErrorToSexp" ((PVar "err")) (EApp (EApp (EVar "node") (ELit (LString "stable-node-id-error"))) (EListLit (EApp (EVar "errorSexp") (EVar "err")))))
