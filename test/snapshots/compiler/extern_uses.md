# META
source_lines=29
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Addr(..)}
import ir.core_ir.{CProgram(..), CExpr(..), DeclFacts(..)}
import ir.extern_lower.{walkExternVars}
import ir.extern_types.{ExternUse(..), ExternUseKind(..)}
import support.ordmap.{omHasKey}
import support.util.{reverseL, startsWith}

export
collectExternUses : CProgram -> List ExternUse
collectExternUses (prog@(CProgram _ _ _ _ _ facts)) =
  let uses = Ref []
  let _ =
    walkExternVars
      (scope supplied name addr =>
        let _ =
          if not (omHasKey name scope)
            && (omHasKey name facts.factExterns
              || startsWith "$extern$" name) then
            uses :=
              ExternUse {
                  useSymbol = name,
                  useKind =
                    if supplied < 0 then ExternValue else ExternApplication,
                  suppliedCoreArguments = if supplied < 0 then 0 else supplied,
                }
                :: !uses
        CVar name addr)
      prog
  reverseL !uses
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CExpr" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "walkExternVars" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternUse" true) (mem "ExternUseKind" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false))))
(DTypeSig true "collectExternUses" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternUse"))))
(DFunDef false "collectExternUses" ((PAs "prog" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "walkExternVars") (ELam ((PVar "scope") (PVar "supplied") (PVar "name") (PVar "addr")) (EBlock (DoLet false false PWild (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "facts") "factExterns")) (EApp (EApp (EVar "startsWith") (ELit (LString "$extern$"))) (EVar "name")))) (EApp (EApp (EVar "setRef") (EVar "uses")) (EBinOp "::" (ERecordCreate "ExternUse" ((fa "useSymbol" (EVar "name")) (fa "useKind" (EIf (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (EVar "ExternValue") (EVar "ExternApplication"))) (fa "suppliedCoreArguments" (EIf (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (ELit (LInt 0)) (EVar "supplied"))))) (EUnOp "!" (EVar "uses")))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "uses"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CExpr" true) (mem "DeclFacts" true))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "walkExternVars" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternUse" true) (mem "ExternUseKind" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false))))
(DTypeSig true "collectExternUses" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternUse"))))
(DFunDef false "collectExternUses" ((PAs "prog" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "uses") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "walkExternVars") (ELam ((PVar "scope") (PVar "supplied") (PVar "name") (PVar "addr")) (EBlock (DoLet false false PWild (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "facts") "factExterns")) (EApp (EApp (EVar "startsWith") (ELit (LString "$extern$"))) (EVar "name")))) (EApp (EApp (EVar "setRef") (EVar "uses")) (EBinOp "::" (ERecordCreate "ExternUse" ((fa "useSymbol" (EVar "name")) (fa "useKind" (EIf (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (EVar "ExternValue") (EVar "ExternApplication"))) (fa "suppliedCoreArguments" (EIf (EBinOp "<" (EVar "supplied") (ELit (LInt 0))) (ELit (LInt 0)) (EVar "supplied"))))) (EUnOp "!" (EVar "uses")))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "CVar") (EVar "name")) (EVar "addr")))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "uses"))))))
