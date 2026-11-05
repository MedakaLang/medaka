# META
source_lines=75
stages=DESUGAR,MARK
# SOURCE
import list.{reverse}
import ir.core_ir.{CProgram}
import ir.core_ir_sexp.{cprogramToSexp}
import ir.core_lint.{lintProgram}
-- The runner for a declared list of Core IR passes.  A pass is a named
-- `CProgram -> CProgram` step over a context `c` that the pass list's owner
-- defines, so this module knows no pass and imports no lowering.

-- One step of a pipeline: [passRun] reads the context and rewrites the program.
public export data CorePass c = CorePass {
  passName : String,
  passRun : c -> CProgram -> CProgram,
}

-- Built once by the caller (a value, never ambient state).  [lint] asks the
-- runner to check the program after every pass; [dumpAfter] names the passes
-- whose output is captured, with "all" for every pass.
public export data PassConfig = PassConfig {
  lint : Bool,
  dumpAfter : List String,
}

export
defaultPassConfig : PassConfig
defaultPassConfig = PassConfig { lint = True, dumpAfter = [] }

-- A broken invariant found after pass [faultPass].
public export data PassFault = PassFault {
  faultPass : String,
  faultMessage : String,
}

-- The final program, the captured dumps as (pass name, sexp text) in list
-- order, and the faults found.
public export data PassRun = PassRun {
  program : CProgram,
  dumps : List (String, String),
  faults : List PassFault,
}

wantsDump : PassConfig -> String -> Bool
wantsDump config which =
  elem "all" config.dumpAfter || elem which config.dumpAfter

-- Runs [passes] left to right over [start].  A pass that panics is not caught.
-- With [lint] on, the start program is checked under the name `input` and the
-- program after each pass under that pass's name.
export
runPasses : PassConfig -> c -> List (CorePass c) -> CProgram -> PassRun
runPasses config ctx passes start =
  let first = PassRun start [] (reverse (lintFaults config "input" start))
  let stepped = fold (step config ctx) first passes
  PassRun stepped.program (reverse stepped.dumps) (reverse stepped.faults)

lintFaults : PassConfig -> String -> CProgram -> List PassFault
lintFaults config which prog =
  if config.lint then
    map
      (message => PassFault { faultPass = which, faultMessage = message })
      (lintProgram prog)
  else
    []

