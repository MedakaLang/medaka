# META
source_lines=18
stages=CORE_IR
# SOURCE
-- user-defined interface + impls, argument-position dispatch
interface Shape a where
  area : a -> Int
  name : a -> String
data Circle = Circle Int
data Square = Square Int
data Rect = Rect Int Int
impl Shape Circle where
  area (Circle r) = 3 * r * r
  name _ = "circle"
impl Shape Square where
  area (Square s) = s * s
  name _ = "square"
impl Shape Rect where
  area (Rect w h) = w * h
  name _ = "rect"
describe s = name s ++ ":" ++ intToString (area s)
main = (area (Circle 2), area (Square 3), area (Rect 2 5), describe (Circle 1), describe (Rect 3 3))
# CORE_IR
(CProgram ((CBind "describe" (CClause ((PVar "s")) (CBinPrim "++" (CBinPrim "++" (CApp (CVar "name" AGlobal) ((CVar "s" (ALocal 0 0))) CallDynamic false) (CLit (LString ":"))) (CApp (CVar "intToString" AGlobal) ((CApp (CVar "area" AGlobal) ((CVar "s" (ALocal 0 0))) CallDynamic false)) CallDynamic false))))
(CBind "main" (CClause () (CTuple (CApp (CVar "area" AGlobal) ((CApp (CVar "Circle" AGlobal) ((CLit (LInt 2))) CallExact false)) CallDynamic false) (CApp (CVar "area" AGlobal) ((CApp (CVar "Square" AGlobal) ((CLit (LInt 3))) CallExact false)) CallDynamic false) (CApp (CVar "area" AGlobal) ((CApp (CVar "Rect" AGlobal) ((CLit (LInt 2)) (CLit (LInt 5))) CallExact false)) CallDynamic false) (CApp (CVar "describe" AGlobal) ((CApp (CVar "Circle" AGlobal) ((CLit (LInt 1))) CallExact false)) CallExact false) (CApp (CVar "describe" AGlobal) ((CApp (CVar "Rect" AGlobal) ((CLit (LInt 3)) (CLit (LInt 3))) CallExact false)) CallExact false))))) ((ca "Circle" 1) (ca "Square" 1) (ca "Rect" 2)) ((ct "Circle" "Circle") (ct "Square" "Square") (ct "Rect" "Rect")) ((CImplEntry "area" 0 1 (CImplTagged "Circle" "Shape|Circle|" "Shape" ("Circle" "" "") (0) ((PCon "Circle" (PVar "r"))) (CBinPrim "*" (CBinPrim "*" (CLit (LInt 3)) (CVar "r" (ALocal 0 0))) (CVar "r" (ALocal 0 0))))) (CImplEntry "name" 0 1 (CImplTagged "Circle" "Shape|Circle|" "Shape" ("Circle" "" "") (0) (PWild) (CLit (LString "circle")))) (CImplEntry "area" 0 1 (CImplTagged "Square" "Shape|Square|" "Shape" ("Square" "" "") (0) ((PCon "Square" (PVar "s"))) (CBinPrim "*" (CVar "s" (ALocal 0 0)) (CVar "s" (ALocal 0 0))))) (CImplEntry "name" 0 1 (CImplTagged "Square" "Shape|Square|" "Shape" ("Square" "" "") (0) (PWild) (CLit (LString "square")))) (CImplEntry "area" 0 1 (CImplTagged "Rect" "Shape|Rect|" "Shape" ("Rect" "" "") (0) ((PCon "Rect" (PVar "w") (PVar "h"))) (CBinPrim "*" (CVar "w" (ALocal 0 0)) (CVar "h" (ALocal 0 1))))) (CImplEntry "name" 0 1 (CImplTagged "Rect" "Shape|Rect|" "Shape" ("Rect" "" "") (0) (PWild) (CLit (LString "rect"))))) () (facts () () () none (externs) (manifests) (origins ((function "describe" (single "describe")) (function "main" (single "main"))) ((owner "Circle" ((constructor "Circle" (single "Circle")))) (owner "Rect" ((constructor "Rect" (single "Rect")))) (owner "Square" ((constructor "Square" (single "Square"))))))) (binder-types
(b 0 "" "s" RTValue)
(b 1 "" "r" RTValue)
(b 2 "" "s" RTValue)
(b 3 "" "w" RTValue)
(b 4 "" "h" RTValue)
(b 5 "" "describe" RTValue RTValue)
(b 6 "" "main" RTValue RTValue)))
