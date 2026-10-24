# META
source_lines=172
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Pat(..)}
import ir.core_ir.{
  CProgram(..), CBind(..), CClause(..), CExpr(..), CImplEntry(..),
  CImplBody(..), CField(..), CStmt(..), CArm(..), CGuard(..)
}
import backend.trmc_analysis.{patVars, bindName}
import support.ordmap.{OrdMap, omEmpty, omLookup, omInsert}
import support.util.{startsWith}

export
uniqueBinders : CProgram -> CProgram
uniqueBinders (CProgram groups ctorArs ctorTypes impls mctx facts) =
  CProgram
    (map (ubBind omEmpty) groups)
    ctorArs
    ctorTypes
    (map ubImpl impls)
    mctx
    facts

ubImpl : CImplEntry -> CImplEntry
ubImpl (CImplEntry m a b (CImplTagged t k i sym pos pats body)) =
  CImplEntry
    m
    a
    b
    (CImplTagged
      t
      k
      i
      sym
      pos
      (map (ubPat omEmpty) pats)
      (ubExpr (ubExtend omEmpty pats) body))
ubImpl (CImplEntry m a b (CImplDefault t k i sym pos pats body)) =
  CImplEntry
    m
    a
    b
    (CImplDefault
      t
      k
      i
      sym
      pos
      (map (ubPat omEmpty) pats)
      (ubExpr (ubExtend omEmpty pats) body))

ubShadowable : String -> Bool
ubShadowable x = not (startsWith "$" x)

-- the name a binder introduced now gets
ubNew : OrdMap Int -> String -> String
ubNew sc x = match omLookup x sc
  Some n => if ubShadowable x then "\{x}$\{intToString n}" else x
  None => x

-- the name a reference resolves to
ubRef : OrdMap Int -> String -> String
ubRef sc x = match omLookup x sc
  Some n => if n > 1 then "\{x}$\{intToString (n - 1)}" else x
  None => x

ubBump : OrdMap Int -> String -> OrdMap Int
ubBump sc x =
  if ubShadowable x then
    omInsert
      x
      (match omLookup x sc
        Some n => n + 1
        None => 1)
      sc
  else
    sc

ubBumpAll : OrdMap Int -> List String -> OrdMap Int
ubBumpAll sc [] = sc
ubBumpAll sc (x :: xs) = ubBumpAll (ubBump sc x) xs

ubExtend : OrdMap Int -> List Pat -> OrdMap Int
ubExtend sc pats = ubBumpAll sc (flatMap patVars pats)

ubPat : OrdMap Int -> Pat -> Pat
ubPat sc (PVar x l bid) = PVar (ubNew sc x) l bid
ubPat sc (PCon c ps) = PCon c (map (ubPat sc) ps)
ubPat sc (PCons h t) = PCons (ubPat sc h) (ubPat sc t)
ubPat sc (PTuple ps) = PTuple (map (ubPat sc) ps)
ubPat sc (PList ps) = PList (map (ubPat sc) ps)
ubPat sc (PAs x l bid p) = PAs (ubNew sc x) l bid (ubPat sc p)
ubPat _ p = p

ubBind : OrdMap Int -> CBind -> CBind
ubBind sc (CBind n clauses loc bid) =
  CBind n (map (ubClause sc) clauses) loc bid

ubClause : OrdMap Int -> CClause -> CClause
ubClause sc (CClause pats body) =
  CClause (map (ubPat sc) pats) (ubExpr (ubExtend sc pats) body)

ubExprs : OrdMap Int -> List CExpr -> List CExpr
ubExprs sc es = map (ubExpr sc) es

ubField : OrdMap Int -> CField -> CField
ubField sc (CField l o e) = CField l o (ubExpr sc e)

ubExpr : OrdMap Int -> CExpr -> CExpr
ubExpr sc (CVar x a) = CVar (ubRef sc x) a
ubExpr sc (CApp f args cs) = CApp (ubExpr sc f) (ubExprs sc args) cs
ubExpr sc (CLam pats b) =
  CLam (map (ubPat sc) pats) (ubExpr (ubExtend sc pats) b)
ubExpr sc (CLet r pat e1 e2) =
  let sc2 = ubExtend sc [pat]
  CLet r (ubPat sc pat) (ubExpr (if r then sc2 else sc) e1) (ubExpr sc2 e2)
