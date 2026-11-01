# META
source_lines=210
stages=DESUGAR,MARK
# SOURCE
-- Composed self-hosted front-end LOGIC — wires the stage ports into one
-- `runCheck`, the way bin/main.ml's `check` runs the OCaml pipeline:
--
--   parse → desugar → resolve → exhaust → typecheck
--
-- Run via the thin driver: medaka run compiler/entries/check_main.mdk <rt> <core> <src>
--
-- Output (location-free, so it diffs against the location-stripped oracles):
--   • if resolve reports errors, print them (sorted by the harness) and stop —
--     downstream stages can't run with unbound names;
--   • otherwise print guard-exhaustiveness warnings (exhaust, on the RAW AST)
--     followed by the inferred top-level schemes (typecheck, over core + prog).
--
-- A clean prelude-using program therefore prints exactly its === TYPES ===
-- schemes; a resolve fixture prints its resolve diagnostics; an exhaust fixture
-- prints its guard warning(s) ahead of the schemes.  runtime.mdk seeds the
-- extern signatures; core.mdk is the prelude prepended for resolve + typecheck.

-- LOGIC-ONLY module: the `main` + `withFiles`/`withCore`/`withTarget` driver
-- lives in `compiler/entries/check_main.mdk`.  A private `main` here could not be
-- imported, and an exported value `main` would initialise eagerly in every
-- program that references it.  This module exposes only `runCheck` + its
-- helpers, so it composes cleanly into compiler/driver/medaka_cli.mdk and the
-- batch/modules harnesses.

import frontend.ast.{Decl}
import frontend.parser.{parse}
import frontend.parse_cache.{parsePrelude}
import frontend.desugar.{desugar}
import support.util.{joinNl}
import frontend.resolve.{
  resolveToLines,
  singleFileImportErrors,
  ppResError,
  importedCtorDecls,
}
import frontend.exhaust.{exhaustToLinesWith}
import frontend.desugar_cache.{desugaredPrelude, preludeGeneration}
import types.typecheck.{
  defaultDriveInputs,
  checkOneToLinesWithRuntimeK,
  checkOneErrorsWithRuntime,
  entryReportFromDiags,
  ModDiags,
}

-- exported so the batch typecheck harness's synthetic entry can pull this
-- module into a single union closure (does not change its inferred schemes),
-- and so compiler/entries/check_main.mdk + compiler/driver/medaka_cli.mdk can drive it.
export
runCheck : String -> String -> String -> String
runCheck rsrc csrc tsrc = runCheckFromDecls rsrc csrc (parse tsrc)

-- S-3/#164: `runCheck`'s body, parameterised over the already-parsed target
-- program — so a caller that already has `raw` in hand (e.g. `checkRoute`'s
-- single-module clean arm, which gets it real-span from the loader) does not
-- have to have `runCheck` re-parse `tsrc` from source.  `runCheck` itself
-- keeps its exact signature/behaviour (placeholder-loc `parse`) for every
-- other caller.
export
runCheckFromDecls : String -> String -> List Decl -> String
runCheckFromDecls rsrc csrc raw =
  let desugared = desugar raw
  let runtimeP = parsePrelude rsrc
  let coreP = parsePrelude csrc
  let importErrs = singleFileImportErrors desugared
  let importDiags = joinNl (map ppResError importErrs)
  routeImportCheck importDiags rsrc csrc runtimeP coreP raw desugared
-- R3: check for imports of unknown modules before resolve so we emit
-- UnknownModule (right category) rather than falling through to a
-- spurious typecheck "Unbound variable".  In single-file mode there is
-- no loader, so any non-core import is by definition unknown.

routeImportCheck : String ->
  String ->
  String ->
  List Decl ->
  List Decl ->
  List Decl ->
  List Decl ->
  String
routeImportCheck "" rsrc csrc runtimeP coreP raw desugared =
  let resDiags = resolveToLines runtimeP coreP desugared
  reportFor resDiags rsrc csrc runtimeP coreP raw desugared
routeImportCheck diags _ _ _ _ _ _ = diags

reportFor : String ->
  String ->
  String ->
  List Decl ->
  List Decl ->
  List Decl ->
  List Decl ->
  String
