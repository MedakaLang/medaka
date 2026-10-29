# META
source_lines=79
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_recovery.{
  RecoveryLimits, defaultRecoveryLimits, budgetResult
}
import frontend.syntax_source.{
  SyntaxSource, SyntaxAdmission(..), publishSyntax, syntaxIndex, syntaxRecovered
}
import frontend.recovery_result.{RecoveredSource}
import tools.source_snapshot.{
  SourceRevision(..),
  SourceSnapshot(..),
  SnapshotId(..),
  revisionId,
}

public export data SnapshotMismatch = SnapshotMismatch SnapshotId SnapshotId
export data SnapshotSyntax =
  SnapshotSyntax SnapshotId (Option Int) RecoveredSource
export data PreparedSyntax =
  PreparedSyntax (Option SourceSnapshot) SnapshotSyntax (Option SyntaxSource)

public export data ParseOptions = ParseOptions RecoveryLimits

export
defaultParseOptions : ParseOptions
defaultParseOptions = ParseOptions defaultRecoveryLimits

export
parseSnapshotSyntax : SourceRevision -> PreparedSyntax
parseSnapshotSyntax = prepareSnapshotSyntax defaultParseOptions

export
prepareSnapshotSyntax : ParseOptions -> SourceRevision -> PreparedSyntax
prepareSnapshotSyntax (ParseOptions limits) (revision@(SourceRevision uri version generation text)) =
  match publishSyntax limits text
    Err admission =>
      let count = match admission
        SourceLimit _ => 0
        TokenLimit n => n
      PreparedSyntax
        None
        (SnapshotSyntax (revisionId revision) version (budgetResult text count))
        None
    Ok syntax =>
      PreparedSyntax
        (Some (SourceSnapshot uri version generation text (syntaxIndex syntax)))
        (SnapshotSyntax (revisionId revision) version (syntaxRecovered syntax))
        (Some syntax)

export
snapshotSyntaxSource : PreparedSyntax -> Option SyntaxSource
snapshotSyntaxSource (PreparedSyntax _ _ syntax) = syntax

export
snapshotSyntaxId : PreparedSyntax -> SnapshotId
snapshotSyntaxId (PreparedSyntax _ (SnapshotSyntax id _ _) _) = id

export
snapshotSyntaxVersion : PreparedSyntax -> Option Int
snapshotSyntaxVersion (PreparedSyntax _ (SnapshotSyntax _ version _) _) =
  version

