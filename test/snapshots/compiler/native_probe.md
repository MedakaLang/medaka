# META
source_lines=388
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/native_probe.mdk — one native probe build for all the native
-- arms of a file under `medaka test`.
--
-- Each native engine (`native_doctest.mdk`, `native_test_decls.mdk`,
-- `native_props.mdk`) compiles the target's verbatim source plus its own
-- bindings into a probe of its own.  This module builds ONE program holding
-- every arm's bindings beside the target source once, and runs that binary
-- once per arm: a `main` reads a nonce-named environment variable and runs the
-- one section it names.  One process per section keeps what the separate
-- probes gave each arm: its own globals, its own stdout transcript, and an
-- abort that ends only that arm.  Each section is read back by its own
-- engine's decoder under its own sentinel prefix.
--
-- The selector is an environment variable, not an argument, so the program
-- under test still sees the empty `args ()` it sees in a per-arm probe.
--
-- Two fallbacks give back exactly what the per-arm probes report:
--   * the merged program does not build: every arm runs its own probe, so each
--     reports its own build error, and an error in bindings only one arm adds
--     does not fail the others;
--   * a section's run prints none of its sentinels: that arm runs its own
--     probe.  The native backend can force a top-level nullary binding before
--     `main` runs, depending on the binding's shape, so an arm's binding that
--     panics can end another section's run at startup.

import frontend.ast.{Decl, Expr}
import driver.build_cmd.{
  makeTempDir,
  scratchProbeManifest,
  cleanupTempDir,
  runBuildNativeRoots,
  BuildProfile(..),
  envOr,
  defaultMedakaRoot,
}
import driver.loader.{entrySearchRoots}
import support.path.{joinPath, baseOf, dirOf}
import support.util.{joinNl, splitNl, startsWith, listLen}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert}
import tools.probe_transcript.{
  freshProbeNonce,
  mintNonce,
  probeNameNonce,
  renameUserMain,
  runtimeAlias,
  runtimeDependencyName,
}
import tools.doctest.{Example, ExResult, RunResult(..), buildDetailsFrom}
import tools.native_doctest.{
  doctestProbePrefixes,
  doctestRendered,
  doctestSection,
  runNativeDoctests,
}
import tools.native_test_decls.{
  runNativeTests,
  testProbePrefixes,
  testResultsFromRun,
  testSection,
}
import tools.native_props.{
  NativePropPlan,
  nativePropsSettled,
  planNativePropRequests,
  propProbePrefixes,
  propResultsFromRun,
  propSection,
  runNativePlannedPropRequests,
  runNativePropPlan,
}
import tools.prop_plan.{PlanModule}
import tools.prop_runner.{PropResult, PropRequest}

-- The doctest phase's result, the property rows, the ordinary `test "…"`
-- results, and one result list per test pinned as an expected native error,
-- in the order those tests were given.
public export data NativeArmResults =
  | NativeArmResults RunResult (List PropResult) (List ExResult) (List (List ExResult))

-- One arm of the file.  A test arm numbers its tests from its first index, so
-- the ordinary tests and each pinned test bind distinct names in one program.
data Arm =
  | DocArm (List Example) (List (Result String (List Decl)))
  | TestArm Int (List (String, Int, Expr))
  | PropArm NativePropPlan (List PlanModule)

data ArmOut =
  | DocOut RunResult
  | TestOut (List ExResult)
  | PropOut (List PropResult)

-- `docArm` is the examples and their synth results, when the doctest phase
-- runs; `testArm` the ordinary tests and the tests pinned as an expected native
-- error, when the `test "…"` phase runs.  `props` runs the caller's native
-- property phase on the leaf it is given: the property plan is decided there,
-- so the build happens when the leaf is reached with work to run, and after the
-- phase when it is not.
export
runMergedNativeArms : String ->
  String ->
  List Decl ->
  Option (List Example, List (Result String (List Decl))) ->
  Option (List (String, Int, Expr), List (String, Int, Expr)) ->
  ((String -> String -> List PlanModule -> List PropRequest -> <IO> List PropResult) -> <IO> List PropResult) ->
  <IO> NativeArmResults
runMergedNativeArms target tsrc userDecls docArm testArm props =
  let fixed = docArms docArm ++ testArms testArm
  let held = Ref None
  let propRows = props (mergedPropLeaf held target tsrc userDecls fixed)
  let outs = match !held
    Some ran => ran
    None => runArms target tsrc userDecls fixed
  let (ordinary, pinned) = match testOuts outs
    [] => ([], [])
    batch :: each => (batch, each)
  NativeArmResults (doctestOut outs) propRows ordinary pinned

-- The property leaf the caller's phase reaches with its final requests.  The
-- phase reaches it at most once per file; a second call runs on its own probe.
mergedPropLeaf : Ref (Option (List ArmOut)) ->
  String ->
  String ->
  List Decl ->
  List Arm ->
  String ->
  String ->
  List PlanModule ->
  List PropRequest ->
  <IO> List PropResult
mergedPropLeaf held target tsrc userDecls fixed _ _ modules requests =
  match !held
    Some _ => runNativePlannedPropRequests target tsrc modules requests
    None =>
      let plan = planNativePropRequests tsrc modules requests
      match nativePropsSettled plan
        Some rows => rows
        None =>
          let outs =
            runArms target tsrc userDecls (fixed ++ [PropArm plan modules])
          held := Some outs
          propOut outs

docArms : Option (List Example, List (Result String (List Decl))) -> List Arm
docArms None = []
docArms (Some (examples, synthResults)) = [DocArm examples synthResults]

testArms : Option (List (String, Int, Expr), List (String, Int, Expr)) ->
  List Arm