-- Intentional cross-file duplicate of entries/check_batch.mdk's copy, for the
-- same reason `cleanReport` below carries: both are module-private, and sharing
-- them means exporting this module's report assembly to an entry that exists to
-- reproduce its semantics exactly. Consolidate the two drivers or neither.
-- lint-disable-next-line rule-duplicate-body
reportFor "" rsrc csrc runtimeP coreP raw desugared =
  cleanReport rsrc csrc runtimeP coreP raw desugared
reportFor resDiags _ _ _ _ _ _ = resDiags

cleanReport : String ->
  String ->
  List Decl ->
  List Decl ->
  List Decl ->
  List Decl ->
  String
-- Intentional cross-file duplicate of the same helper in check_batch.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
cleanReport rsrc csrc runtimeP coreP raw desugared =
  let exWarns = exhaustToLinesWith (raw ++ runtimeP ++ coreP) raw
  -- The typecheck runs over the desugar cache's trees, keyed by the prelude
  -- sources, so the core check is memoized: `analyzeFrom` already checked this
  -- prelude in this process, and a keyless check would redo it from scratch.
  -- `desugaredPrelude src` is `desugar (parsePrelude src)`, the same tree.
  let schemes =
    checkOneToLinesWithRuntimeK
      defaultDriveInputs
      (Some (preludeGeneration rsrc csrc))
      (desugaredPrelude rsrc)
      (desugaredPrelude csrc)
      desugared
  joinNonEmpty exWarns schemes

joinNonEmpty : String -> String -> String
-- Intentional cross-file duplicate of entries/check_batch.mdk's copy — same
-- constraint as `reportFor` above: module-private in both, consolidated with
-- their drivers or not at all.
-- lint-disable-next-line rule-duplicate-body
joinNonEmpty "" b = b
joinNonEmpty a "" = a
joinNonEmpty a b = "\{a}\n\{b}"

-- G1 (SOUNDNESS): does the same front-end pipeline runCheck drives report ANY
-- error?  This is the exit-code predicate for the native CLI: runCheck returns a
-- REPORT string whose success path is a NON-empty signature dump, so "report
-- non-empty" is NOT "had an error".  checkHasErrors instead mirrors runCheck's
-- exact short-circuit ROUTING (single-file imports → resolve → typecheck) and
-- tests each error CATEGORY for content, reusing the same error
-- sources, while ignoring exhaustiveness WARNINGS (not errors) and the success
-- scheme dump.  Keeping this separate from runCheck leaves its stdout byte-
-- identical (the diff_native_cli gate stays green); only the exit code is gated.
export
checkHasErrors : String -> String -> String -> Bool
checkHasErrors rsrc csrc tsrc =
  let raw = parse tsrc
  let desugared = desugar raw
  let runtimeP = parsePrelude rsrc
  let coreP = parsePrelude csrc
  let importErrs = singleFileImportErrors desugared
  match importErrs
    _ :: _ => True
    [] =>
      let resDiags = resolveToLines runtimeP coreP desugared
      match resDiags
        "" =>
          checkOneErrorsWithRuntime
            defaultDriveInputs
            (desugar runtimeP)
            (desugar coreP)
            desugared
        _ => True

-- ── multi-module `check` (DRIVER-COLLAPSE Phase 4, OPTION A) ───────────────
-- The unified `medaka check` path for IMPORT-BEARING files.  The CLI loads the
-- entry + its transitive imports (loadProgram, entry LAST in dependency-first
-- order), DESUGARS each and typechecks the graph ONCE; this renders that pass's
-- per-module diagnostics.  Imports are RESOLVED (vs the single-file path's
-- `UnknownModule`), mirroring how `build`/`run` route through loadProgram → the
-- multi-module typecheck.  Output mirrors runCheck's shape over the entry module.
-- The guard-exhaustiveness pass (`entryExhaust`) is AST-only (no typecheck) over
-- the same entry module; the entry report is a projection of `perMod`, never a
-- second graph pass.  `exWarns` is the entry's guard-exhaustiveness lines, already
-- rendered by a caller that renders them before the graph is typechecked so the
-- desugared modules they read need not stay live through the typecheck.
export
checkModulesReport : String -> List ModDiags -> String
checkModulesReport exWarns perMod =
  joinNonEmpty exWarns (entryReportFromDiags perMod)

