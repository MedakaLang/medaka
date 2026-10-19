# META
source_lines=129
stages=DESUGAR,MARK
# SOURCE
{- | Scalar browser bindings for rendering pure pictures.

   A browser host must supply the versioned canvas bindings. Calls belong
   inside one entry invocation; begin precedes frame reads and rendering. -}

import graphics.{Picture, Point, Shape(..)}

{- | Begin the invocation's picture, requesting further frames when true. -}
export
extern begin : Bool -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_begin"

{- | Active animation time in seconds. -}
export
extern elapsed : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_elapsed"

{- | Seconds since the previous delivered frame, clamped by the host. -}
export
extern delta : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_delta"

{- | Logical viewport width in CSS pixels. -}
export
extern width : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_width"

{- | Logical viewport height in CSS pixels. -}
export
extern height : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_height"

{- | Horizontal pointer position relative to the canvas center. -}
export
extern pointerX : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_pointerX"

{- | Vertical pointer position, increasing upward. -}
export
extern pointerY : Unit -> <FFI "js/canvas"> Float
  bind js "medaka_canvas_v1_pointerY"

{- | Whether the pointer lies inside the canvas. -}
export
extern pointerInside : Unit -> <FFI "js/canvas"> Bool
  bind js "medaka_canvas_v1_pointerInside"

{- | Whether the primary pointer is pressed. -}
export
extern pointerDown : Unit -> <FFI "js/canvas"> Bool
  bind js "medaka_canvas_v1_pointerDown"

extern background : Float -> Float -> Float -> Float -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_background"

extern strokeLine : Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_line"

extern fillCircle : Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  Float ->
  <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_circle"

extern polygonBegin : Float -> Float -> Float -> Float -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_polygonBegin"

extern polygonPoint : Float -> Float -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_polygonPoint"

extern polygonEnd : Unit -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_polygonEnd"

extern end : Unit -> <FFI "js/canvas"> Unit
  bind js "medaka_canvas_v1_end"

renderPoint : Point -> <FFI "js/canvas"> Unit
renderPoint p = polygonPoint p.x p.y

renderShape : Shape -> <FFI "js/canvas"> Unit
renderShape (Line color width from to) =
  strokeLine
    color.red
    color.green
    color.blue
    color.alpha
    width
    from.x
    from.y
    to.x
    to.y
renderShape (Circle color center radius) =
  fillCircle
    color.red
    color.green
    color.blue
    color.alpha
    center.x
    center.y
    radius
renderShape (Polygon color points) =
  polygonBegin color.red color.green color.blue color.alpha
  each renderPoint points
  polygonEnd ()

{- | Render a complete picture after begin and seal its command batch.

   The host validates every scalar, including degenerate shapes, and presents
   the batch only after the guest invocation returns successfully. -}
export
render : Picture -> <FFI "js/canvas"> Unit
render scene =
  let color = scene.background
  background color.red color.green color.blue color.alpha
  each renderShape scene.shapes
  end ()
# DESUGAR
(DUse false (UseGroup ("graphics") ((mem "Picture" false) (mem "Point" false) (mem "Shape" true))))
(DExtern true "begin" (TyFun (TyCon "Bool") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_begin")))
(DExtern true "elapsed" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_elapsed")))
(DExtern true "delta" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_delta")))
(DExtern true "width" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_width")))
(DExtern true "height" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_height")))
(DExtern true "pointerX" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_pointerX")))
(DExtern true "pointerY" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_pointerY")))
(DExtern true "pointerInside" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Bool"))) ((bind "js" "medaka_canvas_v1_pointerInside")))
(DExtern true "pointerDown" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Bool"))) ((bind "js" "medaka_canvas_v1_pointerDown")))
(DExtern false "background" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))))) ((bind "js" "medaka_canvas_v1_background")))
(DExtern false "strokeLine" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))))))))) ((bind "js" "medaka_canvas_v1_line")))
(DExtern false "fillCircle" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))))))) ((bind "js" "medaka_canvas_v1_circle")))
(DExtern false "polygonBegin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))))) ((bind "js" "medaka_canvas_v1_polygonBegin")))
(DExtern false "polygonPoint" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))) ((bind "js" "medaka_canvas_v1_polygonPoint")))
(DExtern false "polygonEnd" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_polygonEnd")))
(DExtern false "end" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_end")))
(DTypeSig false "renderPoint" (TyFun (TyCon "Point") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "renderPoint" ((PVar "p")) (EApp (EApp (EVar "polygonPoint") (EFieldAccess (EVar "p") "x")) (EFieldAccess (EVar "p") "y")))
(DTypeSig false "renderShape" (TyFun (TyCon "Shape") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "renderShape" ((PCon "Line" (PVar "color") (PVar "width") (PVar "from") (PVar "to"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "strokeLine") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha")) (EVar "width")) (EFieldAccess (EVar "from") "x")) (EFieldAccess (EVar "from") "y")) (EFieldAccess (EVar "to") "x")) (EFieldAccess (EVar "to") "y")))
(DFunDef false "renderShape" ((PCon "Circle" (PVar "color") (PVar "center") (PVar "radius"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fillCircle") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha")) (EFieldAccess (EVar "center") "x")) (EFieldAccess (EVar "center") "y")) (EVar "radius")))
(DFunDef false "renderShape" ((PCon "Polygon" (PVar "color") (PVar "points"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "polygonBegin") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha"))) (DoExpr (EApp (EApp (EVar "each") (EVar "renderPoint")) (EVar "points"))) (DoExpr (EApp (EVar "polygonEnd") (ELit LUnit)))))
(DTypeSig true "render" (TyFun (TyCon "Picture") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "render" ((PVar "scene")) (EBlock (DoLet false false (PVar "color") (EFieldAccess (EVar "scene") "background")) (DoExpr (EApp (EApp (EApp (EApp (EVar "background") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha"))) (DoExpr (EApp (EApp (EVar "each") (EVar "renderShape")) (EFieldAccess (EVar "scene") "shapes"))) (DoExpr (EApp (EVar "end") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("graphics") ((mem "Picture" false) (mem "Point" false) (mem "Shape" true))))
(DExtern true "begin" (TyFun (TyCon "Bool") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_begin")))
(DExtern true "elapsed" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_elapsed")))
(DExtern true "delta" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_delta")))
(DExtern true "width" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_width")))
(DExtern true "height" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_height")))
(DExtern true "pointerX" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_pointerX")))
(DExtern true "pointerY" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Float"))) ((bind "js" "medaka_canvas_v1_pointerY")))
(DExtern true "pointerInside" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Bool"))) ((bind "js" "medaka_canvas_v1_pointerInside")))
(DExtern true "pointerDown" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Bool"))) ((bind "js" "medaka_canvas_v1_pointerDown")))
(DExtern false "background" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))))) ((bind "js" "medaka_canvas_v1_background")))
(DExtern false "strokeLine" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))))))))) ((bind "js" "medaka_canvas_v1_line")))
(DExtern false "fillCircle" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))))))) ((bind "js" "medaka_canvas_v1_circle")))
(DExtern false "polygonBegin" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))))) ((bind "js" "medaka_canvas_v1_polygonBegin")))
(DExtern false "polygonPoint" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit")))) ((bind "js" "medaka_canvas_v1_polygonPoint")))
(DExtern false "polygonEnd" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_polygonEnd")))
(DExtern false "end" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))) ((bind "js" "medaka_canvas_v1_end")))
(DTypeSig false "renderPoint" (TyFun (TyCon "Point") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "renderPoint" ((PVar "p")) (EApp (EApp (EVar "polygonPoint") (EFieldAccess (EVar "p") "x")) (EFieldAccess (EVar "p") "y")))
(DTypeSig false "renderShape" (TyFun (TyCon "Shape") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "renderShape" ((PCon "Line" (PVar "color") (PVar "width") (PVar "from") (PVar "to"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "strokeLine") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha")) (EVar "width")) (EFieldAccess (EVar "from") "x")) (EFieldAccess (EVar "from") "y")) (EFieldAccess (EVar "to") "x")) (EFieldAccess (EVar "to") "y")))
(DFunDef false "renderShape" ((PCon "Circle" (PVar "color") (PVar "center") (PVar "radius"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fillCircle") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha")) (EFieldAccess (EVar "center") "x")) (EFieldAccess (EVar "center") "y")) (EVar "radius")))
(DFunDef false "renderShape" ((PCon "Polygon" (PVar "color") (PVar "points"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "polygonBegin") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha"))) (DoExpr (EApp (EApp (EVar "each") (EVar "renderPoint")) (EVar "points"))) (DoExpr (EApp (EVar "polygonEnd") (ELit LUnit)))))
(DTypeSig true "render" (TyFun (TyCon "Picture") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "render" ((PVar "scene")) (EBlock (DoLet false false (PVar "color") (EFieldAccess (EVar "scene") "background")) (DoExpr (EApp (EApp (EApp (EApp (EVar "background") (EFieldAccess (EVar "color") "red")) (EFieldAccess (EVar "color") "green")) (EFieldAccess (EVar "color") "blue")) (EFieldAccess (EVar "color") "alpha"))) (DoExpr (EApp (EApp (EVar "each") (EVar "renderShape")) (EFieldAccess (EVar "scene") "shapes"))) (DoExpr (EApp (EVar "end") (ELit LUnit)))))
