# META
source_lines=92
stages=DESUGAR,MARK
# SOURCE
{- | Pictures driven by browser frames and retained simulation models.

   Bind a simulation once at module scope to retain its model across frames.
   Constructing one inside main creates a fresh model on every invocation. -}

import canvas_host as Canvas
import graphics.{Picture}

{- | The primary pointer in logical canvas coordinates. -}
public export data Pointer = Pointer {
  x : Float,
  y : Float,
  inside : Bool,
  down : Bool,
}
  deriving (Eq, Debug)

{- | An immutable snapshot for one delivered frame.

   Times are seconds of active animation; width and height are CSS pixels.
   Delta is zero on the first frame and after resuming, otherwise at most 0.05. -}
public export data Frame = Frame {
  elapsed : Float,
  delta : Float,
  width : Float,
  height : Float,
  pointer : Pointer,
}
  deriving (Eq, Debug)

{- | A retained model with pure update and view functions. -}
export data Simulation model =
  | Simulation (Ref model) (Ref Bool) (Frame -> model -> model) (Frame -> model -> Picture)

readFrame : Unit -> <FFI "js/canvas"> Frame
readFrame _ =
  let pointer = Pointer {
    x = Canvas.pointerX (),
    y = Canvas.pointerY (),
    inside = Canvas.pointerInside (),
    down = Canvas.pointerDown (),
  }
  Frame {
    elapsed = Canvas.elapsed (),
    delta = Canvas.delta (),
    width = Canvas.width (),
    height = Canvas.height (),
    pointer = pointer,
  }

{- | Draw one picture and finish without requesting another frame. -}
export
drawing : Picture -> <FFI "js/canvas"> Unit
drawing scene =
  Canvas.begin False
  Canvas.render scene

{- | Draw a pure scene function of elapsed seconds on each frame. -}
export
animate : (Float -> Picture) -> <FFI "js/canvas"> Unit
animate scene =
  Canvas.begin True
  Canvas.render (scene (Canvas.elapsed ()))

{- | Draw a pure scene function with viewport and pointer input. -}
export
animateWith : (Frame -> Picture) -> <FFI "js/canvas"> Unit
animateWith scene =
  Canvas.begin True
  Canvas.render (scene (readFrame ()))

{- | Capture an initial model and pure update and view functions.

   Construction makes no host call and does not invoke either callback. -}
export
simulation : model ->
  (Frame -> model -> model) ->
  (Frame -> model -> Picture) ->
  Simulation model
simulation initial update view = Simulation (Ref initial) (Ref True) update view

{- | Render the initial model, then update once before each later view.

   Call from main with a simulation retained at module scope. Other effects
   in main repeat on each delivered frame too. -}
export
runSimulation : Simulation model -> <FFI "js/canvas"> Unit
runSimulation (Simulation cell first update view) =
  Canvas.begin True
  let frame = readFrame ()
  if !first then first := False else cell := update frame !cell
  Canvas.render (view frame !cell)