step : PassConfig -> c -> PassRun -> CorePass c -> PassRun
step config ctx acc pass =
  let next = pass.passRun ctx acc.program
  let dumps =
    if wantsDump config pass.passName then
      (pass.passName, cprogramToSexp next) :: acc.dumps
    else
      acc.dumps
  PassRun
    next
    dumps
    (reverse (lintFaults config pass.passName next) ++ acc.faults)
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "core_lint") ((mem "lintProgram" false))))
(DData Public "CorePass" ("c") ((variant "CorePass" (ConNamed (field "passName" (TyCon "String")) (field "passRun" (TyFun (TyVar "c") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))))) ())
(DData Public "PassConfig" () ((variant "PassConfig" (ConNamed (field "lint" (TyCon "Bool")) (field "dumpAfter" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "defaultPassConfig" (TyCon "PassConfig"))
(DFunDef false "defaultPassConfig" () (ERecordCreate "PassConfig" ((fa "lint" (EVar "True")) (fa "dumpAfter" (EListLit)))))
(DData Public "PassFault" () ((variant "PassFault" (ConNamed (field "faultPass" (TyCon "String")) (field "faultMessage" (TyCon "String"))))) ())
(DData Public "PassRun" () ((variant "PassRun" (ConNamed (field "program" (TyCon "CProgram")) (field "dumps" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "faults" (TyApp (TyCon "List") (TyCon "PassFault")))))) ())
(DTypeSig false "wantsDump" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wantsDump" ((PVar "config") (PVar "which")) (EBinOp "||" (EApp (EApp (EVar "elem") (ELit (LString "all"))) (EFieldAccess (EVar "config") "dumpAfter")) (EApp (EApp (EVar "elem") (EVar "which")) (EFieldAccess (EVar "config") "dumpAfter"))))
(DTypeSig true "runPasses" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CorePass") (TyVar "c"))) (TyFun (TyCon "CProgram") (TyCon "PassRun"))))))
(DFunDef false "runPasses" ((PVar "config") (PVar "ctx") (PVar "passes") (PVar "start")) (EBlock (DoLet false false (PVar "first") (EApp (EApp (EApp (EVar "PassRun") (EVar "start")) (EListLit)) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (ELit (LString "input"))) (EVar "start"))))) (DoLet false false (PVar "stepped") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "step") (EVar "config")) (EVar "ctx"))) (EVar "first")) (EVar "passes"))) (DoExpr (EApp (EApp (EApp (EVar "PassRun") (EFieldAccess (EVar "stepped") "program")) (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "dumps"))) (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "faults"))))))
(DTypeSig false "lintFaults" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "PassFault"))))))
(DFunDef false "lintFaults" ((PVar "config") (PVar "which") (PVar "prog")) (EIf (EFieldAccess (EVar "config") "lint") (EApp (EApp (EVar "map") (ELam ((PVar "message")) (ERecordCreate "PassFault" ((fa "faultPass" (EVar "which")) (fa "faultMessage" (EVar "message")))))) (EApp (EVar "lintProgram") (EVar "prog"))) (EListLit)))
(DTypeSig false "step" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyCon "PassRun") (TyFun (TyApp (TyCon "CorePass") (TyVar "c")) (TyCon "PassRun"))))))
(DFunDef false "step" ((PVar "config") (PVar "ctx") (PVar "acc") (PVar "pass")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EFieldAccess (EVar "pass") "passRun") (EVar "ctx")) (EFieldAccess (EVar "acc") "program"))) (DoLet false false (PVar "dumps") (EIf (EApp (EApp (EVar "wantsDump") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EBinOp "::" (ETuple (EFieldAccess (EVar "pass") "passName") (EApp (EVar "cprogramToSexp") (EVar "next"))) (EFieldAccess (EVar "acc") "dumps")) (EFieldAccess (EVar "acc") "dumps"))) (DoExpr (EApp (EApp (EApp (EVar "PassRun") (EVar "next")) (EVar "dumps")) (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EVar "next"))) (EFieldAccess (EVar "acc") "faults"))))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "core_lint") ((mem "lintProgram" false))))
(DData Public "CorePass" ("c") ((variant "CorePass" (ConNamed (field "passName" (TyCon "String")) (field "passRun" (TyFun (TyVar "c") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))))) ())
(DData Public "PassConfig" () ((variant "PassConfig" (ConNamed (field "lint" (TyCon "Bool")) (field "dumpAfter" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "defaultPassConfig" (TyCon "PassConfig"))
(DFunDef false "defaultPassConfig" () (ERecordCreate "PassConfig" ((fa "lint" (EVar "True")) (fa "dumpAfter" (EListLit)))))
(DData Public "PassFault" () ((variant "PassFault" (ConNamed (field "faultPass" (TyCon "String")) (field "faultMessage" (TyCon "String"))))) ())
(DData Public "PassRun" () ((variant "PassRun" (ConNamed (field "program" (TyCon "CProgram")) (field "dumps" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "faults" (TyApp (TyCon "List") (TyCon "PassFault")))))) ())
(DTypeSig false "wantsDump" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wantsDump" ((PVar "config") (PVar "which")) (EBinOp "||" (EApp (EApp (EDictApp "elem") (ELit (LString "all"))) (EFieldAccess (EVar "config") "dumpAfter")) (EApp (EApp (EDictApp "elem") (EVar "which")) (EFieldAccess (EVar "config") "dumpAfter"))))
(DTypeSig true "runPasses" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CorePass") (TyVar "c"))) (TyFun (TyCon "CProgram") (TyCon "PassRun"))))))
(DFunDef false "runPasses" ((PVar "config") (PVar "ctx") (PVar "passes") (PVar "start")) (EBlock (DoLet false false (PVar "first") (EApp (EApp (EApp (EVar "PassRun") (EVar "start")) (EListLit)) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (ELit (LString "input"))) (EVar "start"))))) (DoLet false false (PVar "stepped") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "step") (EVar "config")) (EVar "ctx"))) (EVar "first")) (EVar "passes"))) (DoExpr (EApp (EApp (EApp (EVar "PassRun") (EFieldAccess (EVar "stepped") "program")) (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "dumps"))) (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "faults"))))))
(DTypeSig false "lintFaults" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "PassFault"))))))
(DFunDef false "lintFaults" ((PVar "config") (PVar "which") (PVar "prog")) (EIf (EFieldAccess (EVar "config") "lint") (EApp (EApp (EMethodRef "map") (ELam ((PVar "message")) (ERecordCreate "PassFault" ((fa "faultPass" (EVar "which")) (fa "faultMessage" (EVar "message")))))) (EApp (EVar "lintProgram") (EVar "prog"))) (EListLit)))
(DTypeSig false "step" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyCon "PassRun") (TyFun (TyApp (TyCon "CorePass") (TyVar "c")) (TyCon "PassRun"))))))
(DFunDef false "step" ((PVar "config") (PVar "ctx") (PVar "acc") (PVar "pass")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EFieldAccess (EVar "pass") "passRun") (EVar "ctx")) (EFieldAccess (EVar "acc") "program"))) (DoLet false false (PVar "dumps") (EIf (EApp (EApp (EVar "wantsDump") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EBinOp "::" (ETuple (EFieldAccess (EVar "pass") "passName") (EApp (EVar "cprogramToSexp") (EVar "next"))) (EFieldAccess (EVar "acc") "dumps")) (EFieldAccess (EVar "acc") "dumps"))) (DoExpr (EApp (EApp (EApp (EVar "PassRun") (EVar "next")) (EVar "dumps")) (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EVar "next"))) (EFieldAccess (EVar "acc") "faults"))))))
