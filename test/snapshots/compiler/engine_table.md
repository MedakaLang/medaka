# META
source_lines=244
stages=DESUGAR,MARK
# SOURCE
-- The per-extern engine matrix: for every `stdlib/runtime.mdk` extern, what the
-- pure oracle, `medaka run`, `medaka test --engines eval`/`repl`, the native backend and the
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
-- the third column is `testCapableExterns` over it, which only
-- `medaka test --engines eval` and `medaka repl` use: default `medaka test` is
-- native and follows the native column.  An extern with an empty effect row
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
oracleIntendedOnRun : List (String, String)
oracleIntendedOnRun = [
  ("putStr", stdoutReason),
  ("putStrLn", stdoutReason),
  ("flushStdout", stdoutReason),
]

stdoutReason : String
stdoutReason =
  "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer"

-- Effectful externs bound by neither table: `run` refuses them, each with its
-- reason.  An effectful extern in no table and not here is drift.
refusedOnRun : List (String, String)
refusedOnRun = [
  ("runCommand", execReason),
  ("runCommandBatch", execReason),
  (
    "assertSnapshot",
    "only the test runners bind it; `run` has no snapshot store",
  ),
  ("fetchText", "a browser-host extern; no other engine provides it"),
  ("netResolve", netReason),
  ("netTcpConnect", netReason),
  ("netTcpListen", netReason),
  ("netListenPort", netReason),
  ("netTcpAccept", netReason),
  ("netSend", netReason),
  ("netSendFrom", netReason),
  ("netRecv", netReason),
  ("netShutdown", netReason),
  ("netClose", netReason),
  ("netCloseListener", netReason),
  ("netSetTimeout", netReason),
  ("pdsSignalStart", netReason),
  ("pdsSignalRequested", netReason),
  ("ioPoll", netReason),
  ("netSetNonblock", netReason),
  ("netSetNonblockListener", netReason),
  ("netTryAccept", netReason),
  ("netConnectStart", netReason),
  ("netConnectCheck", netReason),
  ("netTryRecv", netReason),
  ("netTryRecvBytes", netReason),
  ("netTrySend", netReason),
  ("netTrySendFrom", netReason),
  ("netSendBytesFrom", netReason),
  ("netTrySendBytesFrom", netReason),
]

execReason : String
execReason =
  "`run` refuses subprocess execution on purpose; `medaka build` provides it"

netReason : String
netReason =
  "`run` does not bind the socket and poll externs; `medaka build` does"

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
      (S.fromList (map fst oracleIntendedOnRun))
  let tst = nameSet (testCapableExterns ())
  filterMap (mkRow oracle run tst) (declaredExterns decls)

-- Every extern with an effect row must be deliberate for `run`: bound in
-- `ioExternBindings`, oracle-bound and listed, or listed as refused.
driftOf : List Decl -> List String
driftOf decls =
  let run = nameSet (ioExternBindings ())
  let excused = map fst oracleIntendedOnRun ++ map fst refusedOnRun
  filterMap
    (p =>
      if snd p && not (S.has (fst p) run) && not (elem (fst p) excused) then
        Some (fst p)
      else
        None)
    (declaredExterns decls)

-- A runtime.mdk that cannot be read must fail the callers, not yield no rows.
loadRuntime : Unit -> <FileRead, Env> Result String (List Decl)
loadRuntime _ = match readFile runtimePath
  Ok src => Ok (parse src)
  Err e =>
    let cwd = getEnv "PWD" |> optionOr "(unknown)"
    Err "cannot read \{runtimePath} from working directory \{cwd}: \{e}"

export
engineRows : Unit -> <FileRead, Env> Result String (List EngineRow)
engineRows _ = map rowsOf (loadRuntime ())

