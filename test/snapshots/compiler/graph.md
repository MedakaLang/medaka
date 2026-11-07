# META
source_lines=19
stages=DESUGAR,MARK
# SOURCE
-- Worklist closure over a `HashMap String (List String)` graph, shared by wasm_reach and test_runner.

import hash_map.{HashMap, setInPlace, has, findWithDefault}

-- Marks in [seen] every key reachable from [xs0] in [graph] (a worklist walk: a key
-- already in [seen] is skipped, so each is expanded once).
export
markReachable : HashMap String (List String) ->
  HashMap String Unit ->
  List String ->
  Unit
markReachable graph seen xs0 = go xs0
  where
    go [] = ()
    go (w :: work)
      | has w seen = go work
      | otherwise =
        setInPlace w () seen
        go (findWithDefault [] w graph ++ work)
# DESUGAR
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "markReachable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "markReachable" ((PVar "graph") (PVar "seen") (PVar "xs0")) (ELetGroup ((lgb "go" (clause ((PList)) (ELit LUnit)) (clause ((PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EVar "go") (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EVar "go") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EVar "go") (EVar "xs0"))))
# MARK
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "markReachable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "markReachable" ((PVar "graph") (PVar "seen") (PVar "xs0")) (ELetGroup ((lgb "go" (clause ((PList)) (ELit LUnit)) (clause ((PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EVar "go") (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EVar "go") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EVar "go") (EVar "xs0"))))