testArms None = []
testArms (Some (ordinary, pinned)) =
  TestArm 0 ordinary :: pinnedArms (listLen ordinary) pinned

pinnedArms : Int -> List (String, Int, Expr) -> List Arm
pinnedArms _ [] = []
pinnedArms i (t :: rest) = TestArm i [t] :: pinnedArms (i + 1) rest

-- A single arm gains nothing from merging, so it runs on its own probe.
runArms : String -> String -> List Decl -> List Arm -> <IO> List ArmOut
runArms target tsrc userDecls arms
  | listLen arms < 2 = map (armAlone target tsrc userDecls) arms
  | otherwise = match makeTempDir ()
    Err _ => map (armAlone target tsrc userDecls) arms
    Ok tmpDir =>
      let nonce = freshProbeNonce (mintNonce ()) mergedPrefixes tsrc
      -- Bound before the teardown so the binary exists while every section
      -- runs.
      let outs = runMerged target tsrc userDecls arms tmpDir nonce
      let _ = cleanupTempDir tmpDir
      outs

mergedPrefixes : List String
mergedPrefixes =
  doctestProbePrefixes
    ++ testProbePrefixes
    ++ propProbePrefixes
    ++ ["__nps_", "NpIo_"]

runMerged : String ->
  String ->
  List Decl ->
  List Arm ->
  String ->
  String ->
  <IO> List ArmOut
runMerged target tsrc userDecls arms tmpDir nonce =
  let sections = map (armSection nonce) arms
  let outPath = joinPath tmpDir "np_probe"
  if buildMerged target tsrc nonce sections tmpDir outPath then
    runSections target tsrc userDecls nonce outPath 0 arms sections
  else
    map (armAlone target tsrc userDecls) arms

buildMerged : String ->
  String ->
  String ->
  List (String, List String, List String, List String) ->
  String ->
  String ->
  <IO> Bool
