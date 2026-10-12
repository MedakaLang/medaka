# META
source_lines=13
stages=CORE_IR
# SOURCE
-- record create / field access / update / pattern match
data Point = { x : Int, y : Int }
data Box = { label : String, pt : Point }
distSq p = p.x * p.x + p.y * p.y
moveRight p = { p | x = p.x + 1 }
swap p = match p
  Point { x, y } => Point { x = y, y = x }
labelOf b = b.label
main =
  let p = Point { x = 3, y = 4 }
  let q = moveRight p
  let b = Box { label = "origin", pt = Point { x = 0, y = 0 } }
  (p, distSq p, q, distSq q, swap p, labelOf b, b.pt.y)
# CORE_IR
(CProgram ((CBind "distSq" (CClause ((PVar "p")) (CBinPrim "+" (CBinPrim "*" (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "" -1) (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "" -1)) (CBinPrim "*" (CFieldAccess (CVar "p" (ALocal 0 0)) "y" "" -1) (CFieldAccess (CVar "p" (ALocal 0 0)) "y" "" -1)))))
(CBind "moveRight" (CClause ((PVar "p")) (CRecordUpdate "" (CVar "p" (ALocal 0 0)) (cf "x" -1 (CBinPrim "+" (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "" -1) (CLit (LInt 1)))))))
(CBind "swap" (CClause ((PVar "p")) (CDecision (CVar "p" (ALocal 0 0)) ((arm (PRec "Point" ((rf "x" None) (rf "y" None)) false) () (CRecord "Point" (cf "x" -1 (CVar "y" (ALocal 0 1))) (cf "y" -1 (CVar "x" (ALocal 0 0)))))) (CTGuard 0 CTFail))))
(CBind "labelOf" (CClause ((PVar "b")) (CFieldAccess (CVar "b" (ALocal 0 0)) "label" "" -1)))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "p") (CRecord "Point" (cf "x" -1 (CLit (LInt 3))) (cf "y" -1 (CLit (LInt 4))))) (CSLet false (PVar "q") (CApp (CVar "moveRight" AGlobal) ((CVar "p" (ALocal 0 0))) CallExact false)) (CSLet false (PVar "b") (CRecord "Box" (cf "label" -1 (CLit (LString "origin"))) (cf "pt" -1 (CRecord "Point" (cf "x" -1 (CLit (LInt 0))) (cf "y" -1 (CLit (LInt 0))))))) (CSExpr (CTuple (CVar "p" (ALocal 2 0)) (CApp (CVar "distSq" AGlobal) ((CVar "p" (ALocal 2 0))) CallExact false) (CVar "q" (ALocal 1 0)) (CApp (CVar "distSq" AGlobal) ((CVar "q" (ALocal 1 0))) CallExact false) (CApp (CVar "swap" AGlobal) ((CVar "p" (ALocal 2 0))) CallExact false) (CApp (CVar "labelOf" AGlobal) ((CVar "b" (ALocal 0 0))) CallExact false) (CFieldAccess (CFieldAccess (CVar "b" (ALocal 0 0)) "pt" "" -1) "y" "" -1))))))) ((ca "Point" 2) (ca "Box" 2)) ((ct "Point" "Point") (ct "Box" "Box")) () () (facts () ()) (binder-types
(b 0 "" "p" RTValue)
(b 1 "" "p" RTValue)
(b 2 "" "p" RTValue)
(b 3 "" "x" RTValue)
(b 4 "" "y" RTValue)
(b 5 "" "b" RTValue)
(b 6 "" "p" RTValue)
(b 7 "" "q" RTValue)
(b 8 "" "b" RTValue)
(b 9 "" "distSq" RTValue RTValue)
(b 10 "" "moveRight" RTValue RTValue)
(b 11 "" "swap" RTValue RTValue)
(b 12 "" "labelOf" RTValue RTValue)
(b 13 "" "main" RTValue RTValue)))
