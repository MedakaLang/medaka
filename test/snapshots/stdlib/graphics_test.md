# META
source_lines=51
stages=DESUGAR,MARK
# SOURCE
import graphics.{
  Color(..), Picture(..), Point(..), Shape(..), circle, line, picture, point,
  polygon, rgba
}
import test.{expectAll, expectEqual, expectWithin}

ink : Color
ink = rgba 0.2 0.4 0.6 0.8

test "point preserves logical coordinates" =
  expectEqual Point { x = -12.5, y = 30.0 } (point -12.5 30.0)

test "rgba preserves straight color channels" =
  expectEqual Color { red = 0.2, green = 0.4, blue = 0.6, alpha = 0.8 } ink

test "line preserves stroke width and endpoints" =
  expectEqual
    (Line ink 2.0 (point 1.0 2.0) (point 3.0 4.0))
    (line ink 2.0 (point 1.0 2.0) (point 3.0 4.0))

test "circle preserves center and radius" =
  expectEqual (Circle ink (point 3.0 4.0) 5.0) (circle ink (point 3.0 4.0) 5.0)

test "polygon preserves vertex order" =
  let points = [point 0.0 0.0, point 10.0 0.0, point 0.0 10.0]
  expectEqual (Polygon ink points) (polygon ink points)

test "picture preserves background and painting order" =
  let shapes = [circle ink (point 0.0 0.0) 4.0, polygon ink []]
  expectEqual Picture { background = ink, shapes = shapes } (picture ink shapes)

test "degenerate shapes remain ordinary pure data" = expectAll [
  expectEqual (Circle ink (point 0.0 0.0) 0.0) (circle ink (point 0.0 0.0) 0.0),
  expectEqual (Polygon ink []) (polygon ink []),
  expectEqual (Polygon ink [point 1.0 2.0]) (polygon ink [point 1.0 2.0]),
  expectEqual
    (Polygon ink [point 1.0 2.0, point 3.0 4.0])
    (polygon ink [point 1.0 2.0, point 3.0 4.0]),
]

test "invalid shape scalars are preserved for host validation" =
  let invalid = rgba -1.0 2.0 0.0 1.5
  expectAll [
    expectWithin -1.0 invalid.red 0.0,
    expectEqual
      (Line invalid 0.0 (point 1000001.0 0.0) (point 0.0 0.0))
      (line invalid 0.0 (point 1000001.0 0.0) (point 0.0 0.0)),
    expectEqual
      (Circle ink (point 0.0 0.0) -2.0)
      (circle ink (point 0.0 0.0) -2.0),
  ]
