# META
source_lines=53
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_recovery.{parseRecoveringWithIndex}
import frontend.recovery_result.{RecoveredSource}
import support.source_index.{SourceIndex, indexSource}

public export data SourceSnapshot =
  SourceSnapshot String (Option Int) Int String SourceIndex
public export data SnapshotId = SnapshotId String Int

export
makeSnapshot : String -> Option Int -> Int -> String -> SourceSnapshot
makeSnapshot uri version generation text =
  SourceSnapshot uri version generation text (indexSource text)

export
snapshotId : SourceSnapshot -> SnapshotId
snapshotId (SourceSnapshot uri _ generation _ _) = SnapshotId uri generation

export
matchesSnapshot : SnapshotId -> SourceSnapshot -> Bool
matchesSnapshot (SnapshotId uri generation) (SourceSnapshot u _ g _ _) =
  uri == u && generation == g

export data SnapshotSyntax =
  SnapshotSyntax SnapshotId (Option Int) RecoveredSource
public export data SnapshotMismatch = SnapshotMismatch SnapshotId SnapshotId

export
parseSnapshotSyntax : SourceSnapshot -> SnapshotSyntax
parseSnapshotSyntax snapshot = match snapshot
  SourceSnapshot _ version _ text index =>
    SnapshotSyntax
      (snapshotId snapshot)
      version
      (parseRecoveringWithIndex index text)

export
snapshotSyntaxId : SnapshotSyntax -> SnapshotId
snapshotSyntaxId (SnapshotSyntax id _ _) = id

export
snapshotSyntaxVersion : SnapshotSyntax -> Option Int
snapshotSyntaxVersion (SnapshotSyntax _ version _) = version

export
snapshotSyntaxResult : SnapshotSyntax -> RecoveredSource
snapshotSyntaxResult (SnapshotSyntax _ _ result) = result

export
snapshotSyntaxMatches : SourceSnapshot -> SnapshotSyntax -> Bool
snapshotSyntaxMatches snapshot syntax = match snapshot
  SourceSnapshot _ version _ _ _ =>
    matchesSnapshot (snapshotSyntaxId syntax) snapshot
      && version == snapshotSyntaxVersion syntax
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "parseRecoveringWithIndex" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int") (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SourceSnapshot"))))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "generation") (PVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") PWild (PVar "generation") PWild PWild)) (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SourceSnapshot" (PVar "u") PWild (PVar "g") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "generation") (EVar "g"))))
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotSyntax")))
(DFunDef false "parseSnapshotSyntax" ((PVar "snapshot")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild (PVar "version") PWild (PVar "text") (PVar "index")) () (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "snapshotId") (EVar "snapshot"))) (EVar "version")) (EApp (EApp (EVar "parseRecoveringWithIndex") (EVar "index")) (EVar "text"))))))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "SnapshotSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "SnapshotSyntax" (PVar "id") PWild PWild)) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "SnapshotSyntax" PWild (PVar "version") PWild)) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "SnapshotSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "SnapshotSyntax" PWild PWild (PVar "result"))) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "SnapshotSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PVar "snapshot") (PVar "syntax")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild (PVar "version") PWild PWild PWild) () (EBinOp "&&" (EApp (EApp (EVar "matchesSnapshot") (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (EVar "snapshot")) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
# MARK
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "parseRecoveringWithIndex" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int") (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SourceSnapshot"))))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "generation") (PVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") PWild (PVar "generation") PWild PWild)) (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SourceSnapshot" (PVar "u") PWild (PVar "g") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "generation") (EVar "g"))))
(DData Abstract "SnapshotSyntax" () ((variant "SnapshotSyntax" (ConPos (TyCon "SnapshotId") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "RecoveredSource")))) ())
(DData Public "SnapshotMismatch" () ((variant "SnapshotMismatch" (ConPos (TyCon "SnapshotId") (TyCon "SnapshotId")))) ())
(DTypeSig true "parseSnapshotSyntax" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotSyntax")))
(DFunDef false "parseSnapshotSyntax" ((PVar "snapshot")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild (PVar "version") PWild (PVar "text") (PVar "index")) () (EApp (EApp (EApp (EVar "SnapshotSyntax") (EApp (EVar "snapshotId") (EVar "snapshot"))) (EVar "version")) (EApp (EApp (EVar "parseRecoveringWithIndex") (EMethodRef "index")) (EVar "text"))))))
(DTypeSig true "snapshotSyntaxId" (TyFun (TyCon "SnapshotSyntax") (TyCon "SnapshotId")))
(DFunDef false "snapshotSyntaxId" ((PCon "SnapshotSyntax" (PVar "id") PWild PWild)) (EVar "id"))
(DTypeSig true "snapshotSyntaxVersion" (TyFun (TyCon "SnapshotSyntax") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "snapshotSyntaxVersion" ((PCon "SnapshotSyntax" PWild (PVar "version") PWild)) (EVar "version"))
(DTypeSig true "snapshotSyntaxResult" (TyFun (TyCon "SnapshotSyntax") (TyCon "RecoveredSource")))
(DFunDef false "snapshotSyntaxResult" ((PCon "SnapshotSyntax" PWild PWild (PVar "result"))) (EVar "result"))
(DTypeSig true "snapshotSyntaxMatches" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "SnapshotSyntax") (TyCon "Bool"))))
(DFunDef false "snapshotSyntaxMatches" ((PVar "snapshot") (PVar "syntax")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild (PVar "version") PWild PWild PWild) () (EBinOp "&&" (EApp (EApp (EVar "matchesSnapshot") (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (EVar "snapshot")) (EBinOp "==" (EVar "version") (EApp (EVar "snapshotSyntaxVersion") (EVar "syntax")))))))