buildMerged target tsrc nonce sections tmpDir outPath =
  -- `np_<basename>`, so the copy cannot claim the original's module id.
  let entryPath = joinPath tmpDir ("np_" ++ baseOf target)
  match (scratchProbeManifest
    "medaka_native_probe"
    target
    (runtimeDependencyName nonce))
    Err _ => False
    Ok manifest => match writeFile (joinPath tmpDir "medaka.toml") manifest
      Err _ => False
      Ok _ => match writeFile entryPath (mergedSource nonce tsrc sections)
        Err _ => False
        Ok _ =>
          let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
          -- The same build every per-arm probe makes, strictEmit included
          -- (#2679).
          match (runBuildNativeRoots
            root
            (envOr "MEDAKA" (joinPath root "medaka"))
            (envOr "CC" "clang")
            entryPath
            outPath
            tmpDir
            False
            (entrySearchRoots (dirOf target))
            True
            False
            False
            BuildProbe)
            Err _ => False
            Ok _ => True

-- The imports of every section, each once; the target's source once, its own
-- `main` renamed; every section's bindings; one entry per section; and a `main`
-- that runs the section the selector names.  With no selector it runs nothing.
mergedSource : String ->
  String ->
  List (String, List String, List String, List String) ->
  String
mergedSource nonce tsrc sections =
  joinNl
    (distinctLines
        ([
            "import \{runtimeDependencyName nonce}.runtime as \{runtimeAlias nonce}",
            "import \{runtimeDependencyName nonce}.io as \{ioAlias nonce}",
          ]
          ++ flatMap sectionImports sections)
        omEmpty
      ++ ["", renameUserMain tsrc, ""]
      ++ flatMap sectionDecls sections
      ++ entryLines nonce 0 sections
      ++ [
        "main = match \{ioAlias nonce}.getEnvOr \"\{selectorVar nonce}\" \"\"",
      ]
      ++ dispatchLines nonce 0 sections
      ++ ["  _ => ()", ""])

sectionImports : (String, List String, List String, List String) -> List String
sectionImports (_, imports, _, _) = imports

sectionDecls : (String, List String, List String, List String) -> List String
sectionDecls (_, _, decls, _) = decls ++ [""]

distinctLines : List String -> OrdMap Unit -> List String
distinctLines [] _ = []
distinctLines (l :: rest) seen
  | l == "" || omHasKey l seen = distinctLines rest seen
  | otherwise = l :: distinctLines rest (omInsert l () seen)

entryLines : String ->
  Int ->
  List (String, List String, List String, List String) ->
  List String
entryLines _ _ [] = []
entryLines nonce k ((_, _, _, entry) :: rest) =
  ["\{entryName nonce k} _ ="] ++ entry ++ [""] ++ entryLines nonce (k + 1) rest

dispatchLines : String ->
  Int ->
  List (String, List String, List String, List String) ->
  List String
dispatchLines _ _ [] = []
dispatchLines nonce k (_ :: rest) =
  "  \"\{sectionKey k}\" => \{entryName nonce k} ()"
    :: dispatchLines nonce (k + 1) rest

-- The runtime catalog does not export `getEnv`; `io`'s wrapper is reached
-- through the same generated dependency, so a target module named `io` cannot
-- stand in for it.
ioAlias : String -> String
ioAlias nonce = "NpIo_\{probeNameNonce nonce}"

entryName : String -> Int -> String
entryName nonce k = "__nps_\{probeNameNonce nonce}_\{intToString k}__"

sectionKey : Int -> String
sectionKey k = "section_\{intToString k}"

selectorVar : String -> String
selectorVar nonce = "MEDAKA_NATIVE_PROBE_SECTION_\{probeNameNonce nonce}"

runSections : String ->
  String ->
  List Decl ->
  String ->
  String ->
  Int ->
  List Arm ->
  List (String, List String, List String, List String) ->
  <IO> List ArmOut
runSections target tsrc userDecls nonce outPath k (arm :: arms) ((prefix, _, _, _) :: sections) =
  let out = runSection target tsrc userDecls nonce outPath k arm prefix
  out :: runSections target tsrc userDecls nonce outPath (k + 1) arms sections
runSections _ _ _ _ _ _ _ _ = []

-- The probe's own spawns read MEDAKA and MEDAKA_ROOT from its environment, so
-- it gets the environment prefix every per-arm probe gets, plus the selector.
runSection : String ->
  String ->
  List Decl ->
  String ->
  String ->
  Int ->
  Arm ->
  String ->
  <IO> ArmOut
runSection target tsrc userDecls nonce outPath k arm prefix =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  match runCommand "env" [
    "MEDAKA_ROOT=" ++ root,
    "MEDAKA=" ++ envOr "MEDAKA" (joinPath root "medaka"),
    "MEDAKA_EMITTER="
      ++ envOr "MEDAKA_EMITTER" (joinPath root "medaka_emitter"),
    "\{selectorVar nonce}=\{sectionKey k}",
    outPath,
  ]
    Ok (code, out, errOut) =>
      if printedSentinel prefix (splitNl out) then
        armDecode nonce arm code out errOut
      else
        armAlone target tsrc userDecls arm
    Err _ => armAlone target tsrc userDecls arm

printedSentinel : String -> List String -> Bool
printedSentinel _ [] = False
printedSentinel prefix (l :: rest) =
  startsWith prefix l || printedSentinel prefix rest

armSection : String -> Arm -> (String, List String, List String, List String)
armSection nonce (DocArm examples synthResults) =
  doctestSection nonce examples synthResults
armSection nonce (TestArm first tests) = testSection nonce first tests
armSection nonce (PropArm plan modules) = propSection nonce modules plan

armDecode : String -> Arm -> Int -> String -> String -> ArmOut
armDecode nonce (DocArm examples synthResults) code out errOut =
  DocOut
    (buildDetailsFrom
      (doctestRendered nonce examples synthResults code out errOut)
      synthResults
      examples)
armDecode nonce (TestArm first tests) code out errOut =
  TestOut (testResultsFromRun nonce first tests code out errOut)
armDecode nonce (PropArm plan _) code out errOut =
  PropOut (propResultsFromRun nonce plan code out errOut)

-- The arm on its own probe, exactly as its engine runs it outside a merge.
armAlone : String -> String -> List Decl -> Arm -> <IO> ArmOut
armAlone target tsrc userDecls (DocArm examples synthResults) =
  DocOut (runNativeDoctests target tsrc userDecls examples synthResults)
armAlone target tsrc _ (TestArm _ tests) =
  TestOut (runNativeTests target tsrc tests)
armAlone target tsrc _ (PropArm plan modules) =
  PropOut (runNativePropPlan target tsrc modules plan)

doctestOut : List ArmOut -> RunResult
doctestOut [] = RunResult 0 0 0 0 []
doctestOut ((DocOut result) :: _) = result
doctestOut (_ :: rest) = doctestOut rest

testOuts : List ArmOut -> List (List ExResult)
testOuts [] = []
testOuts ((TestOut results) :: rest) = results :: testOuts rest
testOuts (_ :: rest) = testOuts rest

propOut : List ArmOut -> List PropResult
propOut [] = []
propOut ((PropOut rows) :: _) = rows
propOut (_ :: rest) = propOut rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "makeTempDir" false) (mem "scratchProbeManifest" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "BuildProfile" true) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false) (mem "startsWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "freshProbeNonce" false) (mem "mintNonce" false) (mem "probeNameNonce" false) (mem "renameUserMain" false) (mem "runtimeAlias" false) (mem "runtimeDependencyName" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" false) (mem "RunResult" true) (mem "buildDetailsFrom" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "doctestProbePrefixes" false) (mem "doctestRendered" false) (mem "doctestSection" false) (mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false) (mem "testProbePrefixes" false) (mem "testResultsFromRun" false) (mem "testSection" false))))
(DUse false (UseGroup ("tools" "native_props") ((mem "NativePropPlan" false) (mem "nativePropsSettled" false) (mem "planNativePropRequests" false) (mem "propProbePrefixes" false) (mem "propResultsFromRun" false) (mem "propSection" false) (mem "runNativePlannedPropRequests" false) (mem "runNativePropPlan" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "PropRequest" false))))
(DData Public "NativeArmResults" () ((variant "NativeArmResults" (ConPos (TyCon "RunResult") (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "ExResult")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "ExResult")))))) ())
(DData Private "Arm" () ((variant "DocArm" (ConPos (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestArm" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (variant "PropArm" (ConPos (TyCon "NativePropPlan") (TyApp (TyCon "List") (TyCon "PlanModule"))))) ())
(DData Private "ArmOut" () ((variant "DocOut" (ConPos (TyCon "RunResult"))) (variant "TestOut" (ConPos (TyApp (TyCon "List") (TyCon "ExResult")))) (variant "PropOut" (ConPos (TyApp (TyCon "List") (TyCon "PropResult"))))) ())
(DTypeSig true "runMergedNativeArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (TyFun (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))) (TyEffect ("IO") None (TyCon "NativeArmResults")))))))))
(DFunDef false "runMergedNativeArms" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "docArm") (PVar "testArm") (PVar "props")) (EBlock (DoLet false false (PVar "fixed") (EBinOp "++" (EApp (EVar "docArms") (EVar "docArm")) (EApp (EVar "testArms") (EVar "testArm")))) (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "propRows") (EApp (EVar "props") (EApp (EApp (EApp (EApp (EApp (EVar "mergedPropLeaf") (EVar "held")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "fixed")))) (DoLet false false (PVar "outs") (EMatch (EUnOp "!" (EVar "held")) (arm (PCon "Some" (PVar "ran")) () (EVar "ran")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runArms") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "fixed"))))) (DoLet false false (PTuple (PVar "ordinary") (PVar "pinned")) (EMatch (EApp (EVar "testOuts") (EVar "outs")) (arm (PList) () (ETuple (EListLit) (EListLit))) (arm (PCons (PVar "batch") (PVar "each")) () (ETuple (EVar "batch") (EVar "each"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "NativeArmResults") (EApp (EVar "doctestOut") (EVar "outs"))) (EVar "propRows")) (EVar "ordinary")) (EVar "pinned")))))
(DTypeSig false "mergedPropLeaf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ArmOut")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "mergedPropLeaf" ((PVar "held") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "fixed") PWild PWild (PVar "modules") (PVar "requests")) (EMatch (EUnOp "!" (EVar "held")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "requests"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "plan") (EApp (EApp (EApp (EVar "planNativePropRequests") (EVar "tsrc")) (EVar "modules")) (EVar "requests"))) (DoExpr (EMatch (EApp (EVar "nativePropsSettled") (EVar "plan")) (arm (PCon "Some" (PVar "rows")) () (EVar "rows")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EApp (EApp (EVar "runArms") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EBinOp "++" (EVar "fixed") (EListLit (EApp (EApp (EVar "PropArm") (EVar "plan")) (EVar "modules")))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "held")) (EApp (EVar "Some") (EVar "outs")))) (DoExpr (EApp (EVar "propOut") (EVar "outs")))))))))))
(DTypeSig false "docArms" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "docArms" ((PCon "None")) (EListLit))
(DFunDef false "docArms" ((PCon "Some" (PTuple (PVar "examples") (PVar "synthResults")))) (EListLit (EApp (EApp (EVar "DocArm") (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "testArms" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "testArms" ((PCon "None")) (EListLit))
(DFunDef false "testArms" ((PCon "Some" (PTuple (PVar "ordinary") (PVar "pinned")))) (EBinOp "::" (EApp (EApp (EVar "TestArm") (ELit (LInt 0))) (EVar "ordinary")) (EApp (EApp (EVar "pinnedArms") (EApp (EVar "listLen") (EVar "ordinary"))) (EVar "pinned"))))
(DTypeSig false "pinnedArms" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "pinnedArms" (PWild (PList)) (EListLit))
(DFunDef false "pinnedArms" ((PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "TestArm") (EVar "i")) (EListLit (EVar "t"))) (EApp (EApp (EVar "pinnedArms") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "runArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))
(DFunDef false "runArms" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms"))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (EApp (EVar "mintNonce") (ELit LUnit))) (EVar "mergedPrefixes")) (EVar "tsrc"))) (DoLet false false (PVar "outs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMerged") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arms")) (EVar "tmpDir")) (EVar "nonce"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "outs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergedPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mergedPrefixes" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "doctestProbePrefixes") (EVar "testProbePrefixes")) (EVar "propProbePrefixes")) (EListLit (ELit (LString "__nps_")) (ELit (LString "NpIo_")))))
(DTypeSig false "runMerged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))))
(DFunDef false "runMerged" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "arms") (PVar "tmpDir") (PVar "nonce")) (EBlock (DoLet false false (PVar "sections") (EApp (EApp (EVar "map") (EApp (EVar "armSection") (EVar "nonce"))) (EVar "arms"))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "np_probe")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildMerged") (EVar "target")) (EVar "tsrc")) (EVar "nonce")) (EVar "sections")) (EVar "tmpDir")) (EVar "outPath")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSections") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (ELit (LInt 0))) (EVar "arms")) (EVar "sections")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms"))))))
(DTypeSig false "buildMerged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "buildMerged" ((PVar "target") (PVar "tsrc") (PVar "nonce") (PVar "sections") (PVar "tmpDir") (PVar "outPath")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EBinOp "++" (ELit (LString "np_")) (EApp (EVar "baseOf") (EVar "target"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "scratchProbeManifest") (ELit (LString "medaka_native_probe"))) (EVar "target")) (EApp (EVar "runtimeDependencyName") (EVar "nonce"))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "manifest")) () (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "manifest")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EApp (EVar "mergedSource") (EVar "nonce")) (EVar "tsrc")) (EVar "sections"))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "BuildProbe")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EVar "True"))))))))))))))
(DTypeSig false "mergedSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))))
(DFunDef false "mergedSource" ((PVar "nonce") (PVar "tsrc") (PVar "sections")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "distinctLines") (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".runtime as "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".io as "))) (EApp (EVar "display") (EApp (EVar "ioAlias") (EVar "nonce")))) (ELit (LString "")))) (EApp (EApp (EVar "flatMap") (EVar "sectionImports")) (EVar "sections")))) (EVar "omEmpty")) (EListLit (ELit (LString "")) (EApp (EVar "renameUserMain") (EVar "tsrc")) (ELit (LString "")))) (EApp (EApp (EVar "flatMap") (EVar "sectionDecls")) (EVar "sections"))) (EApp (EApp (EApp (EVar "entryLines") (EVar "nonce")) (ELit (LInt 0))) (EVar "sections"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "main = match ")) (EApp (EVar "display") (EApp (EVar "ioAlias") (EVar "nonce")))) (ELit (LString ".getEnvOr \""))) (EApp (EVar "display") (EApp (EVar "selectorVar") (EVar "nonce")))) (ELit (LString "\" \"\""))))) (EApp (EApp (EApp (EVar "dispatchLines") (EVar "nonce")) (ELit (LInt 0))) (EVar "sections"))) (EListLit (ELit (LString "  _ => ()")) (ELit (LString ""))))))
(DTypeSig false "sectionImports" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionImports" ((PTuple PWild (PVar "imports") PWild PWild)) (EVar "imports"))
(DTypeSig false "sectionDecls" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionDecls" ((PTuple PWild PWild (PVar "decls") PWild)) (EBinOp "++" (EVar "decls") (EListLit (ELit (LString "")))))
(DTypeSig false "distinctLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "distinctLines" ((PList) PWild) (EListLit))
(DFunDef false "distinctLines" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EIf (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString ""))) (EApp (EApp (EVar "omHasKey") (EVar "l")) (EVar "seen"))) (EApp (EApp (EVar "distinctLines") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EVar "distinctLines") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "l")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "entryLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "entryLines" ((PVar "nonce") (PVar "k") (PCons (PTuple PWild PWild PWild (PVar "entry")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "entryName") (EVar "nonce")) (EVar "k")))) (ELit (LString " _ =")))) (EVar "entry")) (EListLit (ELit (LString "")))) (EApp (EApp (EApp (EVar "entryLines") (EVar "nonce")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "dispatchLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dispatchLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "dispatchLines" ((PVar "nonce") (PVar "k") (PCons PWild (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  \"")) (EApp (EVar "display") (EApp (EVar "sectionKey") (EVar "k")))) (ELit (LString "\" => "))) (EApp (EVar "display") (EApp (EApp (EVar "entryName") (EVar "nonce")) (EVar "k")))) (ELit (LString " ()"))) (EApp (EApp (EApp (EVar "dispatchLines") (EVar "nonce")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "ioAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ioAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpIo_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "entryName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "entryName" ((PVar "nonce") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "__nps_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "__"))))
(DTypeSig false "sectionKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "sectionKey" ((PVar "k")) (EBinOp "++" (EBinOp "++" (ELit (LString "section_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ""))))
(DTypeSig false "selectorVar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "selectorVar" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_NATIVE_PROBE_SECTION_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "runSections" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))))))
(DFunDef false "runSections" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "nonce") (PVar "outPath") (PVar "k") (PCons (PVar "arm") (PVar "arms")) (PCons (PTuple (PVar "prefix") PWild PWild PWild) (PVar "sections"))) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSection") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (EVar "k")) (EVar "arm")) (EVar "prefix"))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSections") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "arms")) (EVar "sections"))))))
(DFunDef false "runSections" (PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "runSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "ArmOut")))))))))))
(DFunDef false "runSection" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "nonce") (PVar "outPath") (PVar "k") (PVar "arm") (PVar "prefix")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EListLit (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EVar "root")) (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka_emitter"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "selectorVar") (EVar "nonce")))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "sectionKey") (EVar "k")))) (ELit (LString ""))) (EVar "outPath"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EIf (EApp (EApp (EVar "printedSentinel") (EVar "prefix")) (EApp (EVar "splitNl") (EVar "out"))) (EApp (EApp (EApp (EApp (EApp (EVar "armDecode") (EVar "nonce")) (EVar "arm")) (EVar "code")) (EVar "out")) (EVar "errOut")) (EApp (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arm")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arm")))))))
(DTypeSig false "printedSentinel" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "printedSentinel" (PWild (PList)) (EVar "False"))
(DFunDef false "printedSentinel" ((PVar "prefix") (PCons (PVar "l") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "l")) (EApp (EApp (EVar "printedSentinel") (EVar "prefix")) (EVar "rest"))))
(DTypeSig false "armSection" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "armSection" ((PVar "nonce") (PCon "DocArm" (PVar "examples") (PVar "synthResults"))) (EApp (EApp (EApp (EVar "doctestSection") (EVar "nonce")) (EVar "examples")) (EVar "synthResults")))
(DFunDef false "armSection" ((PVar "nonce") (PCon "TestArm" (PVar "first") (PVar "tests"))) (EApp (EApp (EApp (EVar "testSection") (EVar "nonce")) (EVar "first")) (EVar "tests")))
(DFunDef false "armSection" ((PVar "nonce") (PCon "PropArm" (PVar "plan") (PVar "modules"))) (EApp (EApp (EApp (EVar "propSection") (EVar "nonce")) (EVar "modules")) (EVar "plan")))
(DTypeSig false "armDecode" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ArmOut")))))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "DocArm" (PVar "examples") (PVar "synthResults")) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "DocOut") (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestRendered") (EVar "nonce")) (EVar "examples")) (EVar "synthResults")) (EVar "code")) (EVar "out")) (EVar "errOut"))) (EVar "synthResults")) (EVar "examples"))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "TestArm" (PVar "first") (PVar "tests")) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "TestOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testResultsFromRun") (EVar "nonce")) (EVar "first")) (EVar "tests")) (EVar "code")) (EVar "out")) (EVar "errOut"))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "PropArm" (PVar "plan") PWild) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "PropOut") (EApp (EApp (EApp (EApp (EApp (EVar "propResultsFromRun") (EVar "nonce")) (EVar "plan")) (EVar "code")) (EVar "out")) (EVar "errOut"))))
(DTypeSig false "armAlone" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Arm") (TyEffect ("IO") None (TyCon "ArmOut")))))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PCon "DocArm" (PVar "examples") (PVar "synthResults"))) (EApp (EVar "DocOut") (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") PWild (PCon "TestArm" PWild (PVar "tests"))) (EApp (EVar "TestOut") (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "tests"))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") PWild (PCon "PropArm" (PVar "plan") (PVar "modules"))) (EApp (EVar "PropOut") (EApp (EApp (EApp (EApp (EVar "runNativePropPlan") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "plan"))))
(DTypeSig false "doctestOut" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyCon "RunResult")))
(DFunDef false "doctestOut" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "doctestOut" ((PCons (PCon "DocOut" (PVar "result")) PWild)) (EVar "result"))
(DFunDef false "doctestOut" ((PCons PWild (PVar "rest"))) (EApp (EVar "doctestOut") (EVar "rest")))
(DTypeSig false "testOuts" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "ExResult")))))
(DFunDef false "testOuts" ((PList)) (EListLit))
(DFunDef false "testOuts" ((PCons (PCon "TestOut" (PVar "results")) (PVar "rest"))) (EBinOp "::" (EVar "results") (EApp (EVar "testOuts") (EVar "rest"))))
(DFunDef false "testOuts" ((PCons PWild (PVar "rest"))) (EApp (EVar "testOuts") (EVar "rest")))
(DTypeSig false "propOut" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyApp (TyCon "List") (TyCon "PropResult"))))
(DFunDef false "propOut" ((PList)) (EListLit))
(DFunDef false "propOut" ((PCons (PCon "PropOut" (PVar "rows")) PWild)) (EVar "rows"))
(DFunDef false "propOut" ((PCons PWild (PVar "rest"))) (EApp (EVar "propOut") (EVar "rest")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "makeTempDir" false) (mem "scratchProbeManifest" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "BuildProfile" true) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false) (mem "startsWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "freshProbeNonce" false) (mem "mintNonce" false) (mem "probeNameNonce" false) (mem "renameUserMain" false) (mem "runtimeAlias" false) (mem "runtimeDependencyName" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" false) (mem "RunResult" true) (mem "buildDetailsFrom" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "doctestProbePrefixes" false) (mem "doctestRendered" false) (mem "doctestSection" false) (mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false) (mem "testProbePrefixes" false) (mem "testResultsFromRun" false) (mem "testSection" false))))
(DUse false (UseGroup ("tools" "native_props") ((mem "NativePropPlan" false) (mem "nativePropsSettled" false) (mem "planNativePropRequests" false) (mem "propProbePrefixes" false) (mem "propResultsFromRun" false) (mem "propSection" false) (mem "runNativePlannedPropRequests" false) (mem "runNativePropPlan" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "PropRequest" false))))
(DData Public "NativeArmResults" () ((variant "NativeArmResults" (ConPos (TyCon "RunResult") (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "ExResult")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "ExResult")))))) ())
(DData Private "Arm" () ((variant "DocArm" (ConPos (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestArm" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (variant "PropArm" (ConPos (TyCon "NativePropPlan") (TyApp (TyCon "List") (TyCon "PlanModule"))))) ())
(DData Private "ArmOut" () ((variant "DocOut" (ConPos (TyCon "RunResult"))) (variant "TestOut" (ConPos (TyApp (TyCon "List") (TyCon "ExResult")))) (variant "PropOut" (ConPos (TyApp (TyCon "List") (TyCon "PropResult"))))) ())
(DTypeSig true "runMergedNativeArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (TyFun (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))) (TyEffect ("IO") None (TyCon "NativeArmResults")))))))))
(DFunDef false "runMergedNativeArms" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "docArm") (PVar "testArm") (PVar "props")) (EBlock (DoLet false false (PVar "fixed") (EBinOp "++" (EApp (EVar "docArms") (EVar "docArm")) (EApp (EVar "testArms") (EVar "testArm")))) (DoLet false false (PVar "held") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "propRows") (EApp (EVar "props") (EApp (EApp (EApp (EApp (EApp (EVar "mergedPropLeaf") (EVar "held")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "fixed")))) (DoLet false false (PVar "outs") (EMatch (EUnOp "!" (EVar "held")) (arm (PCon "Some" (PVar "ran")) () (EVar "ran")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runArms") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "fixed"))))) (DoLet false false (PTuple (PVar "ordinary") (PVar "pinned")) (EMatch (EApp (EVar "testOuts") (EVar "outs")) (arm (PList) () (ETuple (EListLit) (EListLit))) (arm (PCons (PVar "batch") (PVar "each")) () (ETuple (EVar "batch") (EVar "each"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "NativeArmResults") (EApp (EVar "doctestOut") (EVar "outs"))) (EVar "propRows")) (EVar "ordinary")) (EVar "pinned")))))
(DTypeSig false "mergedPropLeaf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ArmOut")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "mergedPropLeaf" ((PVar "held") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "fixed") PWild PWild (PVar "modules") (PVar "requests")) (EMatch (EUnOp "!" (EVar "held")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "requests"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "plan") (EApp (EApp (EApp (EVar "planNativePropRequests") (EVar "tsrc")) (EVar "modules")) (EVar "requests"))) (DoExpr (EMatch (EApp (EVar "nativePropsSettled") (EVar "plan")) (arm (PCon "Some" (PVar "rows")) () (EVar "rows")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EApp (EApp (EVar "runArms") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EBinOp "++" (EVar "fixed") (EListLit (EApp (EApp (EVar "PropArm") (EVar "plan")) (EVar "modules")))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "held")) (EApp (EVar "Some") (EVar "outs")))) (DoExpr (EApp (EVar "propOut") (EVar "outs")))))))))))
(DTypeSig false "docArms" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))))) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "docArms" ((PCon "None")) (EListLit))
(DFunDef false "docArms" ((PCon "Some" (PTuple (PVar "examples") (PVar "synthResults")))) (EListLit (EApp (EApp (EVar "DocArm") (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "testArms" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "testArms" ((PCon "None")) (EListLit))
(DFunDef false "testArms" ((PCon "Some" (PTuple (PVar "ordinary") (PVar "pinned")))) (EBinOp "::" (EApp (EApp (EVar "TestArm") (ELit (LInt 0))) (EVar "ordinary")) (EApp (EApp (EVar "pinnedArms") (EApp (EVar "listLen") (EVar "ordinary"))) (EVar "pinned"))))
(DTypeSig false "pinnedArms" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "pinnedArms" (PWild (PList)) (EListLit))
(DFunDef false "pinnedArms" ((PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "TestArm") (EVar "i")) (EListLit (EVar "t"))) (EApp (EApp (EVar "pinnedArms") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "runArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))
(DFunDef false "runArms" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" PWild) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms"))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (EApp (EVar "mintNonce") (ELit LUnit))) (EVar "mergedPrefixes")) (EVar "tsrc"))) (DoLet false false (PVar "outs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMerged") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arms")) (EVar "tmpDir")) (EVar "nonce"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "outs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergedPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mergedPrefixes" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "doctestProbePrefixes") (EVar "testProbePrefixes")) (EVar "propProbePrefixes")) (EListLit (ELit (LString "__nps_")) (ELit (LString "NpIo_")))))
(DTypeSig false "runMerged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))))
(DFunDef false "runMerged" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "arms") (PVar "tmpDir") (PVar "nonce")) (EBlock (DoLet false false (PVar "sections") (EApp (EApp (EMethodRef "map") (EApp (EVar "armSection") (EVar "nonce"))) (EVar "arms"))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "np_probe")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildMerged") (EVar "target")) (EVar "tsrc")) (EVar "nonce")) (EVar "sections")) (EVar "tmpDir")) (EVar "outPath")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSections") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (ELit (LInt 0))) (EVar "arms")) (EVar "sections")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls"))) (EVar "arms"))))))
(DTypeSig false "buildMerged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "buildMerged" ((PVar "target") (PVar "tsrc") (PVar "nonce") (PVar "sections") (PVar "tmpDir") (PVar "outPath")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EBinOp "++" (ELit (LString "np_")) (EApp (EVar "baseOf") (EVar "target"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "scratchProbeManifest") (ELit (LString "medaka_native_probe"))) (EVar "target")) (EApp (EVar "runtimeDependencyName") (EVar "nonce"))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "manifest")) () (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "manifest")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EApp (EVar "mergedSource") (EVar "nonce")) (EVar "tsrc")) (EVar "sections"))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "BuildProbe")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" PWild) () (EVar "True"))))))))))))))
(DTypeSig false "mergedSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))))
(DFunDef false "mergedSource" ((PVar "nonce") (PVar "tsrc") (PVar "sections")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "distinctLines") (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".runtime as "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".io as "))) (EApp (EMethodRef "display") (EApp (EVar "ioAlias") (EVar "nonce")))) (ELit (LString "")))) (EApp (EApp (EDictApp "flatMap") (EVar "sectionImports")) (EVar "sections")))) (EVar "omEmpty")) (EListLit (ELit (LString "")) (EApp (EVar "renameUserMain") (EVar "tsrc")) (ELit (LString "")))) (EApp (EApp (EDictApp "flatMap") (EVar "sectionDecls")) (EVar "sections"))) (EApp (EApp (EApp (EVar "entryLines") (EVar "nonce")) (ELit (LInt 0))) (EVar "sections"))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "main = match ")) (EApp (EMethodRef "display") (EApp (EVar "ioAlias") (EVar "nonce")))) (ELit (LString ".getEnvOr \""))) (EApp (EMethodRef "display") (EApp (EVar "selectorVar") (EVar "nonce")))) (ELit (LString "\" \"\""))))) (EApp (EApp (EApp (EVar "dispatchLines") (EVar "nonce")) (ELit (LInt 0))) (EVar "sections"))) (EListLit (ELit (LString "  _ => ()")) (ELit (LString ""))))))
(DTypeSig false "sectionImports" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionImports" ((PTuple PWild (PVar "imports") PWild PWild)) (EVar "imports"))
(DTypeSig false "sectionDecls" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionDecls" ((PTuple PWild PWild (PVar "decls") PWild)) (EBinOp "++" (EVar "decls") (EListLit (ELit (LString "")))))
(DTypeSig false "distinctLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "distinctLines" ((PList) PWild) (EListLit))
(DFunDef false "distinctLines" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EIf (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString ""))) (EApp (EApp (EVar "omHasKey") (EVar "l")) (EVar "seen"))) (EApp (EApp (EVar "distinctLines") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EVar "distinctLines") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "l")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "entryLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "entryLines" ((PVar "nonce") (PVar "k") (PCons (PTuple PWild PWild PWild (PVar "entry")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "entryName") (EVar "nonce")) (EVar "k")))) (ELit (LString " _ =")))) (EVar "entry")) (EListLit (ELit (LString "")))) (EApp (EApp (EApp (EVar "entryLines") (EVar "nonce")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "dispatchLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dispatchLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "dispatchLines" ((PVar "nonce") (PVar "k") (PCons PWild (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  \"")) (EApp (EMethodRef "display") (EApp (EVar "sectionKey") (EVar "k")))) (ELit (LString "\" => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "entryName") (EVar "nonce")) (EVar "k")))) (ELit (LString " ()"))) (EApp (EApp (EApp (EVar "dispatchLines") (EVar "nonce")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "ioAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ioAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpIo_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "entryName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "entryName" ((PVar "nonce") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "__nps_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "__"))))
(DTypeSig false "sectionKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "sectionKey" ((PVar "k")) (EBinOp "++" (EBinOp "++" (ELit (LString "section_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ""))))
(DTypeSig false "selectorVar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "selectorVar" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_NATIVE_PROBE_SECTION_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "runSections" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ArmOut"))))))))))))
(DFunDef false "runSections" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "nonce") (PVar "outPath") (PVar "k") (PCons (PVar "arm") (PVar "arms")) (PCons (PTuple (PVar "prefix") PWild PWild PWild) (PVar "sections"))) (EBlock (DoLet false false (PVar "out") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSection") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (EVar "k")) (EVar "arm")) (EVar "prefix"))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSections") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "nonce")) (EVar "outPath")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "arms")) (EVar "sections"))))))
(DFunDef false "runSections" (PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "runSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "ArmOut")))))))))))
(DFunDef false "runSection" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "nonce") (PVar "outPath") (PVar "k") (PVar "arm") (PVar "prefix")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EListLit (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EVar "root")) (EBinOp "++" (ELit (LString "MEDAKA=")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka_emitter"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "selectorVar") (EVar "nonce")))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "sectionKey") (EVar "k")))) (ELit (LString ""))) (EVar "outPath"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EIf (EApp (EApp (EVar "printedSentinel") (EVar "prefix")) (EApp (EVar "splitNl") (EVar "out"))) (EApp (EApp (EApp (EApp (EApp (EVar "armDecode") (EVar "nonce")) (EVar "arm")) (EVar "code")) (EVar "out")) (EVar "errOut")) (EApp (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arm")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "armAlone") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "arm")))))))
(DTypeSig false "printedSentinel" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "printedSentinel" (PWild (PList)) (EVar "False"))
(DFunDef false "printedSentinel" ((PVar "prefix") (PCons (PVar "l") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "l")) (EApp (EApp (EVar "printedSentinel") (EVar "prefix")) (EVar "rest"))))
(DTypeSig false "armSection" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "armSection" ((PVar "nonce") (PCon "DocArm" (PVar "examples") (PVar "synthResults"))) (EApp (EApp (EApp (EVar "doctestSection") (EVar "nonce")) (EVar "examples")) (EVar "synthResults")))
(DFunDef false "armSection" ((PVar "nonce") (PCon "TestArm" (PVar "first") (PVar "tests"))) (EApp (EApp (EApp (EVar "testSection") (EVar "nonce")) (EVar "first")) (EVar "tests")))
(DFunDef false "armSection" ((PVar "nonce") (PCon "PropArm" (PVar "plan") (PVar "modules"))) (EApp (EApp (EApp (EVar "propSection") (EVar "nonce")) (EVar "modules")) (EVar "plan")))
(DTypeSig false "armDecode" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ArmOut")))))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "DocArm" (PVar "examples") (PVar "synthResults")) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "DocOut") (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestRendered") (EVar "nonce")) (EVar "examples")) (EVar "synthResults")) (EVar "code")) (EVar "out")) (EVar "errOut"))) (EVar "synthResults")) (EVar "examples"))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "TestArm" (PVar "first") (PVar "tests")) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "TestOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testResultsFromRun") (EVar "nonce")) (EVar "first")) (EVar "tests")) (EVar "code")) (EVar "out")) (EVar "errOut"))))
(DFunDef false "armDecode" ((PVar "nonce") (PCon "PropArm" (PVar "plan") PWild) (PVar "code") (PVar "out") (PVar "errOut")) (EApp (EVar "PropOut") (EApp (EApp (EApp (EApp (EApp (EVar "propResultsFromRun") (EVar "nonce")) (EVar "plan")) (EVar "code")) (EVar "out")) (EVar "errOut"))))
(DTypeSig false "armAlone" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Arm") (TyEffect ("IO") None (TyCon "ArmOut")))))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PCon "DocArm" (PVar "examples") (PVar "synthResults"))) (EApp (EVar "DocOut") (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") PWild (PCon "TestArm" PWild (PVar "tests"))) (EApp (EVar "TestOut") (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "tests"))))
(DFunDef false "armAlone" ((PVar "target") (PVar "tsrc") PWild (PCon "PropArm" (PVar "plan") (PVar "modules"))) (EApp (EVar "PropOut") (EApp (EApp (EApp (EApp (EVar "runNativePropPlan") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "plan"))))
(DTypeSig false "doctestOut" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyCon "RunResult")))
(DFunDef false "doctestOut" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "doctestOut" ((PCons (PCon "DocOut" (PVar "result")) PWild)) (EVar "result"))
(DFunDef false "doctestOut" ((PCons PWild (PVar "rest"))) (EApp (EVar "doctestOut") (EVar "rest")))
(DTypeSig false "testOuts" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "ExResult")))))
(DFunDef false "testOuts" ((PList)) (EListLit))
(DFunDef false "testOuts" ((PCons (PCon "TestOut" (PVar "results")) (PVar "rest"))) (EBinOp "::" (EVar "results") (EApp (EVar "testOuts") (EVar "rest"))))
(DFunDef false "testOuts" ((PCons PWild (PVar "rest"))) (EApp (EVar "testOuts") (EVar "rest")))
(DTypeSig false "propOut" (TyFun (TyApp (TyCon "List") (TyCon "ArmOut")) (TyApp (TyCon "List") (TyCon "PropResult"))))
(DFunDef false "propOut" ((PList)) (EListLit))
(DFunDef false "propOut" ((PCons (PCon "PropOut" (PVar "rows")) PWild)) (EVar "rows"))
(DFunDef false "propOut" ((PCons PWild (PVar "rest"))) (EApp (EVar "propOut") (EVar "rest")))
