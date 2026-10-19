# META
source_lines=93
stages=DESUGAR,MARK
# SOURCE
{- | Pure pictures in logical canvas coordinates.

   The origin is at the viewport center, with x right and y up. Constructors
   preserve their arguments; the canvas host validates a whole frame before
   presenting it. -}

{- | A position measured in logical CSS pixels. -}
public export data Point = Point { x : Float, y : Float } deriving (Eq, Debug)

{- | Straight RGBA components in the range zero through one. -}
public export data Color = Color {
  red : Float,
  green : Float,
  blue : Float,
  alpha : Float,
}
  deriving (Eq, Debug)

{- | A stroked line, filled circle, or filled polygon.

   Zero-radius circles and polygons with fewer than three points paint
   nothing. Line widths must be positive; radii must be nonnegative. -}
public export data Shape =
  | Line Color Float Point Point
  | Circle Color Point Float
  | Polygon Color (List Point)
  deriving (Eq, Debug)

{- | A complete frame, painted in list order over its background.

   Transparent backgrounds clear the preceding frame before painting. -}
public export data Picture = Picture {
  background : Color,
  shapes : List Shape,
}
  deriving (Eq, Debug)

{- | A point at the given horizontal and vertical coordinates.

   > point 3.0 4.0
   Point { x = 3.0, y = 4.0 }
   -}
export
point : Float -> Float -> Point
point x y = Point { x = x, y = y }

{- | A color with the given red, green, blue, and alpha components.

   Values are preserved, including components outside the host's valid range.

   > rgba 1.0 0.5 0.0 1.0
   Color { red = 1.0, green = 0.5, blue = 0.0, alpha = 1.0 }
   -}
export
rgba : Float -> Float -> Float -> Float -> Color
rgba red green blue alpha =
  Color { red = red, green = green, blue = blue, alpha = alpha }

{- | A line whose width uses logical CSS pixels.

   > line (rgba 1.0 0.0 0.0 1.0) 2.0 (point 0.0 0.0) (point 5.0 5.0)
   Line (Color { red = 1.0, green = 0.0, blue = 0.0, alpha = 1.0 }) 2.0 (Point { x = 0.0, y = 0.0 }) (Point { x = 5.0, y = 5.0 })
   -}
export
line : Color -> Float -> Point -> Point -> Shape
line color width from to = Line color width from to

{- | A filled circle whose radius uses logical CSS pixels.

   > circle (rgba 0.0 0.5 1.0 1.0) (point 2.0 3.0) 4.0
   Circle (Color { red = 0.0, green = 0.5, blue = 1.0, alpha = 1.0 }) (Point { x = 2.0, y = 3.0 }) 4.0
   -}
export
circle : Color -> Point -> Float -> Shape
circle color center radius = Circle color center radius

{- | A filled polygon whose final point connects to its first point.

   > polygon (rgba 0.0 1.0 0.0 1.0) [point 0.0 0.0, point 4.0 0.0, point 2.0 3.0]
   Polygon (Color { red = 0.0, green = 1.0, blue = 0.0, alpha = 1.0 }) [Point { x = 0.0, y = 0.0 }, Point { x = 4.0, y = 0.0 }, Point { x = 2.0, y = 3.0 }]
   -}
export
polygon : Color -> List Point -> Shape
polygon color points = Polygon color points

{- | A complete picture with shapes painted in their supplied order.

   > picture (rgba 0.0 0.0 0.0 1.0) [circle (rgba 1.0 1.0 1.0 1.0) (point 0.0 0.0) 2.0]
   Picture { background = Color { red = 0.0, green = 0.0, blue = 0.0, alpha = 1.0 }, shapes = [Circle (Color { red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0 }) (Point { x = 0.0, y = 0.0 }) 2.0] }
   -}
