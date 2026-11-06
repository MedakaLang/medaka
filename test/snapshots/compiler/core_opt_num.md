# META
source_lines=22
stages=DESUGAR,MARK
# SOURCE
import ir.core_ir.{CExpr(..), CProgram(..), MethodEvidence(..)}
import ir.core_walk.{rewriteProgram}
import types.route_key.{numIntWord}
import frontend.ast.{Route(..)}
-- Core IR optimization over numeric method occurrences.
--
-- `fold-num-int-fromint`: `Num Int`'s own `fromInt` is the identity (`stdlib/core.mdk`
-- defines it `fromInt x = x`, on a word that is already a tagged Int), so a saturated
-- application routed to that impl is its argument.  The witness is the route's own
-- word, never the argument's shape: `fromInt` at `Float` or at a user `impl Num` is a
-- real conversion and keeps its call.  Empty prerequisite and context routes are
-- required rather than assumed, so any other evidence shape is left alone.

-- Replace every saturated `fromInt` at `Num Int` by its argument.
export
foldNumIntFromInt : CProgram -> CProgram
foldNumIntFromInt = rewriteProgram foldNode

foldNode : CExpr -> CExpr
foldNode (CApp (CMethod "fromInt" (MethodEvidence _ _ (RKey word [] _) [] [])) (a :: []) _)
  | word == numIntWord = a
foldNode e = e
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CProgram" true) (mem "MethodEvidence" true))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "rewriteProgram" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "numIntWord" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DTypeSig true "foldNumIntFromInt" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "foldNumIntFromInt" () (EApp (EVar "rewriteProgram") (EVar "foldNode")))
(DTypeSig false "foldNode" (TyFun (TyCon "CExpr") (TyCon "CExpr")))
(DFunDef false "foldNode" ((PCon "CApp" (PCon "CMethod" (PLit (LString "fromInt")) (PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") (PList) PWild) (PList) (PList))) (PCons (PVar "a") (PList)) PWild)) (EIf (EBinOp "==" (EVar "word") (EVar "numIntWord")) (EVar "a") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "foldNode" ((PVar "e")) (EVar "e"))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CProgram" true) (mem "MethodEvidence" true))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "rewriteProgram" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "numIntWord" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DTypeSig true "foldNumIntFromInt" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "foldNumIntFromInt" () (EApp (EVar "rewriteProgram") (EVar "foldNode")))
(DTypeSig false "foldNode" (TyFun (TyCon "CExpr") (TyCon "CExpr")))
(DFunDef false "foldNode" ((PCon "CApp" (PCon "CMethod" (PLit (LString "fromInt")) (PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") (PList) PWild) (PList) (PList))) (PCons (PVar "a") (PList)) PWild)) (EIf (EBinOp "==" (EVar "word") (EVar "numIntWord")) (EVar "a") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "foldNode" ((PVar "e")) (EVar "e"))