# DESUGAR
(DUse false (UseGroup ("graphics") ((mem "Color" true) (mem "Picture" true) (mem "Point" true) (mem "Shape" true) (mem "circle" false) (mem "line" false) (mem "picture" false) (mem "point" false) (mem "polygon" false) (mem "rgba" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectWithin" false))))
(DTypeSig false "ink" (TyCon "Color"))
(DFunDef false "ink" () (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.2))) (ELit (LFloat 0.4))) (ELit (LFloat 0.6))) (ELit (LFloat 0.8))))
(DTest false "point preserves logical coordinates" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Point" ((fa "x" (EUnOp "-" (ELit (LFloat 12.5)))) (fa "y" (ELit (LFloat 30.0)))))) (EApp (EApp (EVar "point") (ELit (LFloat -12.5))) (ELit (LFloat 30.0)))))
(DTest false "rgba preserves straight color channels" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Color" ((fa "red" (ELit (LFloat 0.2))) (fa "green" (ELit (LFloat 0.4))) (fa "blue" (ELit (LFloat 0.6))) (fa "alpha" (ELit (LFloat 0.8)))))) (EVar "ink")))
(DTest false "line preserves stroke width and endpoints" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EApp (EVar "Line") (EVar "ink")) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0))))) (EApp (EApp (EApp (EApp (EVar "line") (EVar "ink")) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0))))))
(DTest false "circle preserves center and radius" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))) (ELit (LFloat 5.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))) (ELit (LFloat 5.0)))))
(DTest false "polygon preserves vertex order" (EBlock (DoLet false false (PVar "points") (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 10.0))) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 10.0))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EVar "points"))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EVar "points"))))))
(DTest false "picture preserves background and painting order" (EBlock (DoLet false false (PVar "shapes") (EListLit (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 4.0))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit)))) (DoExpr (EApp (EApp (EVar "expectEqual") (ERecordCreate "Picture" ((fa "background" (EVar "ink")) (fa "shapes" (EVar "shapes"))))) (EApp (EApp (EVar "picture") (EVar "ink")) (EVar "shapes"))))))
(DTest false "degenerate shapes remain ordinary pure data" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 0.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))))))))
(DTest false "invalid shape scalars are preserved for host validation" (EBlock (DoLet false false (PVar "invalid") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat -1.0))) (ELit (LFloat 2.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.5)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat -1.0))) (EFieldAccess (EVar "invalid") "red")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EApp (EVar "Line") (EVar "invalid")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1000001.0))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))) (EApp (EApp (EApp (EApp (EVar "line") (EVar "invalid")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1000001.0))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat -2.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat -2.0)))))))))
# MARK
(DUse false (UseGroup ("graphics") ((mem "Color" true) (mem "Picture" true) (mem "Point" true) (mem "Shape" true) (mem "circle" false) (mem "line" false) (mem "picture" false) (mem "point" false) (mem "polygon" false) (mem "rgba" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectWithin" false))))
(DTypeSig false "ink" (TyCon "Color"))
(DFunDef false "ink" () (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.2))) (ELit (LFloat 0.4))) (ELit (LFloat 0.6))) (ELit (LFloat 0.8))))
(DTest false "point preserves logical coordinates" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Point" ((fa "x" (EUnOp "-" (ELit (LFloat 12.5)))) (fa "y" (ELit (LFloat 30.0)))))) (EApp (EApp (EVar "point") (ELit (LFloat -12.5))) (ELit (LFloat 30.0)))))
(DTest false "rgba preserves straight color channels" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Color" ((fa "red" (ELit (LFloat 0.2))) (fa "green" (ELit (LFloat 0.4))) (fa "blue" (ELit (LFloat 0.6))) (fa "alpha" (ELit (LFloat 0.8)))))) (EVar "ink")))
(DTest false "line preserves stroke width and endpoints" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EApp (EVar "Line") (EVar "ink")) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0))))) (EApp (EApp (EApp (EApp (EVar "line") (EVar "ink")) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0))))))
(DTest false "circle preserves center and radius" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))) (ELit (LFloat 5.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))) (ELit (LFloat 5.0)))))
(DTest false "polygon preserves vertex order" (EBlock (DoLet false false (PVar "points") (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 10.0))) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 10.0))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EVar "points"))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EVar "points"))))))
(DTest false "picture preserves background and painting order" (EBlock (DoLet false false (PVar "shapes") (EListLit (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 4.0))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit)))) (DoExpr (EApp (EApp (EVar "expectEqual") (ERecordCreate "Picture" ((fa "background" (EVar "ink")) (fa "shapes" (EVar "shapes"))))) (EApp (EApp (EVar "picture") (EVar "ink")) (EVar "shapes"))))))
(DTest false "degenerate shapes remain ordinary pure data" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 0.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0)))))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "Polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))))) (EApp (EApp (EVar "polygon") (EVar "ink")) (EListLit (EApp (EApp (EVar "point") (ELit (LFloat 1.0))) (ELit (LFloat 2.0))) (EApp (EApp (EVar "point") (ELit (LFloat 3.0))) (ELit (LFloat 4.0)))))))))
(DTest false "invalid shape scalars are preserved for host validation" (EBlock (DoLet false false (PVar "invalid") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat -1.0))) (ELit (LFloat 2.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.5)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat -1.0))) (EFieldAccess (EVar "invalid") "red")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EApp (EVar "Line") (EVar "invalid")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1000001.0))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))) (EApp (EApp (EApp (EApp (EVar "line") (EVar "invalid")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "point") (ELit (LFloat 1000001.0))) (ELit (LFloat 0.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EApp (EVar "Circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat -2.0)))) (EApp (EApp (EApp (EVar "circle") (EVar "ink")) (EApp (EApp (EVar "point") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (ELit (LFloat -2.0)))))))))