export
snapshotSyntaxResult : PreparedSyntax -> RecoveredSource
snapshotSyntaxResult (PreparedSyntax _ (SnapshotSyntax _ _ result) _) = result

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
snapshotSyntaxSnapshot (PreparedSyntax snapshot _ _) = snapshot
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" false) (mem "defaultRecoveryLimits" false) (mem "budgetResult" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SyntaxSource" false) (mem "SyntaxAdmission" true) (mem "publishSyntax" false) (mem "syntaxIndex" false) (mem "syntaxRecovered" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))) ())
(DData Public "ParseOptions" () ((variant "ParseOptions" (ConPos (TyCon "RecoveryLimits")))) ())
(DTypeSig true "defaultParseOptions" (TyCon "ParseOptions"))
(DFunDef false "defaultParseOptions" () (EApp (EVar "ParseOptions") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntax") (EVar "defaultParseOptions")))
(DTypeSig true "prepareSnapshotSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax"))))
(DFunDef false "prepareSnapshotSyntax" ((PCon "ParseOptions" (PVar "limits")) (PAs "revision" (PCon "SourceRevision" (PVar "uri") (PVar "version") (PVar "generation") (PVar "text")))) (EMatch (EApp (EApp (EVar "publishSyntax") (EVar "limits")) (EVar "text")) (arm (PCon "Err" (PVar "admission")) () (EBlock (DoLet false false (PVar "count") (EMatch (EVar "admission") (arm (PCon "SourceLimit" PWild) () (ELit (LInt 0))) (arm (PCon "TokenLimit" (PVar "n")) () (EVar "n")))) (DoExpr (EApp (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "budgetResult") (EVar "text")) (EVar "count")))) (EVar "None"))))) (arm (PCon "Ok" (PVar "syntax")) () (EApp (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "syntaxIndex") (EVar "syntax"))))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EVar "syntaxRecovered") (EVar "syntax")))) (EApp (EVar "Some") (EVar "syntax"))))))
(DTypeSig true "snapshotSyntaxSource" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))
(DFunDef false "snapshotSyntaxSource" ((PCon "PreparedSyntax" PWild PWild (PVar "syntax"))) (EVar "syntax"))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "PreparedSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" (PVar "id") PWild PWild) PWild)) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild (PVar "version") PWild) PWild)) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "PreparedSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild PWild (PVar "result")) PWild)) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceRevision") (TyFun (TyCon "PreparedSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild PWild)) (PVar "syntax")) (EMatch (ETuple (EApp (EVar "revisionId") (EVar "revision")) (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (arm (PTuple (PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SnapshotId" (PVar "otherUri") (PVar "otherGeneration"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "otherUri")) (EBinOp "==" (EVar "generation") (EVar "otherGeneration"))) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
(DTypeSig true "snapshotSyntaxSnapshot" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SourceSnapshot"))))
(DFunDef false "snapshotSyntaxSnapshot" ((PCon "PreparedSyntax" (PVar "snapshot") PWild PWild)) (EVar "snapshot"))
# MARK
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" false) (mem "defaultRecoveryLimits" false) (mem "budgetResult" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SyntaxSource" false) (mem "SyntaxAdmission" true) (mem "publishSyntax" false) (mem "syntaxIndex" false) (mem "syntaxRecovered" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))) ())
(DData Public "ParseOptions" () ((variant "ParseOptions" (ConPos (TyCon "RecoveryLimits")))) ())
(DTypeSig true "defaultParseOptions" (TyCon "ParseOptions"))
(DFunDef false "defaultParseOptions" () (EApp (EVar "ParseOptions") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntax") (EVar "defaultParseOptions")))
(DTypeSig true "prepareSnapshotSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax"))))
(DFunDef false "prepareSnapshotSyntax" ((PCon "ParseOptions" (PVar "limits")) (PAs "revision" (PCon "SourceRevision" (PVar "uri") (PVar "version") (PVar "generation") (PVar "text")))) (EMatch (EApp (EApp (EVar "publishSyntax") (EVar "limits")) (EVar "text")) (arm (PCon "Err" (PVar "admission")) () (EBlock (DoLet false false (PVar "count") (EMatch (EVar "admission") (arm (PCon "SourceLimit" PWild) () (ELit (LInt 0))) (arm (PCon "TokenLimit" (PVar "n")) () (EVar "n")))) (DoExpr (EApp (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "budgetResult") (EVar "text")) (EDictApp "count")))) (EVar "None"))))) (arm (PCon "Ok" (PVar "syntax")) () (EApp (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "syntaxIndex") (EVar "syntax"))))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EVar "syntaxRecovered") (EVar "syntax")))) (EApp (EVar "Some") (EVar "syntax"))))))
(DTypeSig true "snapshotSyntaxSource" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))
(DFunDef false "snapshotSyntaxSource" ((PCon "PreparedSyntax" PWild PWild (PVar "syntax"))) (EVar "syntax"))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "PreparedSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" (PVar "id") PWild PWild) PWild)) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild (PVar "version") PWild) PWild)) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "PreparedSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "PreparedSyntax" PWild (PCon "SnapshotSyntax" PWild PWild (PVar "result")) PWild)) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceRevision") (TyFun (TyCon "PreparedSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PAs "revision" (PCon "SourceRevision" PWild (PVar "version") PWild PWild)) (PVar "syntax")) (EMatch (ETuple (EApp (EVar "revisionId") (EVar "revision")) (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (arm (PTuple (PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SnapshotId" (PVar "otherUri") (PVar "otherGeneration"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "otherUri")) (EBinOp "==" (EVar "generation") (EVar "otherGeneration"))) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
(DTypeSig true "snapshotSyntaxSnapshot" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyCon "SourceSnapshot"))))
(DFunDef false "snapshotSyntaxSnapshot" ((PCon "PreparedSyntax" (PVar "snapshot") PWild PWild)) (EVar "snapshot"))
