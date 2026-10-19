# META
source_lines=65
stages=DESUGAR,MARK
# SOURCE
import animation.{Frame(..), Pointer(..), Simulation, simulation}
import graphics.{Picture, circle, picture, point, rgba}
import test.{expectAll, expectEqual, expectWithin}

frame : Frame
frame = Frame {
  elapsed = 2.0,
  delta = 0.05,
  width = 640.0,
  height = 360.0,
  pointer = Pointer { x = 15.0, y = -20.0, inside = True, down = False },
}

update : Frame -> Float -> Float
update input model = model + input.delta * 20.0

view : Frame -> Float -> Picture
view input model = picture (rgba 0.0 0.0 0.0 0.0) [
  circle (rgba 1.0 0.0 0.0 1.0) (point model input.pointer.y) 5.0,
]

countedUpdate : Ref Int -> Frame -> Float -> Float
countedUpdate calls input model =
  calls := !calls + 1
  update input model

countedView : Ref Int -> Frame -> Float -> Picture
countedView calls input model =
  calls := !calls + 1
  view input model

test "frame retains seconds and logical viewport dimensions" = expectAll [
  expectWithin 2.0 frame.elapsed 0.0,
  expectWithin 0.05 frame.delta 0.0,
  expectEqual (640.0, 360.0) (frame.width, frame.height),
]

test "pointer retains centered coordinates and button state" =
  expectEqual
    Pointer { x = 15.0, y = -20.0, inside = True, down = False }
    frame.pointer

test "initial model view uses the model without an update" =
  expectEqual
    (picture (rgba 0.0 0.0 0.0 0.0) [
      circle (rgba 1.0 0.0 0.0 1.0) (point 10.0 -20.0) 5.0,
    ])
    (view frame 10.0)

test "one update then view uses the delivered delta once" =
  let next = update frame 10.0
  expectAll [
    expectWithin 11.0 next 1e-06,
    expectEqual
      (picture (rgba 0.0 0.0 0.0 0.0) [
        circle (rgba 1.0 0.0 0.0 1.0) (point 11.0 -20.0) 5.0,
      ])
      (view frame next),
  ]

test "simulation construction makes no host call or eager callback" =
  let calls = Ref 0
  let _app =
    simulation 10.0 (countedUpdate calls) (countedView calls) : Simulation Float
  expectEqual 0 !calls
