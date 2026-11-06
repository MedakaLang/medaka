# META
source_lines=118
stages=DESUGAR,MARK
# SOURCE
import list.{reverse}
import string.{join, split}
import support.util.{filterList}
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

-- The library default: unlinted, because library callers (tests, tools) lower
-- programs that need not be well scoped.  The emit entries turn lint on.
export
defaultPassConfig : PassConfig
defaultPassConfig = PassConfig { lint = False, dumpAfter = [] }

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

-- The lint switch an emit entry reads: `1` on, `0` off, unset on.  Any other
-- value is an error naming the valid ones.
export
lintSwitch : Option String -> Result String Bool
lintSwitch None = Ok True
lintSwitch (Some "1") = Ok True
lintSwitch (Some "0") = Ok False
lintSwitch (Some other) = Err "unknown value `\{other}`; valid values: 0, 1"

-- A comma-separated dump request against a pipeline whose passes are
-- [passNames].  Besides those names it may use `input` (the program before the
-- first pass) and `all` (every pass; `input` is dumped only when named).  An
-- unknown name is an error naming the valid ones.
export
dumpSwitch : List String -> Option String -> Result String (List String)
dumpSwitch passNames value =
  let valid = passNames ++ ["input", "all"]
  let names = match value
    Some text => filterList (/= "") (split "," text)
    None => []
  match filterList (n => not (elem n valid)) names
    [] => Ok names
    bad :: _ =>
      Err "unknown pass name `\{bad}`; valid names: \{join ", " valid}"