export
picture : Color -> List Shape -> Picture
picture background shapes = Picture { background = background, shapes = shapes }
# DESUGAR
(DData Public "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Float")) (field "y" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "Point")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "Point")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Point {")) (ELit (LString " x = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DData Public "Color" () ((variant "Color" (ConNamed (field "red" (TyCon "Float")) (field "green" (TyCon "Float")) (field "blue" (TyCon "Float")) (field "alpha" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "Color")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Color" ((rf "red" (PVar "__a0")) (rf "green" (PVar "__a1")) (rf "blue" (PVar "__a2")) (rf "alpha" (PVar "__a3"))) false) (PRec "Color" ((rf "red" (PVar "__b0")) (rf "green" (PVar "__b1")) (rf "blue" (PVar "__b2")) (rf "alpha" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Color")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Color" ((rf "red" (PVar "__a0")) (rf "green" (PVar "__a1")) (rf "blue" (PVar "__a2")) (rf "alpha" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Color {")) (ELit (LString " red = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", green = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", blue = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", alpha = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "Shape" () ((variant "Line" (ConPos (TyCon "Color") (TyCon "Float") (TyCon "Point") (TyCon "Point"))) (variant "Circle" (ConPos (TyCon "Color") (TyCon "Point") (TyCon "Float"))) (variant "Polygon" (ConPos (TyCon "Color") (TyApp (TyCon "List") (TyCon "Point"))))) ())
(DImpl true "Eq" ((TyCon "Shape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Line" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "Line" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3")))) (arm (PTuple (PCon "Circle" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Circle" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "Polygon" (PVar "__a0") (PVar "__a1")) (PCon "Polygon" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Line" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Line ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3"))))) (arm (PCon "Circle" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "Polygon" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Polygon ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "Picture" () ((variant "Picture" (ConNamed (field "background" (TyCon "Color")) (field "shapes" (TyApp (TyCon "List") (TyCon "Shape")))))) ())
(DImpl true "Eq" ((TyCon "Picture")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Picture" ((rf "background" (PVar "__a0")) (rf "shapes" (PVar "__a1"))) false) (PRec "Picture" ((rf "background" (PVar "__b0")) (rf "shapes" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "Picture")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Picture" ((rf "background" (PVar "__a0")) (rf "shapes" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Picture {")) (ELit (LString " background = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", shapes = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DTypeSig true "point" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Point"))))
(DFunDef false "point" ((PVar "x") (PVar "y")) (ERecordCreate "Point" ((fa "x" (EVar "x")) (fa "y" (EVar "y")))))
(DTypeSig true "rgba" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Color"))))))
(DFunDef false "rgba" ((PVar "red") (PVar "green") (PVar "blue") (PVar "alpha")) (ERecordCreate "Color" ((fa "red" (EVar "red")) (fa "green" (EVar "green")) (fa "blue" (EVar "blue")) (fa "alpha" (EVar "alpha")))))
(DTypeSig true "line" (TyFun (TyCon "Color") (TyFun (TyCon "Float") (TyFun (TyCon "Point") (TyFun (TyCon "Point") (TyCon "Shape"))))))
(DFunDef false "line" ((PVar "color") (PVar "width") (PVar "from") (PVar "to")) (EApp (EApp (EApp (EApp (EVar "Line") (EVar "color")) (EVar "width")) (EVar "from")) (EVar "to")))
(DTypeSig true "circle" (TyFun (TyCon "Color") (TyFun (TyCon "Point") (TyFun (TyCon "Float") (TyCon "Shape")))))
(DFunDef false "circle" ((PVar "color") (PVar "center") (PVar "radius")) (EApp (EApp (EApp (EVar "Circle") (EVar "color")) (EVar "center")) (EVar "radius")))
(DTypeSig true "polygon" (TyFun (TyCon "Color") (TyFun (TyApp (TyCon "List") (TyCon "Point")) (TyCon "Shape"))))
(DFunDef false "polygon" ((PVar "color") (PVar "points")) (EApp (EApp (EVar "Polygon") (EVar "color")) (EVar "points")))
(DTypeSig true "picture" (TyFun (TyCon "Color") (TyFun (TyApp (TyCon "List") (TyCon "Shape")) (TyCon "Picture"))))
(DFunDef false "picture" ((PVar "background") (PVar "shapes")) (ERecordCreate "Picture" ((fa "background" (EVar "background")) (fa "shapes" (EVar "shapes")))))
# MARK
(DData Public "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Float")) (field "y" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "Point")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "Point")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Point {")) (ELit (LString " x = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DData Public "Color" () ((variant "Color" (ConNamed (field "red" (TyCon "Float")) (field "green" (TyCon "Float")) (field "blue" (TyCon "Float")) (field "alpha" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "Color")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Color" ((rf "red" (PVar "__a0")) (rf "green" (PVar "__a1")) (rf "blue" (PVar "__a2")) (rf "alpha" (PVar "__a3"))) false) (PRec "Color" ((rf "red" (PVar "__b0")) (rf "green" (PVar "__b1")) (rf "blue" (PVar "__b2")) (rf "alpha" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Color")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Color" ((rf "red" (PVar "__a0")) (rf "green" (PVar "__a1")) (rf "blue" (PVar "__a2")) (rf "alpha" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Color {")) (ELit (LString " red = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", green = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", blue = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", alpha = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "Shape" () ((variant "Line" (ConPos (TyCon "Color") (TyCon "Float") (TyCon "Point") (TyCon "Point"))) (variant "Circle" (ConPos (TyCon "Color") (TyCon "Point") (TyCon "Float"))) (variant "Polygon" (ConPos (TyCon "Color") (TyApp (TyCon "List") (TyCon "Point"))))) ())
(DImpl true "Eq" ((TyCon "Shape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Line" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "Line" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3")))) (arm (PTuple (PCon "Circle" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "Circle" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "Polygon" (PVar "__a0") (PVar "__a1")) (PCon "Polygon" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Line" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Line ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3"))))) (arm (PCon "Circle" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "Polygon" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Polygon ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "Picture" () ((variant "Picture" (ConNamed (field "background" (TyCon "Color")) (field "shapes" (TyApp (TyCon "List") (TyCon "Shape")))))) ())
(DImpl true "Eq" ((TyCon "Picture")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Picture" ((rf "background" (PVar "__a0")) (rf "shapes" (PVar "__a1"))) false) (PRec "Picture" ((rf "background" (PVar "__b0")) (rf "shapes" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "Picture")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Picture" ((rf "background" (PVar "__a0")) (rf "shapes" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Picture {")) (ELit (LString " background = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", shapes = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DTypeSig true "point" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Point"))))
(DFunDef false "point" ((PVar "x") (PVar "y")) (ERecordCreate "Point" ((fa "x" (EVar "x")) (fa "y" (EVar "y")))))
(DTypeSig true "rgba" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Color"))))))
(DFunDef false "rgba" ((PVar "red") (PVar "green") (PVar "blue") (PVar "alpha")) (ERecordCreate "Color" ((fa "red" (EVar "red")) (fa "green" (EVar "green")) (fa "blue" (EVar "blue")) (fa "alpha" (EVar "alpha")))))
(DTypeSig true "line" (TyFun (TyCon "Color") (TyFun (TyCon "Float") (TyFun (TyCon "Point") (TyFun (TyCon "Point") (TyCon "Shape"))))))
(DFunDef false "line" ((PVar "color") (PVar "width") (PVar "from") (PVar "to")) (EApp (EApp (EApp (EApp (EVar "Line") (EVar "color")) (EVar "width")) (EVar "from")) (EVar "to")))
(DTypeSig true "circle" (TyFun (TyCon "Color") (TyFun (TyCon "Point") (TyFun (TyCon "Float") (TyCon "Shape")))))
(DFunDef false "circle" ((PVar "color") (PVar "center") (PVar "radius")) (EApp (EApp (EApp (EVar "Circle") (EVar "color")) (EVar "center")) (EVar "radius")))
(DTypeSig true "polygon" (TyFun (TyCon "Color") (TyFun (TyApp (TyCon "List") (TyCon "Point")) (TyCon "Shape"))))
(DFunDef false "polygon" ((PVar "color") (PVar "points")) (EApp (EApp (EVar "Polygon") (EVar "color")) (EVar "points")))
(DTypeSig true "picture" (TyFun (TyCon "Color") (TyFun (TyApp (TyCon "List") (TyCon "Shape")) (TyCon "Picture"))))
(DFunDef false "picture" ((PVar "background") (PVar "shapes")) (ERecordCreate "Picture" ((fa "background" (EVar "background")) (fa "shapes" (EVar "shapes")))))
