# META
source_lines=63
stages=DESUGAR,MARK
# SOURCE
-- The parts of the module-chain memo key that cover what a recorded step reads
-- from modules outside its own prefix.  Every instance head is visible to the whole
-- graph whether or not a module imports its definer, and every constrained
-- signature's bare name joins every module's dict-name set (`chainGraphKey`).  An
-- interface declaration's method names are read by bare name by every module
-- checked after its declarer, whether or not it imports it, so a step's key carries
-- the interface rows of the modules before it (`interfaceRows`).  A step's own
-- source key cannot see any of them when another module declares them.
import frontend.ast.{
  Decl(..), Ty(..), Require(..), ImplMethod(..), ifaceMethodName
}
import support.util.{joinWith}
import types.route_key.{implRouteKeyWord}

export
chainGraphKey : List (String, List Decl) -> String
chainGraphKey modules = joinWith "\n" (flatMap moduleRows modules)

moduleRows : (String, List Decl) -> List String
moduleRows (mid, decls) = flatMap (declRow mid) decls

declRow : String -> Decl -> List String
declRow mid (DImpl { iface, tys, reqs, methods, implOrigin }) =
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
declRow mid (DAttrib _ d) = declRow mid d
declRow mid d = map (n => "\{mid} dict \{n}") (constrainedSigName d)

-- Module [mid]'s interface declarations, each with its method names.
export
interfaceRows : String -> List Decl -> List String
interfaceRows mid decls = flatMap (interfaceRow mid) decls

interfaceRow : String -> Decl -> List String
interfaceRow mid (DInterface { name, methods }) = [
  "\{mid} interface \{name} with \{joinWith "," (map ifaceMethodName methods)}",
]
interfaceRow mid (DAttrib _ d) = interfaceRow mid d
interfaceRow _ _ = []

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
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DTypeSig true "chainGraphKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "chainGraphKey" ((PVar "modules")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "flatMap") (EVar "moduleRows")) (EVar "modules"))))
(DTypeSig false "moduleRows" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleRows" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "declRow") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "declRow" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declRow" ((PVar "mid") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) false)) (EBlock (DoLet false false (PVar "reqWords") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "r") "requireOrigin")) (EFieldAccess (EVar "r") "requireHead")) (EFieldAccess (EVar "r") "requireArgs")) (EVar "None")))) (EVar "reqs"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "methods"))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " impl "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None")))) (ELit (LString " requires "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "reqWords")))) (ELit (LString " with "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "names")))) (ELit (LString "")))))))
(DFunDef false "declRow" ((PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declRow") (EVar "mid")) (EVar "d")))
(DFunDef false "declRow" ((PVar "mid") (PVar "d")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " dict "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))) (EApp (EVar "constrainedSigName") (EVar "d"))))
(DTypeSig true "interfaceRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "interfaceRows" ((PVar "mid") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "interfaceRow") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "interfaceRow" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "interfaceRow" ((PVar "mid") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) false)) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " interface "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " with "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods"))))) (ELit (LString "")))))
(DFunDef false "interfaceRow" ((PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "interfaceRow") (EVar "mid")) (EVar "d")))
(DFunDef false "interfaceRow" (PWild PWild) (EListLit))
(DTypeSig true "constrainedSigName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigName" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigName") (EVar "d")))
(DFunDef false "constrainedSigName" (PWild) (EListLit))
(DTypeSig true "isConstrainedTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isConstrainedTy" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "isConstrainedTy" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Require" true) (mem "ImplMethod" true) (mem "ifaceMethodName" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DTypeSig true "chainGraphKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "chainGraphKey" ((PVar "modules")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EDictApp "flatMap") (EVar "moduleRows")) (EVar "modules"))))
(DTypeSig false "moduleRows" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleRows" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declRow") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "declRow" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declRow" ((PVar "mid") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) false)) (EBlock (DoLet false false (PVar "reqWords") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "r") "requireOrigin")) (EFieldAccess (EVar "r") "requireHead")) (EFieldAccess (EVar "r") "requireArgs")) (EVar "None")))) (EVar "reqs"))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "methods"))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " impl "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None")))) (ELit (LString " requires "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "reqWords")))) (ELit (LString " with "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "names")))) (ELit (LString "")))))))
(DFunDef false "declRow" ((PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declRow") (EVar "mid")) (EVar "d")))
(DFunDef false "declRow" ((PVar "mid") (PVar "d")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " dict "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))) (EApp (EVar "constrainedSigName") (EVar "d"))))
(DTypeSig true "interfaceRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "interfaceRows" ((PVar "mid") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "interfaceRow") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "interfaceRow" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "interfaceRow" ((PVar "mid") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) false)) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " interface "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " with "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods"))))) (ELit (LString "")))))
(DFunDef false "interfaceRow" ((PVar "mid") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "interfaceRow") (EVar "mid")) (EVar "d")))
(DFunDef false "interfaceRow" (PWild PWild) (EListLit))
(DTypeSig true "constrainedSigName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigName" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigName") (EVar "d")))
(DFunDef false "constrainedSigName" (PWild) (EListLit))
(DTypeSig true "isConstrainedTy" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "isConstrainedTy" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "isConstrainedTy" (PWild) (EVar "False"))