-- Runs [passes] left to right over [start].  A pass that panics is not caught.
-- With [lint] on, the start program is checked under the name `input` and the
-- program after each pass under that pass's name; a dump of `input` is the
-- start program.
export
runPasses : PassConfig -> c -> List (CorePass c) -> CProgram -> PassRun
runPasses config ctx passes start =
  let first = PassRun {
    program = start,
    dumps =
      if elem "input" config.dumpAfter then
        [("input", cprogramToSexp start)]
      else
        [],
    faults = reverse (lintFaults config "input" start),
  }
  let stepped = fold (step config ctx) first passes
  PassRun {
    program = stepped.program,
    dumps = reverse stepped.dumps,
    faults = reverse stepped.faults,
  }

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
  PassRun {
    program = next,
    dumps = dumps,
    faults = reverse (lintFaults config pass.passName next) ++ acc.faults,
  }
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "join" false) (mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "core_lint") ((mem "lintProgram" false))))
(DData Public "CorePass" ("c") ((variant "CorePass" (ConNamed (field "passName" (TyCon "String")) (field "passRun" (TyFun (TyVar "c") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))))) ())
(DData Public "PassConfig" () ((variant "PassConfig" (ConNamed (field "lint" (TyCon "Bool")) (field "dumpAfter" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "defaultPassConfig" (TyCon "PassConfig"))
(DFunDef false "defaultPassConfig" () (ERecordCreate "PassConfig" ((fa "lint" (EVar "False")) (fa "dumpAfter" (EListLit)))))
(DData Public "PassFault" () ((variant "PassFault" (ConNamed (field "faultPass" (TyCon "String")) (field "faultMessage" (TyCon "String"))))) ())
(DData Public "PassRun" () ((variant "PassRun" (ConNamed (field "program" (TyCon "CProgram")) (field "dumps" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "faults" (TyApp (TyCon "List") (TyCon "PassFault")))))) ())
(DTypeSig false "wantsDump" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wantsDump" ((PVar "config") (PVar "which")) (EBinOp "||" (EApp (EApp (EVar "elem") (ELit (LString "all"))) (EFieldAccess (EVar "config") "dumpAfter")) (EApp (EApp (EVar "elem") (EVar "which")) (EFieldAccess (EVar "config") "dumpAfter"))))
(DTypeSig true "lintSwitch" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "lintSwitch" ((PCon "None")) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "lintSwitch" ((PCon "Some" (PLit (LString "1")))) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "lintSwitch" ((PCon "Some" (PLit (LString "0")))) (EApp (EVar "Ok") (EVar "False")))
(DFunDef false "lintSwitch" ((PCon "Some" (PVar "other"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown value `")) (EApp (EVar "$core.display") (EVar "other"))) (ELit (LString "`; valid values: 0, 1")))))
(DTypeSig true "dumpSwitch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dumpSwitch" ((PVar "passNames") (PVar "value")) (EBlock (DoLet false false (PVar "valid") (EBinOp "++" (EVar "passNames") (EListLit (ELit (LString "input")) (ELit (LString "all"))))) (DoLet false false (PVar "names") (EMatch (EVar "value") (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EVar "text")))) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "valid"))))) (EVar "names")) (arm (PList) () (EApp (EVar "Ok") (EVar "names"))) (arm (PCons (PVar "bad") PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown pass name `")) (EApp (EVar "$core.display") (EVar "bad"))) (ELit (LString "`; valid names: "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "valid")))) (ELit (LString "")))))))))
(DTypeSig true "runPasses" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CorePass") (TyVar "c"))) (TyFun (TyCon "CProgram") (TyCon "PassRun"))))))
(DFunDef false "runPasses" ((PVar "config") (PVar "ctx") (PVar "passes") (PVar "start")) (EBlock (DoLet false false (PVar "first") (ERecordCreate "PassRun" ((fa "program" (EVar "start")) (fa "dumps" (EIf (EApp (EApp (EVar "elem") (ELit (LString "input"))) (EFieldAccess (EVar "config") "dumpAfter")) (EListLit (ETuple (ELit (LString "input")) (EApp (EVar "cprogramToSexp") (EVar "start")))) (EListLit))) (fa "faults" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (ELit (LString "input"))) (EVar "start"))))))) (DoLet false false (PVar "stepped") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "step") (EVar "config")) (EVar "ctx"))) (EVar "first")) (EVar "passes"))) (DoExpr (ERecordCreate "PassRun" ((fa "program" (EFieldAccess (EVar "stepped") "program")) (fa "dumps" (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "dumps"))) (fa "faults" (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "faults"))))))))
(DTypeSig false "lintFaults" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "PassFault"))))))
(DFunDef false "lintFaults" ((PVar "config") (PVar "which") (PVar "prog")) (EIf (EFieldAccess (EVar "config") "lint") (EApp (EApp (EVar "map") (ELam ((PVar "message")) (ERecordCreate "PassFault" ((fa "faultPass" (EVar "which")) (fa "faultMessage" (EVar "message")))))) (EApp (EVar "lintProgram") (EVar "prog"))) (EListLit)))
(DTypeSig false "step" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyCon "PassRun") (TyFun (TyApp (TyCon "CorePass") (TyVar "c")) (TyCon "PassRun"))))))
(DFunDef false "step" ((PVar "config") (PVar "ctx") (PVar "acc") (PVar "pass")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EFieldAccess (EVar "pass") "passRun") (EVar "ctx")) (EFieldAccess (EVar "acc") "program"))) (DoLet false false (PVar "dumps") (EIf (EApp (EApp (EVar "wantsDump") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EBinOp "::" (ETuple (EFieldAccess (EVar "pass") "passName") (EApp (EVar "cprogramToSexp") (EVar "next"))) (EFieldAccess (EVar "acc") "dumps")) (EFieldAccess (EVar "acc") "dumps"))) (DoExpr (ERecordCreate "PassRun" ((fa "program" (EVar "next")) (fa "dumps" (EVar "dumps")) (fa "faults" (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EVar "next"))) (EFieldAccess (EVar "acc") "faults"))))))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "join" false) (mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "core_lint") ((mem "lintProgram" false))))
(DData Public "CorePass" ("c") ((variant "CorePass" (ConNamed (field "passName" (TyCon "String")) (field "passRun" (TyFun (TyVar "c") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))))) ())
(DData Public "PassConfig" () ((variant "PassConfig" (ConNamed (field "lint" (TyCon "Bool")) (field "dumpAfter" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "defaultPassConfig" (TyCon "PassConfig"))
(DFunDef false "defaultPassConfig" () (ERecordCreate "PassConfig" ((fa "lint" (EVar "False")) (fa "dumpAfter" (EListLit)))))
(DData Public "PassFault" () ((variant "PassFault" (ConNamed (field "faultPass" (TyCon "String")) (field "faultMessage" (TyCon "String"))))) ())
(DData Public "PassRun" () ((variant "PassRun" (ConNamed (field "program" (TyCon "CProgram")) (field "dumps" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "faults" (TyApp (TyCon "List") (TyCon "PassFault")))))) ())
(DTypeSig false "wantsDump" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wantsDump" ((PVar "config") (PVar "which")) (EBinOp "||" (EApp (EApp (EDictApp "elem") (ELit (LString "all"))) (EFieldAccess (EVar "config") "dumpAfter")) (EApp (EApp (EDictApp "elem") (EVar "which")) (EFieldAccess (EVar "config") "dumpAfter"))))
(DTypeSig true "lintSwitch" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "lintSwitch" ((PCon "None")) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "lintSwitch" ((PCon "Some" (PLit (LString "1")))) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "lintSwitch" ((PCon "Some" (PLit (LString "0")))) (EApp (EVar "Ok") (EVar "False")))
(DFunDef false "lintSwitch" ((PCon "Some" (PVar "other"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown value `")) (EApp (EVar "$core.display") (EVar "other"))) (ELit (LString "`; valid values: 0, 1")))))
(DTypeSig true "dumpSwitch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dumpSwitch" ((PVar "passNames") (PVar "value")) (EBlock (DoLet false false (PVar "valid") (EBinOp "++" (EVar "passNames") (EListLit (ELit (LString "input")) (ELit (LString "all"))))) (DoLet false false (PVar "names") (EMatch (EVar "value") (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EVar "text")))) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "valid"))))) (EVar "names")) (arm (PList) () (EApp (EVar "Ok") (EVar "names"))) (arm (PCons (PVar "bad") PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown pass name `")) (EApp (EVar "$core.display") (EVar "bad"))) (ELit (LString "`; valid names: "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "valid")))) (ELit (LString "")))))))))
(DTypeSig true "runPasses" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CorePass") (TyVar "c"))) (TyFun (TyCon "CProgram") (TyCon "PassRun"))))))
(DFunDef false "runPasses" ((PVar "config") (PVar "ctx") (PVar "passes") (PVar "start")) (EBlock (DoLet false false (PVar "first") (ERecordCreate "PassRun" ((fa "program" (EVar "start")) (fa "dumps" (EIf (EApp (EApp (EDictApp "elem") (ELit (LString "input"))) (EFieldAccess (EVar "config") "dumpAfter")) (EListLit (ETuple (ELit (LString "input")) (EApp (EVar "cprogramToSexp") (EVar "start")))) (EListLit))) (fa "faults" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (ELit (LString "input"))) (EVar "start"))))))) (DoLet false false (PVar "stepped") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "step") (EVar "config")) (EVar "ctx"))) (EVar "first")) (EVar "passes"))) (DoExpr (ERecordCreate "PassRun" ((fa "program" (EFieldAccess (EVar "stepped") "program")) (fa "dumps" (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "dumps"))) (fa "faults" (EApp (EVar "reverse") (EFieldAccess (EVar "stepped") "faults"))))))))
(DTypeSig false "lintFaults" (TyFun (TyCon "PassConfig") (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "PassFault"))))))
(DFunDef false "lintFaults" ((PVar "config") (PVar "which") (PVar "prog")) (EIf (EFieldAccess (EVar "config") "lint") (EApp (EApp (EMethodRef "map") (ELam ((PVar "message")) (ERecordCreate "PassFault" ((fa "faultPass" (EVar "which")) (fa "faultMessage" (EVar "message")))))) (EApp (EVar "lintProgram") (EVar "prog"))) (EListLit)))
(DTypeSig false "step" (TyFun (TyCon "PassConfig") (TyFun (TyVar "c") (TyFun (TyCon "PassRun") (TyFun (TyApp (TyCon "CorePass") (TyVar "c")) (TyCon "PassRun"))))))
(DFunDef false "step" ((PVar "config") (PVar "ctx") (PVar "acc") (PVar "pass")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EFieldAccess (EVar "pass") "passRun") (EVar "ctx")) (EFieldAccess (EVar "acc") "program"))) (DoLet false false (PVar "dumps") (EIf (EApp (EApp (EVar "wantsDump") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EBinOp "::" (ETuple (EFieldAccess (EVar "pass") "passName") (EApp (EVar "cprogramToSexp") (EVar "next"))) (EFieldAccess (EVar "acc") "dumps")) (EFieldAccess (EVar "acc") "dumps"))) (DoExpr (ERecordCreate "PassRun" ((fa "program" (EVar "next")) (fa "dumps" (EVar "dumps")) (fa "faults" (EBinOp "++" (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "lintFaults") (EVar "config")) (EFieldAccess (EVar "pass") "passName")) (EVar "next"))) (EFieldAccess (EVar "acc") "faults"))))))))
