# META
source_lines=96
stages=DESUGAR,MARK
# SOURCE
-- What the auto-print judgment of a value `main` (`autoPrintWanted`,
-- types/typecheck.mdk) reads off the entry module's own declarations: where
-- another binding uses `main`, and whether a diagnostic lies inside `main`'s
-- binding.  Pure functions over the AST; no typechecker state.

import frontend.ast.{Decl(..), Expr(..), Loc(..)}
import frontend.desugar.{mapChildren}
import frontend.marker.{declBodies, declRefs, localBoundNames}
import support.util.{anyList}

-- The first use of the top-level `main` by another binding of [decls], located
-- at the innermost span around it, else at [fallback].  A binding that binds a
-- local `main` anywhere (a parameter, a `let`, a pattern) is read as using that
-- local, so none of its occurrences count.
export
mainUseSite : Loc -> List Decl -> Option Loc
mainUseSite _ [] = None
mainUseSite fallback (d :: rest) =
  if usesTopMain d then
    Some (optionOr fallback (firstVarSpan "main" (declBodies d)))
  else
    mainUseSite fallback rest

export
mainUsedMsg : String
mainUsedMsg =
  "`main` is the auto-printed entry point, so other bindings cannot use it; move the shared value into its own binding"

usesTopMain : Decl -> Bool
usesTopMain d =
  not (definesMain d)
    && anyList (== "main") (declRefs d)
    && not (anyList (== "main") (localBoundNames [d]))

definesMain : Decl -> Bool
definesMain (DAttrib _ d) = definesMain d
definesMain (DFunDef _ "main" _ _ _ _) = True
definesMain _ = False

-- The innermost span around the first occurrence of [name] in [bodies].
firstVarSpan : String -> List Expr -> Option Loc
firstVarSpan name bodies =
  let found = Ref None
  let _ = map (walkLocated (visitVar name found) None) bodies
  !found

visitVar : String -> Ref (Option Loc) -> Option Loc -> Expr -> Unit
visitVar name found at (EVar x) = match !found
  None => if x == name then found := at
  Some _ => ()
visitVar _ _ _ _ = ()

-- Visit every subexpression of [e] top-down with the innermost `ELoc` span
-- enclosing it.
walkLocated : (Option Loc -> Expr -> Unit) -> Option Loc -> Expr -> Unit
walkLocated visit at e =
  let here = match e
    ELoc l _ => Some l
    _ => at
  visit here e
  let _ = mapChildren (c => keep c (walkLocated visit here c)) e
  ()

keep : Expr -> Unit -> Expr
keep e _ = e

-- True iff [loc] starts inside the binding of the zero-argument `main` in
-- [decls]: from its name token to the end of the last span its body carries.
export
inMainBinding : List Decl -> Option Loc -> Bool
inMainBinding _ None = False
inMainBinding decls (Some (Loc f l c _ _)) = match mainBinding decls
  Some (Loc mf sl sc el ec, body) =>
    let (endL, endC) = bodyEnd (el, ec) body
    f == mf && before (sl, sc) (l, c) && before (l, c) (endL, endC)
  None => False

mainBinding : List Decl -> Option (Loc, Expr)
mainBinding [] = None
mainBinding ((DAttrib _ d) :: rest) = mainBinding (d :: rest)
mainBinding ((DFunDef _ "main" [] body site _) :: _) = Some (site, body)
mainBinding (_ :: rest) = mainBinding rest

bodyEnd : (Int, Int) -> Expr -> (Int, Int)
bodyEnd start body =
  let last = Ref start
  walkLocated (visitEnd last) None body
  !last

visitEnd : Ref (Int, Int) -> Option Loc -> Expr -> Unit
visitEnd last _ (ELoc (Loc _ _ _ el ec) _) =
  if before !last (el, ec) then last := (el, ec)
visitEnd _ _ _ = ()

