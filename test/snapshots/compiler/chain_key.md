# META
source_lines=55
stages=DESUGAR,MARK
# SOURCE
-- The part of the module-chain memo key that covers what a recorded step reads
-- from modules outside its own prefix: every instance head, which is visible to
-- the whole graph whether or not a module imports its definer, every interface
-- declaration with its method names and the declaring module's position, which a
-- module checked after it reads by bare name whether or not it imports it, and
-- every constrained signature's bare name, which joins every module's dict-name
-- set.  A step's own source key cannot see any of them when a later module declares
-- them.
import frontend.ast.{
  Decl(..), Ty(..), Require(..), ImplMethod(..), ifaceMethodName
}
import list.{indexed}
import support.util.{joinWith}
import types.route_key.{implRouteKeyWord}

export
chainGraphKey : List (String, List Decl) -> String
chainGraphKey modules = joinWith "\n" (flatMap moduleRows (indexed modules))

moduleRows : (Int, (String, List Decl)) -> List String
moduleRows (pos, (mid, decls)) = flatMap (declRow pos mid) decls

declRow : Int -> String -> Decl -> List String
declRow _ mid (DImpl { iface, tys, reqs, methods, implOrigin }) =
  let reqWords =
    map
      (r => implRouteKeyWord r.requireOrigin r.requireHead r.requireArgs None)
      reqs
  let names =
    map
      (m => match m
        ImplMethod n _ _ => n)
      methods
  [
    "\{mid} impl \{implRouteKeyWord implOrigin iface tys None} requires \{joinWith "," reqWords} with \{joinWith "," names}",
  ]
declRow pos mid (DInterface { name, methods }) = [
  "\{mid} interface \{name} with \{joinWith "," (map ifaceMethodName methods)} at \{intToString pos}",
]
declRow pos mid (DAttrib _ d) = declRow pos mid d
declRow _ mid d = map (n => "\{mid} dict \{n}") (constrainedSigName d)

-- A `=>`-constrained top-level signature's name, looking through attributes.
export
constrainedSigName : Decl -> List String
constrainedSigName (DTypeSig _ n ty _)
  | isConstrainedTy ty = [n]
  | otherwise = []
constrainedSigName (DAttrib _ d) = constrainedSigName d
constrainedSigName _ = []

export
isConstrainedTy : Ty -> Bool
isConstrainedTy (TyConstrained _ _) = True
isConstrainedTy _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Require" true) (mem "ImplMethod" true) (mem "ifaceMethodName" false))))
(DUse false (UseGroup ("list") ((mem "indexed" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DTypeSig true "chainGraphKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "chainGraphKey" ((PVar "modules")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "flatMap") (EVar "moduleRows")) (EApp (EVar "indexed") (EVar "modules")))))
(DTypeSig false "moduleRows" (TyFun (TyTuple (TyCon "Int") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleRows" ((PTuple (PVar "pos") (PTuple (PVar "mid") (PVar "decls")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "declRow") (EVar "pos")) (EVar "mid"))) (EVar "decls")))
(DTypeSig false "declRow" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declRow" (PWild (PVar "mid") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) false)) (EBlock (DoLet false false (PVar "reqWords") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "r") "requireOrigin")) (EFieldAccess (EVar "r") "requireHead")) (EFieldAccess (EVar "r") "requireArgs")) (EVar "None")))) (EVar "reqs"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "methods"))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " impl "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None")))) (ELit (LString " requires "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "reqWords")))) (ELit (LString " with "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "names")))) (ELit (LString "")))))))
(DFunDef false "declRow" ((PVar "pos") (PVar "mid") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) false)) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " interface "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " with "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods"))))) (ELit (LString " at "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "pos")))) (ELit (LString "")))))
(DFunDef false "declRow" ((PVar "pos") (PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "declRow") (EVar "pos")) (EVar "mid")) (EVar "d")))
(DFunDef false "declRow" (PWild (PVar "mid") (PVar "d")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " dict "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))) (EApp (EVar "constrainedSigName") (EVar "d"))))
(DTypeSig true "constrainedSigName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigName" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigName") (EVar "d")))
(DFunDef false "constrainedSigName" (PWild) (EListLit))
(DTypeSig true "isConstrainedTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isConstrainedTy" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "isConstrainedTy" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Require" true) (mem "ImplMethod" true) (mem "ifaceMethodName" false))))
(DUse false (UseGroup ("list") ((mem "indexed" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DTypeSig true "chainGraphKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "chainGraphKey" ((PVar "modules")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EDictApp "flatMap") (EVar "moduleRows")) (EApp (EVar "indexed") (EVar "modules")))))
(DTypeSig false "moduleRows" (TyFun (TyTuple (TyCon "Int") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleRows" ((PTuple (PVar "pos") (PTuple (PVar "mid") (PVar "decls")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "declRow") (EVar "pos")) (EVar "mid"))) (EVar "decls")))
(DTypeSig false "declRow" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declRow" (PWild (PVar "mid") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) false)) (EBlock (DoLet false false (PVar "reqWords") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "r") "requireOrigin")) (EFieldAccess (EVar "r") "requireHead")) (EFieldAccess (EVar "r") "requireArgs")) (EVar "None")))) (EVar "reqs"))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "methods"))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " impl "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None")))) (ELit (LString " requires "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "reqWords")))) (ELit (LString " with "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "names")))) (ELit (LString "")))))))
(DFunDef false "declRow" ((PVar "pos") (PVar "mid") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) false)) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " interface "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " with "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods"))))) (ELit (LString " at "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "pos")))) (ELit (LString "")))))
(DFunDef false "declRow" ((PVar "pos") (PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "declRow") (EVar "pos")) (EVar "mid")) (EVar "d")))
(DFunDef false "declRow" (PWild (PVar "mid") (PVar "d")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " dict "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))) (EApp (EVar "constrainedSigName") (EVar "d"))))
(DTypeSig true "constrainedSigName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigName" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigName") (EVar "d")))
(DFunDef false "constrainedSigName" (PWild) (EListLit))
(DTypeSig true "isConstrainedTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isConstrainedTy" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "isConstrainedTy" (PWild) (EVar "False"))
