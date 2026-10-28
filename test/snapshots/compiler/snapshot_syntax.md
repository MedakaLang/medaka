# META
source_lines=58
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_recovery.{
  parseRecoveringWithIndex, defaultRecoveryAdmission
}
import frontend.recovery_result.{RecoveredSource}
import tools.source_snapshot.{
  SourceRevision(..), SourceSnapshot(..), SnapshotId(..), revisionId,
  snapshotFromRevision
}

public export data SnapshotMismatch = SnapshotMismatch SnapshotId SnapshotId
export data SnapshotSyntax =
  SnapshotSyntax SnapshotId (Option Int) RecoveredSource
export data PreparedSyntax =
  PreparedSyntax (Option SourceSnapshot) SnapshotSyntax

export
parseSnapshotSyntax : SourceRevision -> PreparedSyntax
parseSnapshotSyntax (revision@(SourceRevision _ version _ text)) =
  match defaultRecoveryAdmission text
    Some result =>
      PreparedSyntax None (SnapshotSyntax (revisionId revision) version result)
    None =>
      let snapshot = snapshotFromRevision revision
      match snapshot
        SourceSnapshot _ _ _ _ index =>
          PreparedSyntax
            (Some snapshot)
            (SnapshotSyntax
              (revisionId revision)
              version
              (parseRecoveringWithIndex index text))

export
snapshotSyntaxId : PreparedSyntax -> SnapshotId
snapshotSyntaxId (PreparedSyntax _ (SnapshotSyntax id _ _)) = id

export
snapshotSyntaxVersion : PreparedSyntax -> Option Int
snapshotSyntaxVersion (PreparedSyntax _ (SnapshotSyntax _ version _)) = version

export
snapshotSyntaxResult : PreparedSyntax -> RecoveredSource
snapshotSyntaxResult (PreparedSyntax _ (SnapshotSyntax _ _ result)) = result

export
snapshotSyntaxMatches : SourceRevision -> PreparedSyntax -> Bool
snapshotSyntaxMatches (revision@(SourceRevision _ version _ _)) syntax = match (
  revisionId revision,
  snapshotSyntaxId syntax,
)
  (SnapshotId uri generation, SnapshotId otherUri otherGeneration) =>
    uri == otherUri
      && generation == otherGeneration
      && version == snapshotSyntaxVersion syntax

export
snapshotSyntaxSnapshot : PreparedSyntax -> Option SourceSnapshot
snapshotSyntaxSnapshot (PreparedSyntax snapshot _) = snapshot
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "parseRecoveringWithIndex" false) (mem "defaultRecoveryAdmission" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false) (mem "snapshotFromRevision" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax")))) ())
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild (PVar "text")))) (EMatch (EApp (EVar "defaultRecoveryAdmission") (EVar "text")) (arm (PCon "Some" (PVar "result")) () (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EVar "result")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "snapshot") (EApp (EVar "snapshotFromRevision") (EVar "revision"))) (DoExpr (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index")) () (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EVar "snapshot"))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "parseRecoveringWithIndex") (EVar "index")) (EVar "text")))))))))))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "PreparedSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" (PVar "id") PWild PWild))) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild (PVar "version") PWild))) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "PreparedSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild PWild (PVar "result")))) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceRevision") (TyFun (TyCon "PreparedSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild PWild)) (PVar "syntax")) (EMatch (ETuple (EApp (EVar "revisionId") (EVar "revision")) (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (arm (PTuple (PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SnapshotId" (PVar "otherUri") (PVar "otherGeneration"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "otherUri")) (EBinOp "==" (EVar "generation") (EVar "otherGeneration"))) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
(DTypeSig true "snapshotSyntaxSnapshot" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SourceSnapshot"))))
(DFunDef false "snapshotSyntaxSnapshot" ((PCon "PreparedSyntax" (PVar "snapshot") PWild)) (EVar "snapshot"))
# MARK
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "parseRecoveringWithIndex" false) (mem "defaultRecoveryAdmission" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false) (mem "snapshotFromRevision" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax")))) ())
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild (PVar "text")))) (EMatch (EApp (EVar "defaultRecoveryAdmission") (EVar "text")) (arm (PCon "Some" (PVar "result")) () (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EVar "result")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "snapshot") (EApp (EVar "snapshotFromRevision") (EVar "revision"))) (DoExpr (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index")) () (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EVar "snapshot"))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "parseRecoveringWithIndex") (EMethodRef "index")) (EVar "text")))))))))))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "PreparedSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" (PVar "id") PWild PWild))) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild (PVar "version") PWild))) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "PreparedSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild PWild (PVar "result")))) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceRevision") (TyFun (TyCon "PreparedSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild PWild)) (PVar "syntax")) (EMatch (ETuple (EApp (EVar "revisionId") (EVar "revision")) (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (arm (PTuple (PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SnapshotId" (PVar "otherUri") (PVar "otherGeneration"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "otherUri")) (EBinOp "==" (EVar "generation") (EVar "otherGeneration"))) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
(DTypeSig true "snapshotSyntaxSnapshot" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SourceSnapshot"))))
(DFunDef false "snapshotSyntaxSnapshot" ((PCon "PreparedSyntax" (PVar "snapshot") PWild)) (EVar "snapshot"))