ubExpr sc (CLetGroup binds body) =
  let sc2 = ubBumpAll sc (map bindName binds)
  CLetGroup (map (b => ubBind sc2 (ubRenameBind sc b)) binds) (ubExpr sc2 body)
ubExpr sc (CMatch scrut arms) = CMatch (ubExpr sc scrut) (map (ubArm sc) arms)
ubExpr sc (CDecision scrut arms tree) =
  CDecision (ubExpr sc scrut) (map (ubArm sc) arms) tree
ubExpr sc (CIf c t f) = CIf (ubExpr sc c) (ubExpr sc t) (ubExpr sc f)
ubExpr sc (CBinPrim op l r tag loc) =
  CBinPrim op (ubExpr sc l) (ubExpr sc r) tag loc
ubExpr sc (CUnOp op x) = CUnOp op (ubExpr sc x)
ubExpr sc (CTuple es) = CTuple (ubExprs sc es)
ubExpr sc (CList es) = CList (ubExprs sc es)
ubExpr sc (CArray es) = CArray (ubExprs sc es)
ubExpr sc (CRecord n fs) = CRecord n (map (ubField sc) fs)
ubExpr sc (CFieldAccess e l r o) = CFieldAccess (ubExpr sc e) l r o
ubExpr sc (CRecordUpdate n e fs) =
  CRecordUpdate n (ubExpr sc e) (map (ubField sc) fs)
ubExpr sc (CVariantUpdate n e fs) =
  CVariantUpdate n (ubExpr sc e) (map (ubField sc) fs)
ubExpr sc (CRangeList lo hi i) = CRangeList (ubExpr sc lo) (ubExpr sc hi) i
ubExpr sc (CRangeArray lo hi i) = CRangeArray (ubExpr sc lo) (ubExpr sc hi) i
ubExpr sc (CIndex b i) = CIndex (ubExpr sc b) (ubExpr sc i)
ubExpr sc (CSlice b lo hi i) =
  CSlice (ubExpr sc b) (ubExpr sc lo) (ubExpr sc hi) i
ubExpr sc (CStringIndex b i) = CStringIndex (ubExpr sc b) (ubExpr sc i)
ubExpr sc (CStringSlice b lo hi i) =
  CStringSlice (ubExpr sc b) (ubExpr sc lo) (ubExpr sc hi) i
ubExpr sc (CListIndex b i) = CListIndex (ubExpr sc b) (ubExpr sc i)
ubExpr sc (CListSlice b lo hi i) =
  CListSlice (ubExpr sc b) (ubExpr sc lo) (ubExpr sc hi) i
ubExpr sc (CBlock stmts) = CBlock (ubStmts sc stmts)
ubExpr _ e = e

-- a let-group member's own name, as bound in the enclosing scope
ubRenameBind : OrdMap Int -> CBind -> CBind
ubRenameBind sc (CBind n clauses loc bid) = CBind (ubNew sc n) clauses loc bid

ubStmts : OrdMap Int -> List CStmt -> List CStmt
ubStmts _ [] = []
ubStmts sc ((CSExpr e) :: rest) = CSExpr (ubExpr sc e) :: ubStmts sc rest
ubStmts sc ((CSLet r pat e) :: rest) =
  let sc2 = ubExtend sc [pat]
  CSLet r (ubPat sc pat) (ubExpr (if r then sc2 else sc) e) :: ubStmts sc2 rest
ubStmts sc ((CSAssign n e) :: rest) =
  CSAssign (ubRef sc n) (ubExpr sc e) :: ubStmts sc rest

ubArm : OrdMap Int -> CArm -> CArm
ubArm sc (CArm pat guards body) =
  let (guards2, sc2) = ubGuards (ubExtend sc [pat]) guards
  CArm (ubPat sc pat) guards2 (ubExpr sc2 body)

ubGuards : OrdMap Int -> List CGuard -> (List CGuard, OrdMap Int)
ubGuards sc [] = ([], sc)
ubGuards sc ((CGBool g) :: rest) =
  let (rest2, sc2) = ubGuards sc rest
  (CGBool (ubExpr sc g) :: rest2, sc2)
ubGuards sc ((CGBind p e) :: rest) =
  let (rest2, sc2) = ubGuards (ubExtend sc [p]) rest
  (CGBind (ubPat sc p) (ubExpr sc e) :: rest2, sc2)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CField" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false))))