# DESUGAR
(DUse false (UseGroup ("animation") ((mem "Frame" true) (mem "Pointer" true) (mem "Simulation" false) (mem "simulation" false))))
(DUse false (UseGroup ("graphics") ((mem "Picture" false) (mem "circle" false) (mem "picture" false) (mem "point" false) (mem "rgba" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectWithin" false))))
(DTypeSig false "frame" (TyCon "Frame"))
(DFunDef false "frame" () (ERecordCreate "Frame" ((fa "elapsed" (ELit (LFloat 2.0))) (fa "delta" (ELit (LFloat 0.05))) (fa "width" (ELit (LFloat 640.0))) (fa "height" (ELit (LFloat 360.0))) (fa "pointer" (ERecordCreate "Pointer" ((fa "x" (ELit (LFloat 15.0))) (fa "y" (EUnOp "-" (ELit (LFloat 20.0)))) (fa "inside" (EVar "True")) (fa "down" (EVar "False"))))))))
(DTypeSig false "update" (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "update" ((PVar "input") (PVar "model")) (EBinOp "+" (EVar "model") (EBinOp "*" (EFieldAccess (EVar "input") "delta") (ELit (LFloat 20.0)))))
(DTypeSig false "view" (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Picture"))))
(DFunDef false "view" ((PVar "input") (PVar "model")) (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (EVar "model")) (EFieldAccess (EFieldAccess (EVar "input") "pointer") "y"))) (ELit (LFloat 5.0))))))
(DTypeSig false "countedUpdate" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "countedUpdate" ((PVar "calls") (PVar "input") (PVar "model")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "update") (EVar "input")) (EVar "model")))))
(DTypeSig false "countedView" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Picture")))))
(DFunDef false "countedView" ((PVar "calls") (PVar "input") (PVar "model")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "view") (EVar "input")) (EVar "model")))))
(DTest false "frame retains seconds and logical viewport dimensions" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 2.0))) (EFieldAccess (EVar "frame") "elapsed")) (ELit (LFloat 0.0))) (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 0.05))) (EFieldAccess (EVar "frame") "delta")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LFloat 640.0)) (ELit (LFloat 360.0)))) (ETuple (EFieldAccess (EVar "frame") "width") (EFieldAccess (EVar "frame") "height"))))))
(DTest false "pointer retains centered coordinates and button state" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Pointer" ((fa "x" (ELit (LFloat 15.0))) (fa "y" (EUnOp "-" (ELit (LFloat 20.0)))) (fa "inside" (EVar "True")) (fa "down" (EVar "False"))))) (EFieldAccess (EVar "frame") "pointer")))
(DTest false "initial model view uses the model without an update" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 10.0))) (ELit (LFloat -20.0)))) (ELit (LFloat 5.0)))))) (EApp (EApp (EVar "view") (EVar "frame")) (ELit (LFloat 10.0)))))
(DTest false "one update then view uses the delivered delta once" (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "update") (EVar "frame")) (ELit (LFloat 10.0)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 11.0))) (EVar "next")) (ELit (LFloat 1e-06))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 11.0))) (ELit (LFloat -20.0)))) (ELit (LFloat 5.0)))))) (EApp (EApp (EVar "view") (EVar "frame")) (EVar "next"))))))))
(DTest false "simulation construction makes no host call or eager callback" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "_app") (EAnnot (EApp (EApp (EApp (EVar "simulation") (ELit (LFloat 10.0))) (EApp (EVar "countedUpdate") (EVar "calls"))) (EApp (EVar "countedView") (EVar "calls"))) (TyApp (TyCon "Simulation") (TyCon "Float")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EUnOp "!" (EVar "calls"))))))
# MARK
(DUse false (UseGroup ("animation") ((mem "Frame" true) (mem "Pointer" true) (mem "Simulation" false) (mem "simulation" false))))
(DUse false (UseGroup ("graphics") ((mem "Picture" false) (mem "circle" false) (mem "picture" false) (mem "point" false) (mem "rgba" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectWithin" false))))
(DTypeSig false "frame" (TyCon "Frame"))
(DFunDef false "frame" () (ERecordCreate "Frame" ((fa "elapsed" (ELit (LFloat 2.0))) (fa "delta" (ELit (LFloat 0.05))) (fa "width" (ELit (LFloat 640.0))) (fa "height" (ELit (LFloat 360.0))) (fa "pointer" (ERecordCreate "Pointer" ((fa "x" (ELit (LFloat 15.0))) (fa "y" (EUnOp "-" (ELit (LFloat 20.0)))) (fa "inside" (EVar "True")) (fa "down" (EVar "False"))))))))
(DTypeSig false "update" (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "update" ((PVar "input") (PVar "model")) (EBinOp "+" (EVar "model") (EBinOp "*" (EFieldAccess (EVar "input") "delta") (ELit (LFloat 20.0)))))
(DTypeSig false "view" (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Picture"))))
(DFunDef false "view" ((PVar "input") (PVar "model")) (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (EVar "model")) (EFieldAccess (EFieldAccess (EVar "input") "pointer") "y"))) (ELit (LFloat 5.0))))))
(DTypeSig false "countedUpdate" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Float")))))
(DFunDef false "countedUpdate" ((PVar "calls") (PVar "input") (PVar "model")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "update") (EVar "input")) (EVar "model")))))
(DTypeSig false "countedView" (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Frame") (TyFun (TyCon "Float") (TyCon "Picture")))))
(DFunDef false "countedView" ((PVar "calls") (PVar "input") (PVar "model")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "view") (EVar "input")) (EVar "model")))))
(DTest false "frame retains seconds and logical viewport dimensions" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 2.0))) (EFieldAccess (EVar "frame") "elapsed")) (ELit (LFloat 0.0))) (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 0.05))) (EFieldAccess (EVar "frame") "delta")) (ELit (LFloat 0.0))) (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LFloat 640.0)) (ELit (LFloat 360.0)))) (ETuple (EFieldAccess (EVar "frame") "width") (EFieldAccess (EVar "frame") "height"))))))
(DTest false "pointer retains centered coordinates and button state" (EApp (EApp (EVar "expectEqual") (ERecordCreate "Pointer" ((fa "x" (ELit (LFloat 15.0))) (fa "y" (EUnOp "-" (ELit (LFloat 20.0)))) (fa "inside" (EVar "True")) (fa "down" (EVar "False"))))) (EFieldAccess (EVar "frame") "pointer")))
(DTest false "initial model view uses the model without an update" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 10.0))) (ELit (LFloat -20.0)))) (ELit (LFloat 5.0)))))) (EApp (EApp (EVar "view") (EVar "frame")) (ELit (LFloat 10.0)))))
(DTest false "one update then view uses the delivered delta once" (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "update") (EVar "frame")) (ELit (LFloat 10.0)))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 11.0))) (EVar "next")) (ELit (LFloat 1e-06))) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "picture") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0)))) (EListLit (EApp (EApp (EApp (EVar "circle") (EApp (EApp (EApp (EApp (EVar "rgba") (ELit (LFloat 1.0))) (ELit (LFloat 0.0))) (ELit (LFloat 0.0))) (ELit (LFloat 1.0)))) (EApp (EApp (EVar "point") (ELit (LFloat 11.0))) (ELit (LFloat -20.0)))) (ELit (LFloat 5.0)))))) (EApp (EApp (EVar "view") (EVar "frame")) (EVar "next"))))))))
(DTest false "simulation construction makes no host call or eager callback" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "_app") (EAnnot (EApp (EApp (EApp (EVar "simulation") (ELit (LFloat 10.0))) (EApp (EVar "countedUpdate") (EVar "calls"))) (EApp (EVar "countedView") (EVar "calls"))) (TyApp (TyCon "Simulation") (TyCon "Float")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EUnOp "!" (EVar "calls"))))))
