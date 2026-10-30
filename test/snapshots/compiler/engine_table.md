# META
source_lines=193
stages=DESUGAR,MARK
# SOURCE
-- The per-extern engine matrix: for every `stdlib/runtime.mdk` extern, what the
-- pure oracle, `medaka run`, `medaka test`/`repl`, the native backend and the
-- wasm backend each do with it.  Every cell is derived from a table or from the
-- extern's own signature; none is written per extern.
--
-- Lives in `tools/`, not `backend/`: it reads the interpreter's tables
-- (`eval.eval`) and `backend/` must not import `eval/`.
--
-- Cell rules:
--   real     the extern's effect (or value) is the real one.
--   canned   bound, but the effect is not performed: the oracle's fixed value,
--            no-op or captured buffer, or a catalog `FrozenConstant`.
--   refused  not bound: the engine rejects or aborts the call
--            (a catalog `NotProvided` or `TrapStub`).
-- The oracle column is `externBindings`; `run` is `ioExternBindings` over it;
-- `test` is `testCapableExterns` over it.  An extern with an empty effect row
-- is `real` wherever it is bound.

import backend.extern_catalog.{
  Disposition(..),
  ExternRow,
  catalogRows,
  rowLlvm,
  rowName,
  rowWasm,
}
import frontend.ast.{Decl(..), ExternDecl(..), Ty(..)}
import frontend.parser.{parse}
import eval.eval.{externBindings, ioExternBindings, testCapableExterns}
import set as S
import string.{unlines}

public export data Cell = Real | Canned | Refused deriving (Eq)

-- oracle, run, test, native, wasm
public export data EngineRow = EngineRow String Cell Cell Cell Cell Cell

runtimePath : String
runtimePath = "stdlib/runtime.mdk"

-- Effectful externs the oracle binds that `ioExternBindings` rightly does not
-- override, each with its reason.  `run` counts them `real`.
driftExceptions : List (String, String)
driftExceptions = [
  ("putStr", stdoutReason),
  ("putStrLn", stdoutReason),
  ("flushStdout", stdoutReason),
]

stdoutReason : String
stdoutReason =
  "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer"

-- Does the declared type end in a non-empty effect row?
hasEffect : Ty -> Bool
hasEffect (TyFun _ r) = hasEffect r
hasEffect (TyEffect labels _ _) = not (isEmpty labels)
hasEffect (TyConstrained _ t) = hasEffect t
hasEffect (TyQual t _ _) = hasEffect t
hasEffect _ = False

externDeclsOf : List Decl -> List ExternDecl
externDeclsOf [] = []
externDeclsOf ((DExtern ed) :: rest) = ed :: externDeclsOf rest
externDeclsOf ((DAttrib _ d) :: rest) = externDeclsOf (d :: rest)
externDeclsOf (_ :: rest) = externDeclsOf rest

nameSet : List (String, a) -> S.Set String
nameSet bs = S.fromList (map fst bs)

cellOfDisposition : Disposition f -> Cell
cellOfDisposition (NotProvided _ _) = Refused
cellOfDisposition (TrapStub _ _) = Refused
cellOfDisposition (FrozenConstant _ _) = Canned
cellOfDisposition _ = Real

mkRow : S.Set String ->
  S.Set String ->
  S.Set String ->
  (String, Bool) ->
  Option EngineRow
mkRow oracle run tst (name, effectful) =
  match find (r => rowName r == name) catalogRows
    None => None
    Some r =>
      let oracleCell =
        if S.has name oracle then
          if effectful then Canned else Real
        else
          Refused
      let runCell = if S.has name run then Real else oracleCell
      let testCell = if S.has name tst then Real else oracleCell
      Some
        (EngineRow
          name
          oracleCell
          runCell
          testCell
          (cellOfDisposition (rowLlvm r))
          (cellOfDisposition (rowWasm r)))

