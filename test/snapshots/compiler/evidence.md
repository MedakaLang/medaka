# META
source_lines=33
stages=DESUGAR,MARK
# SOURCE
-- Request-owned identities and semantic evidence for the scoped solver.
--
-- These identities are nominal even where an ordinal would currently suffice:
-- callers cannot accidentally exchange a goal, scope, evidence binder, instance,
-- or destination merely because two of them were allocated at the same count.
-- `RequestInstanceId` is deliberately request-local.  It is not a stable cache
-- identity and must not be persisted across typechecking requests.

import frontend.ast.{EvId}
import types.repr.{Mono}

public export data GoalId = GoalId String Int deriving (Eq, Ord, Debug)

public export data ScopeId = ScopeId Int deriving (Eq, Ord, Debug)

-- The owning scope is part of a formal evidence binder's identity.  Generated
-- dictionary names are later renderings of this value, never scope keys.
public export data EvidenceBinderId =
  | EvidenceBinderId ScopeId Int
  deriving (Eq, Ord, Debug)

public export data RequestInstanceId =
  | RequestInstanceId Int
  deriving (Eq, Ord, Debug)

-- Request evidence forms a DAG: prerequisite and superclass edges name other
-- request nodes by `EvId`.  No constructor embeds a recursively copied proof
-- tree.  `Mono` is permitted here because this value is request-owned; a later
-- frozen contract must translate it to immutable templates before publication.
public export data SolverEvidence =
  | GivenEvidence EvidenceBinderId
  | InstanceEvidence RequestInstanceId (List Mono) (List EvId)
  | SuperclassEvidence EvId (List Int)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DData Public "GoalId" () ((variant "GoalId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "GoalId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "GoalId" (PVar "__a0") (PVar "__a1")) (PCon "GoalId" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "GoalId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "GoalId" (PVar "__a0") (PVar "__a1")) (PCon "GoalId" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "GoalId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "GoalId" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "GoalId ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "ScopeId" () ((variant "ScopeId" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "ScopeId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ScopeId" (PVar "__a0")) (PCon "ScopeId" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "ScopeId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ScopeId" (PVar "__a0")) (PCon "ScopeId" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "ScopeId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ScopeId" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ScopeId ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "EvidenceBinderId" () ((variant "EvidenceBinderId" (ConPos (TyCon "ScopeId") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "EvidenceBinderId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) (PCon "EvidenceBinderId" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "EvidenceBinderId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) (PCon "EvidenceBinderId" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "EvidenceBinderId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "EvidenceBinderId ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "RequestInstanceId" () ((variant "RequestInstanceId" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RequestInstanceId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RequestInstanceId" (PVar "__a0")) (PCon "RequestInstanceId" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "RequestInstanceId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RequestInstanceId" (PVar "__a0")) (PCon "RequestInstanceId" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "RequestInstanceId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RequestInstanceId" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RequestInstanceId ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "SolverEvidence" () ((variant "GivenEvidence" (ConPos (TyCon "EvidenceBinderId"))) (variant "InstanceEvidence" (ConPos (TyCon "RequestInstanceId") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "EvId")))) (variant "SuperclassEvidence" (ConPos (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EvId" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DData Public "GoalId" () ((variant "GoalId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "GoalId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "GoalId" (PVar "__a0") (PVar "__a1")) (PCon "GoalId" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "GoalId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "GoalId" (PVar "__a0") (PVar "__a1")) (PCon "GoalId" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "GoalId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "GoalId" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "GoalId ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "ScopeId" () ((variant "ScopeId" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "ScopeId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ScopeId" (PVar "__a0")) (PCon "ScopeId" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "ScopeId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ScopeId" (PVar "__a0")) (PCon "ScopeId" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "ScopeId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ScopeId" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ScopeId ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "EvidenceBinderId" () ((variant "EvidenceBinderId" (ConPos (TyCon "ScopeId") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "EvidenceBinderId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) (PCon "EvidenceBinderId" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "EvidenceBinderId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) (PCon "EvidenceBinderId" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "EvidenceBinderId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "EvidenceBinderId" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "EvidenceBinderId ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "RequestInstanceId" () ((variant "RequestInstanceId" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RequestInstanceId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RequestInstanceId" (PVar "__a0")) (PCon "RequestInstanceId" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "RequestInstanceId")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RequestInstanceId" (PVar "__a0")) (PCon "RequestInstanceId" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "RequestInstanceId")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RequestInstanceId" (PVar "__a0")) () (EBinOp "++" (ELit (LString "RequestInstanceId ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "SolverEvidence" () ((variant "GivenEvidence" (ConPos (TyCon "EvidenceBinderId"))) (variant "InstanceEvidence" (ConPos (TyCon "RequestInstanceId") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "EvId")))) (variant "SuperclassEvidence" (ConPos (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Int"))))) ())
