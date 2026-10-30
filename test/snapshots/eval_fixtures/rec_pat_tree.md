# META
source_lines=21
stages=CORE_IR
# SOURCE
-- record patterns through the decision tree (PRec arms with fall-through)
data Vec = { dx : Int, dy : Int }

magnitude v = v.dx * v.dx + v.dy * v.dy

-- multi-arm record match: specific field-value arms fall through in the tree
axis v = match v
  Vec { dx = 0, dy } => dy
  Vec { dx, dy = 0 } => dx
  Vec { dx, dy } => dx + dy

main =
  let up = Vec { dx = 0, dy = 5 }
  let right = Vec { dx = 3, dy = 0 }
  let diag = Vec { dx = 2, dy = 4 }
  ( magnitude up
  , magnitude right
  , axis up
  , axis right
  , axis diag
  )
# CORE_IR
(CProgram ((CBind "magnitude" (CClause ((PVar "v")) (CBinPrim "+" (CBinPrim "*" (CFieldAccess (CVar "v" (ALocal 0 0)) "dx" "" -1) (CFieldAccess (CVar "v" (ALocal 0 0)) "dx" "" -1)) (CBinPrim "*" (CFieldAccess (CVar "v" (ALocal 0 0)) "dy" "" -1) (CFieldAccess (CVar "v" (ALocal 0 0)) "dy" "" -1)))))
(CBind "axis" (CClause ((PVar "v")) (CDecision (CVar "v" (ALocal 0 0)) ((arm (PRec "Vec" ((rf "dx" (PLit (LInt 0))) (rf "dy" None)) false) () (CVar "dy" (ALocal 0 0))) (arm (PRec "Vec" ((rf "dx" None) (rf "dy" (PLit (LInt 0)))) false) () (CVar "dx" (ALocal 0 0))) (arm (PRec "Vec" ((rf "dx" None) (rf "dy" None)) false) () (CBinPrim "+" (CVar "dx" (ALocal 0 0)) (CVar "dy" (ALocal 0 1))))) (CTGuard 0 (CTGuard 1 (CTGuard 2 CTFail))))))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "up") (CRecord "Vec" (cf "dx" -1 (CLit (LInt 0))) (cf "dy" -1 (CLit (LInt 5))))) (CSLet false (PVar "right") (CRecord "Vec" (cf "dx" -1 (CLit (LInt 3))) (cf "dy" -1 (CLit (LInt 0))))) (CSLet false (PVar "diag") (CRecord "Vec" (cf "dx" -1 (CLit (LInt 2))) (cf "dy" -1 (CLit (LInt 4))))) (CSExpr (CTuple (CApp (CVar "magnitude" AGlobal) ((CVar "up" (ALocal 2 0))) CallExact false) (CApp (CVar "magnitude" AGlobal) ((CVar "right" (ALocal 1 0))) CallExact false) (CApp (CVar "axis" AGlobal) ((CVar "up" (ALocal 2 0))) CallExact false) (CApp (CVar "axis" AGlobal) ((CVar "right" (ALocal 1 0))) CallExact false) (CApp (CVar "axis" AGlobal) ((CVar "diag" (ALocal 0 0))) CallExact false))))))) ((ca "Vec" 2)) ((ct "Vec" "Vec")) () () (facts () () () none (externs) (manifests) (origins ((function "axis" (single "axis")) (function "magnitude" (single "magnitude")) (function "main" (single "main"))) ((owner "Vec" ((constructor "Vec" (single "Vec"))))))) (binder-types
(b 0 "" "v" RTValue)
(b 1 "" "v" RTValue)
(b 2 "" "dy" RTValue)
(b 3 "" "dx" RTValue)
(b 4 "" "dx" RTValue)
(b 5 "" "dy" RTValue)
(b 6 "" "up" RTValue)
(b 7 "" "right" RTValue)
(b 8 "" "diag" RTValue)
(b 9 "" "magnitude" RTValue RTValue)
(b 10 "" "axis" RTValue RTValue)
(b 11 "" "main" RTValue RTValue)))
