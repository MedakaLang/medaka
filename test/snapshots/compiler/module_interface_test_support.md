# META
source_lines=110
stages=DESUGAR,MARK
# SOURCE
-- Helpers the tests of the module interface cache share (`module_interface_test`,
-- `module_interface_sexp_test`, `typecheck_test`): a keyed drive over named
-- sources, the fixture chain leaf, mid, entry, and the rendering of a report.
import frontend.ast.{Decl}
import frontend.desugar.{desugar}
import frontend.parser.{parse, parseLocated}
import support.util.{joinNl}
import types.publish.{ModDiags, TcDiag(..), TcReport(..), ppPubScheme}
import types.tc_types.{DriveOutputs(..), GraphCtx}
import types.typecheck.{
  defaultDriveInputs, checkModulesChainReportForGraph, chainArgs
}

-- The drive's `valueMain` argument for a graph whose entry is no value `main`.
export
noValueMain : Bool
noValueMain = False

-- One keyed drive over [mods], (module id, source) in dependency order, under the
-- chain key [chainKey] and the prelude key (seed, seed + 1).  Every module but the
-- last carries its source as its step key; the last is the entry, which never
-- records.  [runtime] and [core] are the prelude's declarations.
export
keyedDrive : Int ->
  String ->
  List Decl ->
  List Decl ->
  List (String, String) ->
  ((TcReport, DriveOutputs), GraphCtx)
keyedDrive seed chainKey runtime core mods =
  checkModulesChainReportForGraph
    (chainArgs
      defaultDriveInputs
      noValueMain
      (Some (seed, seed + 1))
      chainKey
      (stepKeys mods)
      runtime
      core
      (map (m => (fst m, desugar (parseLocated (snd m)))) mods))

-- [keyedDrive] with no prelude declarations.
export
bareDrive : Int ->
  String ->
  List (String, String) ->
  ((TcReport, DriveOutputs), GraphCtx)
bareDrive seed chainKey mods =
  keyedDrive seed chainKey [] (desugar (parse "")) mods

stepKeys : List (String, String) -> List (Option String)
stepKeys [] = []
stepKeys [_] = [None]
stepKeys (m :: rest) = Some (snd m) :: stepKeys rest

export
leafSrc : String
leafSrc = joinNl [
  "export data Box a = Box a | Empty",
  "export wrap x = Box x",
  "export unwrap : Box Int -> Int",
  "unwrap b = match b",
  "  Box n => n",
  "  Empty => 0",
]

-- [leaf] is the id of the module [midSrc] imports.
export
midSrc : String -> String
midSrc leaf = joinNl [
  "import \{leaf}.{Box(..), wrap}",
  "export twice x = wrap (wrap x)",
]

export
entrySrc : String -> String
entrySrc mid = joinNl ["import \{mid}.{twice}", "entry = twice 1"]

-- One keyed drive over the chain leaf, mid, entry, whose modules are named
-- [p]_leaf, [p]_mid and [p]_entry.  The result is the rendered report, the number
-- of modules the drive served and the graph record it ended in.
export
chainDrive : String ->
  Int ->
  String ->
  String ->
  String ->
  (List String, Int, GraphCtx)
chainDrive p seed chainKey leafText entryText =
  let ((report, outputs), gctx) = bareDrive seed chainKey [
    ("\{p}_leaf", leafText),
    ("\{p}_mid", midSrc "\{p}_leaf"),
    ("\{p}_entry", entryText),
  ]
  (render report, outputs.doServedModules, gctx)

export
render : TcReport -> List String
render r = flatMap renderRow r.trDiagnostics

export
renderRow : ModDiags -> List String
renderRow (mid, (schemes, errs, warns)) =
  map (s => "\{mid}.\{fst s} : \{ppPubScheme (snd s)}") schemes
    ++ map (d => "\{mid} error \{diagCode d}") errs
    ++ map (d => "\{mid} warning \{diagCode d}") warns

