# META
source_lines=19
stages=DESUGAR,MARK
# SOURCE
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
# DESUGAR
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int") (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SourceSnapshot"))))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "generation") (PVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") PWild (PVar "generation") PWild PWild)) (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SourceSnapshot" (PVar "u") PWild (PVar "g") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "generation") (EVar "g"))))
# MARK
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSnapshot" () ((variant "SourceSnapshot" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int") (TyCon "String") (TyCon "SourceIndex")))) ())
(DData Public "SnapshotId" () ((variant "SnapshotId" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "makeSnapshot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SourceSnapshot"))))))
(DFunDef false "makeSnapshot" ((PVar "uri") (PVar "version") (PVar "generation") (PVar "text")) (EApp (EApp (EApp (EApp (EApp (EVar "SourceSnapshot") (EVar "uri")) (EVar "version")) (EVar "generation")) (EVar "text")) (EApp (EVar "indexSource") (EVar "text"))))
(DTypeSig true "snapshotId" (TyFun (TyCon "SourceSnapshot") (TyCon "SnapshotId")))
(DFunDef false "snapshotId" ((PCon "SourceSnapshot" (PVar "uri") PWild (PVar "generation") PWild PWild)) (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation")))
(DTypeSig true "matchesSnapshot" (TyFun (TyCon "SnapshotId") (TyFun (TyCon "SourceSnapshot") (TyCon "Bool"))))
(DFunDef false "matchesSnapshot" ((PCon "SnapshotId" (PVar "uri") (PVar "generation")) (PCon "SourceSnapshot" (PVar "u") PWild (PVar "g") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "uri") (EVar "u")) (EBinOp "==" (EVar "generation") (EVar "g"))))