-- (name, has an effect row) for every extern declared in runtime.mdk.
declaredExterns : List Decl -> List (String, Bool)
declaredExterns decls =
  map (ed => (ed.edName, hasEffect ed.edTy)) (externDeclsOf decls)

rowsOf : List Decl -> List EngineRow
rowsOf decls =
  let oracle = nameSet (externBindings ())
  let run =
    S.union
      (nameSet (ioExternBindings ()))
      (S.fromList (map fst driftExceptions))
  let tst = nameSet (testCapableExterns ())
  filterMap (mkRow oracle run tst) (declaredExterns decls)

-- Effectful externs the oracle binds and `ioExternBindings` does not, minus
-- the named exceptions.
driftOf : List Decl -> List String
driftOf decls =
  let oracle = nameSet (externBindings ())
  let run = nameSet (ioExternBindings ())
  let excused = map fst driftExceptions
  filterMap
    (p =>
      let name = fst p
      if snd p
        && S.has name oracle
        && not (S.has name run)
        && not (elem name excused) then
        Some name
      else
        None)
    (declaredExterns decls)

loadRuntime : Unit -> <FileRead> List Decl
loadRuntime _ = match readFile runtimePath
  Ok src => parse src
  Err _ => []

export
engineRows : Unit -> <FileRead> List EngineRow
engineRows _ = rowsOf (loadRuntime ())

export
runDrift : Unit -> <FileRead> List String
runDrift _ = driftOf (loadRuntime ())

cellText : Cell -> String
cellText Real = "real"
cellText Canned = "canned"
cellText Refused = "refused"

allReal : EngineRow -> Bool
allReal (EngineRow _ a b c d e) = all (== Real) [a, b, c, d, e]

-- Only rows that say something: any non-real cell.
rowLine : EngineRow -> String
rowLine (EngineRow n a b c d e) =
  "| `\{n}` | \{cellText a} | \{cellText b} | \{cellText c} | \{cellText d} | \{cellText e} |"

export
renderEngineTable : List EngineRow -> String
renderEngineTable rows =
  let shown = filter (r => not (allReal r)) rows
  unlines
    ([
        "# Engines",
        "",
        "<!-- GENERATED by compiler/tools/engine_table.mdk; regenerate with `make engines-doc`. -->",
        "",
        "What each engine does with each `stdlib/runtime.mdk` extern. An extern that is",
        "`real` on every engine is left out; so is any extern not in the catalog.",
        "",
        "## Columns",
        "",
        "- **oracle**: the pure interpreter the differential gates run (`externBindings`).",
        "- **run**: `medaka run` (`ioExternBindings` over the oracle).",
        "- **test**: `medaka test` and `medaka repl` (`testCapableExterns` over the oracle).",
        "- **native**, **wasm**: `medaka build` for each target (the extern catalog).",
        "",
        "## Cells",
        "",
        "`real` is the extern's actual effect; `canned` is bound but does not",
        "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is",
        "not bound, so the call is rejected or aborts.",
        "",
        "## Externs that differ",
        "",
        "| extern | oracle | run | test | native | wasm |",
        "|---|---|---|---|---|---|",
      ]
      ++ map rowLine shown)