-- guard-exhaustiveness warnings on the ENTRY module (last) — the multi-module
-- analog of runCheck's `exhaustToLines raw`.  exhaustToLines runs on the desugared
-- decls here (the loaded mods are already desugared); guard-coverage lowering does
-- not erase the `match` shape exhaust inspects, so this surfaces the same warnings.
-- The oracle is the entry's own decls, the decls declaring a constructor its
-- imports bind, and runtime + core — the same scope `typecheckDiagsFold`
-- (`driver/diagnostics.mdk`) gives every module.  `rtD`/`coreD`/`mods` are the
-- DESUGARED decls, which still carry the DData the oracle reads.
export
entryExhaust : List Decl ->
  List Decl ->
  Option (String, String) ->
  List (String, List Decl) ->
  String
entryExhaust rtD coreD sibling mods =
  entryExhaustGo (rtD ++ coreD) (importedCtorDecls coreD sibling mods mods) mods

entryExhaustGo : List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String
entryExhaustGo _ _ [] = ""
entryExhaustGo preludeDecls [(_, imported)] [(_, prog)] =
  exhaustToLinesWith (imported ++ preludeDecls) prog
entryExhaustGo preludeDecls (_ :: scopes) (_ :: rest) =
  entryExhaustGo preludeDecls scopes rest
