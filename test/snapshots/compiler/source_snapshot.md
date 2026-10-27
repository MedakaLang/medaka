# META
source_lines=19
stages=DESUGAR,MARK
# SOURCE
import support.source_index.{SourceIndex, indexSource}

public export data SourceSnapshot =
  SourceSnapshot String (Option Int) String SourceIndex
public export data SnapshotId = SnapshotId String (Option Int) String

export
makeSnapshot : String -> Option Int -> String -> SourceSnapshot
makeSnapshot uri version text =
  SourceSnapshot uri version text (indexSource text)

export
snapshotId : SourceSnapshot -> SnapshotId
snapshotId (SourceSnapshot uri version text _) = SnapshotId uri version text

export
matchesSnapshot : SnapshotId -> SourceSnapshot -> Bool
matchesSnapshot (SnapshotId uri version text) (SourceSnapshot u v t _) =
  uri == u && version == v && text == t
# DESUGAR
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "SourceSnapshot")))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "text")) (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") (PVar "version") (PVar "text") PWild)) (EApp (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "version")) (EVar "text")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "version") (PVar "text")) (PCon "SourceSnapshot" (PVar "u") (PVar "v") (PVar "t") PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "version") (EVar "v"))) (EBinOp "==" (EVar "text") (EVar "t"))))
# MARK
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "SourceSnapshot")))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "text")) (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") (PVar "version") (PVar "text") PWild)) (EApp (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "version")) (EVar "text")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "version") (PVar "text")) (PCon "SourceSnapshot" (PVar "u") (PVar "v") (PVar "t") PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "version") (EVar "v"))) (EBinOp "==" (EVar "text") (EVar "t"))))