before : (Int, Int) -> (Int, Int) -> Bool
before (l1, c1) (l2, c2) = l1 < l2 || l1 == l2 && c1 <= c2
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declBodies" false) (mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false))))
(DTypeSig true "mainUseSite" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "mainUseSite" (PWild (PList)) (EVar "None"))
(DFunDef false "mainUseSite" ((PVar "fallback") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "usesTopMain") (EVar "d")) (EApp (EVar "Some") (EApp (EApp (EVar "optionOr") (EVar "fallback")) (EApp (EApp (EVar "firstVarSpan") (ELit (LString "main"))) (EApp (EVar "declBodies") (EVar "d"))))) (EApp (EApp (EVar "mainUseSite") (EVar "fallback")) (EVar "rest"))))
(DTypeSig true "mainUsedMsg" (TyCon "String"))
(DFunDef false "mainUsedMsg" () (ELit (LString "`main` is the auto-printed entry point, so other bindings cannot use it; move the shared value into its own binding")))
(DTypeSig false "usesTopMain" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "usesTopMain" ((PVar "d")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "definesMain") (EVar "d"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "declRefs") (EVar "d")))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "localBoundNames") (EListLit (EVar "d")))))))
(DTypeSig false "definesMain" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "definesMain" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "definesMain") (EVar "d")))
(DFunDef false "definesMain" ((PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "definesMain" (PWild) (EVar "False"))
(DTypeSig false "firstVarSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "firstVarSpan" ((PVar "name") (PVar "bodies")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "map") (EApp (EApp (EVar "walkLocated") (EApp (EApp (EVar "visitVar") (EVar "name")) (EVar "found"))) (EVar "None"))) (EVar "bodies"))) (DoExpr (EUnOp "!" (EVar "found")))))
(DTypeSig false "visitVar" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "visitVar" ((PVar "name") (PVar "found") (PVar "at") (PCon "EVar" (PVar "x"))) (EMatch (EUnOp "!" (EVar "found")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "at")) (ELit LUnit))) (arm (PCon "Some" PWild) () (ELit LUnit))))
(DFunDef false "visitVar" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkLocated" (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "walkLocated" ((PVar "visit") (PVar "at") (PVar "e")) (EBlock (DoLet false false (PVar "here") (EMatch (EVar "e") (arm (PCon "ELoc" (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "at")))) (DoExpr (EApp (EApp (EVar "visit") (EVar "here")) (EVar "e"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "c")) (EApp (EApp (EVar "keep") (EVar "c")) (EApp (EApp (EApp (EVar "walkLocated") (EVar "visit")) (EVar "here")) (EVar "c"))))) (EVar "e"))) (DoExpr (ELit LUnit))))
(DTypeSig false "keep" (TyFun (TyCon "Expr") (TyFun (TyCon "Unit") (TyCon "Expr"))))
(DFunDef false "keep" ((PVar "e") PWild) (EVar "e"))
(DTypeSig true "inMainBinding" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "inMainBinding" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "inMainBinding" ((PVar "decls") (PCon "Some" (PCon "Loc" (PVar "f") (PVar "l") (PVar "c") PWild PWild))) (EMatch (EApp (EVar "mainBinding") (EVar "decls")) (arm (PCon "Some" (PTuple (PCon "Loc" (PVar "mf") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "body"))) () (EBlock (DoLet false false (PTuple (PVar "endL") (PVar "endC")) (EApp (EApp (EVar "bodyEnd") (ETuple (EVar "el") (EVar "ec"))) (EVar "body"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f") (EVar "mf")) (EApp (EApp (EVar "before") (ETuple (EVar "sl") (EVar "sc"))) (ETuple (EVar "l") (EVar "c")))) (EApp (EApp (EVar "before") (ETuple (EVar "l") (EVar "c"))) (ETuple (EVar "endL") (EVar "endC"))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "mainBinding" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "mainBinding" ((PList)) (EVar "None"))
(DFunDef false "mainBinding" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainBinding") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainBinding" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") (PVar "site") PWild) PWild)) (EApp (EVar "Some") (ETuple (EVar "site") (EVar "body"))))
(DFunDef false "mainBinding" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainBinding") (EVar "rest")))
(DTypeSig false "bodyEnd" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bodyEnd" ((PVar "start") (PVar "body")) (EBlock (DoLet false false (PVar "last") (EApp (EVar "Ref") (EVar "start"))) (DoExpr (EApp (EApp (EApp (EVar "walkLocated") (EApp (EVar "visitEnd") (EVar "last"))) (EVar "None")) (EVar "body"))) (DoExpr (EUnOp "!" (EVar "last")))))
(DTypeSig false "visitEnd" (TyFun (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "visitEnd" ((PVar "last") PWild (PCon "ELoc" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EIf (EApp (EApp (EVar "before") (EUnOp "!" (EVar "last"))) (ETuple (EVar "el") (EVar "ec"))) (EApp (EApp (EVar "setRef") (EVar "last")) (ETuple (EVar "el") (EVar "ec"))) (ELit LUnit)))
(DFunDef false "visitEnd" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "before" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "before" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declBodies" false) (mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false))))
(DTypeSig true "mainUseSite" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "mainUseSite" (PWild (PList)) (EVar "None"))
(DFunDef false "mainUseSite" ((PVar "fallback") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "usesTopMain") (EVar "d")) (EApp (EVar "Some") (EApp (EApp (EVar "optionOr") (EVar "fallback")) (EApp (EApp (EVar "firstVarSpan") (ELit (LString "main"))) (EApp (EVar "declBodies") (EVar "d"))))) (EApp (EApp (EVar "mainUseSite") (EVar "fallback")) (EVar "rest"))))
(DTypeSig true "mainUsedMsg" (TyCon "String"))
(DFunDef false "mainUsedMsg" () (ELit (LString "`main` is the auto-printed entry point, so other bindings cannot use it; move the shared value into its own binding")))
(DTypeSig false "usesTopMain" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "usesTopMain" ((PVar "d")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "definesMain") (EVar "d"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "declRefs") (EVar "d")))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "localBoundNames") (EListLit (EVar "d")))))))
(DTypeSig false "definesMain" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "definesMain" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "definesMain") (EVar "d")))
(DFunDef false "definesMain" ((PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "definesMain" (PWild) (EVar "False"))
(DTypeSig false "firstVarSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "firstVarSpan" ((PVar "name") (PVar "bodies")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "walkLocated") (EApp (EApp (EVar "visitVar") (EVar "name")) (EVar "found"))) (EVar "None"))) (EVar "bodies"))) (DoExpr (EUnOp "!" (EVar "found")))))
(DTypeSig false "visitVar" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "visitVar" ((PVar "name") (PVar "found") (PVar "at") (PCon "EVar" (PVar "x"))) (EMatch (EUnOp "!" (EVar "found")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "at")) (ELit LUnit))) (arm (PCon "Some" PWild) () (ELit LUnit))))
(DFunDef false "visitVar" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkLocated" (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "walkLocated" ((PVar "visit") (PVar "at") (PVar "e")) (EBlock (DoLet false false (PVar "here") (EMatch (EVar "e") (arm (PCon "ELoc" (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "at")))) (DoExpr (EApp (EApp (EVar "visit") (EVar "here")) (EVar "e"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "c")) (EApp (EApp (EVar "keep") (EVar "c")) (EApp (EApp (EApp (EVar "walkLocated") (EVar "visit")) (EVar "here")) (EVar "c"))))) (EVar "e"))) (DoExpr (ELit LUnit))))
(DTypeSig false "keep" (TyFun (TyCon "Expr") (TyFun (TyCon "Unit") (TyCon "Expr"))))
(DFunDef false "keep" ((PVar "e") PWild) (EVar "e"))
(DTypeSig true "inMainBinding" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "inMainBinding" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "inMainBinding" ((PVar "decls") (PCon "Some" (PCon "Loc" (PVar "f") (PVar "l") (PVar "c") PWild PWild))) (EMatch (EApp (EVar "mainBinding") (EVar "decls")) (arm (PCon "Some" (PTuple (PCon "Loc" (PVar "mf") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "body"))) () (EBlock (DoLet false false (PTuple (PVar "endL") (PVar "endC")) (EApp (EApp (EVar "bodyEnd") (ETuple (EVar "el") (EVar "ec"))) (EVar "body"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f") (EVar "mf")) (EApp (EApp (EVar "before") (ETuple (EVar "sl") (EVar "sc"))) (ETuple (EVar "l") (EVar "c")))) (EApp (EApp (EVar "before") (ETuple (EVar "l") (EVar "c"))) (ETuple (EVar "endL") (EVar "endC"))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "mainBinding" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "mainBinding" ((PList)) (EVar "None"))
(DFunDef false "mainBinding" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainBinding") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainBinding" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") (PVar "site") PWild) PWild)) (EApp (EVar "Some") (ETuple (EVar "site") (EVar "body"))))
(DFunDef false "mainBinding" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainBinding") (EVar "rest")))
(DTypeSig false "bodyEnd" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bodyEnd" ((PVar "start") (PVar "body")) (EBlock (DoLet false false (PVar "last") (EApp (EVar "Ref") (EVar "start"))) (DoExpr (EApp (EApp (EApp (EVar "walkLocated") (EApp (EVar "visitEnd") (EVar "last"))) (EVar "None")) (EVar "body"))) (DoExpr (EUnOp "!" (EVar "last")))))
(DTypeSig false "visitEnd" (TyFun (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "visitEnd" ((PVar "last") PWild (PCon "ELoc" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EIf (EApp (EApp (EVar "before") (EUnOp "!" (EVar "last"))) (ETuple (EVar "el") (EVar "ec"))) (EApp (EApp (EVar "setRef") (EVar "last")) (ETuple (EVar "el") (EVar "ec"))) (ELit LUnit)))
(DFunDef false "visitEnd" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "before" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "before" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))))