entryExhaustGo _ [] (_ :: _) = ""
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveToLines" false) (mem "singleFileImportErrors" false) (mem "ppResError" false) (mem "importedCtorDecls" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "exhaustToLinesWith" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "defaultDriveInputs" false) (mem "checkOneToLinesWithRuntimeK" false) (mem "checkOneErrorsWithRuntime" false) (mem "entryReportFromDiags" false) (mem "ModDiags" false))))
(DTypeSig true "runCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "runCheck" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EApp (EApp (EApp (EVar "runCheckFromDecls") (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "parse") (EVar "tsrc"))))
(DTypeSig true "runCheckFromDecls" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "runCheckFromDecls" ((PVar "rsrc") (PVar "csrc") (PVar "raw")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parsePrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parsePrelude") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoLet false false (PVar "importDiags") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResError")) (EVar "importErrs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeImportCheck") (EVar "importDiags")) (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DTypeSig false "routeImportCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))))
(DFunDef false "routeImportCheck" ((PLit (LString "")) (PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportFor") (EVar "resDiags")) (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DFunDef false "routeImportCheck" ((PVar "diags") PWild PWild PWild PWild PWild PWild) (EVar "diags"))
(DTypeSig false "reportFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))))
(DFunDef false "reportFor" ((PLit (LString "")) (PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cleanReport") (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))
(DFunDef false "reportFor" ((PVar "resDiags") PWild PWild PWild PWild PWild PWild) (EVar "resDiags"))
(DTypeSig false "cleanReport" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))))
(DFunDef false "cleanReport" ((PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "checkOneToLinesWithRuntimeK") (EVar "defaultDriveInputs")) (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc")))) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "desugared"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "schemes")))))
(DTypeSig false "joinNonEmpty" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinNonEmpty" ((PLit (LString "")) (PVar "b")) (EVar "b"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PLit (LString ""))) (EVar "a"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "checkHasErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "checkHasErrors" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parsePrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parsePrelude") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoExpr (EMatch (EVar "importErrs") (arm (PCons PWild PWild) () (EVar "True")) (arm (PList) () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EApp (EApp (EApp (EApp (EVar "checkOneErrorsWithRuntime") (EVar "defaultDriveInputs")) (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))) (arm PWild () (EVar "True"))))))))))
(DTypeSig true "checkModulesReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "String"))))
(DFunDef false "checkModulesReport" ((PVar "exWarns") (PVar "perMod")) (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EApp (EVar "entryReportFromDiags") (EVar "perMod"))))
(DTypeSig true "entryExhaust" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "entryExhaust" ((PVar "rtD") (PVar "coreD") (PVar "sibling") (PVar "mods")) (EApp (EApp (EApp (EVar "entryExhaustGo") (EBinOp "++" (EVar "rtD") (EVar "coreD"))) (EApp (EApp (EApp (EApp (EVar "importedCtorDecls") (EVar "coreD")) (EVar "sibling")) (EVar "mods")) (EVar "mods"))) (EVar "mods")))
(DTypeSig false "entryExhaustGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "entryExhaustGo" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "entryExhaustGo" ((PVar "preludeDecls") (PList (PTuple PWild (PVar "imported"))) (PList (PTuple PWild (PVar "prog")))) (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EVar "imported") (EVar "preludeDecls"))) (EVar "prog")))
(DFunDef false "entryExhaustGo" ((PVar "preludeDecls") (PCons PWild (PVar "scopes")) (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "entryExhaustGo") (EVar "preludeDecls")) (EVar "scopes")) (EVar "rest")))
(DFunDef false "entryExhaustGo" (PWild (PList) (PCons PWild PWild)) (ELit (LString "")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveToLines" false) (mem "singleFileImportErrors" false) (mem "ppResError" false) (mem "importedCtorDecls" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "exhaustToLinesWith" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "defaultDriveInputs" false) (mem "checkOneToLinesWithRuntimeK" false) (mem "checkOneErrorsWithRuntime" false) (mem "entryReportFromDiags" false) (mem "ModDiags" false))))
(DTypeSig true "runCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "runCheck" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EApp (EApp (EApp (EVar "runCheckFromDecls") (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "parse") (EVar "tsrc"))))
(DTypeSig true "runCheckFromDecls" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "runCheckFromDecls" ((PVar "rsrc") (PVar "csrc") (PVar "raw")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parsePrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parsePrelude") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoLet false false (PVar "importDiags") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResError")) (EVar "importErrs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeImportCheck") (EVar "importDiags")) (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DTypeSig false "routeImportCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))))
(DFunDef false "routeImportCheck" ((PLit (LString "")) (PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportFor") (EVar "resDiags")) (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DFunDef false "routeImportCheck" ((PVar "diags") PWild PWild PWild PWild PWild PWild) (EVar "diags"))
(DTypeSig false "reportFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))))
(DFunDef false "reportFor" ((PLit (LString "")) (PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cleanReport") (EVar "rsrc")) (EVar "csrc")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))
(DFunDef false "reportFor" ((PVar "resDiags") PWild PWild PWild PWild PWild PWild) (EVar "resDiags"))
(DTypeSig false "cleanReport" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))))
(DFunDef false "cleanReport" ((PVar "rsrc") (PVar "csrc") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "checkOneToLinesWithRuntimeK") (EVar "defaultDriveInputs")) (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc")))) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "desugared"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "schemes")))))
(DTypeSig false "joinNonEmpty" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinNonEmpty" ((PLit (LString "")) (PVar "b")) (EVar "b"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PLit (LString ""))) (EVar "a"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "checkHasErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "checkHasErrors" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parsePrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parsePrelude") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoExpr (EMatch (EVar "importErrs") (arm (PCons PWild PWild) () (EVar "True")) (arm (PList) () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EApp (EApp (EApp (EApp (EVar "checkOneErrorsWithRuntime") (EVar "defaultDriveInputs")) (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))) (arm PWild () (EVar "True"))))))))))
(DTypeSig true "checkModulesReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "String"))))
(DFunDef false "checkModulesReport" ((PVar "exWarns") (PVar "perMod")) (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EApp (EVar "entryReportFromDiags") (EVar "perMod"))))
(DTypeSig true "entryExhaust" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "entryExhaust" ((PVar "rtD") (PVar "coreD") (PVar "sibling") (PVar "mods")) (EApp (EApp (EApp (EVar "entryExhaustGo") (EBinOp "++" (EVar "rtD") (EVar "coreD"))) (EApp (EApp (EApp (EApp (EVar "importedCtorDecls") (EVar "coreD")) (EVar "sibling")) (EVar "mods")) (EVar "mods"))) (EVar "mods")))
(DTypeSig false "entryExhaustGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "entryExhaustGo" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "entryExhaustGo" ((PVar "preludeDecls") (PList (PTuple PWild (PVar "imported"))) (PList (PTuple PWild (PVar "prog")))) (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EVar "imported") (EVar "preludeDecls"))) (EVar "prog")))
(DFunDef false "entryExhaustGo" ((PVar "preludeDecls") (PCons PWild (PVar "scopes")) (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "entryExhaustGo") (EVar "preludeDecls")) (EVar "scopes")) (EVar "rest")))
(DFunDef false "entryExhaustGo" (PWild (PList) (PCons PWild PWild)) (ELit (LString "")))