export
diagCode : TcDiag -> String
diagCode (TcDiag code _ _ _ _ _) = code
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "TcDiag" true) (mem "TcReport" true) (mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" true) (mem "GraphCtx" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "defaultDriveInputs" false) (mem "checkModulesChainReportForGraph" false) (mem "chainArgs" false))))
(DTypeSig true "noValueMain" (TyCon "Bool"))
(DFunDef false "noValueMain" () (EVar "False"))
(DTypeSig true "keyedDrive" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))))))
(DFunDef false "keyedDrive" ((PVar "seed") (PVar "chainKey") (PVar "runtime") (PVar "core") (PVar "mods")) (EApp (EVar "checkModulesChainReportForGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainArgs") (EVar "defaultDriveInputs")) (EVar "noValueMain")) (EApp (EVar "Some") (ETuple (EVar "seed") (EBinOp "+" (EVar "seed") (ELit (LInt 1)))))) (EVar "chainKey")) (EApp (EVar "stepKeys") (EVar "mods"))) (EVar "runtime")) (EVar "core")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EApp (EVar "snd") (EVar "m"))))))) (EVar "mods")))))
(DTypeSig true "bareDrive" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))))
(DFunDef false "bareDrive" ((PVar "seed") (PVar "chainKey") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EVar "keyedDrive") (EVar "seed")) (EVar "chainKey")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (ELit (LString ""))))) (EVar "mods")))
(DTypeSig false "stepKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stepKeys" ((PList)) (EListLit))
(DFunDef false "stepKeys" ((PList PWild)) (EListLit (EVar "None")))
(DFunDef false "stepKeys" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "::" (EApp (EVar "Some") (EApp (EVar "snd") (EVar "m"))) (EApp (EVar "stepKeys") (EVar "rest"))))
(DTypeSig true "leafSrc" (TyCon "String"))
(DFunDef false "leafSrc" () (EApp (EVar "joinNl") (EListLit (ELit (LString "export data Box a = Box a | Empty")) (ELit (LString "export wrap x = Box x")) (ELit (LString "export unwrap : Box Int -> Int")) (ELit (LString "unwrap b = match b")) (ELit (LString "  Box n => n")) (ELit (LString "  Empty => 0")))))
(DTypeSig true "midSrc" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "midSrc" ((PVar "leaf")) (EApp (EVar "joinNl") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EVar "leaf"))) (ELit (LString ".{Box(..), wrap}"))) (ELit (LString "export twice x = wrap (wrap x)")))))
(DTypeSig true "entrySrc" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "entrySrc" ((PVar "mid")) (EApp (EVar "joinNl") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString ".{twice}"))) (ELit (LString "entry = twice 1")))))
(DTypeSig true "chainDrive" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int") (TyCon "GraphCtx"))))))))
(DFunDef false "chainDrive" ((PVar "p") (PVar "seed") (PVar "chainKey") (PVar "leafText") (PVar "entryText")) (EBlock (DoLet false false (PTuple (PTuple (PVar "report") (PVar "outputs")) (PVar "gctx")) (EApp (EApp (EApp (EVar "bareDrive") (EVar "seed")) (EVar "chainKey")) (EListLit (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "_leaf"))) (EVar "leafText")) (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "_mid"))) (EApp (EVar "midSrc") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "_leaf"))))) (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "_entry"))) (EVar "entryText"))))) (DoExpr (ETuple (EApp (EVar "render") (EVar "report")) (EFieldAccess (EVar "outputs") "doServedModules") (EVar "gctx")))))
(DTypeSig true "render" (TyFun (TyCon "TcReport") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "render" ((PVar "r")) (EApp (EApp (EVar "flatMap") (EVar "renderRow")) (EFieldAccess (EVar "r") "trDiagnostics")))
(DTypeSig true "renderRow" (TyFun (TyCon "ModDiags") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderRow" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "s"))))) (ELit (LString ""))))) (EVar "schemes")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " error "))) (EApp (EVar "display") (EApp (EVar "diagCode") (EVar "d")))) (ELit (LString ""))))) (EVar "errs"))) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString " warning "))) (EApp (EVar "display") (EApp (EVar "diagCode") (EVar "d")))) (ELit (LString ""))))) (EVar "warns"))))
(DTypeSig true "diagCode" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "diagCode" ((PCon "TcDiag" (PVar "code") PWild PWild PWild PWild PWild)) (EVar "code"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "TcDiag" true) (mem "TcReport" true) (mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" true) (mem "GraphCtx" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "defaultDriveInputs" false) (mem "checkModulesChainReportForGraph" false) (mem "chainArgs" false))))
(DTypeSig true "noValueMain" (TyCon "Bool"))
(DFunDef false "noValueMain" () (EVar "False"))
(DTypeSig true "keyedDrive" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))))))
(DFunDef false "keyedDrive" ((PVar "seed") (PVar "chainKey") (PVar "runtime") (PVar "core") (PVar "mods")) (EApp (EVar "checkModulesChainReportForGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainArgs") (EVar "defaultDriveInputs")) (EVar "noValueMain")) (EApp (EVar "Some") (ETuple (EVar "seed") (EBinOp "+" (EVar "seed") (ELit (LInt 1)))))) (EVar "chainKey")) (EApp (EVar "stepKeys") (EVar "mods"))) (EVar "runtime")) (EVar "core")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EApp (EVar "snd") (EVar "m"))))))) (EVar "mods")))))
(DTypeSig true "bareDrive" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))))
(DFunDef false "bareDrive" ((PVar "seed") (PVar "chainKey") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EVar "keyedDrive") (EVar "seed")) (EVar "chainKey")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (ELit (LString ""))))) (EVar "mods")))
(DTypeSig false "stepKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stepKeys" ((PList)) (EListLit))
(DFunDef false "stepKeys" ((PList PWild)) (EListLit (EVar "None")))
(DFunDef false "stepKeys" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "::" (EApp (EVar "Some") (EApp (EVar "snd") (EVar "m"))) (EApp (EVar "stepKeys") (EVar "rest"))))
(DTypeSig true "leafSrc" (TyCon "String"))
(DFunDef false "leafSrc" () (EApp (EVar "joinNl") (EListLit (ELit (LString "export data Box a = Box a | Empty")) (ELit (LString "export wrap x = Box x")) (ELit (LString "export unwrap : Box Int -> Int")) (ELit (LString "unwrap b = match b")) (ELit (LString "  Box n => n")) (ELit (LString "  Empty => 0")))))
(DTypeSig true "midSrc" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "midSrc" ((PVar "leaf")) (EApp (EVar "joinNl") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EVar "leaf"))) (ELit (LString ".{Box(..), wrap}"))) (ELit (LString "export twice x = wrap (wrap x)")))))
(DTypeSig true "entrySrc" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "entrySrc" ((PVar "mid")) (EApp (EVar "joinNl") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString ".{twice}"))) (ELit (LString "entry = twice 1")))))
(DTypeSig true "chainDrive" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int") (TyCon "GraphCtx"))))))))
(DFunDef false "chainDrive" ((PVar "p") (PVar "seed") (PVar "chainKey") (PVar "leafText") (PVar "entryText")) (EBlock (DoLet false false (PTuple (PTuple (PVar "report") (PVar "outputs")) (PVar "gctx")) (EApp (EApp (EApp (EVar "bareDrive") (EVar "seed")) (EVar "chainKey")) (EListLit (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "_leaf"))) (EVar "leafText")) (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "_mid"))) (EApp (EVar "midSrc") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "_leaf"))))) (ETuple (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "_entry"))) (EVar "entryText"))))) (DoExpr (ETuple (EApp (EVar "render") (EVar "report")) (EFieldAccess (EVar "outputs") "doServedModules") (EVar "gctx")))))
(DTypeSig true "render" (TyFun (TyCon "TcReport") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "render" ((PVar "r")) (EApp (EApp (EDictApp "flatMap") (EVar "renderRow")) (EFieldAccess (EVar "r") "trDiagnostics")))
(DTypeSig true "renderRow" (TyFun (TyCon "ModDiags") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderRow" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "s"))))) (ELit (LString ""))))) (EVar "schemes")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " error "))) (EApp (EMethodRef "display") (EApp (EVar "diagCode") (EVar "d")))) (ELit (LString ""))))) (EVar "errs"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString " warning "))) (EApp (EMethodRef "display") (EApp (EVar "diagCode") (EVar "d")))) (ELit (LString ""))))) (EVar "warns"))))
(DTypeSig true "diagCode" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "diagCode" ((PCon "TcDiag" (PVar "code") PWild PWild PWild PWild PWild)) (EVar "code"))
