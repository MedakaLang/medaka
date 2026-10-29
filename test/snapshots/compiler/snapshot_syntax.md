# META
source_lines=98
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Decl}
import frontend.parse_recovery.{
  RecoveryLimits, defaultRecoveryLimits, budgetResult
}
import frontend.syntax_source.{
  SyntaxSource, SyntaxAdmission(..), publishSyntax,
  publishSyntaxWithCheckedDecls, syntaxIndex, syntaxRecovered
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

public export data ParseOptions = ParseOptions RecoveryLimits deriving (Eq)

export
defaultParseOptions : ParseOptions
defaultParseOptions = ParseOptions defaultRecoveryLimits

export
parseSnapshotSyntax : SourceRevision -> PreparedSyntax
parseSnapshotSyntax = prepareSnapshotSyntax defaultParseOptions

export
prepareSnapshotSyntax : ParseOptions -> SourceRevision -> PreparedSyntax
prepareSnapshotSyntax = prepareSnapshotSyntaxKnown None

export
prepareSnapshotSyntaxWithCheckedDecls : ParseOptions ->
  SourceRevision ->
  List Decl ->
  PreparedSyntax
prepareSnapshotSyntaxWithCheckedDecls options revision decls =
  prepareSnapshotSyntaxKnown (Some decls) options revision

prepareSnapshotSyntaxKnown : Option (List Decl) ->
  ParseOptions ->
  SourceRevision ->
  PreparedSyntax
prepareSnapshotSyntaxKnown known (ParseOptions limits) (revision@(SourceRevision uri version generation text)) =
  let publication = match known
    None => publishSyntax limits text
    Some decls => publishSyntaxWithCheckedDecls limits text decls
  match publication
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" false) (mem "defaultRecoveryLimits" false) (mem "budgetResult" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SyntaxSource" false) (mem "SyntaxAdmission" true) (mem "publishSyntax" false) (mem "publishSyntaxWithCheckedDecls" false) (mem "syntaxIndex" false) (mem "syntaxRecovered" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))) ())
(DData Public "ParseOptions" () ((variant "ParseOptions" (ConPos (TyCon "RecoveryLimits")))) ())
(DImpl true "Eq" ((TyCon "ParseOptions")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ParseOptions" (PVar "__a0")) (PCon "ParseOptions" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DTypeSig true "defaultParseOptions" (TyCon "ParseOptions"))
(DFunDef false "defaultParseOptions" () (EApp (EVar "ParseOptions") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntax") (EVar "defaultParseOptions")))
(DTypeSig true "prepareSnapshotSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax"))))
(DFunDef false "prepareSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntaxKnown") (EVar "None")))
(DTypeSig true "prepareSnapshotSyntaxWithCheckedDecls" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PreparedSyntax")))))
(DFunDef false "prepareSnapshotSyntaxWithCheckedDecls" ((PVar "options") (PVar "revision") (PVar "decls")) (EApp (EApp (EApp (EVar "prepareSnapshotSyntaxKnown") (EApp (EVar "Some") (EVar "decls"))) (EVar "options")) (EVar "revision")))
(DTypeSig false "prepareSnapshotSyntaxKnown" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))))
(DFunDef false "prepareSnapshotSyntaxKnown" ((PVar "known") (PCon "ParseOptions" (PVar "limits")) (PAs "revision" (PCon "SourceRevision" (PVar "uri") (PVar "version") (PVar "generation") (PVar "text")))) (EBlock (DoLet false false (PVar "publication") (EMatch (EVar "known") (arm (PCon "None") () (EApp (EApp (EVar "publishSyntax") (EVar "limits")) (EVar "text"))) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EApp (EVar "publishSyntaxWithCheckedDecls") (EVar "limits")) (EVar "text")) (EVar "decls"))))) (DoExpr (EMatch (EVar "publication") (arm (PCon "Err" (PVar "admission")) () (EBlock (DoLet false false (PVar "count") (EMatch (EVar "admission") (arm (PCon "SourceLimit" PWild) () (ELit (LInt 0))) (arm (PCon "TokenLimit" (PVar "n")) () (EVar "n")))) (DoExpr (EApp (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "budgetResult") (EVar "text")) (EVar "count")))) (EVar "None"))))) (arm (PCon "Ok" (PVar "syntax")) () (EApp (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "syntaxIndex") (EVar "syntax"))))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EVar "syntaxRecovered") (EVar "syntax")))) (EApp (EVar "Some") (EVar "syntax"))))))))
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" false) (mem "defaultRecoveryLimits" false) (mem "budgetResult" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SyntaxSource" false) (mem "SyntaxAdmission" true) (mem "publishSyntax" false) (mem "publishSyntaxWithCheckedDecls" false) (mem "syntaxIndex" false) (mem "syntaxRecovered" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceRevision" true) (mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "revisionId" false))))
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Abstract "PreparedSyntax" () ((variant "PreparedSyntax" (ConPos (TyApp (TyCon "Option") (TyCon "SourceSnapshot")) (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "SyntaxSource"))))) ())
(DData Public "ParseOptions" () ((variant "ParseOptions" (ConPos (TyCon "RecoveryLimits")))) ())
(DImpl true "Eq" ((TyCon "ParseOptions")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ParseOptions" (PVar "__a0")) (PCon "ParseOptions" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DTypeSig true "defaultParseOptions" (TyCon "ParseOptions"))
(DFunDef false "defaultParseOptions" () (EApp (EVar "ParseOptions") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))
(DFunDef false "parseSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntax") (EVar "defaultParseOptions")))
(DTypeSig true "prepareSnapshotSyntax" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax"))))
(DFunDef false "prepareSnapshotSyntax" () (EApp (EVar "prepareSnapshotSyntaxKnown") (EVar "None")))
(DTypeSig true "prepareSnapshotSyntaxWithCheckedDecls" (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PreparedSyntax")))))
(DFunDef false "prepareSnapshotSyntaxWithCheckedDecls" ((PVar "options") (PVar "revision") (PVar "decls")) (EApp (EApp (EApp (EVar "prepareSnapshotSyntaxKnown") (EApp (EVar "Some") (EVar "decls"))) (EVar "options")) (EVar "revision")))
(DTypeSig false "prepareSnapshotSyntaxKnown" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "ParseOptions") (TyFun (TyCon "SourceRevision") (TyCon "PreparedSyntax")))))
(DFunDef false "prepareSnapshotSyntaxKnown" ((PVar "known") (PCon "ParseOptions" (PVar "limits")) (PAs "revision" (PCon "SourceRevision" (PVar "uri") (PVar "version") (PVar "generation") (PVar "text")))) (EBlock (DoLet false false (PVar "publication") (EMatch (EVar "known") (arm (PCon "None") () (EApp (EApp (EVar "publishSyntax") (EVar "limits")) (EVar "text"))) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EApp (EVar "publishSyntaxWithCheckedDecls") (EVar "limits")) (EVar "text")) (EVar "decls"))))) (DoExpr (EMatch (EVar "publication") (arm (PCon "Err" (PVar "admission")) () (EBlock (DoLet false false (PVar "count") (EMatch (EVar "admission") (arm (PCon "SourceLimit" PWild) () (ELit (LInt 0))) (arm (PCon "TokenLimit" (PVar "n")) () (EVar "n")))) (DoExpr (EApp (EApp (EApp (EVar "PreparedSyntax") (EVar "None")) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EApp (EVar "budgetResult") (EVar "text")) (EDictApp "count")))) (EVar "None"))))) (arm (PCon "Ok" (PVar "syntax")) () (EApp (EApp (EApp (EVar "PreparedSyntax") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "syntaxIndex") (EVar "syntax"))))) (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "revisionId") (EVar "revision"))) (EVar "version")) (EApp (EVar "syntaxRecovered") (EVar "syntax")))) (EApp (EVar "Some") (EVar "syntax"))))))))
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
