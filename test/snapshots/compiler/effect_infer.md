# META
source_lines=22
stages=DESUGAR,MARK
# SOURCE
-- Scoped effect collection. A capture observes performed rows without solving
-- them; inference allowances and signature constraints belong to the checker.
import types.effect_rows.{EffRow(..), Effvar, collectRows}
import support.util.{reverseL}

export
recordEffect : Ref (List EffRow) -> EffRow -> Unit
recordEffect _ (EffRow [] None) = ()
recordEffect ambient row = ambient := row :: !ambient

export
captureEffects : Ref (List EffRow) ->
  (List (Ref Effvar) -> Ref Effvar) ->
  (Unit -> a) ->
  (a, EffRow)
captureEffects ambient makeJoin body =
  let saved = !ambient
  ambient := []
  let result = body ()
  let performed = collectRows makeJoin (reverseL !ambient)
  ambient := saved
  (result, performed)
# DESUGAR
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" false) (mem "collectRows" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
# MARK
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" false) (mem "collectRows" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