(DTypeSig true "uniqueBinders" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "uniqueBinders" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "ubBind") (EVar "omEmpty"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EVar "ubImpl")) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig false "ubImpl" (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry")))
(DFunDef false "ubImpl" ((PCon "CImplEntry" (PVar "m") (PVar "a") (PVar "b") (PCon "CImplTagged" (PVar "t") (PVar "k") (PVar "i") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "a")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "t")) (EVar "k")) (EVar "i")) (EVar "sym")) (EVar "pos")) (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "omEmpty"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "omEmpty")) (EVar "pats"))) (EVar "body")))))
(DFunDef false "ubImpl" ((PCon "CImplEntry" (PVar "m") (PVar "a") (PVar "b") (PCon "CImplDefault" (PVar "t") (PVar "k") (PVar "i") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "a")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "t")) (EVar "k")) (EVar "i")) (EVar "sym")) (EVar "pos")) (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "omEmpty"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "omEmpty")) (EVar "pats"))) (EVar "body")))))
(DTypeSig false "ubShadowable" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ubShadowable" ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "$"))) (EVar "x"))))
(DTypeSig false "ubNew" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ubNew" ((PVar "sc") (PVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EIf (EApp (EVar "ubShadowable") (EVar "x")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EVar "x"))) (arm (PCon "None") () (EVar "x"))))
(DTypeSig false "ubRef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ubRef" ((PVar "sc") (PVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (ELit (LString ""))) (EVar "x"))) (arm (PCon "None") () (EVar "x"))))
(DTypeSig false "ubBump" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubBump" ((PVar "sc") (PVar "x")) (EIf (EApp (EVar "ubShadowable") (EVar "x")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 1))))) (EVar "sc")) (EVar "sc")))
(DTypeSig false "ubBumpAll" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubBumpAll" ((PVar "sc") (PList)) (EVar "sc"))
(DFunDef false "ubBumpAll" ((PVar "sc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "ubBumpAll") (EApp (EApp (EVar "ubBump") (EVar "sc")) (EVar "x"))) (EVar "xs")))
(DTypeSig false "ubExtend" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubExtend" ((PVar "sc") (PVar "pats")) (EApp (EApp (EVar "ubBumpAll") (EVar "sc")) (EApp (EApp (EVar "flatMap") (EVar "patVars")) (EVar "pats"))))
(DTypeSig false "ubPat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "x"))) (EVar "l")) (EVar "bid")))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "h"))) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "t"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "x"))) (EVar "l")) (EVar "bid")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "p"))))
(DFunDef false "ubPat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "ubBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "ubBind" ((PVar "sc") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "ubClause") (EVar "sc"))) (EVar "clauses"))) (EVar "loc")) (EVar "bid")))
(DTypeSig false "ubClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "ubClause" ((PVar "sc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EVar "pats"))) (EVar "body"))))
(DTypeSig false "ubExprs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "CExpr")))))
(DFunDef false "ubExprs" ((PVar "sc") (PVar "es")) (EApp (EApp (EVar "map") (EApp (EVar "ubExpr") (EVar "sc"))) (EVar "es")))
(DTypeSig false "ubField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "ubField" ((PVar "sc") (PCon "CField" (PVar "l") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "l")) (EVar "o")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))))
(DTypeSig false "ubExpr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CVar" (PVar "x") (PVar "a"))) (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "ubRef") (EVar "sc")) (EVar "x"))) (EVar "a")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CApp" (PVar "f") (PVar "args") (PVar "cs"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "f"))) (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "args"))) (EVar "cs")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EVar "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EVar "pats"))) (EVar "b"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EApp (EApp (EVar "ubExpr") (EIf (EVar "r") (EVar "sc2") (EVar "sc"))) (EVar "e1"))) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "e2"))))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubBumpAll") (EVar "sc")) (EApp (EApp (EVar "map") (EVar "bindName")) (EVar "binds")))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EApp (EVar "ubBind") (EVar "sc2")) (EApp (EApp (EVar "ubRenameBind") (EVar "sc")) (EVar "b"))))) (EVar "binds"))) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "body"))))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "ubArm") (EVar "sc"))) (EVar "arms"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "ubArm") (EVar "sc"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "c"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "t"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "f"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "l"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "r"))) (EVar "tag")) (EVar "loc")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "x"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRecord" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "CRecord") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CFieldAccess" (PVar "e") (PVar "l") (PVar "r") (PVar "o"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EVar "l")) (EVar "r")) (EVar "o")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRecordUpdate" (PVar "n") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "n")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CVariantUpdate" (PVar "n") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "n")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CStringIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CStringSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CListIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CListSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "stmts"))))
(DFunDef false "ubExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ubRenameBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "ubRenameBind" ((PVar "sc") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "n"))) (EVar "clauses")) (EVar "loc")) (EVar "bid")))
(DTypeSig false "ubStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt")))))
(DFunDef false "ubStmts" (PWild (PList)) (EListLit))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "rest"))))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EApp (EApp (EVar "ubExpr") (EIf (EVar "r") (EVar "sc2") (EVar "sc"))) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc2")) (EVar "rest"))))))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSAssign" (PVar "n") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EApp (EApp (EVar "ubRef") (EVar "sc")) (EVar "n"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "rest"))))
(DTypeSig false "ubArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "ubArm" ((PVar "sc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EVar "guards2")) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "body"))))))
(DTypeSig false "ubGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "ubGuards" ((PVar "sc") (PList)) (ETuple (EListLit) (EVar "sc")))
(DFunDef false "ubGuards" ((PVar "sc") (PCons (PCon "CGBool" (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EVar "sc")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "g"))) (EVar "rest2")) (EVar "sc2")))))
(DFunDef false "ubGuards" ((PVar "sc") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "p")))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "p"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EVar "rest2")) (EVar "sc2")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CField" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omInsert" false))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false))))
(DTypeSig true "uniqueBinders" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "uniqueBinders" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "ubBind") (EVar "omEmpty"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EVar "ubImpl")) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig false "ubImpl" (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry")))
(DFunDef false "ubImpl" ((PCon "CImplEntry" (PVar "m") (PVar "a") (PVar "b") (PCon "CImplTagged" (PVar "t") (PVar "k") (PVar "i") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "a")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "t")) (EVar "k")) (EVar "i")) (EVar "sym")) (EVar "pos")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "omEmpty"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "omEmpty")) (EVar "pats"))) (EVar "body")))))
(DFunDef false "ubImpl" ((PCon "CImplEntry" (PVar "m") (PVar "a") (PVar "b") (PCon "CImplDefault" (PVar "t") (PVar "k") (PVar "i") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "a")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "t")) (EVar "k")) (EVar "i")) (EVar "sym")) (EVar "pos")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "omEmpty"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "omEmpty")) (EVar "pats"))) (EVar "body")))))
(DTypeSig false "ubShadowable" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ubShadowable" ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "$"))) (EVar "x"))))
(DTypeSig false "ubNew" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ubNew" ((PVar "sc") (PVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EIf (EApp (EVar "ubShadowable") (EVar "x")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EVar "x"))) (arm (PCon "None") () (EVar "x"))))
(DTypeSig false "ubRef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ubRef" ((PVar "sc") (PVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp ">" (EVar "n") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (ELit (LString ""))) (EVar "x"))) (arm (PCon "None") () (EVar "x"))))
(DTypeSig false "ubBump" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubBump" ((PVar "sc") (PVar "x")) (EIf (EApp (EVar "ubShadowable") (EVar "x")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "x")) (EVar "sc")) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 1))))) (EVar "sc")) (EVar "sc")))
(DTypeSig false "ubBumpAll" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubBumpAll" ((PVar "sc") (PList)) (EVar "sc"))
(DFunDef false "ubBumpAll" ((PVar "sc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "ubBumpAll") (EApp (EApp (EVar "ubBump") (EVar "sc")) (EVar "x"))) (EVar "xs")))
(DTypeSig false "ubExtend" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "ubExtend" ((PVar "sc") (PVar "pats")) (EApp (EApp (EVar "ubBumpAll") (EVar "sc")) (EApp (EApp (EDictApp "flatMap") (EVar "patVars")) (EVar "pats"))))
(DTypeSig false "ubPat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "x"))) (EVar "l")) (EVar "bid")))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "h"))) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "t"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "ps"))))
(DFunDef false "ubPat" ((PVar "sc") (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "x"))) (EVar "l")) (EVar "bid")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "p"))))
(DFunDef false "ubPat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "ubBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "ubBind" ((PVar "sc") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubClause") (EVar "sc"))) (EVar "clauses"))) (EVar "loc")) (EVar "bid")))
(DTypeSig false "ubClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "ubClause" ((PVar "sc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EVar "pats"))) (EVar "body"))))
(DTypeSig false "ubExprs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "CExpr")))))
(DFunDef false "ubExprs" ((PVar "sc") (PVar "es")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubExpr") (EVar "sc"))) (EVar "es")))
(DTypeSig false "ubField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "ubField" ((PVar "sc") (PCon "CField" (PVar "l") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "l")) (EVar "o")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))))
(DTypeSig false "ubExpr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CVar" (PVar "x") (PVar "a"))) (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "ubRef") (EVar "sc")) (EVar "x"))) (EVar "a")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CApp" (PVar "f") (PVar "args") (PVar "cs"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "f"))) (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "args"))) (EVar "cs")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EMethodRef "map") (EApp (EVar "ubPat") (EVar "sc"))) (EVar "pats"))) (EApp (EApp (EVar "ubExpr") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EVar "pats"))) (EVar "b"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EApp (EApp (EVar "ubExpr") (EIf (EVar "r") (EVar "sc2") (EVar "sc"))) (EVar "e1"))) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "e2"))))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubBumpAll") (EVar "sc")) (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EVar "binds")))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EApp (EVar "ubBind") (EVar "sc2")) (EApp (EApp (EVar "ubRenameBind") (EVar "sc")) (EVar "b"))))) (EVar "binds"))) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "body"))))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubArm") (EVar "sc"))) (EVar "arms"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubArm") (EVar "sc"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "c"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "t"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "f"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "l"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "r"))) (EVar "tag")) (EVar "loc")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "x"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "ubExprs") (EVar "sc")) (EVar "es"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRecord" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "CRecord") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CFieldAccess" (PVar "e") (PVar "l") (PVar "r") (PVar "o"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EVar "l")) (EVar "r")) (EVar "o")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRecordUpdate" (PVar "n") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "n")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CVariantUpdate" (PVar "n") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "n")) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ubField") (EVar "sc"))) (EVar "fs"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CStringIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CStringSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CListIndex" (PVar "b") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "i"))))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CListSlice" (PVar "b") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "b"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "lo"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "ubExpr" ((PVar "sc") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "stmts"))))
(DFunDef false "ubExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ubRenameBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "ubRenameBind" ((PVar "sc") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "ubNew") (EVar "sc")) (EVar "n"))) (EVar "clauses")) (EVar "loc")) (EVar "bid")))
(DTypeSig false "ubStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt")))))
(DFunDef false "ubStmts" (PWild (PList)) (EListLit))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "rest"))))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sc2") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EApp (EApp (EVar "ubExpr") (EIf (EVar "r") (EVar "sc2") (EVar "sc"))) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc2")) (EVar "rest"))))))
(DFunDef false "ubStmts" ((PVar "sc") (PCons (PCon "CSAssign" (PVar "n") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EApp (EApp (EVar "ubRef") (EVar "sc")) (EVar "n"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EApp (EApp (EVar "ubStmts") (EVar "sc")) (EVar "rest"))))
(DTypeSig false "ubArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "ubArm" ((PVar "sc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "pat")))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "pat"))) (EVar "guards2")) (EApp (EApp (EVar "ubExpr") (EVar "sc2")) (EVar "body"))))))
(DTypeSig false "ubGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "ubGuards" ((PVar "sc") (PList)) (ETuple (EListLit) (EVar "sc")))
(DFunDef false "ubGuards" ((PVar "sc") (PCons (PCon "CGBool" (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EVar "sc")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "g"))) (EVar "rest2")) (EVar "sc2")))))
(DFunDef false "ubGuards" ((PVar "sc") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "sc2")) (EApp (EApp (EVar "ubGuards") (EApp (EApp (EVar "ubExtend") (EVar "sc")) (EListLit (EVar "p")))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "ubPat") (EVar "sc")) (EVar "p"))) (EApp (EApp (EVar "ubExpr") (EVar "sc")) (EVar "e"))) (EVar "rest2")) (EVar "sc2")))))