# DESUGAR
(DUse false (UseAlias ("canvas_host") "Canvas"))
(DUse false (UseGroup ("graphics") ((mem "Picture" false))))
(DData Public "Pointer" () ((variant "Pointer" (ConNamed (field "x" (TyCon "Float")) (field "y" (TyCon "Float")) (field "inside" (TyCon "Bool")) (field "down" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "Pointer")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Pointer" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1")) (rf "inside" (PVar "__a2")) (rf "down" (PVar "__a3"))) false) (PRec "Pointer" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1")) (rf "inside" (PVar "__b2")) (rf "down" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Pointer")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Pointer" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1")) (rf "inside" (PVar "__a2")) (rf "down" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pointer {")) (ELit (LString " x = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", inside = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", down = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "Frame" () ((variant "Frame" (ConNamed (field "elapsed" (TyCon "Float")) (field "delta" (TyCon "Float")) (field "width" (TyCon "Float")) (field "height" (TyCon "Float")) (field "pointer" (TyCon "Pointer"))))) ())
(DImpl true "Eq" ((TyCon "Frame")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Frame" ((rf "elapsed" (PVar "__a0")) (rf "delta" (PVar "__a1")) (rf "width" (PVar "__a2")) (rf "height" (PVar "__a3")) (rf "pointer" (PVar "__a4"))) false) (PRec "Frame" ((rf "elapsed" (PVar "__b0")) (rf "delta" (PVar "__b1")) (rf "width" (PVar "__b2")) (rf "height" (PVar "__b3")) (rf "pointer" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "Frame")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Frame" ((rf "elapsed" (PVar "__a0")) (rf "delta" (PVar "__a1")) (rf "width" (PVar "__a2")) (rf "height" (PVar "__a3")) (rf "pointer" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Frame {")) (ELit (LString " elapsed = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", delta = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", width = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", height = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", pointer = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Abstract "Simulation" ("model") ((variant "Simulation" (ConPos (TyApp (TyCon "Ref") (TyVar "model")) (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyVar "model"))) (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyCon "Picture")))))) ())
(DTypeSig false "readFrame" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Frame"))))
(DFunDef false "readFrame" (PWild) (EBlock (DoLet false false (PVar "pointer") (ERecordCreate "Pointer" ((fa "x" (EApp (EVar "Canvas.pointerX") (ELit LUnit))) (fa "y" (EApp (EVar "Canvas.pointerY") (ELit LUnit))) (fa "inside" (EApp (EVar "Canvas.pointerInside") (ELit LUnit))) (fa "down" (EApp (EVar "Canvas.pointerDown") (ELit LUnit)))))) (DoExpr (ERecordCreate "Frame" ((fa "elapsed" (EApp (EVar "Canvas.elapsed") (ELit LUnit))) (fa "delta" (EApp (EVar "Canvas.delta") (ELit LUnit))) (fa "width" (EApp (EVar "Canvas.width") (ELit LUnit))) (fa "height" (EApp (EVar "Canvas.height") (ELit LUnit))) (fa "pointer" (EVar "pointer")))))))
(DTypeSig true "drawing" (TyFun (TyCon "Picture") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "drawing" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "False"))) (DoExpr (EApp (EVar "Canvas.render") (EVar "scene")))))
(DTypeSig true "animate" (TyFun (TyFun (TyCon "Float") (TyCon "Picture")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "animate" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EVar "scene") (EApp (EVar "Canvas.elapsed") (ELit LUnit)))))))
(DTypeSig true "animateWith" (TyFun (TyFun (TyCon "Frame") (TyCon "Picture")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "animateWith" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EVar "scene") (EApp (EVar "readFrame") (ELit LUnit)))))))
(DTypeSig true "simulation" (TyFun (TyVar "model") (TyFun (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyVar "model"))) (TyFun (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyCon "Picture"))) (TyApp (TyCon "Simulation") (TyVar "model"))))))
(DFunDef false "simulation" ((PVar "initial") (PVar "update") (PVar "view")) (EApp (EApp (EApp (EApp (EVar "Simulation") (EApp (EVar "Ref") (EVar "initial"))) (EApp (EVar "Ref") (EVar "True"))) (EVar "update")) (EVar "view")))
(DTypeSig true "runSimulation" (TyFun (TyApp (TyCon "Simulation") (TyVar "model")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "runSimulation" ((PCon "Simulation" (PVar "cell") (PVar "first") (PVar "update") (PVar "view"))) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoLet false false (PVar "frame") (EApp (EVar "readFrame") (ELit LUnit))) (DoExpr (EIf (EUnOp "!" (EVar "first")) (EApp (EApp (EVar "setRef") (EVar "first")) (EVar "False")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "update") (EVar "frame")) (EUnOp "!" (EVar "cell")))))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EApp (EVar "view") (EVar "frame")) (EUnOp "!" (EVar "cell")))))))
# MARK
(DUse false (UseAlias ("canvas_host") "Canvas"))
(DUse false (UseGroup ("graphics") ((mem "Picture" false))))
(DData Public "Pointer" () ((variant "Pointer" (ConNamed (field "x" (TyCon "Float")) (field "y" (TyCon "Float")) (field "inside" (TyCon "Bool")) (field "down" (TyCon "Bool"))))) ())
(DImpl true "Eq" ((TyCon "Pointer")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Pointer" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1")) (rf "inside" (PVar "__a2")) (rf "down" (PVar "__a3"))) false) (PRec "Pointer" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1")) (rf "inside" (PVar "__b2")) (rf "down" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Pointer")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Pointer" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1")) (rf "inside" (PVar "__a2")) (rf "down" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pointer {")) (ELit (LString " x = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", inside = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", down = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "Frame" () ((variant "Frame" (ConNamed (field "elapsed" (TyCon "Float")) (field "delta" (TyCon "Float")) (field "width" (TyCon "Float")) (field "height" (TyCon "Float")) (field "pointer" (TyCon "Pointer"))))) ())
(DImpl true "Eq" ((TyCon "Frame")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Frame" ((rf "elapsed" (PVar "__a0")) (rf "delta" (PVar "__a1")) (rf "width" (PVar "__a2")) (rf "height" (PVar "__a3")) (rf "pointer" (PVar "__a4"))) false) (PRec "Frame" ((rf "elapsed" (PVar "__b0")) (rf "delta" (PVar "__b1")) (rf "width" (PVar "__b2")) (rf "height" (PVar "__b3")) (rf "pointer" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "Frame")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Frame" ((rf "elapsed" (PVar "__a0")) (rf "delta" (PVar "__a1")) (rf "width" (PVar "__a2")) (rf "height" (PVar "__a3")) (rf "pointer" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Frame {")) (ELit (LString " elapsed = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", delta = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", width = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", height = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", pointer = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Abstract "Simulation" ("model") ((variant "Simulation" (ConPos (TyApp (TyCon "Ref") (TyVar "model")) (TyApp (TyCon "Ref") (TyCon "Bool")) (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyVar "model"))) (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyCon "Picture")))))) ())
(DTypeSig false "readFrame" (TyFun (TyCon "Unit") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Frame"))))
(DFunDef false "readFrame" (PWild) (EBlock (DoLet false false (PVar "pointer") (ERecordCreate "Pointer" ((fa "x" (EApp (EVar "Canvas.pointerX") (ELit LUnit))) (fa "y" (EApp (EVar "Canvas.pointerY") (ELit LUnit))) (fa "inside" (EApp (EVar "Canvas.pointerInside") (ELit LUnit))) (fa "down" (EApp (EVar "Canvas.pointerDown") (ELit LUnit)))))) (DoExpr (ERecordCreate "Frame" ((fa "elapsed" (EApp (EVar "Canvas.elapsed") (ELit LUnit))) (fa "delta" (EApp (EVar "Canvas.delta") (ELit LUnit))) (fa "width" (EApp (EVar "Canvas.width") (ELit LUnit))) (fa "height" (EApp (EVar "Canvas.height") (ELit LUnit))) (fa "pointer" (EVar "pointer")))))))
(DTypeSig true "drawing" (TyFun (TyCon "Picture") (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "drawing" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "False"))) (DoExpr (EApp (EVar "Canvas.render") (EVar "scene")))))
(DTypeSig true "animate" (TyFun (TyFun (TyCon "Float") (TyCon "Picture")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "animate" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EVar "scene") (EApp (EVar "Canvas.elapsed") (ELit LUnit)))))))
(DTypeSig true "animateWith" (TyFun (TyFun (TyCon "Frame") (TyCon "Picture")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "animateWith" ((PVar "scene")) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EVar "scene") (EApp (EVar "readFrame") (ELit LUnit)))))))
(DTypeSig true "simulation" (TyFun (TyVar "model") (TyFun (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyVar "model"))) (TyFun (TyFun (TyCon "Frame") (TyFun (TyVar "model") (TyCon "Picture"))) (TyApp (TyCon "Simulation") (TyVar "model"))))))
(DFunDef false "simulation" ((PVar "initial") (PVar "update") (PVar "view")) (EApp (EApp (EApp (EApp (EVar "Simulation") (EApp (EVar "Ref") (EVar "initial"))) (EApp (EVar "Ref") (EVar "True"))) (EVar "update")) (EVar "view")))
(DTypeSig true "runSimulation" (TyFun (TyApp (TyCon "Simulation") (TyVar "model")) (TyEffect ((atom "FFI" "js/canvas")) None (TyCon "Unit"))))
(DFunDef false "runSimulation" ((PCon "Simulation" (PVar "cell") (PVar "first") (PVar "update") (PVar "view"))) (EBlock (DoExpr (EApp (EVar "Canvas.begin") (EVar "True"))) (DoLet false false (PVar "frame") (EApp (EVar "readFrame") (ELit LUnit))) (DoExpr (EIf (EUnOp "!" (EVar "first")) (EApp (EApp (EVar "setRef") (EVar "first")) (EVar "False")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "update") (EVar "frame")) (EUnOp "!" (EVar "cell")))))) (DoExpr (EApp (EVar "Canvas.render") (EApp (EApp (EVar "view") (EVar "frame")) (EUnOp "!" (EVar "cell")))))))