# DESUGAR
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "ExternRow" false) (mem "catalogRows" false) (mem "rowLlvm" false) (mem "rowName" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "externBindings" false) (mem "ioExternBindings" false) (mem "testCapableExterns" false))))
(DUse false (UseAlias ("set") "S"))
(DUse false (UseGroup ("string") ((mem "unlines" false))))
(DData Public "Cell" () ((variant "Real" (ConPos)) (variant "Canned" (ConPos)) (variant "Refused" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Cell")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Real") (PCon "Real")) () (EVar "True")) (arm (PTuple (PCon "Canned") (PCon "Canned")) () (EVar "True")) (arm (PTuple (PCon "Refused") (PCon "Refused")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "EngineRow" () ((variant "EngineRow" (ConPos (TyCon "String") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell")))) ())
(DTypeSig false "runtimePath" (TyCon "String"))
(DFunDef false "runtimePath" () (ELit (LString "stdlib/runtime.mdk")))
(DTypeSig false "driftExceptions" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "driftExceptions" () (EListLit (ETuple (ELit (LString "putStr")) (EVar "stdoutReason")) (ETuple (ELit (LString "putStrLn")) (EVar "stdoutReason")) (ETuple (ELit (LString "flushStdout")) (EVar "stdoutReason"))))
(DTypeSig false "stdoutReason" (TyCon "String"))
(DFunDef false "stdoutReason" () (ELit (LString "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer")))
(DTypeSig false "hasEffect" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "hasEffect" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "hasEffect") (EVar "r")))
(DFunDef false "hasEffect" ((PCon "TyEffect" (PVar "labels") PWild PWild)) (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "labels"))))
(DFunDef false "hasEffect" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "hasEffect") (EVar "t")))
(DFunDef false "hasEffect" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "hasEffect") (EVar "t")))
(DFunDef false "hasEffect" (PWild) (EVar "False"))
(DTypeSig false "externDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDeclsOf" ((PList)) (EListLit))
(DFunDef false "externDeclsOf" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDeclsOf") (EVar "rest"))))
(DFunDef false "externDeclsOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDeclsOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDeclsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDeclsOf") (EVar "rest")))
(DTypeSig false "nameSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "S.Set") (TyCon "String"))))
(DFunDef false "nameSet" ((PVar "bs")) (EApp (EVar "S.fromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bs"))))
(DTypeSig false "cellOfDisposition" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyCon "Cell")))
(DFunDef false "cellOfDisposition" ((PCon "NotProvided" PWild PWild)) (EVar "Refused"))
(DFunDef false "cellOfDisposition" ((PCon "TrapStub" PWild PWild)) (EVar "Refused"))
(DFunDef false "cellOfDisposition" ((PCon "FrozenConstant" PWild PWild)) (EVar "Canned"))
(DFunDef false "cellOfDisposition" (PWild) (EVar "Real"))
(DTypeSig false "mkRow" (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "EngineRow")))))))
(DFunDef false "mkRow" ((PVar "oracle") (PVar "run") (PVar "tst") (PTuple (PVar "name") (PVar "effectful"))) (EMatch (EApp (EApp (EVar "find") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "rowName") (EVar "r")) (EVar "name")))) (EVar "catalogRows")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false (PVar "oracleCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "oracle")) (EIf (EVar "effectful") (EVar "Canned") (EVar "Real")) (EVar "Refused"))) (DoLet false false (PVar "runCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "run")) (EVar "Real") (EVar "oracleCell"))) (DoLet false false (PVar "testCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "tst")) (EVar "Real") (EVar "oracleCell"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EngineRow") (EVar "name")) (EVar "oracleCell")) (EVar "runCell")) (EVar "testCell")) (EApp (EVar "cellOfDisposition") (EApp (EVar "rowLlvm") (EVar "r")))) (EApp (EVar "cellOfDisposition") (EApp (EVar "rowWasm") (EVar "r"))))))))))
(DTypeSig false "declaredExterns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "declaredExterns" ((PVar "decls")) (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "hasEffect") (EFieldAccess (EVar "ed") "edTy"))))) (EApp (EVar "externDeclsOf") (EVar "decls"))))
(DTypeSig false "rowsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "EngineRow"))))
(DFunDef false "rowsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EApp (EVar "S.union") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (EApp (EVar "S.fromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "driftExceptions"))))) (DoLet false false (PVar "tst") (EApp (EVar "nameSet") (EApp (EVar "testCapableExterns") (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "mkRow") (EVar "oracle")) (EVar "run")) (EVar "tst"))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "driftOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "driftOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (DoLet false false (PVar "excused") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "driftExceptions"))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PVar "p")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "fst") (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "snd") (EVar "p")) (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "oracle"))) (EApp (EVar "not") (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "run")))) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "name")) (EVar "excused")))) (EApp (EVar "Some") (EVar "name")) (EVar "None")))))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "loadRuntime" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "loadRuntime" (PWild) (EMatch (EApp (EVar "readFile") (EVar "runtimePath")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "parse") (EVar "src"))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig true "engineRows" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "EngineRow")))))
(DFunDef false "engineRows" (PWild) (EApp (EVar "rowsOf") (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig true "runDrift" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "runDrift" (PWild) (EApp (EVar "driftOf") (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig false "cellText" (TyFun (TyCon "Cell") (TyCon "String")))
(DFunDef false "cellText" ((PCon "Real")) (ELit (LString "real")))
(DFunDef false "cellText" ((PCon "Canned")) (ELit (LString "canned")))
(DFunDef false "cellText" ((PCon "Refused")) (ELit (LString "refused")))
(DTypeSig false "allReal" (TyFun (TyCon "EngineRow") (TyCon "Bool")))
(DFunDef false "allReal" ((PCon "EngineRow" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EApp (EApp (EVar "all") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "Real")))) (EListLit (EVar "a") (EVar "b") (EVar "c") (EVar "d") (EVar "e"))))
(DTypeSig false "rowLine" (TyFun (TyCon "EngineRow") (TyCon "String")))
(DFunDef false "rowLine" ((PCon "EngineRow" (PVar "n") (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "a")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "b")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "c")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "d")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "e")))) (ELit (LString " |"))))
(DTypeSig true "renderEngineTable" (TyFun (TyApp (TyCon "List") (TyCon "EngineRow")) (TyCon "String")))
(DFunDef false "renderEngineTable" ((PVar "rows")) (EBlock (DoLet false false (PVar "shown") (EApp (EApp (EVar "filter") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EVar "allReal") (EVar "r"))))) (EVar "rows"))) (DoExpr (EApp (EVar "unlines") (EBinOp "++" (EListLit (ELit (LString "# Engines")) (ELit (LString "")) (ELit (LString "<!-- GENERATED by compiler/tools/engine_table.mdk; regenerate with `make engines-doc`. -->")) (ELit (LString "")) (ELit (LString "What each engine does with each `stdlib/runtime.mdk` extern. An extern that is")) (ELit (LString "`real` on every engine is left out; so is any extern not in the catalog.")) (ELit (LString "")) (ELit (LString "## Columns")) (ELit (LString "")) (ELit (LString "- **oracle**: the pure interpreter the differential gates run (`externBindings`).")) (ELit (LString "- **run**: `medaka run` (`ioExternBindings` over the oracle).")) (ELit (LString "- **test**: `medaka test` and `medaka repl` (`testCapableExterns` over the oracle).")) (ELit (LString "- **native**, **wasm**: `medaka build` for each target (the extern catalog).")) (ELit (LString "")) (ELit (LString "## Cells")) (ELit (LString "")) (ELit (LString "`real` is the extern's actual effect; `canned` is bound but does not")) (ELit (LString "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is")) (ELit (LString "not bound, so the call is rejected or aborts.")) (ELit (LString "")) (ELit (LString "## Externs that differ")) (ELit (LString "")) (ELit (LString "| extern | oracle | run | test | native | wasm |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EVar "map") (EVar "rowLine")) (EVar "shown")))))))
# MARK
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "Disposition" true) (mem "ExternRow" false) (mem "catalogRows" false) (mem "rowLlvm" false) (mem "rowName" false) (mem "rowWasm" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "externBindings" false) (mem "ioExternBindings" false) (mem "testCapableExterns" false))))
(DUse false (UseAlias ("set") "S"))
(DUse false (UseGroup ("string") ((mem "unlines" false))))
(DData Public "Cell" () ((variant "Real" (ConPos)) (variant "Canned" (ConPos)) (variant "Refused" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Cell")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Real") (PCon "Real")) () (EVar "True")) (arm (PTuple (PCon "Canned") (PCon "Canned")) () (EVar "True")) (arm (PTuple (PCon "Refused") (PCon "Refused")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "EngineRow" () ((variant "EngineRow" (ConPos (TyCon "String") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell") (TyCon "Cell")))) ())
(DTypeSig false "runtimePath" (TyCon "String"))
(DFunDef false "runtimePath" () (ELit (LString "stdlib/runtime.mdk")))
(DTypeSig false "driftExceptions" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "driftExceptions" () (EListLit (ETuple (ELit (LString "putStr")) (EVar "stdoutReason")) (ETuple (ELit (LString "putStrLn")) (EVar "stdoutReason")) (ETuple (ELit (LString "flushStdout")) (EVar "stdoutReason"))))
(DTypeSig false "stdoutReason" (TyCon "String"))
(DFunDef false "stdoutReason" () (ELit (LString "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer")))
(DTypeSig false "hasEffect" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "hasEffect" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "hasEffect") (EVar "r")))
(DFunDef false "hasEffect" ((PCon "TyEffect" (PVar "labels") PWild PWild)) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "labels"))))
(DFunDef false "hasEffect" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "hasEffect") (EVar "t")))
(DFunDef false "hasEffect" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "hasEffect") (EVar "t")))
(DFunDef false "hasEffect" (PWild) (EVar "False"))
(DTypeSig false "externDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDeclsOf" ((PList)) (EListLit))
(DFunDef false "externDeclsOf" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDeclsOf") (EVar "rest"))))
(DFunDef false "externDeclsOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDeclsOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDeclsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDeclsOf") (EVar "rest")))
(DTypeSig false "nameSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "S.Set") (TyCon "String"))))
(DFunDef false "nameSet" ((PVar "bs")) (EApp (EVar "S.fromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bs"))))
(DTypeSig false "cellOfDisposition" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyCon "Cell")))
(DFunDef false "cellOfDisposition" ((PCon "NotProvided" PWild PWild)) (EVar "Refused"))
(DFunDef false "cellOfDisposition" ((PCon "TrapStub" PWild PWild)) (EVar "Refused"))
(DFunDef false "cellOfDisposition" ((PCon "FrozenConstant" PWild PWild)) (EVar "Canned"))
(DFunDef false "cellOfDisposition" (PWild) (EVar "Real"))
(DTypeSig false "mkRow" (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyApp (TyCon "S.Set") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "EngineRow")))))))
(DFunDef false "mkRow" ((PVar "oracle") (PVar "run") (PVar "tst") (PTuple (PVar "name") (PVar "effectful"))) (EMatch (EApp (EApp (EDictApp "find") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "rowName") (EVar "r")) (EVar "name")))) (EVar "catalogRows")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false (PVar "oracleCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "oracle")) (EIf (EVar "effectful") (EVar "Canned") (EVar "Real")) (EVar "Refused"))) (DoLet false false (PVar "runCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "run")) (EVar "Real") (EVar "oracleCell"))) (DoLet false false (PVar "testCell") (EIf (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "tst")) (EVar "Real") (EVar "oracleCell"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EngineRow") (EVar "name")) (EVar "oracleCell")) (EVar "runCell")) (EVar "testCell")) (EApp (EVar "cellOfDisposition") (EApp (EVar "rowLlvm") (EVar "r")))) (EApp (EVar "cellOfDisposition") (EApp (EVar "rowWasm") (EVar "r"))))))))))
(DTypeSig false "declaredExterns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "declaredExterns" ((PVar "decls")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "hasEffect") (EFieldAccess (EVar "ed") "edTy"))))) (EApp (EVar "externDeclsOf") (EVar "decls"))))
(DTypeSig false "rowsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "EngineRow"))))
(DFunDef false "rowsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EApp (EVar "S.union") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (EApp (EVar "S.fromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "driftExceptions"))))) (DoLet false false (PVar "tst") (EApp (EVar "nameSet") (EApp (EVar "testCapableExterns") (ELit LUnit)))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "mkRow") (EVar "oracle")) (EVar "run")) (EVar "tst"))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "driftOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "driftOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (DoLet false false (PVar "excused") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "driftExceptions"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "p")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "fst") (EVar "p"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "snd") (EVar "p")) (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "oracle"))) (EApp (EVar "not") (EApp (EApp (EVar "S.has") (EVar "name")) (EVar "run")))) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "name")) (EVar "excused")))) (EApp (EVar "Some") (EVar "name")) (EVar "None")))))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "loadRuntime" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "loadRuntime" (PWild) (EMatch (EApp (EVar "readFile") (EVar "runtimePath")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "parse") (EVar "src"))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig true "engineRows" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "EngineRow")))))
(DFunDef false "engineRows" (PWild) (EApp (EVar "rowsOf") (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig true "runDrift" (TyFun (TyCon "Unit") (TyEffect ("FileRead") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "runDrift" (PWild) (EApp (EVar "driftOf") (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig false "cellText" (TyFun (TyCon "Cell") (TyCon "String")))
(DFunDef false "cellText" ((PCon "Real")) (ELit (LString "real")))
(DFunDef false "cellText" ((PCon "Canned")) (ELit (LString "canned")))
(DFunDef false "cellText" ((PCon "Refused")) (ELit (LString "refused")))
(DTypeSig false "allReal" (TyFun (TyCon "EngineRow") (TyCon "Bool")))
(DFunDef false "allReal" ((PCon "EngineRow" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EApp (EApp (EDictApp "all") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "Real")))) (EListLit (EVar "a") (EVar "b") (EVar "c") (EVar "d") (EVar "e"))))
(DTypeSig false "rowLine" (TyFun (TyCon "EngineRow") (TyCon "String")))
(DFunDef false "rowLine" ((PCon "EngineRow" (PVar "n") (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "a")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "b")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "c")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "d")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "e")))) (ELit (LString " |"))))
(DTypeSig true "renderEngineTable" (TyFun (TyApp (TyCon "List") (TyCon "EngineRow")) (TyCon "String")))
(DFunDef false "renderEngineTable" ((PVar "rows")) (EBlock (DoLet false false (PVar "shown") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EVar "allReal") (EVar "r"))))) (EVar "rows"))) (DoExpr (EApp (EVar "unlines") (EBinOp "++" (EListLit (ELit (LString "# Engines")) (ELit (LString "")) (ELit (LString "<!-- GENERATED by compiler/tools/engine_table.mdk; regenerate with `make engines-doc`. -->")) (ELit (LString "")) (ELit (LString "What each engine does with each `stdlib/runtime.mdk` extern. An extern that is")) (ELit (LString "`real` on every engine is left out; so is any extern not in the catalog.")) (ELit (LString "")) (ELit (LString "## Columns")) (ELit (LString "")) (ELit (LString "- **oracle**: the pure interpreter the differential gates run (`externBindings`).")) (ELit (LString "- **run**: `medaka run` (`ioExternBindings` over the oracle).")) (ELit (LString "- **test**: `medaka test` and `medaka repl` (`testCapableExterns` over the oracle).")) (ELit (LString "- **native**, **wasm**: `medaka build` for each target (the extern catalog).")) (ELit (LString "")) (ELit (LString "## Cells")) (ELit (LString "")) (ELit (LString "`real` is the extern's actual effect; `canned` is bound but does not")) (ELit (LString "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is")) (ELit (LString "not bound, so the call is rejected or aborts.")) (ELit (LString "")) (ELit (LString "## Externs that differ")) (ELit (LString "")) (ELit (LString "| extern | oracle | run | test | native | wasm |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EMethodRef "map") (EVar "rowLine")) (EVar "shown")))))))