export
runDrift : Unit -> <FileRead, Env> Result String (List String)
runDrift _ = map driftOf (loadRuntime ())

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
        "What each way of running Medaka does with each `stdlib/runtime.mdk` extern, the",
        "primitives the standard library is built on. An extern that is `real` everywhere",
        "is left out; so is any extern the compiler's backend table does not list.",
        "",
        "## Columns",
        "",
        "- **oracle**: the compiler's internal reference interpreter, which its own",
        "  differential tests use; you never run it directly.",
        "- **run**: `medaka run`.",
        "- **test --engines eval, repl**: `medaka test --engines eval` and `medaka repl`.",
        "  Plain `medaka test` runs natively, so read the **native** column for it.",
        "- **native**: a program built with `medaka build`, and the default `medaka test`.",
        "- **wasm**: a program built for the wasm target (the browser playground).",
        "",
        "## Cells",
        "",
        "`real` is the extern's actual effect; `canned` is bound but does not",
        "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is",
        "not bound, so the call is rejected or aborts.",
        "",
        "## Externs that differ",
        "",
        "| extern | oracle | run | test --engines eval, repl | native | wasm |",
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
(DTypeSig false "oracleIntendedOnRun" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "oracleIntendedOnRun" () (EListLit (ETuple (ELit (LString "putStr")) (EVar "stdoutReason")) (ETuple (ELit (LString "putStrLn")) (EVar "stdoutReason")) (ETuple (ELit (LString "flushStdout")) (EVar "stdoutReason"))))
(DTypeSig false "stdoutReason" (TyCon "String"))
(DFunDef false "stdoutReason" () (ELit (LString "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer")))
(DTypeSig false "refusedOnRun" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "refusedOnRun" () (EListLit (ETuple (ELit (LString "runCommand")) (EVar "execReason")) (ETuple (ELit (LString "runCommandBatch")) (EVar "execReason")) (ETuple (ELit (LString "assertSnapshot")) (ELit (LString "only the test runners bind it; `run` has no snapshot store"))) (ETuple (ELit (LString "fetchText")) (ELit (LString "a browser-host extern; no other engine provides it"))) (ETuple (ELit (LString "netResolve")) (EVar "netReason")) (ETuple (ELit (LString "netTcpConnect")) (EVar "netReason")) (ETuple (ELit (LString "netTcpListen")) (EVar "netReason")) (ETuple (ELit (LString "netListenPort")) (EVar "netReason")) (ETuple (ELit (LString "netTcpAccept")) (EVar "netReason")) (ETuple (ELit (LString "netSend")) (EVar "netReason")) (ETuple (ELit (LString "netSendFrom")) (EVar "netReason")) (ETuple (ELit (LString "netRecv")) (EVar "netReason")) (ETuple (ELit (LString "netShutdown")) (EVar "netReason")) (ETuple (ELit (LString "netClose")) (EVar "netReason")) (ETuple (ELit (LString "netCloseListener")) (EVar "netReason")) (ETuple (ELit (LString "netSetTimeout")) (EVar "netReason")) (ETuple (ELit (LString "pdsSignalStart")) (EVar "netReason")) (ETuple (ELit (LString "pdsSignalRequested")) (EVar "netReason")) (ETuple (ELit (LString "ioPoll")) (EVar "netReason")) (ETuple (ELit (LString "netSetNonblock")) (EVar "netReason")) (ETuple (ELit (LString "netSetNonblockListener")) (EVar "netReason")) (ETuple (ELit (LString "netTryAccept")) (EVar "netReason")) (ETuple (ELit (LString "netConnectStart")) (EVar "netReason")) (ETuple (ELit (LString "netConnectCheck")) (EVar "netReason")) (ETuple (ELit (LString "netTryRecv")) (EVar "netReason")) (ETuple (ELit (LString "netTryRecvBytes")) (EVar "netReason")) (ETuple (ELit (LString "netTrySend")) (EVar "netReason")) (ETuple (ELit (LString "netTrySendFrom")) (EVar "netReason")) (ETuple (ELit (LString "netSendBytesFrom")) (EVar "netReason")) (ETuple (ELit (LString "netTrySendBytesFrom")) (EVar "netReason"))))
(DTypeSig false "execReason" (TyCon "String"))
(DFunDef false "execReason" () (ELit (LString "`run` refuses subprocess execution on purpose; `medaka build` provides it")))
(DTypeSig false "netReason" (TyCon "String"))
(DFunDef false "netReason" () (ELit (LString "`run` does not bind the socket and poll externs; `medaka build` does")))
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
(DFunDef false "rowsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EApp (EVar "S.union") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (EApp (EVar "S.fromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "oracleIntendedOnRun"))))) (DoLet false false (PVar "tst") (EApp (EVar "nameSet") (EApp (EVar "testCapableExterns") (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "mkRow") (EVar "oracle")) (EVar "run")) (EVar "tst"))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "driftOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "driftOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "run") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (DoLet false false (PVar "excused") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "oracleIntendedOnRun")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "refusedOnRun")))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "snd") (EVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "S.has") (EApp (EVar "fst") (EVar "p"))) (EVar "run")))) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EApp (EVar "fst") (EVar "p"))) (EVar "excused")))) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "p"))) (EVar "None")))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "loadRuntime" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "loadRuntime" (PWild) (EMatch (EApp (EVar "readFile") (EVar "runtimePath")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Ok") (EApp (EVar "parse") (EVar "src")))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "cwd") (EBinOp "|>" (EApp (EVar "getEnv") (ELit (LString "PWD"))) (EApp (EVar "optionOr") (ELit (LString "(unknown)"))))) (DoExpr (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read ")) (EApp (EVar "display") (EVar "runtimePath"))) (ELit (LString " from working directory "))) (EApp (EVar "display") (EVar "cwd"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))))))
(DTypeSig true "engineRows" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "EngineRow"))))))
(DFunDef false "engineRows" (PWild) (EApp (EApp (EVar "map") (EVar "rowsOf")) (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig true "runDrift" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "runDrift" (PWild) (EApp (EApp (EVar "map") (EVar "driftOf")) (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig false "cellText" (TyFun (TyCon "Cell") (TyCon "String")))
(DFunDef false "cellText" ((PCon "Real")) (ELit (LString "real")))
(DFunDef false "cellText" ((PCon "Canned")) (ELit (LString "canned")))
(DFunDef false "cellText" ((PCon "Refused")) (ELit (LString "refused")))
(DTypeSig false "allReal" (TyFun (TyCon "EngineRow") (TyCon "Bool")))
(DFunDef false "allReal" ((PCon "EngineRow" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EApp (EApp (EVar "all") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "Real")))) (EListLit (EVar "a") (EVar "b") (EVar "c") (EVar "d") (EVar "e"))))
(DTypeSig false "rowLine" (TyFun (TyCon "EngineRow") (TyCon "String")))
(DFunDef false "rowLine" ((PCon "EngineRow" (PVar "n") (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "a")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "b")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "c")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "d")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "cellText") (EVar "e")))) (ELit (LString " |"))))
(DTypeSig true "renderEngineTable" (TyFun (TyApp (TyCon "List") (TyCon "EngineRow")) (TyCon "String")))
(DFunDef false "renderEngineTable" ((PVar "rows")) (EBlock (DoLet false false (PVar "shown") (EApp (EApp (EVar "filter") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EVar "allReal") (EVar "r"))))) (EVar "rows"))) (DoExpr (EApp (EVar "unlines") (EBinOp "++" (EListLit (ELit (LString "# Engines")) (ELit (LString "")) (ELit (LString "<!-- GENERATED by compiler/tools/engine_table.mdk; regenerate with `make engines-doc`. -->")) (ELit (LString "")) (ELit (LString "What each way of running Medaka does with each `stdlib/runtime.mdk` extern, the")) (ELit (LString "primitives the standard library is built on. An extern that is `real` everywhere")) (ELit (LString "is left out; so is any extern the compiler's backend table does not list.")) (ELit (LString "")) (ELit (LString "## Columns")) (ELit (LString "")) (ELit (LString "- **oracle**: the compiler's internal reference interpreter, which its own")) (ELit (LString "  differential tests use; you never run it directly.")) (ELit (LString "- **run**: `medaka run`.")) (ELit (LString "- **test --engines eval, repl**: `medaka test --engines eval` and `medaka repl`.")) (ELit (LString "  Plain `medaka test` runs natively, so read the **native** column for it.")) (ELit (LString "- **native**: a program built with `medaka build`, and the default `medaka test`.")) (ELit (LString "- **wasm**: a program built for the wasm target (the browser playground).")) (ELit (LString "")) (ELit (LString "## Cells")) (ELit (LString "")) (ELit (LString "`real` is the extern's actual effect; `canned` is bound but does not")) (ELit (LString "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is")) (ELit (LString "not bound, so the call is rejected or aborts.")) (ELit (LString "")) (ELit (LString "## Externs that differ")) (ELit (LString "")) (ELit (LString "| extern | oracle | run | test --engines eval, repl | native | wasm |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EVar "map") (EVar "rowLine")) (EVar "shown")))))))
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
(DTypeSig false "oracleIntendedOnRun" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "oracleIntendedOnRun" () (EListLit (ETuple (ELit (LString "putStr")) (EVar "stdoutReason")) (ETuple (ELit (LString "putStrLn")) (EVar "stdoutReason")) (ETuple (ELit (LString "flushStdout")) (EVar "stdoutReason"))))
(DTypeSig false "stdoutReason" (TyCon "String"))
(DFunDef false "stdoutReason" () (ELit (LString "the oracle appends to its stdout buffer; `run`'s driver (evalModulesOutputRunFacts) arms the flush and the CLI prints that buffer")))
(DTypeSig false "refusedOnRun" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "refusedOnRun" () (EListLit (ETuple (ELit (LString "runCommand")) (EVar "execReason")) (ETuple (ELit (LString "runCommandBatch")) (EVar "execReason")) (ETuple (ELit (LString "assertSnapshot")) (ELit (LString "only the test runners bind it; `run` has no snapshot store"))) (ETuple (ELit (LString "fetchText")) (ELit (LString "a browser-host extern; no other engine provides it"))) (ETuple (ELit (LString "netResolve")) (EVar "netReason")) (ETuple (ELit (LString "netTcpConnect")) (EVar "netReason")) (ETuple (ELit (LString "netTcpListen")) (EVar "netReason")) (ETuple (ELit (LString "netListenPort")) (EVar "netReason")) (ETuple (ELit (LString "netTcpAccept")) (EVar "netReason")) (ETuple (ELit (LString "netSend")) (EVar "netReason")) (ETuple (ELit (LString "netSendFrom")) (EVar "netReason")) (ETuple (ELit (LString "netRecv")) (EVar "netReason")) (ETuple (ELit (LString "netShutdown")) (EVar "netReason")) (ETuple (ELit (LString "netClose")) (EVar "netReason")) (ETuple (ELit (LString "netCloseListener")) (EVar "netReason")) (ETuple (ELit (LString "netSetTimeout")) (EVar "netReason")) (ETuple (ELit (LString "pdsSignalStart")) (EVar "netReason")) (ETuple (ELit (LString "pdsSignalRequested")) (EVar "netReason")) (ETuple (ELit (LString "ioPoll")) (EVar "netReason")) (ETuple (ELit (LString "netSetNonblock")) (EVar "netReason")) (ETuple (ELit (LString "netSetNonblockListener")) (EVar "netReason")) (ETuple (ELit (LString "netTryAccept")) (EVar "netReason")) (ETuple (ELit (LString "netConnectStart")) (EVar "netReason")) (ETuple (ELit (LString "netConnectCheck")) (EVar "netReason")) (ETuple (ELit (LString "netTryRecv")) (EVar "netReason")) (ETuple (ELit (LString "netTryRecvBytes")) (EVar "netReason")) (ETuple (ELit (LString "netTrySend")) (EVar "netReason")) (ETuple (ELit (LString "netTrySendFrom")) (EVar "netReason")) (ETuple (ELit (LString "netSendBytesFrom")) (EVar "netReason")) (ETuple (ELit (LString "netTrySendBytesFrom")) (EVar "netReason"))))
(DTypeSig false "execReason" (TyCon "String"))
(DFunDef false "execReason" () (ELit (LString "`run` refuses subprocess execution on purpose; `medaka build` provides it")))
(DTypeSig false "netReason" (TyCon "String"))
(DFunDef false "netReason" () (ELit (LString "`run` does not bind the socket and poll externs; `medaka build` does")))
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
(DFunDef false "rowsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "nameSet") (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false (PVar "run") (EApp (EApp (EVar "S.union") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (EApp (EVar "S.fromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "oracleIntendedOnRun"))))) (DoLet false false (PVar "tst") (EApp (EVar "nameSet") (EApp (EVar "testCapableExterns") (ELit LUnit)))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "mkRow") (EVar "oracle")) (EVar "run")) (EVar "tst"))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "driftOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "driftOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "run") (EApp (EVar "nameSet") (EApp (EVar "ioExternBindings") (ELit LUnit)))) (DoLet false false (PVar "excused") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "oracleIntendedOnRun")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "refusedOnRun")))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "snd") (EVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "S.has") (EApp (EVar "fst") (EVar "p"))) (EVar "run")))) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EApp (EVar "fst") (EVar "p"))) (EVar "excused")))) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "p"))) (EVar "None")))) (EApp (EVar "declaredExterns") (EVar "decls"))))))
(DTypeSig false "loadRuntime" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "loadRuntime" (PWild) (EMatch (EApp (EVar "readFile") (EVar "runtimePath")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Ok") (EApp (EVar "parse") (EVar "src")))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "cwd") (EBinOp "|>" (EApp (EVar "getEnv") (ELit (LString "PWD"))) (EApp (EVar "optionOr") (ELit (LString "(unknown)"))))) (DoExpr (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read ")) (EApp (EMethodRef "display") (EVar "runtimePath"))) (ELit (LString " from working directory "))) (EApp (EMethodRef "display") (EVar "cwd"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))))))
(DTypeSig true "engineRows" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "EngineRow"))))))
(DFunDef false "engineRows" (PWild) (EApp (EApp (EMethodRef "map") (EVar "rowsOf")) (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig true "runDrift" (TyFun (TyCon "Unit") (TyEffect ("FileRead" "Env") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "runDrift" (PWild) (EApp (EApp (EMethodRef "map") (EVar "driftOf")) (EApp (EVar "loadRuntime") (ELit LUnit))))
(DTypeSig false "cellText" (TyFun (TyCon "Cell") (TyCon "String")))
(DFunDef false "cellText" ((PCon "Real")) (ELit (LString "real")))
(DFunDef false "cellText" ((PCon "Canned")) (ELit (LString "canned")))
(DFunDef false "cellText" ((PCon "Refused")) (ELit (LString "refused")))
(DTypeSig false "allReal" (TyFun (TyCon "EngineRow") (TyCon "Bool")))
(DFunDef false "allReal" ((PCon "EngineRow" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EApp (EApp (EDictApp "all") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "Real")))) (EListLit (EVar "a") (EVar "b") (EVar "c") (EVar "d") (EVar "e"))))
(DTypeSig false "rowLine" (TyFun (TyCon "EngineRow") (TyCon "String")))
(DFunDef false "rowLine" ((PCon "EngineRow" (PVar "n") (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "a")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "b")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "c")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "d")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "cellText") (EVar "e")))) (ELit (LString " |"))))
(DTypeSig true "renderEngineTable" (TyFun (TyApp (TyCon "List") (TyCon "EngineRow")) (TyCon "String")))
(DFunDef false "renderEngineTable" ((PVar "rows")) (EBlock (DoLet false false (PVar "shown") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EVar "allReal") (EVar "r"))))) (EVar "rows"))) (DoExpr (EApp (EVar "unlines") (EBinOp "++" (EListLit (ELit (LString "# Engines")) (ELit (LString "")) (ELit (LString "<!-- GENERATED by compiler/tools/engine_table.mdk; regenerate with `make engines-doc`. -->")) (ELit (LString "")) (ELit (LString "What each way of running Medaka does with each `stdlib/runtime.mdk` extern, the")) (ELit (LString "primitives the standard library is built on. An extern that is `real` everywhere")) (ELit (LString "is left out; so is any extern the compiler's backend table does not list.")) (ELit (LString "")) (ELit (LString "## Columns")) (ELit (LString "")) (ELit (LString "- **oracle**: the compiler's internal reference interpreter, which its own")) (ELit (LString "  differential tests use; you never run it directly.")) (ELit (LString "- **run**: `medaka run`.")) (ELit (LString "- **test --engines eval, repl**: `medaka test --engines eval` and `medaka repl`.")) (ELit (LString "  Plain `medaka test` runs natively, so read the **native** column for it.")) (ELit (LString "- **native**: a program built with `medaka build`, and the default `medaka test`.")) (ELit (LString "- **wasm**: a program built for the wasm target (the browser playground).")) (ELit (LString "")) (ELit (LString "## Cells")) (ELit (LString "")) (ELit (LString "`real` is the extern's actual effect; `canned` is bound but does not")) (ELit (LString "perform the effect (a fixed value, a no-op or a captured buffer); `refused` is")) (ELit (LString "not bound, so the call is rejected or aborts.")) (ELit (LString "")) (ELit (LString "## Externs that differ")) (ELit (LString "")) (ELit (LString "| extern | oracle | run | test --engines eval, repl | native | wasm |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EMethodRef "map") (EVar "rowLine")) (EVar "shown")))))))
