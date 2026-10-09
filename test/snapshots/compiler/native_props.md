# META
source_lines=2137
stages=DESUGAR,MARK
# SOURCE
-- Native property runner.  It deliberately compiles one probe per target, then
-- lets the driver (below) judge the printed Bool transcript.  A probe never
-- prints a pass/fail label of its own.

import frontend.ast.{
  Decl(..), Expr, PropParam(..), Ty(..), TyConOrigin(..), Variant(..),
  Field(..), ConPayload(..), Pat(..), mapTyFull
}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import driver.build_cmd.{
  ppBuildReport, makeTempDir, scratchProbeManifest, cleanupTempDir,
  runBuildNativeRoots, BuildProfile(..), envOr, defaultMedakaRoot
}
import driver.loader.{entrySearchRoots}
import support.path.{joinPath, baseOf, dirOf}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert, omKeys, omLookup}
import support.util.{
  joinNl, joinWith, splitNl, filterList, lookupAssoc, listLen, zipL, reverseL
}
import string.{replaceAll}
import string.{toInt}
import tools.probe_transcript.{
  Chunk(..), chunksOf, decodeValue, endTag, firstNonEmptyLine, mintNonce,
  freshProbeNonce, noncedPrefix, renameUserMain, runtimeDependencyName,
  runtimeDependencyPrefix, sentinelLine, tagsInOrder, valuePrintExprWith
}
import tools.printer.{exprToString, ppTy}
import tools.prop_plan.{
  PlanModule(..), TypeKey(..), CustomPlan(..), PlanEnv(..), GenPlan(..),
  PlanDef(..), PlanCtor(..), PlanField(..), PlanError(..), PlanErrorReason(..),
  PlanVisibility(..), planErrorText, buildPlanEnvModules, planFor, planDef,
  instantiateCtor, planTy, typeKeyWord, ctorWeights, listLengthBound,
  listBoundDecays, listLenMax, optionWeights, resultWeights, maxGenDepth,
  SoftWeight(..), softCtorWeights, intMin, intMax, structuralRngModulus,
  structuralRngMultiplier, structuralRngIncrement, structuralRngMixMultiplier1,
  structuralRngMixMultiplier2, structuralRngWordModulus, structuralRngWordHalf,
  ShrinkAction(..), shrinkActions, IntShrinkStep(..), intShrinkSteps
}
import tools.prop_runner.{
  PropResult(..), PropStatus(..), PropFailureKind(..), filterProps,
  filterPropsByName, propSeedValue, PropRequest(..), propRequestName,
  propRequestSeed, propRequestCases
}

sentinelBase : String
sentinelBase = "@@__mdk_native_prop__@@"

sentinelPrefix : String -> String
sentinelPrefix nonce = noncedPrefix sentinelBase nonce

sentinelFor : String -> String -> String
sentinelFor nonce tag = sentinelLine (sentinelPrefix nonce) tag

startTag : Int -> String
startTag i = "\{intToString i}.start"

boolTag : Int -> String
boolTag i = "\{intToString i}.bool"

detailTag : Int -> String
detailTag i = "\{intToString i}.detail"

seedTag : Int -> String
seedTag i = "\{intToString i}.seed"

expectedTags : Int -> List (Decl, PropRequest) -> List String
expectedTags _ [] = [endTag]
expectedTags i (_ :: rest) =
  [startTag i, seedTag i, boolTag i, detailTag i] ++ expectedTags (i + 1) rest

-- The command path supplies paired raw/runtime declarations so the native
-- renderer can share identity-aware planning with the evaluator.
export
runNativePlannedPropRequests : String ->
  String ->
  List PlanModule ->
  List PropRequest ->
  <IO> List PropResult
runNativePlannedPropRequests target tsrc modules requests =
  let props = filterProps (desugarProps tsrc)
  match requestIndex requests omEmpty
    Err duplicate => nativeProtocolErrors duplicate requests
    Ok index => match duplicateSelectedPropName props index omEmpty
      Some duplicate =>
        nativeProtocolErrors
          "duplicate property declaration name \"{duplicate}\""
          requests
      None => match buildPlanEnvModules (plannedRoot modules) modules
        Err e =>
          plannedResults (planCapabilities props index (planErrorText e)) []
        Ok env =>
          let outcomes = plannedOutcomes env modules props index
          let runnable = plannedRunnable outcomes
          match runnable
            [] => plannedResults outcomes []
            _ => match nativeRenderedPlanned target tsrc modules env runnable
              Err failure =>
                plannedResults
                  outcomes
                  (map (nativePlannedFailure failure) runnable)
              Ok rows => plannedResults outcomes rows

-- Expose the rendered probe without compiling it so the registry shape can be
-- checked directly.  The execution path above and this renderer share the
-- same planning and closed-graph construction.
export
renderNativePlannedProbe : String ->
  String ->
  List PlanModule ->
  List PropRequest ->
  Result String String
renderNativePlannedProbe target tsrc modules requests =
  let props = filterProps (desugarProps tsrc)
  match requestIndex requests omEmpty
    Err e => Err e
    Ok index => match duplicateSelectedPropName props index omEmpty
      Some duplicate =>
        Err "duplicate property declaration name \"\{duplicate}\""
      None => match buildPlanEnvModules (plannedRoot modules) modules
        Err e => Err (planErrorText e)
        Ok env =>
          let jobs = plannedRunnable (plannedOutcomes env modules props index)
          if listLen jobs == 0 then
            Err "native property runner: no selected property could be rendered"
          else
            let nonce =
              freshProbeNonce "source_check" probeNamespacePrefixes tsrc
            Ok (plannedProbeSource nonce target tsrc modules env jobs)

plannedRoot : List PlanModule -> String
plannedRoot [] = ""
plannedRoot [PlanModule name _ _] = name
plannedRoot (_ :: rest) = plannedRoot rest

planCapabilities : List Decl ->
  OrdMap PropRequest ->
  String ->
  List NativePlanOutcome
planCapabilities [] _ _ = []
planCapabilities ((d@(DProp _ _ _ _)) :: rest) requests message =
  match omLookup (propName d) requests
    Some r =>
      NativeCapability d r message :: planCapabilities rest requests message
    None => planCapabilities rest requests message
planCapabilities (_ :: rest) requests message =
  planCapabilities rest requests message

-- Planning is deliberately per declaration, before the one shared native
-- build.  A parameter the engines cannot generate is a capability result for
-- that law only; it must not prevent an unrelated law in the same file from
-- getting its compiled result.
data NativePlanOutcome =
  | NativeRunnable Decl PropRequest (List GenPlan)
  | NativeCapability Decl PropRequest String

plannedOutcomes : PlanEnv ->
  List PlanModule ->
  List Decl ->
  OrdMap PropRequest ->
  List NativePlanOutcome
plannedOutcomes _ _ [] _ = []
plannedOutcomes env modules ((d@(DProp _ _ _ _)) :: rest) requests =
  match omLookup (propName d) requests
    None => plannedOutcomes env modules rest requests
    Some r => match runtimePropParams modules (propName d)
      None =>
        NativeCapability
            d
            r
            "property declaration was absent from the elaborated module"
          :: plannedOutcomes env modules rest requests
      Some ps => match planParameters env (propName d) ps []
        Ok plans =>
          NativeRunnable d r plans :: plannedOutcomes env modules rest requests
        Err e =>
          NativeCapability d r (planErrorText e)
            :: plannedOutcomes env modules rest requests
plannedOutcomes env modules (_ :: rest) requests =
  plannedOutcomes env modules rest requests

runtimePropParams : List PlanModule -> String -> Option (List PropParam)
runtimePropParams [] _ = None
runtimePropParams [PlanModule _ _ runtime] name =
  runtimePropParamsIn runtime name
runtimePropParams (_ :: rest) name = runtimePropParams rest name

runtimePropParamsIn : List Decl -> String -> Option (List PropParam)
runtimePropParamsIn [] _ = None
runtimePropParamsIn ((DProp _ name ps _) :: _) wanted
  | name == wanted = Some ps
runtimePropParamsIn (_ :: rest) wanted = runtimePropParamsIn rest wanted

propName : Decl -> String
propName (DProp _ name _ _) = name
propName _ = "<invalid prop>"

planParameters : PlanEnv ->
  String ->
  List PropParam ->
  List GenPlan ->
  Result PlanError (List GenPlan)
planParameters _ _ [] acc = Ok (reverseL acc)
planParameters env property ((PropParam name _ ty) :: rest) acc =
  match planFor env property name ty
    Ok p => planParameters env property rest (p :: acc)
    Err e => Err e

plannedRunnable : List NativePlanOutcome -> List NativePlanOutcome
plannedRunnable [] = []
plannedRunnable ((x@(NativeRunnable _ _ _)) :: rest) = x :: plannedRunnable rest
plannedRunnable (_ :: rest) = plannedRunnable rest

data NativeFailure =
  | NativeBuildFailure String
  | NativeRuntimeFailure String
  | NativeProtocolFailure String

nativePlannedFailure : NativeFailure -> NativePlanOutcome -> PropResult
nativePlannedFailure failure (NativeRunnable d r _) =
  nativeFailure failure (d, r)
nativePlannedFailure failure _ =
  PropResult
    "native"
    "<invalid prop>"
    PropErroredResult
    (Some (nativeFailureKind failure))
    (nativeFailureText failure)
    0
    0

plannedResults : List NativePlanOutcome -> List PropResult -> List PropResult
plannedResults [] _ = []
plannedResults ((NativeCapability d r message) :: rest) rows =
  PropResult
      "native"
      (propName d)
      PropErroredResult
      (Some PropCapabilityError)
      message
      (propRequestSeed r)
      (propRequestCases r)
    :: plannedResults rest rows
plannedResults ((NativeRunnable d r _) :: rest) rows =
  nativeRowFor (propName d) r rows :: plannedResults rest rows

nativeRowFor : String -> PropRequest -> List PropResult -> PropResult
nativeRowFor _ r [] =
  PropResult
    "native"
    (propRequestName r)
    PropErroredResult
    (Some PropRuntimeError)
    "native property runner: the compiled probe omitted this property result"
    (propRequestSeed r)
    (propRequestCases r)
nativeRowFor name r ((row@(PropResult _ rowName _ _ _ _ _)) :: rest) =
  if name == rowName then row else nativeRowFor name r rest

requestIndex : List PropRequest ->
  OrdMap PropRequest ->
  Result String (OrdMap PropRequest)
requestIndex [] index = Ok index
requestIndex (r :: rest) index =
  let name = propRequestName r
  if propRequestCases r <= 0 then
    Err "property request \"{name}\" has a non-positive case budget"
  else if omHasKey name index then
    Err "duplicate property request name \"{name}\""
  else
    requestIndex rest (omInsert name r index)

duplicateSelectedPropName : List Decl ->
  OrdMap PropRequest ->
  OrdMap Unit ->
  Option String
duplicateSelectedPropName [] _ _ = None
duplicateSelectedPropName ((DProp _ name _ _) :: rest) requests seen =
  if omHasKey name seen then
    if omHasKey name requests then
      Some name
    else
      duplicateSelectedPropName rest requests seen
  else
    duplicateSelectedPropName rest requests (omInsert name () seen)
duplicateSelectedPropName (_ :: rest) requests seen =
  duplicateSelectedPropName rest requests seen

nativeProtocolErrors : String -> List PropRequest -> List PropResult
nativeProtocolErrors duplicate requests =
  map (nativeProtocolError duplicate) requests

nativeProtocolError : String -> PropRequest -> PropResult
nativeProtocolError duplicate r =
  PropResult
    "native"
    (propRequestName r)
    PropErroredResult
    (Some PropProtocolError)
    "native property runner: \{duplicate}"
    (propRequestSeed r)
    (propRequestCases r)

desugarProps : String -> List Decl
desugarProps src = desugar (parse src)

nativeFailureKind : NativeFailure -> PropFailureKind
nativeFailureKind (NativeBuildFailure _) = PropBuildError
nativeFailureKind (NativeRuntimeFailure _) = PropRuntimeError
nativeFailureKind (NativeProtocolFailure _) = PropProtocolError

nativeFailureText : NativeFailure -> String
nativeFailureText (NativeBuildFailure text) = text
nativeFailureText (NativeRuntimeFailure text) = text
nativeFailureText (NativeProtocolFailure text) = text

nativeFailure : NativeFailure -> (Decl, PropRequest) -> PropResult
nativeFailure failure (DProp _ name _ _, r) =
  PropResult
    "native"
    name
    PropErroredResult
    (Some (nativeFailureKind failure))
    (nativeFailureText failure)
    (propRequestSeed r)
    (propRequestCases r)
nativeFailure failure (_, r) =
  PropResult
    "native"
    "<invalid prop>"
    PropErroredResult
    (Some (nativeFailureKind failure))
    (nativeFailureText failure)
    (propRequestSeed r)
    (propRequestCases r)

nativeRenderedPlanned : String ->
  String ->
  List PlanModule ->
  PlanEnv ->
  List NativePlanOutcome ->
  <IO> Result NativeFailure (List PropResult)
nativeRenderedPlanned target tsrc modules env jobs = match makeTempDir ()
  Err e =>
    Err
      (NativeRuntimeFailure
        "native property runner: could not create a scratch directory: \{e}")
  Ok tmp =>
    let nonce = freshProbeNonce (mintNonce ()) probeNamespacePrefixes tsrc
    let rendered = runInTmpPlanned target tsrc modules env jobs tmp nonce
    let _ = cleanupTempDir tmp
    rendered

runInTmpPlanned : String ->
  String ->
  List PlanModule ->
  PlanEnv ->
  List NativePlanOutcome ->
  String ->
  String ->
  <IO> Result NativeFailure (List PropResult)
runInTmpPlanned target tsrc modules env jobs tmp nonce =
  let entry = joinPath tmp (scratchEntryName target)
  let out = joinPath tmp "prop_probe"
  match (scratchProbeManifest
    "medaka_native_props"
    target
    (runtimeDependencyName nonce))
    Err e =>
      Err
        (NativeBuildFailure
          "native property runner: could not create the scratch manifest: \{e}")
    Ok manifest => match writeFile (joinPath tmp "medaka.toml") manifest
      Err e =>
        Err
          (NativeBuildFailure
            "native property runner: could not write the scratch manifest: \{e}")
      Ok _ =>
        match (writeFile
          entry
          (plannedProbeSource nonce target tsrc modules env jobs))
          Err e =>
            Err
              (NativeBuildFailure
                "native property runner: could not write the probe source: \{e}")
          Ok _ => buildAndRunPlanned target entry out tmp jobs nonce

buildAndRunPlanned : String ->
  String ->
  String ->
  String ->
  List NativePlanOutcome ->
  String ->
  <IO> Result NativeFailure (List PropResult)
buildAndRunPlanned target entry out tmp jobs nonce =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let medaka = envOr "MEDAKA" (joinPath root "medaka")
  let emitter = envOr "MEDAKA_EMITTER" (joinPath root "medaka_emitter")
  let cc = envOr "CC" "clang"
  match (runBuildNativeRoots
    root
    medaka
    cc
    entry
    out
    tmp
    False
    (entrySearchRoots (dirOf target))
    True
    False
    False
    BuildProbe)
    Err rep =>
      Err
        (NativeBuildFailure
          "native property runner: could not build \{target} natively\n\{ppBuildReport rep}")
    Ok _ => match runCommand "env" [
      "MEDAKA_ROOT=" ++ root,
      "MEDAKA=" ++ medaka,
      "MEDAKA_EMITTER=" ++ emitter,
      out,
    ]
      Err e =>
        Err
          (NativeRuntimeFailure
            "native property runner: could not run the compiled probe: \{e}")
      Ok (code, stdout, stderr) =>
        let props = plannedDeclRequests jobs
        let chunks = chunksOf (sentinelPrefix nonce) (splitNl stdout)
        if tagsInOrder (expectedTags 0 props) chunks then
          Ok (renderAll chunks (abortNote code stderr) 0 props)
        else
          Err
            (NativeProtocolFailure
              "native property runner: the probe printed a forged or malformed transcript; no property result was trusted")

plannedDeclRequests : List NativePlanOutcome -> List (Decl, PropRequest)
plannedDeclRequests [] = []
plannedDeclRequests ((NativeRunnable d r _) :: rest) =
  (d, r) :: plannedDeclRequests rest
plannedDeclRequests (_ :: rest) = plannedDeclRequests rest

scratchEntryName : String -> String
scratchEntryName target = "prop_" ++ baseOf target

abortNote : Int -> String -> String
abortNote code stderr =
  let first = firstNonEmptyLine (splitNl stderr)
  "native property run ended (probe exit \{intToString code})\{if first == "" then "" else " — " ++ first}"

data TranscriptField =
  | FieldMissing
  | FieldIncomplete
  | FieldMalformed
  | FieldDecoded String

transcriptField : String -> OrdMap Chunk -> TranscriptField
transcriptField tag chunks = match omLookup tag chunks
  None => FieldMissing
  Some (Chunk _ _ False) => FieldIncomplete
  Some (Chunk _ lines True) => match decodeValue lines
    Some text => FieldDecoded text
    None => FieldMalformed

renderAll : List Chunk ->
  String ->
  Int ->
  List (Decl, PropRequest) ->
  List PropResult
renderAll chunks note i requests =
  renderIndexed (indexNativeChunks chunks omEmpty) note i requests

indexNativeChunks : List Chunk -> OrdMap Chunk -> OrdMap Chunk
indexNativeChunks [] index = index
indexNativeChunks ((chunk@(Chunk tag _ _)) :: rest) index =
  let next = if omHasKey tag index then index else omInsert tag chunk index
  indexNativeChunks rest next

renderIndexed : OrdMap Chunk ->
  String ->
  Int ->
  List (Decl, PropRequest) ->
  List PropResult
renderIndexed _ _ _ [] = []
renderIndexed chunks note i ((_, request) :: rest) =
  classifyNativeFields chunks note request i
    :: renderIndexed chunks note (i + 1) rest

export
classifyNativeTranscript : List Chunk ->
  String ->
  PropRequest ->
  Int ->
  PropResult
classifyNativeTranscript chunks note request i =
  classifyNativeFields (indexNativeChunks chunks omEmpty) note request i

classifyNativeFields : OrdMap Chunk ->
  String ->
  PropRequest ->
  Int ->
  PropResult
classifyNativeFields chunks note request i =
  let name = propRequestName request
  let seed = propRequestSeed request
  let cases = propRequestCases request
  match (
    transcriptField (seedTag i) chunks,
    transcriptField (boolTag i) chunks,
    transcriptField (detailTag i) chunks,
  )
    (FieldMalformed, _, _) =>
      nativeProtocolError "malformed replay seed in native transcript" request
    (_, FieldMalformed, _) =>
      nativeProtocolError "malformed result value in native transcript" request
    (_, _, FieldMalformed) =>
      nativeProtocolError "malformed detail in native transcript" request
    (FieldDecoded seedText, _, _) if toInt seedText /= Some seed =>
      nativeProtocolError "invalid replay seed in native transcript" request
    (_, FieldDecoded boolText, _) if boolText /= "True"
      && boolText /= "False" =>
      nativeProtocolError "invalid result value in native transcript" request
    (FieldDecoded _, FieldDecoded "True", FieldDecoded detail) =>
      PropResult "native" name PropPassedResult None detail seed cases
    (FieldDecoded _, FieldDecoded "False", FieldDecoded detail) =>
      PropResult
        "native"
        name
        PropFailedResult
        (Some PropLawFalse)
        detail
        seed
        cases
    _ =>
      PropResult
        "native"
        name
        PropErroredResult
        (Some PropRuntimeError)
        "\{note}; this property was not fully reported"
        seed
        cases

-- Probe source ---------------------------------------------------------------

probeNamespacePrefixes : List String
probeNamespacePrefixes = [
  "__np_",
  "NpCore_",
  "NpRuntime_",
  "NpModule_",
  runtimeDependencyPrefix,
]

plannedProbeSource : String ->
  String ->
  String ->
  List PlanModule ->
  PlanEnv ->
  List NativePlanOutcome ->
  String
plannedProbeSource nonce target tsrc modules env jobs =
  let graph = sharedGraph env jobs
  let prefix = genNodePrefix nonce
  joinNl
    (plannedImports nonce modules graph
      ++ [probeTargetSource target tsrc, ""]
      ++ [
        "\{generatedPrefix nonce}state : Ref Int",
        "\{generatedPrefix nonce}state = \{runtimeAlias nonce}.Ref 0",
        "",
        "\{generatedPrefix nonce}custom_state : Ref U64",
        "\{generatedPrefix nonce}custom_state = \{runtimeAlias nonce}.Ref 0",
        "",
        "\{generatedPrefix nonce}word n = ((n % \{intToString structuralRngWordModulus}) + \{intToString structuralRngWordModulus}) % \{intToString structuralRngWordModulus}",
        "",
        "\{generatedPrefix nonce}mul_word left right =",
        "  let x = \{generatedPrefix nonce}word left",
        "  let y = \{generatedPrefix nonce}word right",
        "  let x_low = x % \{intToString structuralRngWordHalf}",
        "  let x_high = x / \{intToString structuralRngWordHalf}",
        "  let y_low = y % \{intToString structuralRngWordHalf}",
        "  let y_high = y / \{intToString structuralRngWordHalf}",
        "  let low = x_low * y_low",
        "  let cross = x_low * y_high + x_high * y_low",
        "  \{generatedPrefix nonce}word (low + (cross % \{intToString structuralRngWordHalf}) * \{intToString structuralRngWordHalf})",
        "",
        "\{generatedPrefix nonce}next _ =",
        "  let s = (!\{generatedPrefix nonce}state * \{intToString structuralRngMultiplier} + \{intToString structuralRngIncrement}) % \{intToString structuralRngModulus}",
        "  \{generatedPrefix nonce}state := s",
        "  let word = \{generatedPrefix nonce}word s",
        "  let h1 = \{generatedPrefix nonce}word (\{runtimeAlias nonce}.bitXor word (\{runtimeAlias nonce}.shiftRight word 16))",
        "  let h2 = \{generatedPrefix nonce}mul_word h1 \{intToString structuralRngMixMultiplier1}",
        "  let h3 = \{generatedPrefix nonce}word (\{runtimeAlias nonce}.bitXor h2 (\{runtimeAlias nonce}.shiftRight h2 13))",
        "  let h4 = \{generatedPrefix nonce}mul_word h3 \{intToString structuralRngMixMultiplier2}",
        "  \{generatedPrefix nonce}word (\{runtimeAlias nonce}.bitXor h4 (\{runtimeAlias nonce}.shiftRight h4 16))",
        "",
        "\{generatedPrefix nonce}int _ = \{generatedPrefix nonce}choose \{intToString (intMax - intMin + 1)} + \{intToString intMin}",
        "\{generatedPrefix nonce}bool _ = \{generatedPrefix nonce}choose 2 == 1",
        "\{generatedPrefix nonce}choose n =",
        "  let word = \{generatedPrefix nonce}next ()",
        "  if n <= 0 then 0 else word % n",
        "\{generatedPrefix nonce}char _ = \{coreAlias nonce}.optionOr ' ' (\{runtimeAlias nonce}.charFromCode (32 + \{generatedPrefix nonce}choose 95))",
        "\{generatedPrefix nonce}string n = if n <= 0 then \"\" else \{runtimeAlias nonce}.charToStr (\{generatedPrefix nonce}char ()) ++ \{generatedPrefix nonce}string (n - 1)",
        "",
        "\{generatedPrefix nonce}join_strings _ [] = \"\"",
        "\{generatedPrefix nonce}join_strings _ (x :: []) = x",
        "\{generatedPrefix nonce}join_strings sep (x :: xs) = x ++ sep ++ \{generatedPrefix nonce}join_strings sep xs",
        "",
        "\{generatedPrefix nonce}array_to_list arr = \{generatedPrefix nonce}array_to_list_go arr 0",
        "\{generatedPrefix nonce}array_to_list_go arr i = if i >= \{runtimeAlias nonce}.arrayLength arr then [] else arr[i] :: \{generatedPrefix nonce}array_to_list_go arr (i + 1)",
        "",
        "\{generatedPrefix nonce}delete_each [] = []",
        "\{generatedPrefix nonce}delete_each (x :: xs) = xs :: \{coreAlias nonce}.map (ys => x :: ys) (\{generatedPrefix nonce}delete_each xs)",
        "\{generatedPrefix nonce}replace_each f [] = []",
        "\{generatedPrefix nonce}replace_each f (x :: xs) = \{coreAlias nonce}.map (ys => ys :: xs) (f x) ++ \{coreAlias nonce}.map (ys => x :: ys) (\{generatedPrefix nonce}replace_each f xs)",
        "",
      ]
      ++ plannedPropLines nonce modules env graph jobs 0
      ++ graphLines nonce modules env (coreAlias nonce) prefix graph
      ++ graphAuxLines nonce modules env (coreAlias nonce) prefix graph
      ++ ["main ="]
      ++ plannedMainLines nonce jobs 0
      ++ [
        "  \{runtimeAlias nonce}.putStrLn \"\{sentinelFor nonce endTag}\"",
        "",
      ])

-- Each imported module gets a probe-local alias. Constructor selection is by
-- the TypeKey owner, never by a bare source spelling.
coreAlias : String -> String
coreAlias nonce = "NpCore_\{probeNameNonce nonce}"

runtimeAlias : String -> String
runtimeAlias nonce = "NpRuntime_\{probeNameNonce nonce}"

probeNameNonce : String -> String
probeNameNonce nonce = replaceAll "-" "_" nonce

generatedPrefix : String -> String
generatedPrefix nonce = "__np_\{probeNameNonce nonce}_"

generatedName : String -> String -> String
generatedName nonce stem = generatedPrefix nonce ++ stem

plannedImports : String -> List PlanModule -> NativeGraph -> List String
plannedImports nonce modules graph =
  "import core as \{coreAlias nonce}"
    :: "import \{runtimeDependencyName nonce}.runtime as \{runtimeAlias nonce}"
    :: map (importLine nonce modules) (omKeys (graphImportOwners graph omEmpty))

graphImportOwners : NativeGraph -> OrdMap Unit -> OrdMap Unit
graphImportOwners (NativeGraph nodes order _) owners =
  graphImportOwnersGo nodes (reverseL order) owners

graphImportOwnersGo : OrdMap GraphNode ->
  List String ->
  OrdMap Unit ->
  OrdMap Unit
graphImportOwnersGo _ [] owners = owners
graphImportOwnersGo nodes (word :: rest) owners = match omLookup word nodes
  Some (GraphNode _ plan _) =>
    graphImportOwnersGo nodes rest (planImportOwner plan owners)
  None => graphImportOwnersGo nodes rest owners

planImportOwner : GenPlan -> OrdMap Unit -> OrdMap Unit
planImportOwner (GNominal (TypeKey _ (OriginModule owner)) _) owners =
  omInsert owner () owners
planImportOwner (GCustom (CustomPlan _ carrier _)) owners =
  carrierImportOwners carrier owners
planImportOwner _ owners = owners

carrierImportOwners : Ty -> OrdMap Unit -> OrdMap Unit
carrierImportOwners (TyCon { tyConOrigin = (OriginModule owner) }) owners =
  omInsert owner () owners
carrierImportOwners (TyCon {  }) owners = owners
carrierImportOwners (TyVar _) owners = owners
carrierImportOwners (TyApp left right) owners =
  carrierImportOwners right (carrierImportOwners left owners)
carrierImportOwners (TyFun left right) owners =
  carrierImportOwners right (carrierImportOwners left owners)
carrierImportOwners (TyTuple tys) owners = carrierImportOwnersMany tys owners
carrierImportOwners (TyEffect _ _ ty) owners = carrierImportOwners ty owners
carrierImportOwners (TyConstrained _ ty) owners = carrierImportOwners ty owners
carrierImportOwners (TyNamed _ ty _) owners = carrierImportOwners ty owners
carrierImportOwners (TyQual ty _ _) owners = carrierImportOwners ty owners
carrierImportOwners (TyRow _ _ _) owners = owners
carrierImportOwners (TyAuth _ _) owners = owners

carrierImportOwnersMany : List Ty -> OrdMap Unit -> OrdMap Unit
carrierImportOwnersMany [] owners = owners
carrierImportOwnersMany (ty :: rest) owners =
  carrierImportOwnersMany rest (carrierImportOwners ty owners)

importLine : String -> List PlanModule -> String -> String
importLine nonce modules owner = match moduleAlias nonce modules owner
  Some alias => "import \{owner} as \{alias}"
  None => ""

moduleAlias : String -> List PlanModule -> String -> Option String
moduleAlias nonce modules owner =
  moduleAliasGo nonce (dropLastPlanModule modules) owner 0

moduleAliasGo : String -> List PlanModule -> String -> Int -> Option String
moduleAliasGo _ [] _ _ = None
moduleAliasGo nonce ((PlanModule name _ _) :: rest) owner i =
  if name == owner then
    Some "NpModule_\{probeNameNonce nonce}_\{intToString i}"
  else
    moduleAliasGo nonce rest owner (i + 1)

dropLastPlanModule : List PlanModule -> List PlanModule
dropLastPlanModule [] = []
dropLastPlanModule [_] = []
dropLastPlanModule (x :: xs) = x :: dropLastPlanModule xs

planSourceTy : String -> List PlanModule -> GenPlan -> String
planSourceTy _ _ GInt = "Int"
planSourceTy _ _ GBool = "Bool"
planSourceTy _ _ GFloat = "Float"
planSourceTy _ _ GChar = "Char"
planSourceTy _ _ GString = "String"
planSourceTy _ _ GUnit = "Unit"
planSourceTy nonce modules (GList plan) =
  "List (\{planSourceTy nonce modules plan})"
planSourceTy nonce modules (GArray plan) =
  "Array (\{planSourceTy nonce modules plan})"
planSourceTy nonce modules (GOption plan) =
  "Option (\{planSourceTy nonce modules plan})"
planSourceTy nonce modules (GResult err ok) =
  "Result (\{planSourceTy nonce modules err}) (\{planSourceTy nonce modules ok})"
planSourceTy nonce modules (GTuple plans) =
  "(\{joinWith ", " (map (planSourceTy nonce modules) plans)})"
planSourceTy nonce modules (GNominal key plans) =
  nominalSourceTy nonce modules key plans
planSourceTy nonce modules (GCustom (CustomPlan _ carrier _)) =
  carrierSourceTy nonce modules carrier

effectfulPlanSourceTy : String -> List PlanModule -> GenPlan -> String
effectfulPlanSourceTy nonce modules plan =
  "<Rand> \{planSourceTy nonce modules plan}"

carrierSourceTy : String -> List PlanModule -> Ty -> String
carrierSourceTy nonce modules carrier =
  ppTy (fst (mapTyFull (qualifyCarrierTy nonce modules) carrier))

qualifyCarrierTy : String -> List PlanModule -> Ty -> (Ty, Bool)
qualifyCarrierTy nonce modules (ty@(TyCon { tyConName, tyConOrigin = (OriginModule owner) })) =
  match moduleAlias nonce modules owner
    Some alias => (TyCon { ty | tyConName = "\{alias}.\{tyConName}" }, True)
    None => (ty, False)
qualifyCarrierTy _ _ ty = (ty, False)

nominalSourceTy : String -> List PlanModule -> TypeKey -> List GenPlan -> String
nominalSourceTy nonce modules (TypeKey name (OriginModule owner)) plans =
  let head = match moduleAlias nonce modules owner
    Some alias => "\{alias}.\{name}"
    None => name
  if listLen plans == 0 then
    head
  else
    "\{head} \{joinWith " " (map (plan => paren (planSourceTy nonce modules plan)) plans)}"
nominalSourceTy _ _ (TypeKey name _) [] = name
nominalSourceTy nonce modules (TypeKey name _) plans =
  "\{name} \{joinWith " " (map (plan => paren (planSourceTy nonce modules plan)) plans)}"

typeKeyName : TypeKey -> String
typeKeyName (TypeKey name _) = name

plannedPropLines : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  List NativePlanOutcome ->
  Int ->
  List String
plannedPropLines _ _ _ _ [] _ = []
plannedPropLines nonce modules env graph ((NativeRunnable (DProp _ _ params body) r plans) :: rest) i =
  fnLines nonce i params body
    ++ plannedRunLines nonce modules graph i params plans (propRequestCases r)
    ++ plannedShrinkLines nonce modules graph i params plans
    ++ plannedPropLines nonce modules env graph rest (i + 1)
plannedPropLines nonce modules env graph (_ :: rest) i =
  plannedPropLines nonce modules env graph rest i

-- Every closed plan, including containers and primitives, gets one helper.
-- The map is the registry; the reverse discovery list only preserves stable
-- source order.  The recorded depth is the shallowest path discovered, which
-- makes applied recursive families finite even when each recursive occurrence
-- changes its type arguments.
data NativeGraph = NativeGraph (OrdMap GraphNode) (List String) Int

data GraphNode = GraphNode Int GenPlan Int

buildGraph : PlanEnv -> GenPlan -> NativeGraph
buildGraph env root = graphExplore env root 0 (NativeGraph omEmpty [] 0)

-- One probe renders one helper per distinct plan, whichever properties and
-- parameters draw it.  Each root keeps its own closed exploration; the file
-- registry is the union of those node sets, so a root never loses a node to
-- another root's traversal order.
sharedGraph : PlanEnv -> List NativePlanOutcome -> NativeGraph
sharedGraph env jobs = sharedGraphGo env jobs (NativeGraph omEmpty [] 0)

sharedGraphGo : PlanEnv -> List NativePlanOutcome -> NativeGraph -> NativeGraph
sharedGraphGo _ [] graph = graph
sharedGraphGo env ((NativeRunnable _ _ plans) :: rest) graph =
  sharedGraphGo env rest (sharedGraphPlans env plans graph)
sharedGraphGo env (_ :: rest) graph = sharedGraphGo env rest graph

sharedGraphPlans : PlanEnv -> List GenPlan -> NativeGraph -> NativeGraph
sharedGraphPlans _ [] graph = graph
sharedGraphPlans env (plan :: rest) graph = match buildGraph env plan
  NativeGraph nodes order _ =>
    sharedGraphPlans env rest (mergeGraphNodes nodes (reverseL order) graph)

mergeGraphNodes : OrdMap GraphNode -> List String -> NativeGraph -> NativeGraph
mergeGraphNodes _ [] graph = graph
mergeGraphNodes fresh (word :: rest) (graph@(NativeGraph nodes order next)) =
  match omLookup word fresh
    Some (GraphNode _ plan depth) if not (omHasKey word nodes) =>
      mergeGraphNodes
        fresh
        rest
        (NativeGraph
          (omInsert word (GraphNode next plan depth) nodes)
          (word :: order)
          (next + 1))
    _ => mergeGraphNodes fresh rest graph

graphExplore : PlanEnv -> GenPlan -> Int -> NativeGraph -> NativeGraph
graphExplore env plan depth (graph@(NativeGraph nodes order next)) =
  let word = genPlanWord plan
  match omLookup word nodes
    Some (GraphNode ident _ oldDepth) =>
      if depth < oldDepth then
        graphChildren
          env
          plan
          depth
          (NativeGraph
            (omInsert word (GraphNode ident plan depth) nodes)
            order
            next)
      else
        graph
    None =>
      graphChildren
        env
        plan
        depth
        (NativeGraph
          (omInsert word (GraphNode next plan depth) nodes)
          (word :: order)
          (next + 1))

graphChildren : PlanEnv -> GenPlan -> Int -> NativeGraph -> NativeGraph
graphChildren _ GInt _ graph = graph
graphChildren _ GBool _ graph = graph
graphChildren _ GFloat _ graph = graph
graphChildren _ GChar _ graph = graph
graphChildren _ GString _ graph = graph
graphChildren _ GUnit _ graph = graph
graphChildren env (GCustom custom) depth graph =
  if depth >= maxGenDepth then
    graph
  else match customStructuralPlan env custom
    None => graph
    Some (plan@(GNominal key _)) => match planDef env key
      Ok (PlanDef _ owner _ visibility ctors) =>
        if nominalCtorsVisible env owner visibility then
          graphDisplayCtorChildren env plan ctors depth graph
        else
          graph
      Err _ => graph
    Some _ => graph
graphChildren env (GList p) depth graph =
  if listLengthBound env depth p <= 0 then
    graph
  else
    graphExplore env p depth graph
graphChildren env (GArray p) depth graph =
  if listLengthBound env depth p <= 0 then
    graph
  else
    graphExplore env p depth graph
graphChildren env (GOption p) depth graph = match optionWeights env depth p
  [_, someWeight] =>
    if someWeight <= 0 then graph else graphExplore env p depth graph
  _ => graph
graphChildren env (GResult err ok) depth graph =
  match resultWeights env depth err ok
    [errWeight, okWeight] =>
      let withErr =
        if errWeight <= 0 then graph else graphExplore env err depth graph
      if okWeight <= 0 then withErr else graphExplore env ok depth withErr
    _ => graph
graphChildren env (GTuple ps) depth graph = graphExploreMany env ps depth graph
graphChildren env (plan@(GNominal key _)) depth graph = match planDef env key
  Err _ => graph
  Ok (PlanDef _ owner _ visibility ctors) =>
    if nominalCtorsVisible env owner visibility then
      graphCtorChildren env plan ctors (ctorWeights env plan depth) depth graph
    else
      graph

nominalCtorsVisible : PlanEnv -> String -> PlanVisibility -> Bool
nominalCtorsVisible (PlanEnv root _ _ _ _) owner PlanAbstract = owner == root
nominalCtorsVisible _ _ PlanPublicCtors = True
nominalCtorsVisible (PlanEnv root _ _ _ _) owner PlanLocal = owner == root

customStructuralPlan : PlanEnv -> CustomPlan -> Option GenPlan
customStructuralPlan env (CustomPlan key carrier _) =
  map (GNominal key) (customPlanArgs env (carrierArgs carrier))

carrierArgs : Ty -> List Ty
carrierArgs (TyApp head arg) = carrierArgs head ++ [arg]
carrierArgs _ = []

customPlanArgs : PlanEnv -> List Ty -> Option (List GenPlan)
customPlanArgs _ [] = Some []
customPlanArgs env (ty :: rest) = match (
  planFor env "custom display" "value" ty,
  customPlanArgs env rest,
)
  (Ok plan, Some plans) => Some (plan :: plans)
  _ => None

graphExploreMany : PlanEnv -> List GenPlan -> Int -> NativeGraph -> NativeGraph
graphExploreMany _ [] _ graph = graph
graphExploreMany env (plan :: rest) depth graph =
  graphExploreMany env rest depth (graphExplore env plan depth graph)

graphCtorChildren : PlanEnv ->
  GenPlan ->
  List PlanCtor ->
  List Int ->
  Int ->
  NativeGraph ->
  NativeGraph
graphCtorChildren _ _ [] _ _ graph = graph
graphCtorChildren env plan (ctor :: rest) (weight :: weights) depth graph =
  let next =
    if weight <= 0 then
      graph
    else match instantiateCtor env plan ctor
      Err _ => graph
      Ok fields => graphExploreMany env (map snd fields) (depth + 1) graph
  graphCtorChildren env plan rest weights depth next
graphCtorChildren _ _ _ _ _ graph = graph

graphDisplayCtorChildren : PlanEnv ->
  GenPlan ->
  List PlanCtor ->
  Int ->
  NativeGraph ->
  NativeGraph
graphDisplayCtorChildren _ _ [] _ graph = graph
graphDisplayCtorChildren env plan (ctor :: rest) depth graph =
  let next = match instantiateCtor env plan ctor
    Err _ => graph
    Ok fields => graphExploreMany env (map snd fields) (depth + 1) graph
  graphDisplayCtorChildren env plan rest depth next

genPlanWord : GenPlan -> String
genPlanWord GInt = "int"
genPlanWord GBool = "bool"
genPlanWord GFloat = "float"
genPlanWord GChar = "char"
genPlanWord GString = "string"
genPlanWord GUnit = "unit"
genPlanWord (GList p) = "list(" ++ genPlanWord p ++ ")"
genPlanWord (GArray p) = "array(" ++ genPlanWord p ++ ")"
genPlanWord (GOption p) = "option(" ++ genPlanWord p ++ ")"
genPlanWord (GResult err ok) = "result(\{genPlanWord err},\{genPlanWord ok})"
genPlanWord (GTuple ps) = "tuple(" ++ joinWith "," (map genPlanWord ps) ++ ")"
genPlanWord (GNominal key ps) =
  "nominal(\{typeKeyWord key};\{joinWith "," (map genPlanWord ps)})"
genPlanWord (GCustom (CustomPlan _ _ route)) = "custom(" ++ route ++ ")"

genNodePrefix : String -> String
genNodePrefix nonce = "\{generatedPrefix nonce}gen"

graphNodeName : String -> Int -> String
graphNodeName prefix ident = "\{prefix}_node_\{intToString ident}"

graphRef : NativeGraph -> String -> GenPlan -> String -> String
graphRef (NativeGraph nodes _ _) prefix plan depth =
  match omLookup (genPlanWord plan) nodes
    Some (GraphNode ident _ _) => "\{graphNodeName prefix ident} \{depth}"
    None => "panic \"native property runner: missing closed generator plan\""

graphLines : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  String ->
  NativeGraph ->
  List String
graphLines nonce modules env core prefix (NativeGraph nodes order _) =
  graphLinesGo nonce modules env core prefix nodes (reverseL order)

graphLinesGo : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  String ->
  OrdMap GraphNode ->
  List String ->
  List String
graphLinesGo _ _ _ _ _ _ [] = []
graphLinesGo nonce modules env core prefix nodes (word :: rest) =
  match omLookup word nodes
    None => graphLinesGo nonce modules env core prefix nodes rest
    Some (GraphNode ident plan _) =>
      [
          "\{graphNodeName prefix ident} : Int -> \{effectfulPlanSourceTy nonce modules plan}",
          "\{graphNodeName prefix ident} depth = \{graphNodeBody nonce modules env core (NativeGraph nodes [] 0) prefix plan}",
          "",
        ]
        ++ graphLinesGo nonce modules env core prefix nodes rest

graphDraw : List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String
graphDraw _ _ graph prefix plan = graphRef graph prefix plan "depth"

graphCtorDraw : List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String
graphCtorDraw _ _ graph prefix plan = graphRef graph prefix plan "(depth + 1)"

graphNodeBody : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String
graphNodeBody nonce _ _ _ _ _ GInt = "\{generatedPrefix nonce}int ()"
graphNodeBody nonce _ _ _ _ _ GBool = "\{generatedPrefix nonce}bool ()"
graphNodeBody nonce _ _ _ _ _ GFloat =
  "\{runtimeAlias nonce}.intToFloat (\{generatedPrefix nonce}choose 2000001) * (1.0 / 1000000.0) - 1.0"
graphNodeBody nonce _ _ _ _ _ GChar = "\{generatedPrefix nonce}char ()"
graphNodeBody nonce _ _ _ _ _ GString = stringExpr nonce 0
graphNodeBody _ _ _ _ _ _ GUnit = "()"
graphNodeBody nonce _ _ core _ _ (GCustom _) = customDrawExpr nonce core
graphNodeBody nonce modules env core graph prefix (GList p) =
  renderListByDepth nonce "[" "]" env p (graphDraw modules env graph prefix p)
graphNodeBody nonce modules env core graph prefix (GArray p) =
  renderListByDepth nonce "[|" "|]" env p (graphDraw modules env graph prefix p)
graphNodeBody nonce modules env core graph prefix (GOption p) =
  renderOptionByDepth nonce env p (graphDraw modules env graph prefix p)
graphNodeBody nonce modules env core graph prefix (GResult err ok) =
  renderResultByDepth
    nonce
    env
    err
    ok
    (graphDraw modules env graph prefix err)
    (graphDraw modules env graph prefix ok)
graphNodeBody _ modules env core graph prefix (GTuple ps) =
  "(\{joinWith ", " (map (graphDraw modules env graph prefix) ps)})"
graphNodeBody nonce modules env core graph prefix (plan@(GNominal key _)) =
  match planDef env key
    Err _ => "panic \"native property runner: missing planned constructor\""
    Ok (PlanDef _ owner _ visibility ctors) =>
      if nominalCtorsVisible env owner visibility then
        graphCtorByDepth nonce modules env graph prefix plan owner ctors
      else
        "panic \"native property runner: inaccessible constructor\""

-- Below `maxGenDepth` every container and constructor policy is either
-- depth-independent or a decaying weight rendered over the runtime `depth`;
-- at the bound the finite-height policy applies.  The two regimes share one
-- generator body.
byDepth : String -> String -> String
byDepth below atBound =
  if below == atBound then
    below
  else
    "if depth < \{intToString maxGenDepth} then \{below} else \{atBound}"

graphCtorByDepth : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List PlanCtor ->
  String
graphCtorByDepth nonce modules env graph prefix plan owner ctors =
  let choice = graphCtorChoice nonce modules env graph prefix plan owner ctors
  byDepth
    (choice (softCtorWeights env plan))
    (choice (map SoftFixed (ctorWeights env plan maxGenDepth)))

softWeightPositive : SoftWeight -> Bool
softWeightPositive SoftNever = False
softWeightPositive (SoftFixed weight) = weight > 0
softWeightPositive (SoftDecaying _) = True

anySoftWeightPositive : List SoftWeight -> Bool
anySoftWeightPositive [] = False
anySoftWeightPositive (weight :: rest) =
  softWeightPositive weight || anySoftWeightPositive rest

softWeightExpr : SoftWeight -> String
softWeightExpr SoftNever = "0"
softWeightExpr (SoftFixed weight) = intToString weight
softWeightExpr (SoftDecaying start) =
  "(if depth >= \{intToString (start - 1)} then 1 else \{intToString start} - depth)"

softWeightTotal : List SoftWeight -> String
softWeightTotal weights = softWeightTotalGo weights 0 []

softWeightTotalGo : List SoftWeight -> Int -> List String -> String
softWeightTotalGo [] fixed [] = intToString fixed
softWeightTotalGo [] 0 decaying = "(\{joinWith " + " decaying})"
softWeightTotalGo [] fixed decaying =
  "(\{intToString fixed} + \{joinWith " + " decaying})"
softWeightTotalGo (SoftNever :: rest) fixed decaying =
  softWeightTotalGo rest fixed decaying
softWeightTotalGo ((SoftFixed weight) :: rest) fixed decaying =
  softWeightTotalGo rest (fixed + weight) decaying
softWeightTotalGo ((weight@(SoftDecaying _)) :: rest) fixed decaying =
  softWeightTotalGo rest fixed (softWeightExpr weight :: decaying)

graphCtorChoice : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List PlanCtor ->
  List SoftWeight ->
  String
graphCtorChoice _ _ _ _ _ _ _ [] _ =
  "panic \"native property runner: no finite constructor\""
graphCtorChoice nonce modules env graph prefix plan owner ctors weights =
  if not (anySoftWeightPositive weights) then
    "panic \"native property runner: no finite constructor\""
  else
    let picked = generatedName nonce "ctor_choice"
    "(let \{picked} = \{generatedPrefix nonce}choose \{softWeightTotal weights} in \{graphCtorChoiceAt nonce modules env graph prefix plan owner ctors weights picked})"

graphCtorChoiceAt : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List PlanCtor ->
  List SoftWeight ->
  String ->
  String
graphCtorChoiceAt _ _ _ _ _ _ _ [] _ _ =
  "panic \"native property runner: no finite constructor\""
graphCtorChoiceAt nonce modules env graph prefix plan owner (ctor :: rest) (weight :: weights) picked =
  if not (softWeightPositive weight) then
    graphCtorChoiceAt
      nonce
      modules
      env
      graph
      prefix
      plan
      owner
      rest
      weights
      picked
  else
    let here = graphCtorValue nonce modules env graph prefix plan owner ctor
    let tail =
      graphCtorChoiceAt
        nonce
        modules
        env
        graph
        prefix
        plan
        owner
        rest
        weights
        "(\{picked} - \{softWeightExpr weight})"
    if not (anySoftWeightPositive weights) then
      here
    else
      "if \{picked} < \{softWeightExpr weight} then \{here} else \{tail}"
graphCtorChoiceAt _ _ _ _ _ _ _ _ _ _ =
  "panic \"native property runner: no finite constructor\""

graphCtorValue : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  PlanCtor ->
  String
graphCtorValue nonce modules env graph prefix plan owner (ctor@(PlanCtor source _ _)) =
  match instantiateCtor env plan ctor
    Err _ => "panic \"native property runner: invalid constructor plan\""
    Ok fields =>
      let values = map (graphCtorDraw modules env graph prefix) (map snd fields)
      let ref = qualifiedCtor nonce modules owner source
      if hasNamedField fields then
        "\{ref} { \{joinWith ", " (namedAssignments fields values)} }"
      else if listLen values == 0 then
        ref
      else
        "\{ref} \{joinWith " " (map paren values)}"

renderOptionChoice : String -> List Int -> String -> String
renderOptionChoice nonce [noneWeight, someWeight] child =
  "if \{generatedPrefix nonce}choose \{noneWeight + someWeight} < \{noneWeight} then None else Some (\{child})"
renderOptionChoice _ _ child = "Some (\{child})"

renderOptionByDepth : String -> PlanEnv -> GenPlan -> String -> String
renderOptionByDepth nonce env p child =
  byDepth
    (renderOptionChoice nonce (optionWeights env 0 p) child)
    (renderOptionChoice nonce (optionWeights env maxGenDepth p) child)

renderResultChoice : String -> List Int -> String -> String -> String
renderResultChoice nonce [errWeight, okWeight] error ok =
  "if \{generatedPrefix nonce}choose \{errWeight + okWeight} < \{errWeight} then Err (\{error}) else Ok (\{ok})"
renderResultChoice _ _ error _ = "Err (\{error})"

renderResultByDepth : String ->
  PlanEnv ->
  GenPlan ->
  GenPlan ->
  String ->
  String ->
  String
renderResultByDepth nonce env err ok error okExpr =
  byDepth
    (renderResultChoice nonce (resultWeights env 0 err ok) error okExpr)
    (renderResultChoice
      nonce
      (resultWeights env maxGenDepth err ok)
      error
      okExpr)

customDrawExpr : String -> String -> String
customDrawExpr nonce core =
  "\n  let caller = \{runtimeAlias nonce}.randomState ()\n  let _ = \{runtimeAlias nonce}.restoreRandomState (!\{generatedPrefix nonce}custom_state)\n  let x = \{core}.arbitrary ()\n  let next = \{runtimeAlias nonce}.randomState ()\n  let _ = \{generatedPrefix nonce}custom_state := next\n  let _ = \{runtimeAlias nonce}.restoreRandomState caller\n  x"

stringExpr : String -> Int -> String
stringExpr nonce _ =
  "\{generatedPrefix nonce}string (\{generatedPrefix nonce}choose (if depth >= \{intToString maxGenDepth} then 1 else 11))"

renderListByDepth : String ->
  String ->
  String ->
  PlanEnv ->
  GenPlan ->
  String ->
  String
renderListByDepth nonce open close env p child =
  if listBoundDecays env p then
    renderListChoiceN
      nonce
      open
      close
      child
      listLenMax
      "(if depth >= \{intToString listLenMax} then 1 else \{intToString (listLenMax + 1)} - depth)"
  else
    renderListByDepthFlat nonce open close env p child

renderListByDepthFlat : String ->
  String ->
  String ->
  PlanEnv ->
  GenPlan ->
  String ->
  String
renderListByDepthFlat nonce open close env p child =
  byDepth
    (renderListChoice nonce open close child (listLengthBound env 0 p))
    (renderListChoice
      nonce
      open
      close
      child
      (listLengthBound env maxGenDepth p))

renderListChoice : String -> String -> String -> String -> Int -> String
renderListChoice nonce open close child bound =
  renderListChoiceN nonce open close child bound (intToString (bound + 1))

renderListChoiceN : String ->
  String ->
  String ->
  String ->
  Int ->
  String ->
  String
renderListChoiceN nonce open close child bound count =
  "match \{generatedPrefix nonce}choose \{count}\n\{renderListArms open close child bound 0}"

renderListArms : String -> String -> String -> Int -> Int -> String
renderListArms open close child bound n
  | n > bound = ""
renderListArms open close child bound n =
  "  \{if n == bound then "_" else intToString n} => \{open}\{joinWith ", " (repeatString child n)}\{close}\n\{renderListArms open close child bound (n + 1)}"

repeatString : String -> Int -> List String
repeatString _ 0 = []
repeatString x n = x :: repeatString x (n - 1)

qualifiedCtor : String -> List PlanModule -> String -> String -> String
qualifiedCtor nonce modules owner ctor = match moduleAlias nonce modules owner
  Some alias => "\{alias}.\{ctor}"
  None => ctor

hasNamedField : List (Option String, GenPlan) -> Bool
hasNamedField [] = False
hasNamedField ((Some _, _) :: _) = True
hasNamedField (_ :: rest) = hasNamedField rest

namedAssignments : List (Option String, GenPlan) -> List String -> List String
namedAssignments [] _ = []
namedAssignments _ [] = []
namedAssignments ((Some name, _) :: rest) (value :: values) =
  "\{name} = \{value}" :: namedAssignments rest values
namedAssignments ((None, _) :: rest) (_ :: values) =
  namedAssignments rest values

paren : String -> String
paren x = "(\{x})"

shrinkNodeName : String -> Int -> String
shrinkNodeName prefix ident = "\{prefix}_shrink_\{intToString ident}"

displayNodeName : String -> Int -> String
displayNodeName prefix ident = "\{prefix}_display_\{intToString ident}"

graphShrinkRef : NativeGraph -> String -> GenPlan -> String -> String
graphShrinkRef (NativeGraph nodes _ _) prefix plan name =
  match omLookup (genPlanWord plan) nodes
    Some (GraphNode ident _ _) => "\{shrinkNodeName prefix ident} \{name}"
    None => "[]"

graphDisplayRef : NativeGraph -> String -> GenPlan -> String -> String
graphDisplayRef (NativeGraph nodes _ _) prefix plan name =
  match omLookup (genPlanWord plan) nodes
    Some (GraphNode ident _ _) => "\{displayNodeName prefix ident} \{name}"
    None => "\"<unavailable>\""

-- Shrinking and rendering use the generator's exact closed graph.  In
-- particular, a recursive nominal is a call to its helper, never another
-- source-level expansion of its constructors.
graphAuxLines : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  String ->
  NativeGraph ->
  List String
graphAuxLines nonce modules env core prefix (NativeGraph nodes order _) =
  graphAuxLinesGo nonce modules env core prefix nodes (reverseL order)

graphAuxLinesGo : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  String ->
  OrdMap GraphNode ->
  List String ->
  List String
graphAuxLinesGo _ _ _ _ _ _ [] = []
graphAuxLinesGo nonce modules env core prefix nodes (word :: rest) =
  match omLookup word nodes
    None => graphAuxLinesGo nonce modules env core prefix nodes rest
    Some (GraphNode ident plan _) =>
      let graph = NativeGraph nodes [] 0
      [
          "\{shrinkNodeName prefix ident} : \{planSourceTy nonce modules plan} -> List (\{planSourceTy nonce modules plan})",
          "\{shrinkNodeName prefix ident} value = \{candidateNodeBody nonce modules env core graph prefix plan "value"}",
          "",
          "\{displayNodeName prefix ident} : \{planSourceTy nonce modules plan} -> String",
          "\{displayNodeName prefix ident} value = \{displayNodeBody nonce modules env graph prefix plan "value"}",
          "",
        ]
        ++ graphAuxLinesGo nonce modules env core prefix nodes rest

candidateNodeBody : String ->
  List PlanModule ->
  PlanEnv ->
  String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  String
candidateNodeBody _ _ _ _ _ _ GInt name = nativeIntCandidates name
candidateNodeBody _ _ _ _ _ _ GBool name = "if \{name} then [False] else []"
candidateNodeBody _ _ _ _ _ _ GFloat name =
  "if \{name} == 0.0 then [] else [0.0, \{name} / 2.0]"
candidateNodeBody _ _ _ _ _ _ GChar _ = "[]"
candidateNodeBody nonce _ _ _ _ _ GString name =
  "if \{name} == \"\" then [] else [\{runtimeAlias nonce}.stringSlice 0 (\{runtimeAlias nonce}.stringLength \{name} / 2) \{name}]"
candidateNodeBody _ _ _ _ _ _ GUnit _ = "[]"
candidateNodeBody _ _ _ core _ _ (GCustom _) name = "\{core}.shrink \{name}"
candidateNodeBody nonce modules env _ graph prefix (GList p) name =
  graphListCandidates nonce graph prefix p name (shrinkActions (GList p))
candidateNodeBody nonce modules env _ graph prefix (GArray p) name =
  graphArrayCandidates nonce graph prefix p name (shrinkActions (GArray p))
candidateNodeBody nonce modules env _ graph prefix (GOption p) name =
  graphOptionCandidates nonce graph prefix p name (shrinkActions (GOption p))
candidateNodeBody nonce modules env _ graph prefix (result@(GResult err ok)) name =
  graphResultCandidates nonce graph prefix err ok name (shrinkActions result)
candidateNodeBody nonce _ _ _ graph prefix (GTuple ps) name =
  graphTupleCandidates nonce graph prefix ps name (shrinkActions (GTuple ps))
candidateNodeBody nonce modules env _ graph prefix (plan@(GNominal key _)) name =
  graphNominalCandidates nonce modules env graph prefix plan key name

displayNodeBody : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  String
displayNodeBody nonce _ _ _ _ GInt name =
  "\{runtimeAlias nonce}.intToString \{name}"
displayNodeBody _ _ _ _ _ GBool name = "if \{name} then \"True\" else \"False\""
displayNodeBody nonce _ _ _ _ GFloat name = "\{coreAlias nonce}.debug \{name}"
displayNodeBody nonce _ _ _ _ GChar name = "\{coreAlias nonce}.debug \{name}"
displayNodeBody nonce _ _ _ _ GString name = "\{coreAlias nonce}.debug \{name}"
displayNodeBody _ _ _ _ _ GUnit _ = "\"()\""
displayNodeBody nonce modules env graph prefix (GCustom (custom@(CustomPlan key _ _))) name =
  match customStructuralPlan env custom
    Some plan =>
      graphNominalDisplay nonce modules env graph prefix plan key name
    None => "\"<\{typeKeyName key}>\""
displayNodeBody nonce _ _ graph prefix (GList p) name =
  "\"[\" ++ \{generatedPrefix nonce}join_strings \", \" (\{coreAlias nonce}.map (x => \{graphDisplayRef graph prefix p "x"}) \{name}) ++ \"]\""
displayNodeBody nonce _ _ graph prefix (GArray p) name =
  "\"[|\" ++ \{generatedPrefix nonce}join_strings \", \" (\{coreAlias nonce}.map (x => \{graphDisplayRef graph prefix p "x"}) (\{generatedPrefix nonce}array_to_list \{name})) ++ \"|]\""
displayNodeBody _ _ _ graph prefix (GOption p) name =
  "match \{name}\n  None => \"None\"\n  Some x => \"Some (\" ++ \{graphDisplayRef graph prefix p "x"} ++ \")\""
displayNodeBody _ _ _ graph prefix (GResult err ok) name =
  "match \{name}\n  Err x => \"Err (\" ++ \{graphDisplayRef graph prefix err "x"} ++ \")\"\n  Ok x => \"Ok (\" ++ \{graphDisplayRef graph prefix ok "x"} ++ \")\""
displayNodeBody _ _ _ graph prefix (GTuple ps) name =
  let vars = tupleVars (listLen ps)
  "match \{name}\n  (\{joinWith ", " vars}) => \"(\" ++ \{graphJoinDisplays graph prefix ps vars} ++ \")\""
displayNodeBody nonce modules env graph prefix (plan@(GNominal key _)) name =
  graphNominalDisplay nonce modules env graph prefix plan key name

nativeIntCandidates : String -> String
nativeIntCandidates name =
  "if \{name} == 0 then [] else [\{joinWith ", " (map (nativeIntStep name) intShrinkSteps)}]"

nativeIntStep : String -> IntShrinkStep -> String
nativeIntStep _ IntToZero = "0"
nativeIntStep name IntHalf = "\{name} / 2"
nativeIntStep name IntTowardZero = "\{name} + (if \{name} > 0 then -1 else 1)"

joinCandidateFamilies : List String -> String
joinCandidateFamilies [] = "[]"
joinCandidateFamilies [family] = family
joinCandidateFamilies (family :: families) =
  "\{family} ++ \{joinCandidateFamilies families}"

graphListCandidates : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  String
graphListCandidates nonce graph prefix plan name actions =
  joinCandidateFamilies
    (graphListCandidateFamilies nonce graph prefix plan name actions)

graphListCandidateFamilies : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  List String
graphListCandidateFamilies _ _ _ _ _ [] = []
graphListCandidateFamilies nonce graph prefix plan name (DeleteElements :: actions) =
  "\{generatedPrefix nonce}delete_each \{name}"
    :: graphListCandidateFamilies nonce graph prefix plan name actions
graphListCandidateFamilies nonce graph prefix plan name (ShrinkChildren :: actions) =
  "\{generatedPrefix nonce}replace_each (x => \{graphShrinkRef graph prefix plan "x"}) \{name}"
    :: graphListCandidateFamilies nonce graph prefix plan name actions
graphListCandidateFamilies nonce graph prefix plan name (_ :: actions) =
  graphListCandidateFamilies nonce graph prefix plan name actions

graphArrayCandidates : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  String
graphArrayCandidates nonce graph prefix plan name actions =
  joinCandidateFamilies
    (graphArrayCandidateFamilies nonce graph prefix plan name actions)

graphArrayCandidateFamilies : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  List String
graphArrayCandidateFamilies _ _ _ _ _ [] = []
graphArrayCandidateFamilies nonce graph prefix plan name (DeleteElements :: actions) =
  "\{coreAlias nonce}.map \{runtimeAlias nonce}.arrayFromList (\{generatedPrefix nonce}delete_each (\{generatedPrefix nonce}array_to_list \{name}))"
    :: graphArrayCandidateFamilies nonce graph prefix plan name actions
graphArrayCandidateFamilies nonce graph prefix plan name (ShrinkChildren :: actions) =
  "\{coreAlias nonce}.map \{runtimeAlias nonce}.arrayFromList (\{generatedPrefix nonce}replace_each (x => \{graphShrinkRef graph prefix plan "x"}) (\{generatedPrefix nonce}array_to_list \{name}))"
    :: graphArrayCandidateFamilies nonce graph prefix plan name actions
graphArrayCandidateFamilies nonce graph prefix plan name (_ :: actions) =
  graphArrayCandidateFamilies nonce graph prefix plan name actions

graphOptionCandidates : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  String
graphOptionCandidates nonce graph prefix plan name actions =
  "match \{name}\n  None => []\n  Some x => \{joinCandidateFamilies (graphOptionCandidateFamilies nonce graph prefix plan actions)}"

graphOptionCandidateFamilies : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  List ShrinkAction ->
  List String
graphOptionCandidateFamilies _ _ _ _ [] = []
graphOptionCandidateFamilies nonce graph prefix plan (ReplaceEarlierNullary :: actions) =
  "[None]" :: graphOptionCandidateFamilies nonce graph prefix plan actions
graphOptionCandidateFamilies nonce graph prefix plan (ShrinkChildren :: actions) =
  "\{coreAlias nonce}.map Some (\{graphShrinkRef graph prefix plan "x"})"
    :: graphOptionCandidateFamilies nonce graph prefix plan actions
graphOptionCandidateFamilies nonce graph prefix plan (_ :: actions) =
  graphOptionCandidateFamilies nonce graph prefix plan actions

graphResultCandidates : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  String
graphResultCandidates nonce graph prefix err ok name actions =
  "match \{name}\n  Err x => \{joinCandidateFamilies (graphResultCandidateFamilies nonce graph prefix err "Err" actions)}\n  Ok x => \{joinCandidateFamilies (graphResultCandidateFamilies nonce graph prefix ok "Ok" actions)}"

graphResultCandidateFamilies : String ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List ShrinkAction ->
  List String
graphResultCandidateFamilies _ _ _ _ _ [] = []
graphResultCandidateFamilies nonce graph prefix plan tag (ShrinkChildren :: actions) =
  "\{coreAlias nonce}.map \{tag} (\{graphShrinkRef graph prefix plan "x"})"
    :: graphResultCandidateFamilies nonce graph prefix plan tag actions
graphResultCandidateFamilies nonce graph prefix plan tag (_ :: actions) =
  graphResultCandidateFamilies nonce graph prefix plan tag actions

graphTupleCandidates : String ->
  NativeGraph ->
  String ->
  List GenPlan ->
  String ->
  List ShrinkAction ->
  String
graphTupleCandidates nonce graph prefix plans name actions =
  let values = tupleVars (listLen plans)
  "match \{name}\n  (\{joinWith ", " values}) => \{graphTupleCandidatesByActions nonce graph prefix plans values values actions}"

graphTupleCandidatesByActions : String ->
  NativeGraph ->
  String ->
  List GenPlan ->
  List String ->
  List String ->
  List ShrinkAction ->
  String
graphTupleCandidatesByActions _ _ _ _ _ _ [] = "[]"
graphTupleCandidatesByActions nonce graph prefix plans all values (ShrinkChildren :: actions) =
  "\{graphTupleCandidateLists nonce graph prefix plans all values 0} ++ \{graphTupleCandidatesByActions nonce graph prefix plans all values actions}"
graphTupleCandidatesByActions nonce graph prefix plans all values (_ :: actions) =
  graphTupleCandidatesByActions nonce graph prefix plans all values actions

graphTupleCandidateLists : String ->
  NativeGraph ->
  String ->
  List GenPlan ->
  List String ->
  List String ->
  Int ->
  String
graphTupleCandidateLists nonce _ _ [] _ _ _ = "[]"
graphTupleCandidateLists nonce graph prefix (plan :: plans) all (value :: values) index =
  "\{coreAlias nonce}.map (candidate => (\{joinWith ", " (replaceName index "candidate" all)})) (\{graphShrinkRef graph prefix plan value}) ++ \{graphTupleCandidateLists nonce graph prefix plans all values (index + 1)}"
graphTupleCandidateLists nonce _ _ _ _ _ _ = "[]"

graphNominalCandidates : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  TypeKey ->
  String ->
  String
graphNominalCandidates nonce modules env graph prefix plan key name =
  match planDef env key
    Err _ => "[]"
    Ok (PlanDef _ owner _ visibility ctors) =>
      if nominalCtorsVisible env owner visibility then
        "match \{name}\n\{joinNl (graphNominalCandidateArms nonce modules env graph prefix plan owner ctors None)}"
      else
        "[]"

graphNominalCandidateArms : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  List PlanCtor ->
  Option PlanCtor ->
  List String
graphNominalCandidateArms _ _ _ _ _ _ _ [] _ = []
graphNominalCandidateArms nonce modules env graph prefix plan owner (ctor :: ctors) earlier =
  graphNominalCandidateArm
      nonce
      modules
      env
      graph
      prefix
      plan
      owner
      earlier
      ctor
    :: graphNominalCandidateArms
      nonce
      modules
      env
      graph
      prefix
      plan
      owner
      ctors
      (nextEarlierNullary earlier ctor)

nextEarlierNullary : Option PlanCtor -> PlanCtor -> Option PlanCtor
nextEarlierNullary None (ctor@(PlanCtor _ _ [])) = Some ctor
nextEarlierNullary earlier (PlanCtor _ _ []) = earlier
nextEarlierNullary earlier _ = earlier

graphNominalCandidateArm : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  Option PlanCtor ->
  PlanCtor ->
  String
graphNominalCandidateArm nonce modules env graph prefix plan owner earlier (ctor@(PlanCtor source _ _)) =
  match instantiateCtor env plan ctor
    Err _ => "  _ => []"
    Ok fields =>
      let values = tupleVars (listLen fields)
      let ref = qualifiedCtor nonce modules owner source
      let replacements =
        graphNominalReplacementByActions
          nonce
          modules
          owner
          earlier
          (shrinkActions plan)
      if hasNamedField fields then
        "  \{ref} { \{joinWith ", " (namedAssignments fields values)} } => \{joinCandidateFamilies [replacements, graphNominalFieldCandidatesByActions nonce graph prefix ref fields fields values values True 0 (shrinkActions plan)]}"
      else if listLen values == 0 then
        "  \{ref} => \{joinCandidateFamilies [replacements]}"
      else
        "  \{ref} \{joinWith " " values} => \{joinCandidateFamilies [replacements, graphNominalFieldCandidatesByActions nonce graph prefix ref fields fields values values False 0 (shrinkActions plan)]}"

graphNominalReplacementByActions : String ->
  List PlanModule ->
  String ->
  Option PlanCtor ->
  List ShrinkAction ->
  String
graphNominalReplacementByActions _ _ _ _ [] = "[]"
graphNominalReplacementByActions nonce modules owner earlier (ReplaceEarlierNullary :: _) =
  graphNominalReplacement nonce modules owner earlier
graphNominalReplacementByActions nonce modules owner earlier (_ :: actions) =
  graphNominalReplacementByActions nonce modules owner earlier actions

graphNominalReplacement : String ->
  List PlanModule ->
  String ->
  Option PlanCtor ->
  String
graphNominalReplacement _ _ _ None = "[]"
graphNominalReplacement nonce modules owner (Some (PlanCtor source _ [])) =
  "[\{qualifiedCtor nonce modules owner source}]"
graphNominalReplacement _ _ _ (Some _) = "[]"

graphNominalFieldCandidatesByActions : String ->
  NativeGraph ->
  String ->
  String ->
  List (Option String, GenPlan) ->
  List (Option String, GenPlan) ->
  List String ->
  List String ->
  Bool ->
  Int ->
  List ShrinkAction ->
  String
graphNominalFieldCandidatesByActions _ _ _ _ _ _ _ _ _ _ [] = "[]"
graphNominalFieldCandidatesByActions nonce graph prefix ref all fields allValues values named index (ShrinkChildren :: actions) =
  "\{graphNominalFieldCandidates nonce graph prefix ref all fields allValues values named index} ++ \{graphNominalFieldCandidatesByActions nonce graph prefix ref all fields allValues values named index actions}"
graphNominalFieldCandidatesByActions nonce graph prefix ref all fields allValues values named index (_ :: actions) =
  graphNominalFieldCandidatesByActions
    nonce
    graph
    prefix
    ref
    all
    fields
    allValues
    values
    named
    index
    actions

graphNominalFieldCandidates : String ->
  NativeGraph ->
  String ->
  String ->
  List (Option String, GenPlan) ->
  List (Option String, GenPlan) ->
  List String ->
  List String ->
  Bool ->
  Int ->
  String
graphNominalFieldCandidates nonce _ _ _ _ [] _ _ _ _ = "[]"
graphNominalFieldCandidates nonce graph prefix ref all ((_, plan) :: rest) allValues (value :: values) named index =
  "\{coreAlias nonce}.map (candidate => \{rebuildCtor ref all (replaceName index "candidate" allValues) named}) (\{graphShrinkRef graph prefix plan value}) ++ \{graphNominalFieldCandidates nonce graph prefix ref all rest allValues values named (index + 1)}"
graphNominalFieldCandidates nonce _ _ _ _ _ _ _ _ _ = "[]"

graphJoinDisplays : NativeGraph ->
  String ->
  List GenPlan ->
  List String ->
  String
graphJoinDisplays _ _ [] _ = "\"\""
graphJoinDisplays graph prefix (plan :: plans) (value :: values) =
  graphDisplayRef graph prefix plan value
    ++ graphJoinDisplaysTail graph prefix plans values
graphJoinDisplays _ _ _ _ = "\"\""

graphJoinDisplaysTail : NativeGraph ->
  String ->
  List GenPlan ->
  List String ->
  String
graphJoinDisplaysTail _ _ [] _ = ""
graphJoinDisplaysTail graph prefix (plan :: plans) (value :: values) =
  " ++ \", \" ++ \{graphDisplayRef graph prefix plan value}\{graphJoinDisplaysTail graph prefix plans values}"
graphJoinDisplaysTail _ _ _ _ = ""

graphNominalDisplay : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  TypeKey ->
  String ->
  String
graphNominalDisplay nonce modules env graph prefix plan (TypeKey typeName origin) name =
  match planDef env (TypeKey typeName origin)
    Err _ => "\"<unavailable>\""
    Ok (PlanDef _ owner _ visibility ctors) =>
      if nominalCtorsVisible env owner visibility then
        "match \{name}\n\{joinNl (map (graphNominalDisplayArm nonce modules env graph prefix plan owner) ctors)}"
      else
        "\"<\{typeName}>\""

graphNominalDisplayArm : String ->
  List PlanModule ->
  PlanEnv ->
  NativeGraph ->
  String ->
  GenPlan ->
  String ->
  PlanCtor ->
  String
graphNominalDisplayArm nonce modules env graph prefix plan owner (ctor@(PlanCtor source _ _)) =
  match instantiateCtor env plan ctor
    Err _ => "  _ => \"<unavailable>\""
    Ok fields =>
      let values = tupleVars (listLen fields)
      let ref = qualifiedCtor nonce modules owner source
      let text =
        if hasNamedField fields then
          "\"\{source} { \" ++ \{graphNamedDisplays graph prefix fields values} ++ \" }\""
        else if listLen values == 0 then
          "\"\{source}\""
        else
          "\"\{source} (\" ++ \{graphJoinDisplays graph prefix (map snd fields) values} ++ \")\""
      let pat =
        if hasNamedField fields then
          "\{ref} { \{joinWith ", " (namedAssignments fields values)} }"
        else if listLen values == 0 then
          ref
        else
          "\{ref} \{joinWith " " values}"
      "  \{pat} => \{text}"

graphNamedDisplays : NativeGraph ->
  String ->
  List (Option String, GenPlan) ->
  List String ->
  String
graphNamedDisplays _ _ [] _ = ""
graphNamedDisplays graph prefix ((Some field, plan) :: rest) (value :: values) =
  "\"\{field} = \" ++ \{graphDisplayRef graph prefix plan value}\{graphNamedDisplaysTail graph prefix rest values}"
graphNamedDisplays _ _ _ _ = ""

graphNamedDisplaysTail : NativeGraph ->
  String ->
  List (Option String, GenPlan) ->
  List String ->
  String
graphNamedDisplaysTail _ _ [] _ = ""
graphNamedDisplaysTail graph prefix ((Some field, plan) :: rest) (value :: values) =
  " ++ \", \" ++ \"\{field} = \" ++ \{graphDisplayRef graph prefix plan value}\{graphNamedDisplaysTail graph prefix rest values}"
graphNamedDisplaysTail _ _ _ _ = ""

plannedRunLines : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  List String
plannedRunLines nonce modules graph i ps plans _ =
  [
      "\{runName nonce i} \{generatedPrefix nonce}cases =",
      "  if \{generatedPrefix nonce}cases <= 0 then (True, \"\") else",
    ]
    ++ plannedBindings nonce graph i ps plans 0
    ++ [
      "    let ok = \{fnName nonce i} \{joinWith " " (paramSlots nonce i ps)}",
    ]
    ++ plannedFailureLines nonce i ps plans
    ++ [""]

plannedBindings : String ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  List String
plannedBindings nonce graph i ((PropParam _ _ _) :: rest) (plan :: plans) j =
  [
      "    let \{slotName nonce i j} = \{graphRef graph (genNodePrefix nonce) plan "0"}",
    ]
    ++ plannedBindings nonce graph i rest plans (j + 1)
plannedBindings _ _ _ _ _ _ = []

slotName : String -> Int -> Int -> String
slotName nonce i j =
  "\{generatedPrefix nonce}arg_\{intToString i}_\{intToString j}"

paramSlots : String -> Int -> List PropParam -> List String
paramSlots nonce i ps = paramSlotsGo nonce i ps 0

paramSlotsGo : String -> Int -> List PropParam -> Int -> List String
paramSlotsGo _ _ [] _ = []
paramSlotsGo nonce i (_ :: rest) j =
  slotName nonce i j :: paramSlotsGo nonce i rest (j + 1)

plannedFailureLines : String ->
  Int ->
  List PropParam ->
  List GenPlan ->
  List String
plannedFailureLines nonce i [] _ = [
  "    if ok then \{runName nonce i} (\{generatedPrefix nonce}cases - 1) else (False, \"counterexample\")",
]
plannedFailureLines nonce i ps plans = [
  "    if ok then \{runName nonce i} (\{generatedPrefix nonce}cases - 1) else \{plannedShrinkStart nonce i ps plans}",
]

plannedShrinkStart : String -> Int -> List PropParam -> List GenPlan -> String
plannedShrinkStart nonce i ps plans =
  "\{shrinkName nonce i} 100 \{joinWith " " (paramSlots nonce i ps)}"

shrinkName : String -> Int -> String
shrinkName nonce i = "\{generatedPrefix nonce}shrink_\{intToString i}"

-- The generated shrinker tries every candidate, left-to-right, and restarts
-- from parameter zero after each successful reduction.  Only custom plans may
-- invoke `shrink`; structural plans deliberately use the shared construction
-- policy above and remain displayable without imposing Debug on a nominal.
plannedShrinkLines : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  List String
plannedShrinkLines _ _ _ _ [] _ = []
plannedShrinkLines nonce modules graph i ps plans =
  shrinkTopLines nonce modules graph i ps plans
    ++ shrinkTryLines nonce modules graph i ps plans 0

shrinkTopLines : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  List String
shrinkTopLines nonce modules graph i ps plans =
  let startCandidates =
    candidateExprAt nonce graph i 0 (nthPlan 0 plans) (slotName nonce i 0)
  [
    "\{shrinkName nonce i} \{generatedPrefix nonce}fuel \{joinWith " " (paramSlots nonce i ps)} =",
    "  if \{generatedPrefix nonce}fuel <= 0 then (False, \{plannedDetailSlots nonce modules graph i ps plans} ++ \" (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)\") else \{shrinkTryName nonce i 0} \{generatedPrefix nonce}fuel \{startCandidates} \{joinWith " " (paramSlots nonce i ps)}",
    "",
  ]

shrinkTryName : String -> Int -> Int -> String
shrinkTryName nonce i j =
  "\{generatedPrefix nonce}try_\{intToString i}_\{intToString j}"

shrinkTryLines : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  List String
shrinkTryLines nonce _ _ _ [] _ _ = []
shrinkTryLines nonce _ _ _ ps _ j
  | j >= listLen ps = []
shrinkTryLines nonce modules graph i ps plans j =
  shrinkTryLine nonce modules graph i ps plans j
    ++ shrinkTryLines nonce modules graph i ps plans (j + 1)

shrinkTryLine : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  List String
shrinkTryLine nonce modules graph i ps plans j =
  let current = slotName nonce i j
  let plan = nthPlan j plans
  let params = paramSlots nonce i ps
  let after =
    if j + 1 >= listLen ps then
      "(False, \{plannedDetailSlots nonce modules graph i ps plans})"
    else
      let nextCandidates =
        candidateExprAt
          nonce
          graph
          i
          (j + 1)
          (nthPlan (j + 1) plans)
          (slotName nonce i (j + 1))
      "\{shrinkTryName nonce i (j + 1)} \{generatedPrefix nonce}fuel \{nextCandidates} \{joinWith " " params}"
  [
    "\{shrinkTryName nonce i j} \{generatedPrefix nonce}fuel \{generatedPrefix nonce}candidates \{joinWith " " params} =",
    "  match \{generatedPrefix nonce}candidates",
    "    [] => \{after}",
    "    \{generatedPrefix nonce}candidate :: \{generatedPrefix nonce}rest =>",
    "      if \{fnName nonce i} \{joinWith " " (replaceName j (generatedName nonce "candidate") params)} then \{shrinkTryName nonce i j} \{generatedPrefix nonce}fuel \{generatedPrefix nonce}rest \{joinWith " " params}",
    "      else \{shrinkName nonce i} (\{generatedPrefix nonce}fuel - 1) \{joinWith " " (replaceName j (generatedName nonce "candidate") params)}",
    "",
  ]

nthPlan : Int -> List GenPlan -> GenPlan
nthPlan 0 (p :: _) = p
nthPlan n (_ :: rest) = nthPlan (n - 1) rest
nthPlan _ [] = GUnit

candidateExprAt : String ->
  NativeGraph ->
  Int ->
  Int ->
  GenPlan ->
  String ->
  String
candidateExprAt nonce graph _ _ plan name =
  "(\{graphShrinkRef graph (genNodePrefix nonce) plan name})"

replaceName : Int -> String -> List String -> List String
replaceName _ _ [] = []
replaceName 0 replacement (_ :: rest) = replacement :: rest
replaceName n replacement (x :: rest) =
  x :: replaceName (n - 1) replacement rest

plannedDetailSlots : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  String
plannedDetailSlots _ _ _ _ [] _ = "\"counterexample\""
plannedDetailSlots nonce modules graph i ps plans =
  plannedDetailSlotsGo nonce modules graph i ps plans 0

plannedDetailSlotsGo : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  String
plannedDetailSlotsGo _ _ _ _ [] _ _ = "\"counterexample\""
plannedDetailSlotsGo nonce modules graph i ((PropParam name _ _) :: rest) (plan :: plans) j =
  "\"\{name} = \" ++ \{graphDisplayRef graph (genNodePrefix nonce) plan (slotName nonce i j)}\{plannedDetailSlotsTail nonce modules graph i rest plans (j + 1)}"
plannedDetailSlotsGo _ _ _ _ _ _ _ = "\"counterexample\""

plannedDetailSlotsTail : String ->
  List PlanModule ->
  NativeGraph ->
  Int ->
  List PropParam ->
  List GenPlan ->
  Int ->
  String
plannedDetailSlotsTail _ _ _ _ [] _ _ = ""
plannedDetailSlotsTail nonce modules graph i ((PropParam name _ _) :: rest) (plan :: plans) j =
  " ++ \"\\n\" ++ \"\{name} = \" ++ \{graphDisplayRef graph (genNodePrefix nonce) plan (slotName nonce i j)}\{plannedDetailSlotsTail nonce modules graph i rest plans (j + 1)}"
plannedDetailSlotsTail _ _ _ _ _ _ _ = ""

tupleVars : Int -> List String
tupleVars n = tupleVarsGo n 0

tupleVarsGo : Int -> Int -> List String
tupleVarsGo n i =
  if i >= n then [] else "v\{intToString i}" :: tupleVarsGo n (i + 1)

rebuildCtor : String ->
  List (Option String, GenPlan) ->
  List String ->
  Bool ->
  String
rebuildCtor ref fields values named =
  if named then
    "\{ref} { \{joinWith ", " (namedAssignments fields values)} }"
  else
    "\{ref} \{joinWith " " (map paren values)}"

plannedMainLines : String -> List NativePlanOutcome -> Int -> List String
plannedMainLines _ [] _ = []
plannedMainLines nonce ((NativeRunnable (DProp _ _ params _) r plans) :: rest) i =
  [
      "  let _ = \{runtimeAlias nonce}.putStrLn \"\{sentinelFor nonce (startTag i)}\"",
      "  let _ = \{generatedPrefix nonce}state := ((\{intToString (propRequestSeed r)} % \{intToString structuralRngModulus}) + \{intToString structuralRngModulus}) % \{intToString structuralRngModulus}",
      "  let caller = \{runtimeAlias nonce}.randomState ()",
      "  let _ = \{runtimeAlias nonce}.setSeed \{intToString (propRequestSeed r)}",
      "  let _ = \{generatedPrefix nonce}custom_state := \{runtimeAlias nonce}.randomState ()",
      "  let _ = \{runtimeAlias nonce}.restoreRandomState caller",
      "  let seed = \{intToString (propRequestSeed r)}",
      "  let _ = \{runtimeAlias nonce}.putStrLn \"\{sentinelFor nonce (seedTag i)}\"",
      "  let _ = \{valuePrintExprWith (runtimeAlias nonce ++ ".putStrLn") (runtimeAlias nonce ++ ".debugStringLit") (runtimeAlias nonce ++ ".intToString seed")}",
      "  let (ok, detail) = \{runName nonce i} \{intToString (propRequestCases r)}",
      "  let _ = \{runtimeAlias nonce}.putStrLn \"\{sentinelFor nonce (boolTag i)}\"",
      "  let _ = \{valuePrintExprWith (runtimeAlias nonce ++ ".putStrLn") (runtimeAlias nonce ++ ".debugStringLit") (coreAlias nonce ++ ".debug ok")}",
      "  let _ = \{runtimeAlias nonce}.putStrLn \"\{sentinelFor nonce (detailTag i)}\"",
      "  let _ = \{valuePrintExprWith (runtimeAlias nonce ++ ".putStrLn") (runtimeAlias nonce ++ ".debugStringLit") "detail"}",
    ]
    ++ plannedMainLines nonce rest (i + 1)
plannedMainLines nonce (_ :: rest) i = plannedMainLines nonce rest i

-- `core.mdk` is the auto-prelude, so splicing its declarations into a scratch
-- entry duplicates every prelude binding.  Its property bodies can instead be
-- compiled in an ordinary entry where core is already the auto-prelude.
probeTargetSource : String -> String -> String
probeTargetSource target src =
  if baseOf target == "core.mdk" then "" else renameUserMain src

fnName : String -> Int -> String
fnName nonce i = "\{generatedPrefix nonce}prop_\{intToString i}"

runName : String -> Int -> String
runName nonce i = "\{generatedPrefix nonce}run_\{intToString i}"

fnLines : String -> Int -> List PropParam -> Expr -> List String
fnLines nonce i ps body = [
  "\{fnName nonce i} \{joinWith " " (map paramName ps)} = \{exprToString body}",
  "",
]

paramName : PropParam -> String
paramName (PropParam n _ _) = n
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "PropParam" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true) (mem "Pat" true) (mem "mapTyFull" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "scratchProbeManifest" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "BuildProfile" true) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "listLen" false) (mem "zipL" false) (mem "reverseL" false))))
(DUse false (UseGroup ("string") ((mem "replaceAll" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "decodeValue" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "mintNonce" false) (mem "freshProbeNonce" false) (mem "noncedPrefix" false) (mem "renameUserMain" false) (mem "runtimeDependencyName" false) (mem "runtimeDependencyPrefix" false) (mem "sentinelLine" false) (mem "tagsInOrder" false) (mem "valuePrintExprWith" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false) (mem "ppTy" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" true) (mem "TypeKey" true) (mem "CustomPlan" true) (mem "PlanEnv" true) (mem "GenPlan" true) (mem "PlanDef" true) (mem "PlanCtor" true) (mem "PlanField" true) (mem "PlanError" true) (mem "PlanErrorReason" true) (mem "PlanVisibility" true) (mem "planErrorText" false) (mem "buildPlanEnvModules" false) (mem "planFor" false) (mem "planDef" false) (mem "instantiateCtor" false) (mem "planTy" false) (mem "typeKeyWord" false) (mem "ctorWeights" false) (mem "listLengthBound" false) (mem "listBoundDecays" false) (mem "listLenMax" false) (mem "optionWeights" false) (mem "resultWeights" false) (mem "maxGenDepth" false) (mem "SoftWeight" true) (mem "softCtorWeights" false) (mem "intMin" false) (mem "intMax" false) (mem "structuralRngModulus" false) (mem "structuralRngMultiplier" false) (mem "structuralRngIncrement" false) (mem "structuralRngMixMultiplier1" false) (mem "structuralRngMixMultiplier2" false) (mem "structuralRngWordModulus" false) (mem "structuralRngWordHalf" false) (mem "ShrinkAction" true) (mem "shrinkActions" false) (mem "IntShrinkStep" true) (mem "intShrinkSteps" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propSeedValue" false) (mem "PropRequest" true) (mem "propRequestName" false) (mem "propRequestSeed" false) (mem "propRequestCases" false))))
(DTypeSig false "sentinelBase" (TyCon "String"))
(DFunDef false "sentinelBase" () (ELit (LString "@@__mdk_native_prop__@@")))
(DTypeSig false "sentinelPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelPrefix" ((PVar "nonce")) (EApp (EApp (EVar "noncedPrefix") (EVar "sentinelBase")) (EVar "nonce")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelFor" ((PVar "nonce") (PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EVar "tag")))
(DTypeSig false "startTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "startTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".start"))))
(DTypeSig false "boolTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "boolTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".bool"))))
(DTypeSig false "detailTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "detailTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".detail"))))
(DTypeSig false "seedTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "seedTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".seed"))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EApp (EVar "startTag") (EVar "i")) (EApp (EVar "seedTag") (EVar "i")) (EApp (EVar "boolTag") (EVar "i")) (EApp (EVar "detailTag") (EVar "i"))) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "runNativePlannedPropRequests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runNativePlannedPropRequests" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "requests")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EApp (EVar "desugarProps") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EVar "requestIndex") (EVar "requests")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "duplicate")) () (EApp (EApp (EVar "nativeProtocolErrors") (EVar "duplicate")) (EVar "requests"))) (arm (PCon "Ok" (PVar "index")) () (EMatch (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "props")) (EVar "index")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "duplicate")) () (EApp (EApp (EVar "nativeProtocolErrors") (ELit (LString "duplicate property declaration name \"{duplicate}\""))) (EVar "requests"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EApp (EVar "plannedRoot") (EVar "modules"))) (EVar "modules")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "plannedResults") (EApp (EApp (EApp (EVar "planCapabilities") (EVar "props")) (EVar "index")) (EApp (EVar "planErrorText") (EVar "e")))) (EListLit))) (arm (PCon "Ok" (PVar "env")) () (EBlock (DoLet false false (PVar "outcomes") (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "props")) (EVar "index"))) (DoLet false false (PVar "runnable") (EApp (EVar "plannedRunnable") (EVar "outcomes"))) (DoExpr (EMatch (EVar "runnable") (arm (PList) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EListLit))) (arm PWild () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "nativeRenderedPlanned") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "runnable")) (arm (PCon "Err" (PVar "failure")) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EApp (EApp (EVar "map") (EApp (EVar "nativePlannedFailure") (EVar "failure"))) (EVar "runnable")))) (arm (PCon "Ok" (PVar "rows")) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EVar "rows")))))))))))))))))
(DTypeSig true "renderNativePlannedProbe" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderNativePlannedProbe" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "requests")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EApp (EVar "desugarProps") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EVar "requestIndex") (EVar "requests")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "index")) () (EMatch (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "props")) (EVar "index")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "duplicate")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "duplicate property declaration name \"")) (EApp (EVar "display") (EVar "duplicate"))) (ELit (LString "\""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EApp (EVar "plannedRoot") (EVar "modules"))) (EVar "modules")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "planErrorText") (EVar "e")))) (arm (PCon "Ok" (PVar "env")) () (EBlock (DoLet false false (PVar "jobs") (EApp (EVar "plannedRunnable") (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "props")) (EVar "index")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "jobs")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "native property runner: no selected property could be rendered"))) (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (ELit (LString "source_check"))) (EVar "probeNamespacePrefixes")) (EVar "tsrc"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedProbeSource") (EVar "nonce")) (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs")))))))))))))))))
(DTypeSig false "plannedRoot" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyCon "String")))
(DFunDef false "plannedRoot" ((PList)) (ELit (LString "")))
(DFunDef false "plannedRoot" ((PList (PCon "PlanModule" (PVar "name") PWild PWild))) (EVar "name"))
(DFunDef false "plannedRoot" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedRoot") (EVar "rest")))
(DTypeSig false "planCapabilities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "NativePlanOutcome"))))))
(DFunDef false "planCapabilities" ((PList) PWild PWild) (EListLit))
(DFunDef false "planCapabilities" ((PCons (PAs "d" (PCon "DProp" PWild PWild PWild PWild)) (PVar "rest")) (PVar "requests") (PVar "message")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "propName") (EVar "d"))) (EVar "requests")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (EVar "message")) (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))))
(DFunDef false "planCapabilities" ((PCons PWild (PVar "rest")) (PVar "requests") (PVar "message")) (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))
(DData Private "NativePlanOutcome" () ((variant "NativeRunnable" (ConPos (TyCon "Decl") (TyCon "PropRequest") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "NativeCapability" (ConPos (TyCon "Decl") (TyCon "PropRequest") (TyCon "String")))) ())
(DTypeSig false "plannedOutcomes" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "NativePlanOutcome")))))))
(DFunDef false "plannedOutcomes" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedOutcomes" ((PVar "env") (PVar "modules") (PCons (PAs "d" (PCon "DProp" PWild PWild PWild PWild)) (PVar "rest")) (PVar "requests")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "propName") (EVar "d"))) (EVar "requests")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests"))) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EApp (EVar "runtimePropParams") (EVar "modules")) (EApp (EVar "propName") (EVar "d"))) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (ELit (LString "property declaration was absent from the elaborated module"))) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))) (arm (PCon "Some" (PVar "ps")) () (EMatch (EApp (EApp (EApp (EApp (EVar "planParameters") (EVar "env")) (EApp (EVar "propName") (EVar "d"))) (EVar "ps")) (EListLit)) (arm (PCon "Ok" (PVar "plans")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeRunnable") (EVar "d")) (EVar "r")) (EVar "plans")) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))) (arm (PCon "Err" (PVar "e")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (EApp (EVar "planErrorText") (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests"))))))))))
(DFunDef false "plannedOutcomes" ((PVar "env") (PVar "modules") (PCons PWild (PVar "rest")) (PVar "requests")) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))
(DTypeSig false "runtimePropParams" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PropParam"))))))
(DFunDef false "runtimePropParams" ((PList) PWild) (EVar "None"))
(DFunDef false "runtimePropParams" ((PList (PCon "PlanModule" PWild PWild (PVar "runtime"))) (PVar "name")) (EApp (EApp (EVar "runtimePropParamsIn") (EVar "runtime")) (EVar "name")))
(DFunDef false "runtimePropParams" ((PCons PWild (PVar "rest")) (PVar "name")) (EApp (EApp (EVar "runtimePropParams") (EVar "rest")) (EVar "name")))
(DTypeSig false "runtimePropParamsIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PropParam"))))))
(DFunDef false "runtimePropParamsIn" ((PList) PWild) (EVar "None"))
(DFunDef false "runtimePropParamsIn" ((PCons (PCon "DProp" PWild (PVar "name") (PVar "ps") PWild) PWild) (PVar "wanted")) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runtimePropParamsIn" ((PCons PWild (PVar "rest")) (PVar "wanted")) (EApp (EApp (EVar "runtimePropParamsIn") (EVar "rest")) (EVar "wanted")))
(DTypeSig false "propName" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "propName" ((PCon "DProp" PWild (PVar "name") PWild PWild)) (EVar "name"))
(DFunDef false "propName" (PWild) (ELit (LString "<invalid prop>")))
(DTypeSig false "planParameters" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planParameters" (PWild PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "planParameters" ((PVar "env") (PVar "property") (PCons (PCon "PropParam" (PVar "name") PWild (PVar "ty")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (EVar "property")) (EVar "name")) (EVar "ty")) (arm (PCon "Ok" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "planParameters") (EVar "env")) (EVar "property")) (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "acc")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "plannedRunnable" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyApp (TyCon "List") (TyCon "NativePlanOutcome"))))
(DFunDef false "plannedRunnable" ((PList)) (EListLit))
(DFunDef false "plannedRunnable" ((PCons (PAs "x" (PCon "NativeRunnable" PWild PWild PWild)) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "plannedRunnable") (EVar "rest"))))
(DFunDef false "plannedRunnable" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedRunnable") (EVar "rest")))
(DData Private "NativeFailure" () ((variant "NativeBuildFailure" (ConPos (TyCon "String"))) (variant "NativeRuntimeFailure" (ConPos (TyCon "String"))) (variant "NativeProtocolFailure" (ConPos (TyCon "String")))) ())
(DTypeSig false "nativePlannedFailure" (TyFun (TyCon "NativeFailure") (TyFun (TyCon "NativePlanOutcome") (TyCon "PropResult"))))
(DFunDef false "nativePlannedFailure" ((PVar "failure") (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild)) (EApp (EApp (EVar "nativeFailure") (EVar "failure")) (ETuple (EVar "d") (EVar "r"))))
(DFunDef false "nativePlannedFailure" ((PVar "failure") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<invalid prop>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "plannedResults" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "plannedResults" ((PList) PWild) (EListLit))
(DFunDef false "plannedResults" ((PCons (PCon "NativeCapability" (PVar "d") (PVar "r") (PVar "message")) (PVar "rest")) (PVar "rows")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propName") (EVar "d"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EVar "message")) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))) (EApp (EApp (EVar "plannedResults") (EVar "rest")) (EVar "rows"))))
(DFunDef false "plannedResults" ((PCons (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild) (PVar "rest")) (PVar "rows")) (EBinOp "::" (EApp (EApp (EApp (EVar "nativeRowFor") (EApp (EVar "propName") (EVar "d"))) (EVar "r")) (EVar "rows")) (EApp (EApp (EVar "plannedResults") (EVar "rest")) (EVar "rows"))))
(DTypeSig false "nativeRowFor" (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "PropResult")))))
(DFunDef false "nativeRowFor" (PWild (PVar "r") (PList)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propRequestName") (EVar "r"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (ELit (LString "native property runner: the compiled probe omitted this property result"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DFunDef false "nativeRowFor" ((PVar "name") (PVar "r") (PCons (PAs "row" (PCon "PropResult" PWild (PVar "rowName") PWild PWild PWild PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "rowName")) (EVar "row") (EApp (EApp (EApp (EVar "nativeRowFor") (EVar "name")) (EVar "r")) (EVar "rest"))))
(DTypeSig false "requestIndex" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "PropRequest"))))))
(DFunDef false "requestIndex" ((PList) (PVar "index")) (EApp (EVar "Ok") (EVar "index")))
(DFunDef false "requestIndex" ((PCons (PVar "r") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "propRequestName") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EApp (EVar "propRequestCases") (EVar "r")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "property request \"{name}\" has a non-positive case budget"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "index")) (EApp (EVar "Err") (ELit (LString "duplicate property request name \"{name}\""))) (EApp (EApp (EVar "requestIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "r")) (EVar "index"))))))))
(DTypeSig false "duplicateSelectedPropName" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "duplicateSelectedPropName" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "duplicateSelectedPropName" ((PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest")) (PVar "requests") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "requests")) (EApp (EVar "Some") (EVar "name")) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EVar "seen"))) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))
(DFunDef false "duplicateSelectedPropName" ((PCons PWild (PVar "rest")) (PVar "requests") (PVar "seen")) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EVar "seen")))
(DTypeSig false "nativeProtocolErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "nativeProtocolErrors" ((PVar "duplicate") (PVar "requests")) (EApp (EApp (EVar "map") (EApp (EVar "nativeProtocolError") (EVar "duplicate"))) (EVar "requests")))
(DTypeSig false "nativeProtocolError" (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyCon "PropResult"))))
(DFunDef false "nativeProtocolError" ((PVar "duplicate") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propRequestName") (EVar "r"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: ")) (EApp (EVar "display") (EVar "duplicate"))) (ELit (LString "")))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DTypeSig false "desugarProps" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugarProps" ((PVar "src")) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src"))))
(DTypeSig false "nativeFailureKind" (TyFun (TyCon "NativeFailure") (TyCon "PropFailureKind")))
(DFunDef false "nativeFailureKind" ((PCon "NativeBuildFailure" PWild)) (EVar "PropBuildError"))
(DFunDef false "nativeFailureKind" ((PCon "NativeRuntimeFailure" PWild)) (EVar "PropRuntimeError"))
(DFunDef false "nativeFailureKind" ((PCon "NativeProtocolFailure" PWild)) (EVar "PropProtocolError"))
(DTypeSig false "nativeFailureText" (TyFun (TyCon "NativeFailure") (TyCon "String")))
(DFunDef false "nativeFailureText" ((PCon "NativeBuildFailure" (PVar "text"))) (EVar "text"))
(DFunDef false "nativeFailureText" ((PCon "NativeRuntimeFailure" (PVar "text"))) (EVar "text"))
(DFunDef false "nativeFailureText" ((PCon "NativeProtocolFailure" (PVar "text"))) (EVar "text"))
(DTypeSig false "nativeFailure" (TyFun (TyCon "NativeFailure") (TyFun (TyTuple (TyCon "Decl") (TyCon "PropRequest")) (TyCon "PropResult"))))
(DFunDef false "nativeFailure" ((PVar "failure") (PTuple (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DFunDef false "nativeFailure" ((PVar "failure") (PTuple PWild (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<invalid prop>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DTypeSig false "nativeRenderedPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "nativeRenderedPlanned" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeRuntimeFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not create a scratch directory: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (EApp (EVar "mintNonce") (ELit LUnit))) (EVar "probeNamespacePrefixes")) (EVar "tsrc"))) (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runInTmpPlanned") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs")) (EVar "tmp")) (EVar "nonce"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmp"))) (DoExpr (EVar "rendered"))))))
(DTypeSig false "runInTmpPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "runInTmpPlanned" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs") (PVar "tmp") (PVar "nonce")) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "out") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (ELit (LString "prop_probe")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "scratchProbeManifest") (ELit (LString "medaka_native_props"))) (EVar "target")) (EApp (EVar "runtimeDependencyName") (EVar "nonce"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not create the scratch manifest: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "manifest")) () (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (ELit (LString "medaka.toml")))) (EVar "manifest")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not write the scratch manifest: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedProbeSource") (EVar "nonce")) (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not write the probe source: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRunPlanned") (EVar "target")) (EVar "entry")) (EVar "out")) (EVar "tmp")) (EVar "jobs")) (EVar "nonce")))))))))))
(DTypeSig false "buildAndRunPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "buildAndRunPlanned" ((PVar "target") (PVar "entry") (PVar "out") (PVar "tmp") (PVar "jobs") (PVar "nonce")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (DoLet false false (PVar "emitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka_emitter"))))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entry")) (EVar "out")) (EVar "tmp")) (EVar "False")) (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "BuildProbe")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not build ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EVar "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EListLit (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EVar "root")) (EBinOp "++" (ELit (LString "MEDAKA=")) (EVar "medaka")) (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EVar "emitter")) (EVar "out"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeRuntimeFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not run the compiled probe: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "stdout") (PVar "stderr"))) () (EBlock (DoLet false false (PVar "props") (EApp (EVar "plannedDeclRequests") (EVar "jobs"))) (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "splitNl") (EVar "stdout")))) (DoExpr (EIf (EApp (EApp (EVar "tagsInOrder") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "props"))) (EVar "chunks")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "stderr"))) (ELit (LInt 0))) (EVar "props"))) (EApp (EVar "Err") (EApp (EVar "NativeProtocolFailure") (ELit (LString "native property runner: the probe printed a forged or malformed transcript; no property result was trusted"))))))))))))))
(DTypeSig false "plannedDeclRequests" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest")))))
(DFunDef false "plannedDeclRequests" ((PList)) (EListLit))
(DFunDef false "plannedDeclRequests" ((PCons (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "d") (EVar "r")) (EApp (EVar "plannedDeclRequests") (EVar "rest"))))
(DFunDef false "plannedDeclRequests" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedDeclRequests") (EVar "rest")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "prop_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "stderr")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "stderr")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native property run ended (probe exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "first") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "first"))))) (ELit (LString ""))))))
(DData Private "TranscriptField" () ((variant "FieldMissing" (ConPos)) (variant "FieldIncomplete" (ConPos)) (variant "FieldMalformed" (ConPos)) (variant "FieldDecoded" (ConPos (TyCon "String")))) ())
(DTypeSig false "transcriptField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyCon "TranscriptField"))))
(DFunDef false "transcriptField" ((PVar "tag") (PVar "chunks")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "tag")) (EVar "chunks")) (arm (PCon "None") () (EVar "FieldMissing")) (arm (PCon "Some" (PCon "Chunk" PWild PWild (PCon "False"))) () (EVar "FieldIncomplete")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "lines") (PCon "True"))) () (EMatch (EApp (EVar "decodeValue") (EVar "lines")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "FieldDecoded") (EVar "text"))) (arm (PCon "None") () (EVar "FieldMalformed"))))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PVar "requests")) (EApp (EApp (EApp (EApp (EVar "renderIndexed") (EApp (EApp (EVar "indexNativeChunks") (EVar "chunks")) (EVar "omEmpty"))) (EVar "note")) (EVar "i")) (EVar "requests")))
(DTypeSig false "indexNativeChunks" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyApp (TyCon "OrdMap") (TyCon "Chunk")))))
(DFunDef false "indexNativeChunks" ((PList) (PVar "index")) (EVar "index"))
(DFunDef false "indexNativeChunks" ((PCons (PAs "chunk" (PCon "Chunk" (PVar "tag") PWild PWild)) (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "next") (EIf (EApp (EApp (EVar "omHasKey") (EVar "tag")) (EVar "index")) (EVar "index") (EApp (EApp (EApp (EVar "omInsert") (EVar "tag")) (EVar "chunk")) (EVar "index")))) (DoExpr (EApp (EApp (EVar "indexNativeChunks") (EVar "rest")) (EVar "next")))))
(DTypeSig false "renderIndexed" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "renderIndexed" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderIndexed" ((PVar "chunks") (PVar "note") (PVar "i") (PCons (PTuple PWild (PVar "request")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "classifyNativeFields") (EVar "chunks")) (EVar "note")) (EVar "request")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "renderIndexed") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "classifyNativeTranscript" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyCon "Int") (TyCon "PropResult"))))))
(DFunDef false "classifyNativeTranscript" ((PVar "chunks") (PVar "note") (PVar "request") (PVar "i")) (EApp (EApp (EApp (EApp (EVar "classifyNativeFields") (EApp (EApp (EVar "indexNativeChunks") (EVar "chunks")) (EVar "omEmpty"))) (EVar "note")) (EVar "request")) (EVar "i")))
(DTypeSig false "classifyNativeFields" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyCon "Int") (TyCon "PropResult"))))))
(DFunDef false "classifyNativeFields" ((PVar "chunks") (PVar "note") (PVar "request") (PVar "i")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "propRequestName") (EVar "request"))) (DoLet false false (PVar "seed") (EApp (EVar "propRequestSeed") (EVar "request"))) (DoLet false false (PVar "cases") (EApp (EVar "propRequestCases") (EVar "request"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "transcriptField") (EApp (EVar "seedTag") (EVar "i"))) (EVar "chunks")) (EApp (EApp (EVar "transcriptField") (EApp (EVar "boolTag") (EVar "i"))) (EVar "chunks")) (EApp (EApp (EVar "transcriptField") (EApp (EVar "detailTag") (EVar "i"))) (EVar "chunks"))) (arm (PTuple (PCon "FieldMalformed") PWild PWild) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed replay seed in native transcript"))) (EVar "request"))) (arm (PTuple PWild (PCon "FieldMalformed") PWild) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed result value in native transcript"))) (EVar "request"))) (arm (PTuple PWild PWild (PCon "FieldMalformed")) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed detail in native transcript"))) (EVar "request"))) (arm (PTuple (PCon "FieldDecoded" (PVar "seedText")) PWild PWild) ((GBool (EBinOp "/=" (EApp (EVar "toInt") (EVar "seedText")) (EApp (EVar "Some") (EVar "seed"))))) (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "invalid replay seed in native transcript"))) (EVar "request"))) (arm (PTuple PWild (PCon "FieldDecoded" (PVar "boolText")) PWild) ((GBool (EBinOp "&&" (EBinOp "/=" (EVar "boolText") (ELit (LString "True"))) (EBinOp "/=" (EVar "boolText") (ELit (LString "False")))))) (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "invalid result value in native transcript"))) (EVar "request"))) (arm (PTuple (PCon "FieldDecoded" PWild) (PCon "FieldDecoded" (PLit (LString "True"))) (PCon "FieldDecoded" (PVar "detail"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropPassedResult")) (EVar "None")) (EVar "detail")) (EVar "seed")) (EVar "cases"))) (arm (PTuple (PCon "FieldDecoded" PWild) (PCon "FieldDecoded" (PLit (LString "False"))) (PCon "FieldDecoded" (PVar "detail"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropFailedResult")) (EApp (EVar "Some") (EVar "PropLawFalse"))) (EVar "detail")) (EVar "seed")) (EVar "cases"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "note"))) (ELit (LString "; this property was not fully reported")))) (EVar "seed")) (EVar "cases")))))))
(DTypeSig false "probeNamespacePrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "probeNamespacePrefixes" () (EListLit (ELit (LString "__np_")) (ELit (LString "NpCore_")) (ELit (LString "NpRuntime_")) (ELit (LString "NpModule_")) (EVar "runtimeDependencyPrefix")))
(DTypeSig false "plannedProbeSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyCon "String"))))))))
(DFunDef false "plannedProbeSource" ((PVar "nonce") (PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs")) (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EVar "sharedGraph") (EVar "env")) (EVar "jobs"))) (DoLet false false (PVar "prefix") (EApp (EVar "genNodePrefix") (EVar "nonce"))) (DoExpr (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "plannedImports") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EListLit (EApp (EApp (EVar "probeTargetSource") (EVar "target")) (EVar "tsrc")) (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state : Ref Int"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state = "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".Ref 0"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state : Ref U64"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state = "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".Ref 0"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word n = ((n % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ") + "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ") % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word left right ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word left"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word right"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x_low = x % ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x_high = x / ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y_low = y % ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y_high = y / ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (ELit (LString "  let low = x_low * y_low")) (ELit (LString "  let cross = x_low * y_high + x_high * y_low")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word (low + (cross % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ") * "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ")"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "next _ ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let s = (!")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state * "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngMultiplier")))) (ELit (LString " + "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngIncrement")))) (ELit (LString ") % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state := s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let word = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word s"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h1 = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor word ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight word 16))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h2 = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word h1 "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngMixMultiplier1")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h3 = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor h2 ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight h2 13))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h4 = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word h3 "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngMixMultiplier2")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor h4 ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight h4 16))"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "int _ = "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EBinOp "-" (EVar "intMax") (EVar "intMin")) (ELit (LInt 1)))))) (ELit (LString " + "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "intMin")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "bool _ = "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 2 == 1"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose n ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let word = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "next ()"))) (ELit (LString "  if n <= 0 then 0 else word % n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char _ = "))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".optionOr ' ' ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".charFromCode (32 + "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 95))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string n = if n <= 0 then \"\" else "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".charToStr ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char ()) ++ "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string (n - 1)"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings _ [] = \"\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings _ (x :: []) = x"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings sep (x :: xs) = x ++ sep ++ "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings sep xs"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list arr = "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr 0"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr i = if i >= "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayLength arr then [] else arr[i] :: "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr (i + 1)"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each [] = []"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each (x :: xs) = xs :: "))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => x :: ys) ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each xs)"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f [] = []"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f (x :: xs) = "))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => ys :: xs) (f x) ++ "))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => x :: ys) ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f xs)"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "jobs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EApp (EVar "coreAlias") (EVar "nonce"))) (EVar "prefix")) (EVar "graph"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EApp (EVar "coreAlias") (EVar "nonce"))) (EVar "prefix")) (EVar "graph"))) (EListLit (ELit (LString "main =")))) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "jobs")) (ELit (LInt 0)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EVar "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))))
(DTypeSig false "coreAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "coreAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpCore_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "runtimeAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimeAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpRuntime_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "probeNameNonce" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "probeNameNonce" ((PVar "nonce")) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "-"))) (ELit (LString "_"))) (EVar "nonce")))
(DTypeSig false "generatedPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "generatedPrefix" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "__np_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))))
(DTypeSig false "generatedName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "generatedName" ((PVar "nonce") (PVar "stem")) (EBinOp "++" (EApp (EVar "generatedPrefix") (EVar "nonce")) (EVar "stem")))
(DTypeSig false "plannedImports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedImports" ((PVar "nonce") (PVar "modules") (PVar "graph")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "import core as ")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".runtime as "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ""))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "importLine") (EVar "nonce")) (EVar "modules"))) (EApp (EVar "omKeys") (EApp (EApp (EVar "graphImportOwners") (EVar "graph")) (EVar "omEmpty")))))))
(DTypeSig false "graphImportOwners" (TyFun (TyCon "NativeGraph") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "graphImportOwners" ((PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild) (PVar "owners")) (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))) (EVar "owners")))
(DTypeSig false "graphImportOwnersGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "graphImportOwnersGo" (PWild (PList) (PVar "owners")) (EVar "owners"))
(DFunDef false "graphImportOwnersGo" ((PVar "nodes") (PCons (PVar "word") (PVar "rest")) (PVar "owners")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" PWild (PVar "plan") PWild)) () (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EVar "rest")) (EApp (EApp (EVar "planImportOwner") (EVar "plan")) (EVar "owners")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EVar "rest")) (EVar "owners")))))
(DTypeSig false "planImportOwner" (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "planImportOwner" ((PCon "GNominal" (PCon "TypeKey" PWild (PCon "OriginModule" (PVar "owner"))) PWild) (PVar "owners")) (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (ELit LUnit)) (EVar "owners")))
(DFunDef false "planImportOwner" ((PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild)) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "carrier")) (EVar "owners")))
(DFunDef false "planImportOwner" (PWild (PVar "owners")) (EVar "owners"))
(DTypeSig false "carrierImportOwners" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "carrierImportOwners" ((PRec "TyCon" ((rf "tyConOrigin" (PCon "OriginModule" (PVar "owner")))) false) (PVar "owners")) (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (ELit LUnit)) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PRec "TyCon" () false) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyVar" PWild) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyApp" (PVar "left") (PVar "right")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "right")) (EApp (EApp (EVar "carrierImportOwners") (EVar "left")) (EVar "owners"))))
(DFunDef false "carrierImportOwners" ((PCon "TyFun" (PVar "left") (PVar "right")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "right")) (EApp (EApp (EVar "carrierImportOwners") (EVar "left")) (EVar "owners"))))
(DFunDef false "carrierImportOwners" ((PCon "TyTuple" (PVar "tys")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwnersMany") (EVar "tys")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyEffect" PWild PWild (PVar "ty")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyConstrained" PWild (PVar "ty")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyNamed" PWild (PVar "ty") PWild) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyQual" (PVar "ty") PWild PWild) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyRow" PWild PWild PWild) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyAuth" PWild PWild) (PVar "owners")) (EVar "owners"))
(DTypeSig false "carrierImportOwnersMany" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "carrierImportOwnersMany" ((PList) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwnersMany" ((PCons (PVar "ty") (PVar "rest")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwnersMany") (EVar "rest")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners"))))
(DTypeSig false "importLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "importLine" ((PVar "nonce") (PVar "modules") (PVar "owner")) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EVar "display") (EVar "owner"))) (ELit (LString " as "))) (EApp (EVar "display") (EVar "alias"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "moduleAlias" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "moduleAlias" ((PVar "nonce") (PVar "modules") (PVar "owner")) (EApp (EApp (EApp (EApp (EVar "moduleAliasGo") (EVar "nonce")) (EApp (EVar "dropLastPlanModule") (EVar "modules"))) (EVar "owner")) (ELit (LInt 0))))
(DTypeSig false "moduleAliasGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "moduleAliasGo" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "moduleAliasGo" ((PVar "nonce") (PCons (PCon "PlanModule" (PVar "name") PWild PWild) (PVar "rest")) (PVar "owner") (PVar "i")) (EIf (EBinOp "==" (EVar "name") (EVar "owner")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "NpModule_")) (EApp (EVar "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "moduleAliasGo") (EVar "nonce")) (EVar "rest")) (EVar "owner")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "dropLastPlanModule" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyCon "List") (TyCon "PlanModule"))))
(DFunDef false "dropLastPlanModule" ((PList)) (EListLit))
(DFunDef false "dropLastPlanModule" ((PList PWild)) (EListLit))
(DFunDef false "dropLastPlanModule" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastPlanModule") (EVar "xs"))))
(DTypeSig false "planSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "GenPlan") (TyCon "String")))))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GInt")) (ELit (LString "Int")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GBool")) (ELit (LString "Bool")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GFloat")) (ELit (LString "Float")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GChar")) (ELit (LString "Char")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GString")) (ELit (LString "String")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GUnit")) (ELit (LString "Unit")))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GList" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "List (")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GArray" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Array (")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GOption" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Option (")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Result (")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "err")))) (ELit (LString ") ("))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "ok")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GTuple" (PVar "plans"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules"))) (EVar "plans"))))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GNominal" (PVar "key") (PVar "plans"))) (EApp (EApp (EApp (EApp (EVar "nominalSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "key")) (EVar "plans")))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild))) (EApp (EApp (EApp (EVar "carrierSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "carrier")))
(DTypeSig false "effectfulPlanSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "GenPlan") (TyCon "String")))))
(DFunDef false "effectfulPlanSourceTy" ((PVar "nonce") (PVar "modules") (PVar "plan")) (EBinOp "++" (EBinOp "++" (ELit (LString "<Rand> ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ""))))
(DTypeSig false "carrierSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "Ty") (TyCon "String")))))
(DFunDef false "carrierSourceTy" ((PVar "nonce") (PVar "modules") (PVar "carrier")) (EApp (EVar "ppTy") (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (EApp (EApp (EVar "qualifyCarrierTy") (EVar "nonce")) (EVar "modules"))) (EVar "carrier")))))
(DTypeSig false "qualifyCarrierTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "qualifyCarrierTy" ((PVar "nonce") (PVar "modules") (PAs "ty" (PRec "TyCon" ((rf "tyConName" None) (rf "tyConOrigin" (PCon "OriginModule" (PVar "owner")))) false))) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (ETuple (EVariantUpdate "TyCon" (EVar "ty") ((fa "tyConName" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "tyConName"))) (ELit (LString "")))))) (EVar "True"))) (arm (PCon "None") () (ETuple (EVar "ty") (EVar "False")))))
(DFunDef false "qualifyCarrierTy" (PWild PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "nominalSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "nominalSourceTy" ((PVar "nonce") (PVar "modules") (PCon "TypeKey" (PVar "name") (PCon "OriginModule" (PVar "owner"))) (PVar "plans")) (EBlock (DoLet false false (PVar "head") (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "plans")) (ELit (LInt 0))) (EVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (ELam ((PVar "plan")) (EApp (EVar "paren") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan"))))) (EVar "plans"))))) (ELit (LString "")))))))
(DFunDef false "nominalSourceTy" (PWild PWild (PCon "TypeKey" (PVar "name") PWild) (PList)) (EVar "name"))
(DFunDef false "nominalSourceTy" ((PVar "nonce") (PVar "modules") (PCon "TypeKey" (PVar "name") PWild) (PVar "plans")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (ELam ((PVar "plan")) (EApp (EVar "paren") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan"))))) (EVar "plans"))))) (ELit (LString ""))))
(DTypeSig false "typeKeyName" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "typeKeyName" ((PCon "TypeKey" (PVar "name") PWild)) (EVar "name"))
(DTypeSig false "plannedPropLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedPropLines" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedPropLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PCons (PCon "NativeRunnable" (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "r") (PVar "plans")) (PVar "rest")) (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fnLines") (EVar "nonce")) (EVar "i")) (EVar "params")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedRunLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "params")) (EVar "plans")) (EApp (EVar "propRequestCases") (EVar "r")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedShrinkLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "params")) (EVar "plans"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "plannedPropLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "rest")) (EVar "i")))
(DData Private "NativeGraph" () ((variant "NativeGraph" (ConPos (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))) ())
(DData Private "GraphNode" () ((variant "GraphNode" (ConPos (TyCon "Int") (TyCon "GenPlan") (TyCon "Int")))) ())
(DTypeSig false "buildGraph" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "NativeGraph"))))
(DFunDef false "buildGraph" ((PVar "env") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "root")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "omEmpty")) (EListLit)) (ELit (LInt 0)))))
(DTypeSig false "sharedGraph" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyCon "NativeGraph"))))
(DFunDef false "sharedGraph" ((PVar "env") (PVar "jobs")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "jobs")) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "omEmpty")) (EListLit)) (ELit (LInt 0)))))
(DTypeSig false "sharedGraphGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "sharedGraphGo" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "sharedGraphGo" ((PVar "env") (PCons (PCon "NativeRunnable" PWild PWild (PVar "plans")) (PVar "rest")) (PVar "graph")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "sharedGraphPlans") (EVar "env")) (EVar "plans")) (EVar "graph"))))
(DFunDef false "sharedGraphGo" ((PVar "env") (PCons PWild (PVar "rest")) (PVar "graph")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "rest")) (EVar "graph")))
(DTypeSig false "sharedGraphPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "sharedGraphPlans" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "sharedGraphPlans" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "graph")) (EMatch (EApp (EApp (EVar "buildGraph") (EVar "env")) (EVar "plan")) (arm (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild) () (EApp (EApp (EApp (EVar "sharedGraphPlans") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))) (EVar "graph"))))))
(DTypeSig false "mergeGraphNodes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "mergeGraphNodes" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "mergeGraphNodes" ((PVar "fresh") (PCons (PVar "word") (PVar "rest")) (PAs "graph" (PCon "NativeGraph" (PVar "nodes") (PVar "order") (PVar "next")))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "fresh")) (arm (PCon "Some" (PCon "GraphNode" PWild (PVar "plan") (PVar "depth"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "nodes"))))) (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "fresh")) (EVar "rest")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "next")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EBinOp "::" (EVar "word") (EVar "order"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (arm PWild () (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "fresh")) (EVar "rest")) (EVar "graph")))))
(DTypeSig false "graphExplore" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphExplore" ((PVar "env") (PVar "plan") (PVar "depth") (PAs "graph" (PCon "NativeGraph" (PVar "nodes") (PVar "order") (PVar "next")))) (EBlock (DoLet false false (PVar "word") (EApp (EVar "genPlanWord") (EVar "plan"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild (PVar "oldDepth"))) () (EIf (EBinOp "<" (EVar "depth") (EVar "oldDepth")) (EApp (EApp (EApp (EApp (EVar "graphChildren") (EVar "env")) (EVar "plan")) (EVar "depth")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "ident")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EVar "order")) (EVar "next"))) (EVar "graph"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "graphChildren") (EVar "env")) (EVar "plan")) (EVar "depth")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "next")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EBinOp "::" (EVar "word") (EVar "order"))) (EBinOp "+" (EVar "next") (ELit (LInt 1))))))))))
(DTypeSig false "graphChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphChildren" (PWild (PCon "GInt") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GBool") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GFloat") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GChar") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GString") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GUnit") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GCustom" (PVar "custom")) (PVar "depth") (PVar "graph")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EVar "graph") (EMatch (EApp (EApp (EVar "customStructuralPlan") (EVar "env")) (EVar "custom")) (arm (PCon "None") () (EVar "graph")) (arm (PCon "Some" (PAs "plan" (PCon "GNominal" (PVar "key") PWild))) () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDisplayCtorChildren") (EVar "env")) (EVar "plan")) (EVar "ctors")) (EVar "depth")) (EVar "graph")) (EVar "graph"))) (arm (PCon "Err" PWild) () (EVar "graph")))) (arm (PCon "Some" PWild) () (EVar "graph")))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GList" (PVar "p")) (PVar "depth") (PVar "graph")) (EIf (EBinOp "<=" (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "depth")) (EVar "p")) (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GArray" (PVar "p")) (PVar "depth") (PVar "graph")) (EIf (EBinOp "<=" (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "depth")) (EVar "p")) (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GOption" (PVar "p")) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (EVar "depth")) (EVar "p")) (arm (PList PWild (PVar "someWeight")) () (EIf (EBinOp "<=" (EVar "someWeight") (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph")))) (arm PWild () (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "ok")) (arm (PList (PVar "errWeight") (PVar "okWeight")) () (EBlock (DoLet false false (PVar "withErr") (EIf (EBinOp "<=" (EVar "errWeight") (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "err")) (EVar "depth")) (EVar "graph")))) (DoExpr (EIf (EBinOp "<=" (EVar "okWeight") (ELit (LInt 0))) (EVar "withErr") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "ok")) (EVar "depth")) (EVar "withErr")))))) (arm PWild () (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GTuple" (PVar "ps")) (PVar "depth") (PVar "graph")) (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EVar "ps")) (EVar "depth")) (EVar "graph")))
(DFunDef false "graphChildren" ((PVar "env") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChildren") (EVar "env")) (EVar "plan")) (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "plan")) (EVar "depth"))) (EVar "depth")) (EVar "graph")) (EVar "graph")))))
(DTypeSig false "nominalCtorsVisible" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PlanVisibility") (TyCon "Bool")))))
(DFunDef false "nominalCtorsVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanAbstract")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DFunDef false "nominalCtorsVisible" (PWild PWild (PCon "PlanPublicCtors")) (EVar "True"))
(DFunDef false "nominalCtorsVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanLocal")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DTypeSig false "customStructuralPlan" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "CustomPlan") (TyApp (TyCon "Option") (TyCon "GenPlan")))))
(DFunDef false "customStructuralPlan" ((PVar "env") (PCon "CustomPlan" (PVar "key") (PVar "carrier") PWild)) (EApp (EApp (EVar "map") (EApp (EVar "GNominal") (EVar "key"))) (EApp (EApp (EVar "customPlanArgs") (EVar "env")) (EApp (EVar "carrierArgs") (EVar "carrier")))))
(DTypeSig false "carrierArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "carrierArgs" ((PCon "TyApp" (PVar "head") (PVar "arg"))) (EBinOp "++" (EApp (EVar "carrierArgs") (EVar "head")) (EListLit (EVar "arg"))))
(DFunDef false "carrierArgs" (PWild) (EListLit))
(DTypeSig false "customPlanArgs" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "customPlanArgs" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "customPlanArgs" ((PVar "env") (PCons (PVar "ty") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (ELit (LString "custom display"))) (ELit (LString "value"))) (EVar "ty")) (EApp (EApp (EVar "customPlanArgs") (EVar "env")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Some" (PVar "plans"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm PWild () (EVar "None"))))
(DTypeSig false "graphExploreMany" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphExploreMany" (PWild (PList) PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphExploreMany" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "depth") (PVar "graph")) (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EVar "rest")) (EVar "depth")) (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "plan")) (EVar "depth")) (EVar "graph"))))
(DTypeSig false "graphCtorChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))))
(DFunDef false "graphCtorChildren" (PWild PWild (PList) PWild PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphCtorChildren" ((PVar "env") (PVar "plan") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "depth") (PVar "graph")) (EBlock (DoLet false false (PVar "next") (EIf (EBinOp "<=" (EVar "weight") (ELit (LInt 0))) (EVar "graph") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "fields"))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "graph")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChildren") (EVar "env")) (EVar "plan")) (EVar "rest")) (EVar "weights")) (EVar "depth")) (EVar "next")))))
(DFunDef false "graphCtorChildren" (PWild PWild PWild PWild PWild (PVar "graph")) (EVar "graph"))
(DTypeSig false "graphDisplayCtorChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))))
(DFunDef false "graphDisplayCtorChildren" (PWild PWild (PList) PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphDisplayCtorChildren" ((PVar "env") (PVar "plan") (PCons (PVar "ctor") (PVar "rest")) (PVar "depth") (PVar "graph")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "fields"))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "graph"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "graphDisplayCtorChildren") (EVar "env")) (EVar "plan")) (EVar "rest")) (EVar "depth")) (EVar "next")))))
(DTypeSig false "genPlanWord" (TyFun (TyCon "GenPlan") (TyCon "String")))
(DFunDef false "genPlanWord" ((PCon "GInt")) (ELit (LString "int")))
(DFunDef false "genPlanWord" ((PCon "GBool")) (ELit (LString "bool")))
(DFunDef false "genPlanWord" ((PCon "GFloat")) (ELit (LString "float")))
(DFunDef false "genPlanWord" ((PCon "GChar")) (ELit (LString "char")))
(DFunDef false "genPlanWord" ((PCon "GString")) (ELit (LString "string")))
(DFunDef false "genPlanWord" ((PCon "GUnit")) (ELit (LString "unit")))
(DFunDef false "genPlanWord" ((PCon "GList" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "list(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GArray" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "array(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GOption" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "option(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "result(")) (EApp (EVar "display") (EApp (EVar "genPlanWord") (EVar "err")))) (ELit (LString ","))) (EApp (EVar "display") (EApp (EVar "genPlanWord") (EVar "ok")))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GTuple" (PVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "tuple(")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "genPlanWord")) (EVar "ps")))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GNominal" (PVar "key") (PVar "ps"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "nominal(")) (EApp (EVar "display") (EApp (EVar "typeKeyWord") (EVar "key")))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "genPlanWord")) (EVar "ps"))))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GCustom" (PCon "CustomPlan" PWild PWild (PVar "route")))) (EBinOp "++" (EBinOp "++" (ELit (LString "custom(")) (EVar "route")) (ELit (LString ")"))))
(DTypeSig false "genNodePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "genNodePrefix" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "gen"))))
(DTypeSig false "graphNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "graphNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString "_node_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "graphRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "depth")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "depth"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "panic \"native property runner: missing closed generator plan\"")))))
(DTypeSig false "graphLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))))
(DTypeSig false "graphLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "graphLinesGo" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphLinesGo" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PVar "nodes") (PCons (PVar "word") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") (PVar "plan") PWild)) () (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : Int -> "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "effectfulPlanSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " depth = "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "nodes")) (EListLit)) (ELit (LInt 0)))) (EVar "prefix")) (EVar "plan")))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))))))
(DTypeSig false "graphDraw" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))
(DFunDef false "graphDraw" (PWild PWild (PVar "graph") (PVar "prefix") (PVar "plan")) (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "depth"))))
(DTypeSig false "graphCtorDraw" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))
(DFunDef false "graphCtorDraw" (PWild PWild (PVar "graph") (PVar "prefix") (PVar "plan")) (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "(depth + 1)"))))
(DTypeSig false "graphNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GInt")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "int ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GBool")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "bool ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GFloat")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".intToFloat ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 2000001) * (1.0 / 1000000.0) - 1.0"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GChar")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GString")) (EApp (EApp (EVar "stringExpr") (EVar "nonce")) (ELit (LInt 0))))
(DFunDef false "graphNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GUnit")) (ELit (LString "()")))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild (PVar "core") PWild PWild (PCon "GCustom" PWild)) (EApp (EApp (EVar "customDrawExpr") (EVar "nonce")) (EVar "core")))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepth") (EVar "nonce")) (ELit (LString "["))) (ELit (LString "]"))) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepth") (EVar "nonce")) (ELit (LString "[|"))) (ELit (LString "|]"))) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "renderOptionByDepth") (EVar "nonce")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderResultByDepth") (EVar "nonce")) (EVar "env")) (EVar "err")) (EVar "ok")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "err"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "ok"))))
(DFunDef false "graphNodeBody" (PWild (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix"))) (EVar "ps"))))) (ELit (LString ")"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (ELit (LString "panic \"native property runner: missing planned constructor\""))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorByDepth") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (ELit (LString "panic \"native property runner: inaccessible constructor\""))))))
(DTypeSig false "byDepth" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "byDepth" ((PVar "below") (PVar "atBound")) (EIf (EBinOp "==" (EVar "below") (EVar "atBound")) (EVar "below") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if depth < ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "maxGenDepth")))) (ELit (LString " then "))) (EApp (EVar "display") (EVar "below"))) (ELit (LString " else "))) (EApp (EVar "display") (EVar "atBound"))) (ELit (LString "")))))
(DTypeSig false "graphCtorByDepth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "String"))))))))))
(DFunDef false "graphCtorByDepth" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "ctors")) (EBlock (DoLet false false (PVar "choice") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoice") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors"))) (DoExpr (EApp (EApp (EVar "byDepth") (EApp (EVar "choice") (EApp (EApp (EVar "softCtorWeights") (EVar "env")) (EVar "plan")))) (EApp (EVar "choice") (EApp (EApp (EVar "map") (EVar "SoftFixed")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "plan")) (EVar "maxGenDepth"))))))))
(DTypeSig false "softWeightPositive" (TyFun (TyCon "SoftWeight") (TyCon "Bool")))
(DFunDef false "softWeightPositive" ((PCon "SoftNever")) (EVar "False"))
(DFunDef false "softWeightPositive" ((PCon "SoftFixed" (PVar "weight"))) (EBinOp ">" (EVar "weight") (ELit (LInt 0))))
(DFunDef false "softWeightPositive" ((PCon "SoftDecaying" PWild)) (EVar "True"))
(DTypeSig false "anySoftWeightPositive" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "Bool")))
(DFunDef false "anySoftWeightPositive" ((PList)) (EVar "False"))
(DFunDef false "anySoftWeightPositive" ((PCons (PVar "weight") (PVar "rest"))) (EBinOp "||" (EApp (EVar "softWeightPositive") (EVar "weight")) (EApp (EVar "anySoftWeightPositive") (EVar "rest"))))
(DTypeSig false "softWeightExpr" (TyFun (TyCon "SoftWeight") (TyCon "String")))
(DFunDef false "softWeightExpr" ((PCon "SoftNever")) (ELit (LString "0")))
(DFunDef false "softWeightExpr" ((PCon "SoftFixed" (PVar "weight"))) (EApp (EVar "intToString") (EVar "weight")))
(DFunDef false "softWeightExpr" ((PCon "SoftDecaying" (PVar "start"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(if depth >= ")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "start") (ELit (LInt 1)))))) (ELit (LString " then 1 else "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "start")))) (ELit (LString " - depth)"))))
(DTypeSig false "softWeightTotal" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "String")))
(DFunDef false "softWeightTotal" ((PVar "weights")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "weights")) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "softWeightTotalGo" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "softWeightTotalGo" ((PList) (PVar "fixed") (PList)) (EApp (EVar "intToString") (EVar "fixed")))
(DFunDef false "softWeightTotalGo" ((PList) (PLit (LInt 0)) (PVar "decaying")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " + "))) (EVar "decaying")))) (ELit (LString ")"))))
(DFunDef false "softWeightTotalGo" ((PList) (PVar "fixed") (PVar "decaying")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fixed")))) (ELit (LString " + "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " + "))) (EVar "decaying")))) (ELit (LString ")"))))
(DFunDef false "softWeightTotalGo" ((PCons (PCon "SoftNever") (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EVar "fixed")) (EVar "decaying")))
(DFunDef false "softWeightTotalGo" ((PCons (PCon "SoftFixed" (PVar "weight")) (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EBinOp "+" (EVar "fixed") (EVar "weight"))) (EVar "decaying")))
(DFunDef false "softWeightTotalGo" ((PCons (PAs "weight" (PCon "SoftDecaying" PWild)) (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EVar "fixed")) (EBinOp "::" (EApp (EVar "softWeightExpr") (EVar "weight")) (EVar "decaying"))))
(DTypeSig false "graphCtorChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "String")))))))))))
(DFunDef false "graphCtorChoice" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DFunDef false "graphCtorChoice" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "ctors") (PVar "weights")) (EIf (EApp (EVar "not") (EApp (EVar "anySoftWeightPositive") (EVar "weights"))) (ELit (LString "panic \"native property runner: no finite constructor\"")) (EBlock (DoLet false false (PVar "picked") (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "ctor_choice")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(let ")) (EApp (EVar "display") (EVar "picked"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EVar "display") (EApp (EVar "softWeightTotal") (EVar "weights")))) (ELit (LString " in "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EVar "weights")) (EVar "picked")))) (ELit (LString ")")))))))
(DTypeSig false "graphCtorChoiceAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyFun (TyCon "String") (TyCon "String"))))))))))))
(DFunDef false "graphCtorChoiceAt" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DFunDef false "graphCtorChoiceAt" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "picked")) (EIf (EApp (EVar "not") (EApp (EVar "softWeightPositive") (EVar "weight"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "rest")) (EVar "weights")) (EVar "picked")) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorValue") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctor"))) (DoLet false false (PVar "tail") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "rest")) (EVar "weights")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "picked"))) (ELit (LString " - "))) (EApp (EVar "display") (EApp (EVar "softWeightExpr") (EVar "weight")))) (ELit (LString ")"))))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "anySoftWeightPositive") (EVar "weights"))) (EVar "here") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "picked"))) (ELit (LString " < "))) (EApp (EVar "display") (EApp (EVar "softWeightExpr") (EVar "weight")))) (ELit (LString " then "))) (EApp (EVar "display") (EVar "here"))) (ELit (LString " else "))) (EApp (EVar "display") (EVar "tail"))) (ELit (LString ""))))))))
(DFunDef false "graphCtorChoiceAt" (PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DTypeSig false "graphCtorValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "PlanCtor") (TyCon "String"))))))))))
(DFunDef false "graphCtorValue" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "panic \"native property runner: invalid constructor plan\""))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "graphCtorDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoExpr (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EVar "ref") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "paren")) (EVar "values"))))) (ELit (LString ""))))))))))
(DTypeSig false "renderOptionChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "renderOptionChoice" ((PVar "nonce") (PList (PVar "noneWeight") (PVar "someWeight")) (PVar "child")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EVar "display") (EBinOp "+" (EVar "noneWeight") (EVar "someWeight")))) (ELit (LString " < "))) (EApp (EVar "display") (EVar "noneWeight"))) (ELit (LString " then None else Some ("))) (EApp (EVar "display") (EVar "child"))) (ELit (LString ")"))))
(DFunDef false "renderOptionChoice" (PWild PWild (PVar "child")) (EBinOp "++" (EBinOp "++" (ELit (LString "Some (")) (EApp (EVar "display") (EVar "child"))) (ELit (LString ")"))))
(DTypeSig false "renderOptionByDepth" (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderOptionByDepth" ((PVar "nonce") (PVar "env") (PVar "p") (PVar "child")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EVar "renderOptionChoice") (EVar "nonce")) (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (ELit (LInt 0))) (EVar "p"))) (EVar "child"))) (EApp (EApp (EApp (EVar "renderOptionChoice") (EVar "nonce")) (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (EVar "maxGenDepth")) (EVar "p"))) (EVar "child"))))
(DTypeSig false "renderResultChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderResultChoice" ((PVar "nonce") (PList (PVar "errWeight") (PVar "okWeight")) (PVar "error") (PVar "ok")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EVar "display") (EBinOp "+" (EVar "errWeight") (EVar "okWeight")))) (ELit (LString " < "))) (EApp (EVar "display") (EVar "errWeight"))) (ELit (LString " then Err ("))) (EApp (EVar "display") (EVar "error"))) (ELit (LString ") else Ok ("))) (EApp (EVar "display") (EVar "ok"))) (ELit (LString ")"))))
(DFunDef false "renderResultChoice" (PWild PWild (PVar "error") PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "Err (")) (EApp (EVar "display") (EVar "error"))) (ELit (LString ")"))))
(DTypeSig false "renderResultByDepth" (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderResultByDepth" ((PVar "nonce") (PVar "env") (PVar "err") (PVar "ok") (PVar "error") (PVar "okExpr")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EApp (EVar "renderResultChoice") (EVar "nonce")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (ELit (LInt 0))) (EVar "err")) (EVar "ok"))) (EVar "error")) (EVar "okExpr"))) (EApp (EApp (EApp (EApp (EVar "renderResultChoice") (EVar "nonce")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (EVar "maxGenDepth")) (EVar "err")) (EVar "ok"))) (EVar "error")) (EVar "okExpr"))))
(DTypeSig false "customDrawExpr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "customDrawExpr" ((PVar "nonce") (PVar "core")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  let caller = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()\n  let _ = "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState (!"))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state)\n  let x = "))) (EApp (EVar "display") (EVar "core"))) (ELit (LString ".arbitrary ()\n  let next = "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()\n  let _ = "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state := next\n  let _ = "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState caller\n  x"))))
(DTypeSig false "stringExpr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "stringExpr" ((PVar "nonce") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose (if depth >= "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "maxGenDepth")))) (ELit (LString " then 1 else 11))"))))
(DTypeSig false "renderListByDepth" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListByDepth" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "env") (PVar "p") (PVar "child")) (EIf (EApp (EApp (EVar "listBoundDecays") (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoiceN") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EVar "listLenMax")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(if depth >= ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "listLenMax")))) (ELit (LString " then 1 else "))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "listLenMax") (ELit (LInt 1)))))) (ELit (LString " - depth)")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepthFlat") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "env")) (EVar "p")) (EVar "child"))))
(DTypeSig false "renderListByDepthFlat" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListByDepthFlat" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "env") (PVar "p") (PVar "child")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoice") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (ELit (LInt 0))) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoice") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "maxGenDepth")) (EVar "p")))))
(DTypeSig false "renderListChoice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "renderListChoice" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "child") (PVar "bound")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoiceN") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (EApp (EVar "intToString") (EBinOp "+" (EVar "bound") (ELit (LInt 1))))))
(DTypeSig false "renderListChoiceN" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListChoiceN" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "count")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EVar "display") (EVar "count"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EVar "renderListArms") (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (ELit (LInt 0))))) (ELit (LString ""))))
(DTypeSig false "renderListArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "renderListArms" ((PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "n")) (EIf (EBinOp ">" (EVar "n") (EVar "bound")) (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderListArms" ((PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "n") (EVar "bound")) (ELit (LString "_")) (EApp (EVar "intToString") (EVar "n"))))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "open"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "repeatString") (EVar "child")) (EVar "n"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "close"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EVar "renderListArms") (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (ELit (LString ""))))
(DTypeSig false "repeatString" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatString" (PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "repeatString" ((PVar "x") (PVar "n")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "repeatString") (EVar "x")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "qualifiedCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "qualifiedCtor" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "ctor"))))
(DTypeSig false "hasNamedField" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyCon "Bool")))
(DFunDef false "hasNamedField" ((PList)) (EVar "False"))
(DFunDef false "hasNamedField" ((PCons (PTuple (PCon "Some" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "hasNamedField" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasNamedField") (EVar "rest")))
(DTypeSig false "namedAssignments" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "namedAssignments" ((PList) PWild) (EListLit))
(DFunDef false "namedAssignments" (PWild (PList)) (EListLit))
(DFunDef false "namedAssignments" ((PCons (PTuple (PCon "Some" (PVar "name")) PWild) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "value"))) (ELit (LString ""))) (EApp (EApp (EVar "namedAssignments") (EVar "rest")) (EVar "values"))))
(DFunDef false "namedAssignments" ((PCons (PTuple (PCon "None") PWild) (PVar "rest")) (PCons PWild (PVar "values"))) (EApp (EApp (EVar "namedAssignments") (EVar "rest")) (EVar "values")))
(DTypeSig false "paren" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "paren" ((PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ")"))))
(DTypeSig false "shrinkNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "shrinkNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString "_shrink_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "displayNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "displayNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString "_display_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "graphShrinkRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphShrinkRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "[]")))))
(DTypeSig false "graphDisplayRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphDisplayRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "\"<unavailable>\"")))))
(DTypeSig false "graphAuxLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphAuxLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))))
(DTypeSig false "graphAuxLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "graphAuxLinesGo" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphAuxLinesGo" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PVar "nodes") (PCons (PVar "word") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") (PVar "plan") PWild)) () (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "NativeGraph") (EVar "nodes")) (EListLit)) (ELit (LInt 0)))) (DoExpr (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString " -> List ("))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " value = "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "value"))))) (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString " -> String"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " value = "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "displayNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "value"))))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))))))))
(DTypeSig false "candidateNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GInt") (PVar "name")) (EApp (EVar "nativeIntCandidates") (EVar "name")))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GBool") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " then [False] else []"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GFloat") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " == 0.0 then [] else [0.0, "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " / 2.0]"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GChar") PWild) (ELit (LString "[]")))
(DFunDef false "candidateNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GString") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " == \"\" then [] else ["))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".stringSlice 0 ("))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".stringLength "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " / 2) "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "]"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GUnit") PWild) (ELit (LString "[]")))
(DFunDef false "candidateNodeBody" (PWild PWild PWild (PVar "core") PWild PWild (PCon "GCustom" PWild) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "core"))) (ELit (LString ".shrink "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GList") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GArray") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GOption") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PAs "result" (PCon "GResult" (PVar "err") (PVar "ok"))) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "err")) (EVar "ok")) (EVar "name")) (EApp (EVar "shrinkActions") (EVar "result"))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ps")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GTuple") (EVar "ps")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidates") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name")))
(DTypeSig false "displayNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GInt") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".intToString "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild PWild PWild (PCon "GBool") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " then \"True\" else \"False\""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GFloat") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GChar") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GString") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild PWild PWild (PCon "GUnit") PWild) (ELit (LString "\"()\"")))
(DFunDef false "displayNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PCon "GCustom" (PAs "custom" (PCon "CustomPlan" (PVar "key") PWild PWild))) (PVar "name")) (EMatch (EApp (EApp (EVar "customStructuralPlan") (EVar "env")) (EVar "custom")) (arm (PCon "Some" (PVar "plan")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplay") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name"))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "\"<")) (EApp (EVar "display") (EApp (EVar "typeKeyName") (EVar "key")))) (ELit (LString ">\""))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"[\" ++ ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings \", \" ("))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (x => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString ") "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ") ++ \"]\""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"[|\" ++ ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings \", \" ("))) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (x => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString ") ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ")) ++ \"|]\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  None => \"None\"\n  Some x => \"Some (\" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString " ++ \")\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  Err x => \"Err (\" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "err")) (ELit (LString "x"))))) (ELit (LString " ++ \")\"\n  Ok x => \"Ok (\" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "ok")) (ELit (LString "x"))))) (ELit (LString " ++ \")\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps")) (PVar "name")) (EBlock (DoLet false false (PVar "vars") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "ps")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "vars")))) (ELit (LString ") => \"(\" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplays") (EVar "graph")) (EVar "prefix")) (EVar "ps")) (EVar "vars")))) (ELit (LString " ++ \")\""))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplay") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name")))
(DTypeSig false "nativeIntCandidates" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nativeIntCandidates" ((PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " == 0 then [] else ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "nativeIntStep") (EVar "name"))) (EVar "intShrinkSteps"))))) (ELit (LString "]"))))
(DTypeSig false "nativeIntStep" (TyFun (TyCon "String") (TyFun (TyCon "IntShrinkStep") (TyCon "String"))))
(DFunDef false "nativeIntStep" (PWild (PCon "IntToZero")) (ELit (LString "0")))
(DFunDef false "nativeIntStep" ((PVar "name") (PCon "IntHalf")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " / 2"))))
(DFunDef false "nativeIntStep" ((PVar "name") (PCon "IntTowardZero")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " + (if "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " > 0 then -1 else 1)"))))
(DTypeSig false "joinCandidateFamilies" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCandidateFamilies" ((PList)) (ELit (LString "[]")))
(DFunDef false "joinCandidateFamilies" ((PList (PVar "family"))) (EVar "family"))
(DFunDef false "joinCandidateFamilies" ((PCons (PVar "family") (PVar "families"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "family"))) (ELit (LString " ++ "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EVar "families")))) (ELit (LString ""))))
(DTypeSig false "graphListCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphListCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DTypeSig false "graphListCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphListCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "DeleteElements") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each (x => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ") "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions")))
(DTypeSig false "graphArrayCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphArrayCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DTypeSig false "graphArrayCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphArrayCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "DeleteElements") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayFromList ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "))"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayFromList ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each (x => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ") ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "))"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions")))
(DTypeSig false "graphOptionCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphOptionCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  None => []\n  Some x => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))) (ELit (LString ""))))
(DTypeSig false "graphOptionCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "graphOptionCandidateFamilies" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons (PCon "ReplaceEarlierNullary") (PVar "actions"))) (EBinOp "::" (ELit (LString "[None]")) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map Some ("))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ")"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions")))
(DTypeSig false "graphResultCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))
(DFunDef false "graphResultCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "err") (PVar "ok") (PVar "name") (PVar "actions")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  Err x => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "err")) (ELit (LString "Err"))) (EVar "actions"))))) (ELit (LString "\n  Ok x => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ok")) (ELit (LString "Ok"))) (EVar "actions"))))) (ELit (LString ""))))
(DTypeSig false "graphResultCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphResultCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphResultCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "tag") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "tag")) (EVar "actions"))))
(DFunDef false "graphResultCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "tag") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "tag")) (EVar "actions")))
(DTypeSig false "graphTupleCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphTupleCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "name") (PVar "actions")) (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "plans")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n  ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "values")))) (ELit (LString ") => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values")) (EVar "values")) (EVar "actions")))) (ELit (LString ""))))))
(DTypeSig false "graphTupleCandidatesByActions" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))
(DFunDef false "graphTupleCandidatesByActions" (PWild PWild PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphTupleCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "all") (PVar "values") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidateLists") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "all")) (EVar "values")) (ELit (LInt 0))))) (ELit (LString " ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "all")) (EVar "values")) (EVar "actions")))) (ELit (LString ""))))
(DFunDef false "graphTupleCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "all") (PVar "values") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "all")) (EVar "values")) (EVar "actions")))
(DTypeSig false "graphTupleCandidateLists" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") PWild PWild (PList) PWild PWild PWild) (ELit (LString "[]")))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PVar "all") (PCons (PVar "value") (PVar "values")) (PVar "index")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (candidate => ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EApp (EVar "replaceName") (EVar "index")) (ELit (LString "candidate"))) (EVar "all"))))) (ELit (LString ")) ("))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ") ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidateLists") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "all")) (EVar "values")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") PWild PWild PWild PWild PWild PWild) (ELit (LString "[]")))
(DTypeSig false "graphNominalCandidates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "graphNominalCandidates" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "key") (PVar "name")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (ELit (LString "[]"))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArms") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EVar "None"))))) (ELit (LString ""))) (ELit (LString "[]"))))))
(DTypeSig false "graphNominalCandidateArms" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyApp (TyCon "List") (TyCon "String"))))))))))))
(DFunDef false "graphNominalCandidateArms" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "graphNominalCandidateArms" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PCons (PVar "ctor") (PVar "ctors")) (PVar "earlier")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArm") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "earlier")) (EVar "ctor")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArms") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EApp (EApp (EVar "nextEarlierNullary") (EVar "earlier")) (EVar "ctor")))))
(DTypeSig false "nextEarlierNullary" (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyCon "PlanCtor") (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "nextEarlierNullary" ((PCon "None") (PAs "ctor" (PCon "PlanCtor" PWild PWild (PList)))) (EApp (EVar "Some") (EVar "ctor")))
(DFunDef false "nextEarlierNullary" ((PVar "earlier") (PCon "PlanCtor" PWild PWild (PList))) (EVar "earlier"))
(DFunDef false "nextEarlierNullary" ((PVar "earlier") PWild) (EVar "earlier"))
(DTypeSig false "graphNominalCandidateArm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyCon "PlanCtor") (TyCon "String")))))))))))
(DFunDef false "graphNominalCandidateArm" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "earlier") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "  _ => []"))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoLet false false (PVar "replacements") (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalReplacementByActions") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")) (EApp (EVar "shrinkActions") (EVar "plan")))) (DoExpr (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " } => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "fields")) (EVar "fields")) (EVar "values")) (EVar "values")) (EVar "True")) (ELit (LInt 0))) (EApp (EVar "shrinkActions") (EVar "plan"))))))) (ELit (LString ""))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "values")))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "fields")) (EVar "fields")) (EVar "values")) (EVar "values")) (EVar "False")) (ELit (LInt 0))) (EApp (EVar "shrinkActions") (EVar "plan"))))))) (ELit (LString ""))))))))))
(DTypeSig false "graphNominalReplacementByActions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))
(DFunDef false "graphNominalReplacementByActions" (PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphNominalReplacementByActions" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "earlier") (PCons (PCon "ReplaceEarlierNullary") PWild)) (EApp (EApp (EApp (EApp (EVar "graphNominalReplacement") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")))
(DFunDef false "graphNominalReplacementByActions" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "earlier") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalReplacementByActions") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")) (EVar "actions")))
(DTypeSig false "graphNominalReplacement" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyCon "String"))))))
(DFunDef false "graphNominalReplacement" (PWild PWild PWild (PCon "None")) (ELit (LString "[]")))
(DFunDef false "graphNominalReplacement" ((PVar "nonce") (PVar "modules") (PVar "owner") (PCon "Some" (PCon "PlanCtor" (PVar "source") PWild (PList)))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source")))) (ELit (LString "]"))))
(DFunDef false "graphNominalReplacement" (PWild PWild PWild (PCon "Some" PWild)) (ELit (LString "[]")))
(DTypeSig false "graphNominalFieldCandidatesByActions" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))))))
(DFunDef false "graphNominalFieldCandidatesByActions" (PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphNominalFieldCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PVar "fields") (PVar "allValues") (PVar "values") (PVar "named") (PVar "index") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EVar "index")))) (ELit (LString " ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EVar "index")) (EVar "actions")))) (ELit (LString ""))))
(DFunDef false "graphNominalFieldCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PVar "fields") (PVar "allValues") (PVar "values") (PVar "named") (PVar "index") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EVar "index")) (EVar "actions")))
(DTypeSig false "graphNominalFieldCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyCon "String"))))))))))))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") PWild PWild PWild PWild (PList) PWild PWild PWild PWild) (ELit (LString "[]")))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PCons (PTuple PWild (PVar "plan")) (PVar "rest")) (PVar "allValues") (PCons (PVar "value") (PVar "values")) (PVar "named") (PVar "index")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (candidate => "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "rebuildCtor") (EVar "ref")) (EVar "all")) (EApp (EApp (EApp (EVar "replaceName") (EVar "index")) (ELit (LString "candidate"))) (EVar "allValues"))) (EVar "named")))) (ELit (LString ") ("))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ") ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "all")) (EVar "rest")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") PWild PWild PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "[]")))
(DTypeSig false "graphJoinDisplays" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphJoinDisplays" (PWild PWild (PList) PWild) (ELit (LString "\"\"")))
(DFunDef false "graphJoinDisplays" ((PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")) (EApp (EApp (EApp (EApp (EVar "graphJoinDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values"))))
(DFunDef false "graphJoinDisplays" (PWild PWild PWild PWild) (ELit (LString "\"\"")))
(DTypeSig false "graphJoinDisplaysTail" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphJoinDisplaysTail" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphJoinDisplaysTail" ((PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \", \" ++ ")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphJoinDisplaysTail" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "graphNominalDisplay" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "graphNominalDisplay" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PCon "TypeKey" (PVar "typeName") (PVar "origin")) (PVar "name")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EApp (EApp (EVar "TypeKey") (EVar "typeName")) (EVar "origin"))) (arm (PCon "Err" PWild) () (ELit (LString "\"<unavailable>\""))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplayArm") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner"))) (EVar "ctors"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"<")) (EApp (EVar "display") (EVar "typeName"))) (ELit (LString ">\"")))))))
(DTypeSig false "graphNominalDisplayArm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "PlanCtor") (TyCon "String"))))))))))
(DFunDef false "graphNominalDisplayArm" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "  _ => \"<unavailable>\""))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoLet false false (PVar "text") (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "source"))) (ELit (LString " { \" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplays") (EVar "graph")) (EVar "prefix")) (EVar "fields")) (EVar "values")))) (ELit (LString " ++ \" }\""))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "source"))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "source"))) (ELit (LString " (\" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplays") (EVar "graph")) (EVar "prefix")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "fields"))) (EVar "values")))) (ELit (LString " ++ \")\"")))))) (DoLet false false (PVar "pat") (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EVar "ref") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "values")))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "pat"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "text"))) (ELit (LString ""))))))))
(DTypeSig false "graphNamedDisplays" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphNamedDisplays" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphNamedDisplays" ((PVar "graph") (PVar "prefix") (PCons (PTuple (PCon "Some" (PVar "field")) (PVar "plan")) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "field"))) (ELit (LString " = \" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphNamedDisplays" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "graphNamedDisplaysTail" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphNamedDisplaysTail" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphNamedDisplaysTail" ((PVar "graph") (PVar "prefix") (PCons (PTuple (PCon "Some" (PVar "field")) (PVar "plan")) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \", \" ++ \"")) (EApp (EVar "display") (EVar "field"))) (ELit (LString " = \" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphNamedDisplaysTail" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "plannedRunLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "plannedRunLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  if ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases <= 0 then (True, \"\") else")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedBindings") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    let ok = ")) (EApp (EVar "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))))) (EApp (EApp (EApp (EApp (EVar "plannedFailureLines") (EVar "nonce")) (EVar "i")) (EVar "ps")) (EVar "plans"))) (EListLit (ELit (LString "")))))
(DTypeSig false "plannedBindings" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedBindings" ((PVar "nonce") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" PWild PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    let ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (ELit (LString "0"))))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedBindings") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DFunDef false "plannedBindings" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "slotName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "slotName" ((PVar "nonce") (PVar "i") (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "arg_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "paramSlots" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "paramSlots" ((PVar "nonce") (PVar "i") (PVar "ps")) (EApp (EApp (EApp (EApp (EVar "paramSlotsGo") (EVar "nonce")) (EVar "i")) (EVar "ps")) (ELit (LInt 0))))
(DTypeSig false "paramSlotsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "paramSlotsGo" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "paramSlotsGo" ((PVar "nonce") (PVar "i") (PCons PWild (PVar "rest")) (PVar "j")) (EBinOp "::" (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j")) (EApp (EApp (EApp (EApp (EVar "paramSlotsGo") (EVar "nonce")) (EVar "i")) (EVar "rest")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DTypeSig false "plannedFailureLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "plannedFailureLines" ((PVar "nonce") (PVar "i") (PList) PWild) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    if ok then ")) (EApp (EVar "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases - 1) else (False, \"counterexample\")")))))
(DFunDef false "plannedFailureLines" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "plans")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    if ok then ")) (EApp (EVar "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases - 1) else "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "plannedShrinkStart") (EVar "nonce")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString "")))))
(DTypeSig false "plannedShrinkStart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "plannedShrinkStart" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "plans")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " 100 "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))))
(DTypeSig false "shrinkName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "shrinkName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "shrink_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "plannedShrinkLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedShrinkLines" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedShrinkLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTopLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0)))))
(DTypeSig false "shrinkTopLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "shrinkTopLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EBlock (DoLet false false (PVar "startCandidates") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateExprAt") (EVar "nonce")) (EVar "graph")) (EVar "i")) (ELit (LInt 0))) (EApp (EApp (EVar "nthPlan") (ELit (LInt 0))) (EVar "plans"))) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (ELit (LInt 0))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString " ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  if ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel <= 0 then (False, "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlots") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString " ++ \" (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)\") else "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (ELit (LInt 0))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EVar "display") (EVar "startCandidates"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))) (ELit (LString ""))))))
(DTypeSig false "shrinkTryName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "shrinkTryName" ((PVar "nonce") (PVar "i") (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "try_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "shrinkTryLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "shrinkTryLines" ((PVar "nonce") PWild PWild PWild (PList) PWild PWild) (EListLit))
(DFunDef false "shrinkTryLines" ((PVar "nonce") PWild PWild PWild (PVar "ps") PWild (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "listLen") (EVar "ps"))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "shrinkTryLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") (PVar "j")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLine") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EVar "j")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DTypeSig false "shrinkTryLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "shrinkTryLine" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") (PVar "j")) (EBlock (DoLet false false (PVar "current") (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))) (DoLet false false (PVar "plan") (EApp (EApp (EVar "nthPlan") (EVar "j")) (EVar "plans"))) (DoLet false false (PVar "params") (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))) (DoLet false false (PVar "after") (EIf (EBinOp ">=" (EBinOp "+" (EVar "j") (ELit (LInt 1))) (EApp (EVar "listLen") (EVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(False, ")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlots") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString ")"))) (EBlock (DoLet false false (PVar "nextCandidates") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateExprAt") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EApp (EVar "nthPlan") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "plans"))) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EVar "display") (EVar "nextCandidates"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString ""))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidates "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString " ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  match ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidates"))) (EBinOp "++" (EBinOp "++" (ELit (LString "    [] => ")) (EApp (EVar "display") (EVar "after"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidate :: "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "rest =>"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      if ")) (EApp (EVar "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "replaceName") (EVar "j")) (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "candidate")))) (EVar "params"))))) (ELit (LString " then "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "rest "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      else ")) (EApp (EVar "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel - 1) "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "replaceName") (EVar "j")) (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "candidate")))) (EVar "params"))))) (ELit (LString ""))) (ELit (LString ""))))))
(DTypeSig false "nthPlan" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "GenPlan"))))
(DFunDef false "nthPlan" ((PLit (LInt 0)) (PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "nthPlan" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "nthPlan") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))
(DFunDef false "nthPlan" (PWild (PList)) (EVar "GUnit"))
(DTypeSig false "candidateExprAt" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "candidateExprAt" ((PVar "nonce") (PVar "graph") PWild PWild (PVar "plan") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "replaceName" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "replaceName" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceName" ((PLit (LInt 0)) (PVar "replacement") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "replacement") (EVar "rest")))
(DFunDef false "replaceName" ((PVar "n") (PVar "replacement") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "replaceName") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "replacement")) (EVar "rest"))))
(DTypeSig false "plannedDetailSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))))
(DFunDef false "plannedDetailSlots" (PWild PWild PWild PWild (PList) PWild) (ELit (LString "\"counterexample\"")))
(DFunDef false "plannedDetailSlots" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsGo") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0))))
(DTypeSig false "plannedDetailSlotsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "plannedDetailSlotsGo" (PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "\"counterexample\"")))
(DFunDef false "plannedDetailSlotsGo" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" (PVar "name") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = \" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsTail") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "plannedDetailSlotsGo" (PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "\"counterexample\"")))
(DTypeSig false "plannedDetailSlotsTail" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "plannedDetailSlotsTail" (PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "")))
(DFunDef false "plannedDetailSlotsTail" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" (PVar "name") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \"\\n\" ++ \"")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = \" ++ "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsTail") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "plannedDetailSlotsTail" (PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "tupleVars" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tupleVars" ((PVar "n")) (EApp (EApp (EVar "tupleVarsGo") (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "tupleVarsGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tupleVarsGo" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "v")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))) (EApp (EApp (EVar "tupleVarsGo") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "rebuildCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyCon "String"))))))
(DFunDef false "rebuildCtor" ((PVar "ref") (PVar "fields") (PVar "values") (PVar "named")) (EIf (EVar "named") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "paren")) (EVar "values"))))) (ELit (LString "")))))
(DTypeSig false "plannedMainLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedMainLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "plannedMainLines" ((PVar "nonce") (PCons (PCon "NativeRunnable" (PCon "DProp" PWild PWild (PVar "params") PWild) (PVar "r") (PVar "plans")) (PVar "rest")) (PVar "i")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EVar "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "startTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state := (("))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString " % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ") + "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ") % "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let caller = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".setSeed "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state := "))) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState caller"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let seed = ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EVar "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "seedTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".intToString seed")))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let (ok, detail) = ")) (EApp (EVar "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "propRequestCases") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EVar "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "boolTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (EBinOp "++" (EApp (EVar "coreAlias") (EVar "nonce")) (ELit (LString ".debug ok")))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EVar "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "detailTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (ELit (LString "detail"))))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "plannedMainLines" ((PVar "nonce") (PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "rest")) (EVar "i")))
(DTypeSig false "probeTargetSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "probeTargetSource" ((PVar "target") (PVar "src")) (EIf (EBinOp "==" (EApp (EVar "baseOf") (EVar "target")) (ELit (LString "core.mdk"))) (ELit (LString "")) (EApp (EVar "renameUserMain") (EVar "src"))))
(DTypeSig false "fnName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "fnName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "prop_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "runName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "runName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "run_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "fnLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fnLines" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "body")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "paramName")) (EVar "ps"))))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "exprToString") (EVar "body")))) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig false "paramName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "paramName" ((PCon "PropParam" (PVar "n") PWild PWild)) (EVar "n"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "PropParam" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true) (mem "Pat" true) (mem "mapTyFull" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "scratchProbeManifest" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "BuildProfile" true) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "listLen" false) (mem "zipL" false) (mem "reverseL" false))))
(DUse false (UseGroup ("string") ((mem "replaceAll" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "decodeValue" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "mintNonce" false) (mem "freshProbeNonce" false) (mem "noncedPrefix" false) (mem "renameUserMain" false) (mem "runtimeDependencyName" false) (mem "runtimeDependencyPrefix" false) (mem "sentinelLine" false) (mem "tagsInOrder" false) (mem "valuePrintExprWith" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false) (mem "ppTy" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" true) (mem "TypeKey" true) (mem "CustomPlan" true) (mem "PlanEnv" true) (mem "GenPlan" true) (mem "PlanDef" true) (mem "PlanCtor" true) (mem "PlanField" true) (mem "PlanError" true) (mem "PlanErrorReason" true) (mem "PlanVisibility" true) (mem "planErrorText" false) (mem "buildPlanEnvModules" false) (mem "planFor" false) (mem "planDef" false) (mem "instantiateCtor" false) (mem "planTy" false) (mem "typeKeyWord" false) (mem "ctorWeights" false) (mem "listLengthBound" false) (mem "listBoundDecays" false) (mem "listLenMax" false) (mem "optionWeights" false) (mem "resultWeights" false) (mem "maxGenDepth" false) (mem "SoftWeight" true) (mem "softCtorWeights" false) (mem "intMin" false) (mem "intMax" false) (mem "structuralRngModulus" false) (mem "structuralRngMultiplier" false) (mem "structuralRngIncrement" false) (mem "structuralRngMixMultiplier1" false) (mem "structuralRngMixMultiplier2" false) (mem "structuralRngWordModulus" false) (mem "structuralRngWordHalf" false) (mem "ShrinkAction" true) (mem "shrinkActions" false) (mem "IntShrinkStep" true) (mem "intShrinkSteps" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propSeedValue" false) (mem "PropRequest" true) (mem "propRequestName" false) (mem "propRequestSeed" false) (mem "propRequestCases" false))))
(DTypeSig false "sentinelBase" (TyCon "String"))
(DFunDef false "sentinelBase" () (ELit (LString "@@__mdk_native_prop__@@")))
(DTypeSig false "sentinelPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelPrefix" ((PVar "nonce")) (EApp (EApp (EVar "noncedPrefix") (EVar "sentinelBase")) (EVar "nonce")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelFor" ((PVar "nonce") (PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EVar "tag")))
(DTypeSig false "startTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "startTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".start"))))
(DTypeSig false "boolTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "boolTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".bool"))))
(DTypeSig false "detailTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "detailTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".detail"))))
(DTypeSig false "seedTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "seedTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".seed"))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EApp (EVar "startTag") (EVar "i")) (EApp (EVar "seedTag") (EVar "i")) (EApp (EVar "boolTag") (EVar "i")) (EApp (EVar "detailTag") (EVar "i"))) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "runNativePlannedPropRequests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runNativePlannedPropRequests" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "requests")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EApp (EVar "desugarProps") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EVar "requestIndex") (EVar "requests")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "duplicate")) () (EApp (EApp (EVar "nativeProtocolErrors") (EVar "duplicate")) (EVar "requests"))) (arm (PCon "Ok" (PVar "index")) () (EMatch (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "props")) (EMethodRef "index")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "duplicate")) () (EApp (EApp (EVar "nativeProtocolErrors") (ELit (LString "duplicate property declaration name \"{duplicate}\""))) (EVar "requests"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EApp (EVar "plannedRoot") (EVar "modules"))) (EVar "modules")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "plannedResults") (EApp (EApp (EApp (EVar "planCapabilities") (EVar "props")) (EMethodRef "index")) (EApp (EVar "planErrorText") (EVar "e")))) (EListLit))) (arm (PCon "Ok" (PVar "env")) () (EBlock (DoLet false false (PVar "outcomes") (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "props")) (EMethodRef "index"))) (DoLet false false (PVar "runnable") (EApp (EVar "plannedRunnable") (EVar "outcomes"))) (DoExpr (EMatch (EVar "runnable") (arm (PList) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EListLit))) (arm PWild () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "nativeRenderedPlanned") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "runnable")) (arm (PCon "Err" (PVar "failure")) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "nativePlannedFailure") (EVar "failure"))) (EVar "runnable")))) (arm (PCon "Ok" (PVar "rows")) () (EApp (EApp (EVar "plannedResults") (EVar "outcomes")) (EVar "rows")))))))))))))))))
(DTypeSig true "renderNativePlannedProbe" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderNativePlannedProbe" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "requests")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EApp (EVar "desugarProps") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EVar "requestIndex") (EVar "requests")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "index")) () (EMatch (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "props")) (EMethodRef "index")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "duplicate")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "duplicate property declaration name \"")) (EApp (EMethodRef "display") (EVar "duplicate"))) (ELit (LString "\""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EApp (EVar "plannedRoot") (EVar "modules"))) (EVar "modules")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "planErrorText") (EVar "e")))) (arm (PCon "Ok" (PVar "env")) () (EBlock (DoLet false false (PVar "jobs") (EApp (EVar "plannedRunnable") (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "props")) (EMethodRef "index")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "jobs")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "native property runner: no selected property could be rendered"))) (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (ELit (LString "source_check"))) (EVar "probeNamespacePrefixes")) (EVar "tsrc"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedProbeSource") (EVar "nonce")) (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs")))))))))))))))))
(DTypeSig false "plannedRoot" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyCon "String")))
(DFunDef false "plannedRoot" ((PList)) (ELit (LString "")))
(DFunDef false "plannedRoot" ((PList (PCon "PlanModule" (PVar "name") PWild PWild))) (EVar "name"))
(DFunDef false "plannedRoot" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedRoot") (EVar "rest")))
(DTypeSig false "planCapabilities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "NativePlanOutcome"))))))
(DFunDef false "planCapabilities" ((PList) PWild PWild) (EListLit))
(DFunDef false "planCapabilities" ((PCons (PAs "d" (PCon "DProp" PWild PWild PWild PWild)) (PVar "rest")) (PVar "requests") (PVar "message")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "propName") (EVar "d"))) (EVar "requests")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (EVar "message")) (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))))
(DFunDef false "planCapabilities" ((PCons PWild (PVar "rest")) (PVar "requests") (PVar "message")) (EApp (EApp (EApp (EVar "planCapabilities") (EVar "rest")) (EVar "requests")) (EVar "message")))
(DData Private "NativePlanOutcome" () ((variant "NativeRunnable" (ConPos (TyCon "Decl") (TyCon "PropRequest") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "NativeCapability" (ConPos (TyCon "Decl") (TyCon "PropRequest") (TyCon "String")))) ())
(DTypeSig false "plannedOutcomes" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "NativePlanOutcome")))))))
(DFunDef false "plannedOutcomes" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedOutcomes" ((PVar "env") (PVar "modules") (PCons (PAs "d" (PCon "DProp" PWild PWild PWild PWild)) (PVar "rest")) (PVar "requests")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "propName") (EVar "d"))) (EVar "requests")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests"))) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EApp (EVar "runtimePropParams") (EVar "modules")) (EApp (EVar "propName") (EVar "d"))) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (ELit (LString "property declaration was absent from the elaborated module"))) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))) (arm (PCon "Some" (PVar "ps")) () (EMatch (EApp (EApp (EApp (EApp (EVar "planParameters") (EVar "env")) (EApp (EVar "propName") (EVar "d"))) (EVar "ps")) (EListLit)) (arm (PCon "Ok" (PVar "plans")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeRunnable") (EVar "d")) (EVar "r")) (EVar "plans")) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))) (arm (PCon "Err" (PVar "e")) () (EBinOp "::" (EApp (EApp (EApp (EVar "NativeCapability") (EVar "d")) (EVar "r")) (EApp (EVar "planErrorText") (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests"))))))))))
(DFunDef false "plannedOutcomes" ((PVar "env") (PVar "modules") (PCons PWild (PVar "rest")) (PVar "requests")) (EApp (EApp (EApp (EApp (EVar "plannedOutcomes") (EVar "env")) (EVar "modules")) (EVar "rest")) (EVar "requests")))
(DTypeSig false "runtimePropParams" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PropParam"))))))
(DFunDef false "runtimePropParams" ((PList) PWild) (EVar "None"))
(DFunDef false "runtimePropParams" ((PList (PCon "PlanModule" PWild PWild (PVar "runtime"))) (PVar "name")) (EApp (EApp (EVar "runtimePropParamsIn") (EVar "runtime")) (EVar "name")))
(DFunDef false "runtimePropParams" ((PCons PWild (PVar "rest")) (PVar "name")) (EApp (EApp (EVar "runtimePropParams") (EVar "rest")) (EVar "name")))
(DTypeSig false "runtimePropParamsIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PropParam"))))))
(DFunDef false "runtimePropParamsIn" ((PList) PWild) (EVar "None"))
(DFunDef false "runtimePropParamsIn" ((PCons (PCon "DProp" PWild (PVar "name") (PVar "ps") PWild) PWild) (PVar "wanted")) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runtimePropParamsIn" ((PCons PWild (PVar "rest")) (PVar "wanted")) (EApp (EApp (EVar "runtimePropParamsIn") (EVar "rest")) (EVar "wanted")))
(DTypeSig false "propName" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "propName" ((PCon "DProp" PWild (PVar "name") PWild PWild)) (EVar "name"))
(DFunDef false "propName" (PWild) (ELit (LString "<invalid prop>")))
(DTypeSig false "planParameters" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planParameters" (PWild PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "planParameters" ((PVar "env") (PVar "property") (PCons (PCon "PropParam" (PVar "name") PWild (PVar "ty")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (EVar "property")) (EVar "name")) (EVar "ty")) (arm (PCon "Ok" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "planParameters") (EVar "env")) (EVar "property")) (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "acc")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "plannedRunnable" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyApp (TyCon "List") (TyCon "NativePlanOutcome"))))
(DFunDef false "plannedRunnable" ((PList)) (EListLit))
(DFunDef false "plannedRunnable" ((PCons (PAs "x" (PCon "NativeRunnable" PWild PWild PWild)) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "plannedRunnable") (EVar "rest"))))
(DFunDef false "plannedRunnable" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedRunnable") (EVar "rest")))
(DData Private "NativeFailure" () ((variant "NativeBuildFailure" (ConPos (TyCon "String"))) (variant "NativeRuntimeFailure" (ConPos (TyCon "String"))) (variant "NativeProtocolFailure" (ConPos (TyCon "String")))) ())
(DTypeSig false "nativePlannedFailure" (TyFun (TyCon "NativeFailure") (TyFun (TyCon "NativePlanOutcome") (TyCon "PropResult"))))
(DFunDef false "nativePlannedFailure" ((PVar "failure") (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild)) (EApp (EApp (EVar "nativeFailure") (EVar "failure")) (ETuple (EVar "d") (EVar "r"))))
(DFunDef false "nativePlannedFailure" ((PVar "failure") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<invalid prop>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "plannedResults" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "plannedResults" ((PList) PWild) (EListLit))
(DFunDef false "plannedResults" ((PCons (PCon "NativeCapability" (PVar "d") (PVar "r") (PVar "message")) (PVar "rest")) (PVar "rows")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propName") (EVar "d"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EVar "message")) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))) (EApp (EApp (EVar "plannedResults") (EVar "rest")) (EVar "rows"))))
(DFunDef false "plannedResults" ((PCons (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild) (PVar "rest")) (PVar "rows")) (EBinOp "::" (EApp (EApp (EApp (EVar "nativeRowFor") (EApp (EVar "propName") (EVar "d"))) (EVar "r")) (EVar "rows")) (EApp (EApp (EVar "plannedResults") (EVar "rest")) (EVar "rows"))))
(DTypeSig false "nativeRowFor" (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "PropResult")))))
(DFunDef false "nativeRowFor" (PWild (PVar "r") (PList)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propRequestName") (EVar "r"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (ELit (LString "native property runner: the compiled probe omitted this property result"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DFunDef false "nativeRowFor" ((PVar "name") (PVar "r") (PCons (PAs "row" (PCon "PropResult" PWild (PVar "rowName") PWild PWild PWild PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "rowName")) (EVar "row") (EApp (EApp (EApp (EVar "nativeRowFor") (EVar "name")) (EVar "r")) (EVar "rest"))))
(DTypeSig false "requestIndex" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "PropRequest"))))))
(DFunDef false "requestIndex" ((PList) (PVar "index")) (EApp (EVar "Ok") (EMethodRef "index")))
(DFunDef false "requestIndex" ((PCons (PVar "r") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "propRequestName") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EApp (EVar "propRequestCases") (EVar "r")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "property request \"{name}\" has a non-positive case budget"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EMethodRef "index")) (EApp (EVar "Err") (ELit (LString "duplicate property request name \"{name}\""))) (EApp (EApp (EVar "requestIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "r")) (EMethodRef "index"))))))))
(DTypeSig false "duplicateSelectedPropName" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "duplicateSelectedPropName" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "duplicateSelectedPropName" ((PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest")) (PVar "requests") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "requests")) (EApp (EVar "Some") (EVar "name")) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EVar "seen"))) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))
(DFunDef false "duplicateSelectedPropName" ((PCons PWild (PVar "rest")) (PVar "requests") (PVar "seen")) (EApp (EApp (EApp (EVar "duplicateSelectedPropName") (EVar "rest")) (EVar "requests")) (EVar "seen")))
(DTypeSig false "nativeProtocolErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "nativeProtocolErrors" ((PVar "duplicate") (PVar "requests")) (EApp (EApp (EMethodRef "map") (EApp (EVar "nativeProtocolError") (EVar "duplicate"))) (EVar "requests")))
(DTypeSig false "nativeProtocolError" (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyCon "PropResult"))))
(DFunDef false "nativeProtocolError" ((PVar "duplicate") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EApp (EVar "propRequestName") (EVar "r"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: ")) (EApp (EMethodRef "display") (EVar "duplicate"))) (ELit (LString "")))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DTypeSig false "desugarProps" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugarProps" ((PVar "src")) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src"))))
(DTypeSig false "nativeFailureKind" (TyFun (TyCon "NativeFailure") (TyCon "PropFailureKind")))
(DFunDef false "nativeFailureKind" ((PCon "NativeBuildFailure" PWild)) (EVar "PropBuildError"))
(DFunDef false "nativeFailureKind" ((PCon "NativeRuntimeFailure" PWild)) (EVar "PropRuntimeError"))
(DFunDef false "nativeFailureKind" ((PCon "NativeProtocolFailure" PWild)) (EVar "PropProtocolError"))
(DTypeSig false "nativeFailureText" (TyFun (TyCon "NativeFailure") (TyCon "String")))
(DFunDef false "nativeFailureText" ((PCon "NativeBuildFailure" (PVar "text"))) (EVar "text"))
(DFunDef false "nativeFailureText" ((PCon "NativeRuntimeFailure" (PVar "text"))) (EVar "text"))
(DFunDef false "nativeFailureText" ((PCon "NativeProtocolFailure" (PVar "text"))) (EVar "text"))
(DTypeSig false "nativeFailure" (TyFun (TyCon "NativeFailure") (TyFun (TyTuple (TyCon "Decl") (TyCon "PropRequest")) (TyCon "PropResult"))))
(DFunDef false "nativeFailure" ((PVar "failure") (PTuple (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DFunDef false "nativeFailure" ((PVar "failure") (PTuple PWild (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<invalid prop>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EApp (EVar "nativeFailureKind") (EVar "failure")))) (EApp (EVar "nativeFailureText") (EVar "failure"))) (EApp (EVar "propRequestSeed") (EVar "r"))) (EApp (EVar "propRequestCases") (EVar "r"))))
(DTypeSig false "nativeRenderedPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "nativeRenderedPlanned" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeRuntimeFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not create a scratch directory: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "tmp")) () (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "freshProbeNonce") (EApp (EVar "mintNonce") (ELit LUnit))) (EVar "probeNamespacePrefixes")) (EVar "tsrc"))) (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runInTmpPlanned") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs")) (EVar "tmp")) (EVar "nonce"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmp"))) (DoExpr (EVar "rendered"))))))
(DTypeSig false "runInTmpPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "runInTmpPlanned" ((PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs") (PVar "tmp") (PVar "nonce")) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "out") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (ELit (LString "prop_probe")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "scratchProbeManifest") (ELit (LString "medaka_native_props"))) (EVar "target")) (EApp (EVar "runtimeDependencyName") (EVar "nonce"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not create the scratch manifest: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PVar "manifest")) () (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmp")) (ELit (LString "medaka.toml")))) (EVar "manifest")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not write the scratch manifest: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedProbeSource") (EVar "nonce")) (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EVar "env")) (EVar "jobs"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not write the probe source: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRunPlanned") (EVar "target")) (EVar "entry")) (EVar "out")) (EVar "tmp")) (EVar "jobs")) (EVar "nonce")))))))))))
(DTypeSig false "buildAndRunPlanned" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "NativeFailure")) (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "buildAndRunPlanned" ((PVar "target") (PVar "entry") (PVar "out") (PVar "tmp") (PVar "jobs") (PVar "nonce")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka"))))) (DoLet false false (PVar "emitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "medaka_emitter"))))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entry")) (EVar "out")) (EVar "tmp")) (EVar "False")) (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "BuildProbe")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EApp (EVar "NativeBuildFailure") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not build ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EMethodRef "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString "")))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "env"))) (EListLit (EBinOp "++" (ELit (LString "MEDAKA_ROOT=")) (EVar "root")) (EBinOp "++" (ELit (LString "MEDAKA=")) (EVar "medaka")) (EBinOp "++" (ELit (LString "MEDAKA_EMITTER=")) (EVar "emitter")) (EVar "out"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "NativeRuntimeFailure") (EBinOp "++" (EBinOp "++" (ELit (LString "native property runner: could not run the compiled probe: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "stdout") (PVar "stderr"))) () (EBlock (DoLet false false (PVar "props") (EApp (EVar "plannedDeclRequests") (EVar "jobs"))) (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "splitNl") (EVar "stdout")))) (DoExpr (EIf (EApp (EApp (EVar "tagsInOrder") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "props"))) (EVar "chunks")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "stderr"))) (ELit (LInt 0))) (EVar "props"))) (EApp (EVar "Err") (EApp (EVar "NativeProtocolFailure") (ELit (LString "native property runner: the probe printed a forged or malformed transcript; no property result was trusted"))))))))))))))
(DTypeSig false "plannedDeclRequests" (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest")))))
(DFunDef false "plannedDeclRequests" ((PList)) (EListLit))
(DFunDef false "plannedDeclRequests" ((PCons (PCon "NativeRunnable" (PVar "d") (PVar "r") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "d") (EVar "r")) (EApp (EVar "plannedDeclRequests") (EVar "rest"))))
(DFunDef false "plannedDeclRequests" ((PCons PWild (PVar "rest"))) (EApp (EVar "plannedDeclRequests") (EVar "rest")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "prop_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "stderr")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "stderr")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native property run ended (probe exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "first") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "first"))))) (ELit (LString ""))))))
(DData Private "TranscriptField" () ((variant "FieldMissing" (ConPos)) (variant "FieldIncomplete" (ConPos)) (variant "FieldMalformed" (ConPos)) (variant "FieldDecoded" (ConPos (TyCon "String")))) ())
(DTypeSig false "transcriptField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyCon "TranscriptField"))))
(DFunDef false "transcriptField" ((PVar "tag") (PVar "chunks")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "tag")) (EVar "chunks")) (arm (PCon "None") () (EVar "FieldMissing")) (arm (PCon "Some" (PCon "Chunk" PWild PWild (PCon "False"))) () (EVar "FieldIncomplete")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "lines") (PCon "True"))) () (EMatch (EApp (EVar "decodeValue") (EVar "lines")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "FieldDecoded") (EVar "text"))) (arm (PCon "None") () (EVar "FieldMalformed"))))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PVar "requests")) (EApp (EApp (EApp (EApp (EVar "renderIndexed") (EApp (EApp (EVar "indexNativeChunks") (EVar "chunks")) (EVar "omEmpty"))) (EVar "note")) (EVar "i")) (EVar "requests")))
(DTypeSig false "indexNativeChunks" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyApp (TyCon "OrdMap") (TyCon "Chunk")))))
(DFunDef false "indexNativeChunks" ((PList) (PVar "index")) (EMethodRef "index"))
(DFunDef false "indexNativeChunks" ((PCons (PAs "chunk" (PCon "Chunk" (PVar "tag") PWild PWild)) (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "next") (EIf (EApp (EApp (EVar "omHasKey") (EVar "tag")) (EMethodRef "index")) (EMethodRef "index") (EApp (EApp (EApp (EVar "omInsert") (EVar "tag")) (EVar "chunk")) (EMethodRef "index")))) (DoExpr (EApp (EApp (EVar "indexNativeChunks") (EVar "rest")) (EVar "next")))))
(DTypeSig false "renderIndexed" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "PropRequest"))) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "renderIndexed" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderIndexed" ((PVar "chunks") (PVar "note") (PVar "i") (PCons (PTuple PWild (PVar "request")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "classifyNativeFields") (EVar "chunks")) (EVar "note")) (EVar "request")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "renderIndexed") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "classifyNativeTranscript" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyCon "Int") (TyCon "PropResult"))))))
(DFunDef false "classifyNativeTranscript" ((PVar "chunks") (PVar "note") (PVar "request") (PVar "i")) (EApp (EApp (EApp (EApp (EVar "classifyNativeFields") (EApp (EApp (EVar "indexNativeChunks") (EVar "chunks")) (EVar "omEmpty"))) (EVar "note")) (EVar "request")) (EVar "i")))
(DTypeSig false "classifyNativeFields" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyCon "Int") (TyCon "PropResult"))))))
(DFunDef false "classifyNativeFields" ((PVar "chunks") (PVar "note") (PVar "request") (PVar "i")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "propRequestName") (EVar "request"))) (DoLet false false (PVar "seed") (EApp (EVar "propRequestSeed") (EVar "request"))) (DoLet false false (PVar "cases") (EApp (EVar "propRequestCases") (EVar "request"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "transcriptField") (EApp (EVar "seedTag") (EVar "i"))) (EVar "chunks")) (EApp (EApp (EVar "transcriptField") (EApp (EVar "boolTag") (EVar "i"))) (EVar "chunks")) (EApp (EApp (EVar "transcriptField") (EApp (EVar "detailTag") (EVar "i"))) (EVar "chunks"))) (arm (PTuple (PCon "FieldMalformed") PWild PWild) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed replay seed in native transcript"))) (EVar "request"))) (arm (PTuple PWild (PCon "FieldMalformed") PWild) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed result value in native transcript"))) (EVar "request"))) (arm (PTuple PWild PWild (PCon "FieldMalformed")) () (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "malformed detail in native transcript"))) (EVar "request"))) (arm (PTuple (PCon "FieldDecoded" (PVar "seedText")) PWild PWild) ((GBool (EBinOp "/=" (EApp (EVar "toInt") (EVar "seedText")) (EApp (EVar "Some") (EVar "seed"))))) (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "invalid replay seed in native transcript"))) (EVar "request"))) (arm (PTuple PWild (PCon "FieldDecoded" (PVar "boolText")) PWild) ((GBool (EBinOp "&&" (EBinOp "/=" (EVar "boolText") (ELit (LString "True"))) (EBinOp "/=" (EVar "boolText") (ELit (LString "False")))))) (EApp (EApp (EVar "nativeProtocolError") (ELit (LString "invalid result value in native transcript"))) (EVar "request"))) (arm (PTuple (PCon "FieldDecoded" PWild) (PCon "FieldDecoded" (PLit (LString "True"))) (PCon "FieldDecoded" (PVar "detail"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropPassedResult")) (EVar "None")) (EVar "detail")) (EVar "seed")) (EVar "cases"))) (arm (PTuple (PCon "FieldDecoded" PWild) (PCon "FieldDecoded" (PLit (LString "False"))) (PCon "FieldDecoded" (PVar "detail"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropFailedResult")) (EApp (EVar "Some") (EVar "PropLawFalse"))) (EVar "detail")) (EVar "seed")) (EVar "cases"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "note"))) (ELit (LString "; this property was not fully reported")))) (EVar "seed")) (EVar "cases")))))))
(DTypeSig false "probeNamespacePrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "probeNamespacePrefixes" () (EListLit (ELit (LString "__np_")) (ELit (LString "NpCore_")) (ELit (LString "NpRuntime_")) (ELit (LString "NpModule_")) (EVar "runtimeDependencyPrefix")))
(DTypeSig false "plannedProbeSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyCon "String"))))))))
(DFunDef false "plannedProbeSource" ((PVar "nonce") (PVar "target") (PVar "tsrc") (PVar "modules") (PVar "env") (PVar "jobs")) (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EVar "sharedGraph") (EVar "env")) (EVar "jobs"))) (DoLet false false (PVar "prefix") (EApp (EVar "genNodePrefix") (EVar "nonce"))) (DoExpr (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "plannedImports") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EListLit (EApp (EApp (EVar "probeTargetSource") (EVar "target")) (EVar "tsrc")) (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state : Ref Int"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state = "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".Ref 0"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state : Ref U64"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state = "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".Ref 0"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word n = ((n % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ") + "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ") % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordModulus")))) (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word left right ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word left"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word right"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x_low = x % ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let x_high = x / ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y_low = y % ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let y_high = y / ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ""))) (ELit (LString "  let low = x_low * y_low")) (ELit (LString "  let cross = x_low * y_high + x_high * y_low")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word (low + (cross % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ") * "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngWordHalf")))) (ELit (LString ")"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "next _ ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let s = (!")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state * "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngMultiplier")))) (ELit (LString " + "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngIncrement")))) (ELit (LString ") % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state := s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let word = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word s"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h1 = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor word ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight word 16))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h2 = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word h1 "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngMixMultiplier1")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h3 = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor h2 ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight h2 13))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let h4 = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "mul_word h3 "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngMixMultiplier2")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "word ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".bitXor h4 ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".shiftRight h4 16))"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "int _ = "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EBinOp "-" (EVar "intMax") (EVar "intMin")) (ELit (LInt 1)))))) (ELit (LString " + "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "intMin")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "bool _ = "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 2 == 1"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose n ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let word = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "next ()"))) (ELit (LString "  if n <= 0 then 0 else word % n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char _ = "))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".optionOr ' ' ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".charFromCode (32 + "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 95))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string n = if n <= 0 then \"\" else "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".charToStr ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char ()) ++ "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string (n - 1)"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings _ [] = \"\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings _ (x :: []) = x"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings sep (x :: xs) = x ++ sep ++ "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings sep xs"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list arr = "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr 0"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr i = if i >= "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayLength arr then [] else arr[i] :: "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list_go arr (i + 1)"))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each [] = []"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each (x :: xs) = xs :: "))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => x :: ys) ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each xs)"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f [] = []"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f (x :: xs) = "))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => ys :: xs) (f x) ++ "))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (ys => x :: ys) ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each f xs)"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "jobs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EApp (EVar "coreAlias") (EVar "nonce"))) (EVar "prefix")) (EVar "graph"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EApp (EVar "coreAlias") (EVar "nonce"))) (EVar "prefix")) (EVar "graph"))) (EListLit (ELit (LString "main =")))) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "jobs")) (ELit (LInt 0)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))))
(DTypeSig false "coreAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "coreAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpCore_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "runtimeAlias" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimeAlias" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "NpRuntime_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString ""))))
(DTypeSig false "probeNameNonce" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "probeNameNonce" ((PVar "nonce")) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "-"))) (ELit (LString "_"))) (EVar "nonce")))
(DTypeSig false "generatedPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "generatedPrefix" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "__np_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))))
(DTypeSig false "generatedName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "generatedName" ((PVar "nonce") (PVar "stem")) (EBinOp "++" (EApp (EVar "generatedPrefix") (EVar "nonce")) (EVar "stem")))
(DTypeSig false "plannedImports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedImports" ((PVar "nonce") (PVar "modules") (PVar "graph")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "import core as ")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeDependencyName") (EVar "nonce")))) (ELit (LString ".runtime as "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "importLine") (EVar "nonce")) (EVar "modules"))) (EApp (EVar "omKeys") (EApp (EApp (EVar "graphImportOwners") (EVar "graph")) (EVar "omEmpty")))))))
(DTypeSig false "graphImportOwners" (TyFun (TyCon "NativeGraph") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "graphImportOwners" ((PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild) (PVar "owners")) (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))) (EVar "owners")))
(DTypeSig false "graphImportOwnersGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "graphImportOwnersGo" (PWild (PList) (PVar "owners")) (EVar "owners"))
(DFunDef false "graphImportOwnersGo" ((PVar "nodes") (PCons (PVar "word") (PVar "rest")) (PVar "owners")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" PWild (PVar "plan") PWild)) () (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EVar "rest")) (EApp (EApp (EVar "planImportOwner") (EVar "plan")) (EVar "owners")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "graphImportOwnersGo") (EVar "nodes")) (EVar "rest")) (EVar "owners")))))
(DTypeSig false "planImportOwner" (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "planImportOwner" ((PCon "GNominal" (PCon "TypeKey" PWild (PCon "OriginModule" (PVar "owner"))) PWild) (PVar "owners")) (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (ELit LUnit)) (EVar "owners")))
(DFunDef false "planImportOwner" ((PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild)) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "carrier")) (EVar "owners")))
(DFunDef false "planImportOwner" (PWild (PVar "owners")) (EVar "owners"))
(DTypeSig false "carrierImportOwners" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "carrierImportOwners" ((PRec "TyCon" ((rf "tyConOrigin" (PCon "OriginModule" (PVar "owner")))) false) (PVar "owners")) (EApp (EApp (EApp (EVar "omInsert") (EVar "owner")) (ELit LUnit)) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PRec "TyCon" () false) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyVar" PWild) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyApp" (PVar "left") (PVar "right")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "right")) (EApp (EApp (EVar "carrierImportOwners") (EVar "left")) (EVar "owners"))))
(DFunDef false "carrierImportOwners" ((PCon "TyFun" (PVar "left") (PVar "right")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "right")) (EApp (EApp (EVar "carrierImportOwners") (EVar "left")) (EVar "owners"))))
(DFunDef false "carrierImportOwners" ((PCon "TyTuple" (PVar "tys")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwnersMany") (EVar "tys")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyEffect" PWild PWild (PVar "ty")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyConstrained" PWild (PVar "ty")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyNamed" PWild (PVar "ty") PWild) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyQual" (PVar "ty") PWild PWild) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners")))
(DFunDef false "carrierImportOwners" ((PCon "TyRow" PWild PWild PWild) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwners" ((PCon "TyAuth" PWild PWild) (PVar "owners")) (EVar "owners"))
(DTypeSig false "carrierImportOwnersMany" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "carrierImportOwnersMany" ((PList) (PVar "owners")) (EVar "owners"))
(DFunDef false "carrierImportOwnersMany" ((PCons (PVar "ty") (PVar "rest")) (PVar "owners")) (EApp (EApp (EVar "carrierImportOwnersMany") (EVar "rest")) (EApp (EApp (EVar "carrierImportOwners") (EVar "ty")) (EVar "owners"))))
(DTypeSig false "importLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "importLine" ((PVar "nonce") (PVar "modules") (PVar "owner")) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import ")) (EApp (EMethodRef "display") (EVar "owner"))) (ELit (LString " as "))) (EApp (EMethodRef "display") (EVar "alias"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "moduleAlias" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "moduleAlias" ((PVar "nonce") (PVar "modules") (PVar "owner")) (EApp (EApp (EApp (EApp (EVar "moduleAliasGo") (EVar "nonce")) (EApp (EVar "dropLastPlanModule") (EVar "modules"))) (EVar "owner")) (ELit (LInt 0))))
(DTypeSig false "moduleAliasGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "moduleAliasGo" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "moduleAliasGo" ((PVar "nonce") (PCons (PCon "PlanModule" (PVar "name") PWild PWild) (PVar "rest")) (PVar "owner") (PVar "i")) (EIf (EBinOp "==" (EVar "name") (EVar "owner")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "NpModule_")) (EApp (EMethodRef "display") (EApp (EVar "probeNameNonce") (EVar "nonce")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "moduleAliasGo") (EVar "nonce")) (EVar "rest")) (EVar "owner")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "dropLastPlanModule" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyCon "List") (TyCon "PlanModule"))))
(DFunDef false "dropLastPlanModule" ((PList)) (EListLit))
(DFunDef false "dropLastPlanModule" ((PList PWild)) (EListLit))
(DFunDef false "dropLastPlanModule" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastPlanModule") (EVar "xs"))))
(DTypeSig false "planSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "GenPlan") (TyCon "String")))))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GInt")) (ELit (LString "Int")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GBool")) (ELit (LString "Bool")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GFloat")) (ELit (LString "Float")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GChar")) (ELit (LString "Char")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GString")) (ELit (LString "String")))
(DFunDef false "planSourceTy" (PWild PWild (PCon "GUnit")) (ELit (LString "Unit")))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GList" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "List (")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GArray" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Array (")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GOption" (PVar "plan"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Option (")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Result (")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "err")))) (ELit (LString ") ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "ok")))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GTuple" (PVar "plans"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules"))) (EVar "plans"))))) (ELit (LString ")"))))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GNominal" (PVar "key") (PVar "plans"))) (EApp (EApp (EApp (EApp (EVar "nominalSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "key")) (EVar "plans")))
(DFunDef false "planSourceTy" ((PVar "nonce") (PVar "modules") (PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild))) (EApp (EApp (EApp (EVar "carrierSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "carrier")))
(DTypeSig false "effectfulPlanSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "GenPlan") (TyCon "String")))))
(DFunDef false "effectfulPlanSourceTy" ((PVar "nonce") (PVar "modules") (PVar "plan")) (EBinOp "++" (EBinOp "++" (ELit (LString "<Rand> ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ""))))
(DTypeSig false "carrierSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "Ty") (TyCon "String")))))
(DFunDef false "carrierSourceTy" ((PVar "nonce") (PVar "modules") (PVar "carrier")) (EApp (EVar "ppTy") (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (EApp (EApp (EVar "qualifyCarrierTy") (EVar "nonce")) (EVar "modules"))) (EVar "carrier")))))
(DTypeSig false "qualifyCarrierTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "qualifyCarrierTy" ((PVar "nonce") (PVar "modules") (PAs "ty" (PRec "TyCon" ((rf "tyConName" None) (rf "tyConOrigin" (PCon "OriginModule" (PVar "owner")))) false))) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (ETuple (EVariantUpdate "TyCon" (EVar "ty") ((fa "tyConName" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "tyConName"))) (ELit (LString "")))))) (EVar "True"))) (arm (PCon "None") () (ETuple (EVar "ty") (EVar "False")))))
(DFunDef false "qualifyCarrierTy" (PWild PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "nominalSourceTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "nominalSourceTy" ((PVar "nonce") (PVar "modules") (PCon "TypeKey" (PVar "name") (PCon "OriginModule" (PVar "owner"))) (PVar "plans")) (EBlock (DoLet false false (PVar "head") (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "plans")) (ELit (LInt 0))) (EVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "plan")) (EApp (EVar "paren") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan"))))) (EVar "plans"))))) (ELit (LString "")))))))
(DFunDef false "nominalSourceTy" (PWild PWild (PCon "TypeKey" (PVar "name") PWild) (PList)) (EVar "name"))
(DFunDef false "nominalSourceTy" ((PVar "nonce") (PVar "modules") (PCon "TypeKey" (PVar "name") PWild) (PVar "plans")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "plan")) (EApp (EVar "paren") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan"))))) (EVar "plans"))))) (ELit (LString ""))))
(DTypeSig false "typeKeyName" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "typeKeyName" ((PCon "TypeKey" (PVar "name") PWild)) (EVar "name"))
(DTypeSig false "plannedPropLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedPropLines" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedPropLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PCons (PCon "NativeRunnable" (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "r") (PVar "plans")) (PVar "rest")) (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fnLines") (EVar "nonce")) (EVar "i")) (EVar "params")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedRunLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "params")) (EVar "plans")) (EApp (EVar "propRequestCases") (EVar "r")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedShrinkLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "params")) (EVar "plans"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "plannedPropLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedPropLines") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "rest")) (EVar "i")))
(DData Private "NativeGraph" () ((variant "NativeGraph" (ConPos (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))) ())
(DData Private "GraphNode" () ((variant "GraphNode" (ConPos (TyCon "Int") (TyCon "GenPlan") (TyCon "Int")))) ())
(DTypeSig false "buildGraph" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "NativeGraph"))))
(DFunDef false "buildGraph" ((PVar "env") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "root")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "omEmpty")) (EListLit)) (ELit (LInt 0)))))
(DTypeSig false "sharedGraph" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyCon "NativeGraph"))))
(DFunDef false "sharedGraph" ((PVar "env") (PVar "jobs")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "jobs")) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "omEmpty")) (EListLit)) (ELit (LInt 0)))))
(DTypeSig false "sharedGraphGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "sharedGraphGo" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "sharedGraphGo" ((PVar "env") (PCons (PCon "NativeRunnable" PWild PWild (PVar "plans")) (PVar "rest")) (PVar "graph")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "sharedGraphPlans") (EVar "env")) (EVar "plans")) (EVar "graph"))))
(DFunDef false "sharedGraphGo" ((PVar "env") (PCons PWild (PVar "rest")) (PVar "graph")) (EApp (EApp (EApp (EVar "sharedGraphGo") (EVar "env")) (EVar "rest")) (EVar "graph")))
(DTypeSig false "sharedGraphPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "sharedGraphPlans" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "sharedGraphPlans" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "graph")) (EMatch (EApp (EApp (EVar "buildGraph") (EVar "env")) (EVar "plan")) (arm (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild) () (EApp (EApp (EApp (EVar "sharedGraphPlans") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))) (EVar "graph"))))))
(DTypeSig false "mergeGraphNodes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))
(DFunDef false "mergeGraphNodes" (PWild (PList) (PVar "graph")) (EVar "graph"))
(DFunDef false "mergeGraphNodes" ((PVar "fresh") (PCons (PVar "word") (PVar "rest")) (PAs "graph" (PCon "NativeGraph" (PVar "nodes") (PVar "order") (PVar "next")))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "fresh")) (arm (PCon "Some" (PCon "GraphNode" PWild (PVar "plan") (PVar "depth"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "nodes"))))) (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "fresh")) (EVar "rest")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "next")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EBinOp "::" (EVar "word") (EVar "order"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (arm PWild () (EApp (EApp (EApp (EVar "mergeGraphNodes") (EVar "fresh")) (EVar "rest")) (EVar "graph")))))
(DTypeSig false "graphExplore" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphExplore" ((PVar "env") (PVar "plan") (PVar "depth") (PAs "graph" (PCon "NativeGraph" (PVar "nodes") (PVar "order") (PVar "next")))) (EBlock (DoLet false false (PVar "word") (EApp (EVar "genPlanWord") (EVar "plan"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild (PVar "oldDepth"))) () (EIf (EBinOp "<" (EVar "depth") (EVar "oldDepth")) (EApp (EApp (EApp (EApp (EVar "graphChildren") (EVar "env")) (EVar "plan")) (EVar "depth")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "ident")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EVar "order")) (EVar "next"))) (EVar "graph"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "graphChildren") (EVar "env")) (EVar "plan")) (EVar "depth")) (EApp (EApp (EApp (EVar "NativeGraph") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EApp (EApp (EApp (EVar "GraphNode") (EVar "next")) (EVar "plan")) (EVar "depth"))) (EVar "nodes"))) (EBinOp "::" (EVar "word") (EVar "order"))) (EBinOp "+" (EVar "next") (ELit (LInt 1))))))))))
(DTypeSig false "graphChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphChildren" (PWild (PCon "GInt") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GBool") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GFloat") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GChar") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GString") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" (PWild (PCon "GUnit") PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GCustom" (PVar "custom")) (PVar "depth") (PVar "graph")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EVar "graph") (EMatch (EApp (EApp (EVar "customStructuralPlan") (EVar "env")) (EVar "custom")) (arm (PCon "None") () (EVar "graph")) (arm (PCon "Some" (PAs "plan" (PCon "GNominal" (PVar "key") PWild))) () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDisplayCtorChildren") (EVar "env")) (EVar "plan")) (EVar "ctors")) (EVar "depth")) (EVar "graph")) (EVar "graph"))) (arm (PCon "Err" PWild) () (EVar "graph")))) (arm (PCon "Some" PWild) () (EVar "graph")))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GList" (PVar "p")) (PVar "depth") (PVar "graph")) (EIf (EBinOp "<=" (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "depth")) (EVar "p")) (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GArray" (PVar "p")) (PVar "depth") (PVar "graph")) (EIf (EBinOp "<=" (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "depth")) (EVar "p")) (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GOption" (PVar "p")) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (EVar "depth")) (EVar "p")) (arm (PList PWild (PVar "someWeight")) () (EIf (EBinOp "<=" (EVar "someWeight") (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "p")) (EVar "depth")) (EVar "graph")))) (arm PWild () (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "ok")) (arm (PList (PVar "errWeight") (PVar "okWeight")) () (EBlock (DoLet false false (PVar "withErr") (EIf (EBinOp "<=" (EVar "errWeight") (ELit (LInt 0))) (EVar "graph") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "err")) (EVar "depth")) (EVar "graph")))) (DoExpr (EIf (EBinOp "<=" (EVar "okWeight") (ELit (LInt 0))) (EVar "withErr") (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "ok")) (EVar "depth")) (EVar "withErr")))))) (arm PWild () (EVar "graph"))))
(DFunDef false "graphChildren" ((PVar "env") (PCon "GTuple" (PVar "ps")) (PVar "depth") (PVar "graph")) (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EVar "ps")) (EVar "depth")) (EVar "graph")))
(DFunDef false "graphChildren" ((PVar "env") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "depth") (PVar "graph")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChildren") (EVar "env")) (EVar "plan")) (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "plan")) (EVar "depth"))) (EVar "depth")) (EVar "graph")) (EVar "graph")))))
(DTypeSig false "nominalCtorsVisible" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PlanVisibility") (TyCon "Bool")))))
(DFunDef false "nominalCtorsVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanAbstract")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DFunDef false "nominalCtorsVisible" (PWild PWild (PCon "PlanPublicCtors")) (EVar "True"))
(DFunDef false "nominalCtorsVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanLocal")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DTypeSig false "customStructuralPlan" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "CustomPlan") (TyApp (TyCon "Option") (TyCon "GenPlan")))))
(DFunDef false "customStructuralPlan" ((PVar "env") (PCon "CustomPlan" (PVar "key") (PVar "carrier") PWild)) (EApp (EApp (EMethodRef "map") (EApp (EVar "GNominal") (EVar "key"))) (EApp (EApp (EVar "customPlanArgs") (EVar "env")) (EApp (EVar "carrierArgs") (EVar "carrier")))))
(DTypeSig false "carrierArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "carrierArgs" ((PCon "TyApp" (PVar "head") (PVar "arg"))) (EBinOp "++" (EApp (EVar "carrierArgs") (EVar "head")) (EListLit (EVar "arg"))))
(DFunDef false "carrierArgs" (PWild) (EListLit))
(DTypeSig false "customPlanArgs" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "customPlanArgs" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "customPlanArgs" ((PVar "env") (PCons (PVar "ty") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (ELit (LString "custom display"))) (ELit (LString "value"))) (EVar "ty")) (EApp (EApp (EVar "customPlanArgs") (EVar "env")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Some" (PVar "plans"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm PWild () (EVar "None"))))
(DTypeSig false "graphExploreMany" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))
(DFunDef false "graphExploreMany" (PWild (PList) PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphExploreMany" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "depth") (PVar "graph")) (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EVar "rest")) (EVar "depth")) (EApp (EApp (EApp (EApp (EVar "graphExplore") (EVar "env")) (EVar "plan")) (EVar "depth")) (EVar "graph"))))
(DTypeSig false "graphCtorChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph"))))))))
(DFunDef false "graphCtorChildren" (PWild PWild (PList) PWild PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphCtorChildren" ((PVar "env") (PVar "plan") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "depth") (PVar "graph")) (EBlock (DoLet false false (PVar "next") (EIf (EBinOp "<=" (EVar "weight") (ELit (LInt 0))) (EVar "graph") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "fields"))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "graph")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChildren") (EVar "env")) (EVar "plan")) (EVar "rest")) (EVar "weights")) (EVar "depth")) (EVar "next")))))
(DFunDef false "graphCtorChildren" (PWild PWild PWild PWild PWild (PVar "graph")) (EVar "graph"))
(DTypeSig false "graphDisplayCtorChildren" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyCon "Int") (TyFun (TyCon "NativeGraph") (TyCon "NativeGraph")))))))
(DFunDef false "graphDisplayCtorChildren" (PWild PWild (PList) PWild (PVar "graph")) (EVar "graph"))
(DFunDef false "graphDisplayCtorChildren" ((PVar "env") (PVar "plan") (PCons (PVar "ctor") (PVar "rest")) (PVar "depth") (PVar "graph")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (EVar "graph")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "graphExploreMany") (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "fields"))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "graph"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "graphDisplayCtorChildren") (EVar "env")) (EVar "plan")) (EVar "rest")) (EVar "depth")) (EVar "next")))))
(DTypeSig false "genPlanWord" (TyFun (TyCon "GenPlan") (TyCon "String")))
(DFunDef false "genPlanWord" ((PCon "GInt")) (ELit (LString "int")))
(DFunDef false "genPlanWord" ((PCon "GBool")) (ELit (LString "bool")))
(DFunDef false "genPlanWord" ((PCon "GFloat")) (ELit (LString "float")))
(DFunDef false "genPlanWord" ((PCon "GChar")) (ELit (LString "char")))
(DFunDef false "genPlanWord" ((PCon "GString")) (ELit (LString "string")))
(DFunDef false "genPlanWord" ((PCon "GUnit")) (ELit (LString "unit")))
(DFunDef false "genPlanWord" ((PCon "GList" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "list(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GArray" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "array(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GOption" (PVar "p"))) (EBinOp "++" (EBinOp "++" (ELit (LString "option(")) (EApp (EVar "genPlanWord") (EVar "p"))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "result(")) (EApp (EMethodRef "display") (EApp (EVar "genPlanWord") (EVar "err")))) (ELit (LString ","))) (EApp (EMethodRef "display") (EApp (EVar "genPlanWord") (EVar "ok")))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GTuple" (PVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "tuple(")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "genPlanWord")) (EVar "ps")))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GNominal" (PVar "key") (PVar "ps"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "nominal(")) (EApp (EMethodRef "display") (EApp (EVar "typeKeyWord") (EVar "key")))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "genPlanWord")) (EVar "ps"))))) (ELit (LString ")"))))
(DFunDef false "genPlanWord" ((PCon "GCustom" (PCon "CustomPlan" PWild PWild (PVar "route")))) (EBinOp "++" (EBinOp "++" (ELit (LString "custom(")) (EVar "route")) (ELit (LString ")"))))
(DTypeSig false "genNodePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "genNodePrefix" ((PVar "nonce")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "gen"))))
(DTypeSig false "graphNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "graphNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString "_node_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "graphRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "depth")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "depth"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "panic \"native property runner: missing closed generator plan\"")))))
(DTypeSig false "graphLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))))
(DTypeSig false "graphLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "graphLinesGo" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphLinesGo" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PVar "nodes") (PCons (PVar "word") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") (PVar "plan") PWild)) () (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : Int -> "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "effectfulPlanSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "graphNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " depth = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EApp (EApp (EApp (EVar "NativeGraph") (EVar "nodes")) (EListLit)) (ELit (LInt 0)))) (EVar "prefix")) (EVar "plan")))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))))))
(DTypeSig false "graphDraw" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))
(DFunDef false "graphDraw" (PWild PWild (PVar "graph") (PVar "prefix") (PVar "plan")) (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "depth"))))
(DTypeSig false "graphCtorDraw" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))
(DFunDef false "graphCtorDraw" (PWild PWild (PVar "graph") (PVar "prefix") (PVar "plan")) (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "(depth + 1)"))))
(DTypeSig false "graphNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyCon "String")))))))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GInt")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "int ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GBool")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "bool ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GFloat")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".intToFloat ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose 2000001) * (1.0 / 1000000.0) - 1.0"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GChar")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "char ()"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GString")) (EApp (EApp (EVar "stringExpr") (EVar "nonce")) (ELit (LInt 0))))
(DFunDef false "graphNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GUnit")) (ELit (LString "()")))
(DFunDef false "graphNodeBody" ((PVar "nonce") PWild PWild (PVar "core") PWild PWild (PCon "GCustom" PWild)) (EApp (EApp (EVar "customDrawExpr") (EVar "nonce")) (EVar "core")))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepth") (EVar "nonce")) (ELit (LString "["))) (ELit (LString "]"))) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepth") (EVar "nonce")) (ELit (LString "[|"))) (ELit (LString "|]"))) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "renderOptionByDepth") (EVar "nonce")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "p"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderResultByDepth") (EVar "nonce")) (EVar "env")) (EVar "err")) (EVar "ok")) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "err"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "ok"))))
(DFunDef false "graphNodeBody" (PWild (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "graphDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix"))) (EVar "ps"))))) (ELit (LString ")"))))
(DFunDef false "graphNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (ELit (LString "panic \"native property runner: missing planned constructor\""))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorByDepth") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (ELit (LString "panic \"native property runner: inaccessible constructor\""))))))
(DTypeSig false "byDepth" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "byDepth" ((PVar "below") (PVar "atBound")) (EIf (EBinOp "==" (EVar "below") (EVar "atBound")) (EVar "below") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if depth < ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "maxGenDepth")))) (ELit (LString " then "))) (EApp (EMethodRef "display") (EVar "below"))) (ELit (LString " else "))) (EApp (EMethodRef "display") (EVar "atBound"))) (ELit (LString "")))))
(DTypeSig false "graphCtorByDepth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "String"))))))))))
(DFunDef false "graphCtorByDepth" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "ctors")) (EBlock (DoLet false false (PVar "choice") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoice") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors"))) (DoExpr (EApp (EApp (EVar "byDepth") (EApp (EVar "choice") (EApp (EApp (EVar "softCtorWeights") (EVar "env")) (EVar "plan")))) (EApp (EVar "choice") (EApp (EApp (EMethodRef "map") (EVar "SoftFixed")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "plan")) (EVar "maxGenDepth"))))))))
(DTypeSig false "softWeightPositive" (TyFun (TyCon "SoftWeight") (TyCon "Bool")))
(DFunDef false "softWeightPositive" ((PCon "SoftNever")) (EVar "False"))
(DFunDef false "softWeightPositive" ((PCon "SoftFixed" (PVar "weight"))) (EBinOp ">" (EVar "weight") (ELit (LInt 0))))
(DFunDef false "softWeightPositive" ((PCon "SoftDecaying" PWild)) (EVar "True"))
(DTypeSig false "anySoftWeightPositive" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "Bool")))
(DFunDef false "anySoftWeightPositive" ((PList)) (EVar "False"))
(DFunDef false "anySoftWeightPositive" ((PCons (PVar "weight") (PVar "rest"))) (EBinOp "||" (EApp (EVar "softWeightPositive") (EVar "weight")) (EApp (EVar "anySoftWeightPositive") (EVar "rest"))))
(DTypeSig false "softWeightExpr" (TyFun (TyCon "SoftWeight") (TyCon "String")))
(DFunDef false "softWeightExpr" ((PCon "SoftNever")) (ELit (LString "0")))
(DFunDef false "softWeightExpr" ((PCon "SoftFixed" (PVar "weight"))) (EApp (EVar "intToString") (EVar "weight")))
(DFunDef false "softWeightExpr" ((PCon "SoftDecaying" (PVar "start"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(if depth >= ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "start") (ELit (LInt 1)))))) (ELit (LString " then 1 else "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "start")))) (ELit (LString " - depth)"))))
(DTypeSig false "softWeightTotal" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "String")))
(DFunDef false "softWeightTotal" ((PVar "weights")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "weights")) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "softWeightTotalGo" (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "softWeightTotalGo" ((PList) (PVar "fixed") (PList)) (EApp (EVar "intToString") (EVar "fixed")))
(DFunDef false "softWeightTotalGo" ((PList) (PLit (LInt 0)) (PVar "decaying")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " + "))) (EVar "decaying")))) (ELit (LString ")"))))
(DFunDef false "softWeightTotalGo" ((PList) (PVar "fixed") (PVar "decaying")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fixed")))) (ELit (LString " + "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " + "))) (EVar "decaying")))) (ELit (LString ")"))))
(DFunDef false "softWeightTotalGo" ((PCons (PCon "SoftNever") (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EVar "fixed")) (EVar "decaying")))
(DFunDef false "softWeightTotalGo" ((PCons (PCon "SoftFixed" (PVar "weight")) (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EBinOp "+" (EVar "fixed") (EVar "weight"))) (EVar "decaying")))
(DFunDef false "softWeightTotalGo" ((PCons (PAs "weight" (PCon "SoftDecaying" PWild)) (PVar "rest")) (PVar "fixed") (PVar "decaying")) (EApp (EApp (EApp (EVar "softWeightTotalGo") (EVar "rest")) (EVar "fixed")) (EBinOp "::" (EApp (EVar "softWeightExpr") (EVar "weight")) (EVar "decaying"))))
(DTypeSig false "graphCtorChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyCon "String")))))))))))
(DFunDef false "graphCtorChoice" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DFunDef false "graphCtorChoice" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "ctors") (PVar "weights")) (EIf (EApp (EVar "not") (EApp (EVar "anySoftWeightPositive") (EVar "weights"))) (ELit (LString "panic \"native property runner: no finite constructor\"")) (EBlock (DoLet false false (PVar "picked") (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "ctor_choice")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(let ")) (EApp (EMethodRef "display") (EVar "picked"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EMethodRef "display") (EApp (EVar "softWeightTotal") (EVar "weights")))) (ELit (LString " in "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EVar "weights")) (EVar "picked")))) (ELit (LString ")")))))))
(DTypeSig false "graphCtorChoiceAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "SoftWeight")) (TyFun (TyCon "String") (TyCon "String"))))))))))))
(DFunDef false "graphCtorChoiceAt" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DFunDef false "graphCtorChoiceAt" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "picked")) (EIf (EApp (EVar "not") (EApp (EVar "softWeightPositive") (EVar "weight"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "rest")) (EVar "weights")) (EVar "picked")) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorValue") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctor"))) (DoLet false false (PVar "tail") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphCtorChoiceAt") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "rest")) (EVar "weights")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "picked"))) (ELit (LString " - "))) (EApp (EMethodRef "display") (EApp (EVar "softWeightExpr") (EVar "weight")))) (ELit (LString ")"))))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "anySoftWeightPositive") (EVar "weights"))) (EVar "here") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "picked"))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EApp (EVar "softWeightExpr") (EVar "weight")))) (ELit (LString " then "))) (EApp (EMethodRef "display") (EVar "here"))) (ELit (LString " else "))) (EApp (EMethodRef "display") (EVar "tail"))) (ELit (LString ""))))))))
(DFunDef false "graphCtorChoiceAt" (PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "panic \"native property runner: no finite constructor\"")))
(DTypeSig false "graphCtorValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "PlanCtor") (TyCon "String"))))))))))
(DFunDef false "graphCtorValue" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "panic \"native property runner: invalid constructor plan\""))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "graphCtorDraw") (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoExpr (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EVar "ref") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "paren")) (EVar "values"))))) (ELit (LString ""))))))))))
(DTypeSig false "renderOptionChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "renderOptionChoice" ((PVar "nonce") (PList (PVar "noneWeight") (PVar "someWeight")) (PVar "child")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EMethodRef "display") (EBinOp "+" (EVar "noneWeight") (EVar "someWeight")))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EVar "noneWeight"))) (ELit (LString " then None else Some ("))) (EApp (EMethodRef "display") (EVar "child"))) (ELit (LString ")"))))
(DFunDef false "renderOptionChoice" (PWild PWild (PVar "child")) (EBinOp "++" (EBinOp "++" (ELit (LString "Some (")) (EApp (EMethodRef "display") (EVar "child"))) (ELit (LString ")"))))
(DTypeSig false "renderOptionByDepth" (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderOptionByDepth" ((PVar "nonce") (PVar "env") (PVar "p") (PVar "child")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EVar "renderOptionChoice") (EVar "nonce")) (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (ELit (LInt 0))) (EVar "p"))) (EVar "child"))) (EApp (EApp (EApp (EVar "renderOptionChoice") (EVar "nonce")) (EApp (EApp (EApp (EVar "optionWeights") (EVar "env")) (EVar "maxGenDepth")) (EVar "p"))) (EVar "child"))))
(DTypeSig false "renderResultChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderResultChoice" ((PVar "nonce") (PList (PVar "errWeight") (PVar "okWeight")) (PVar "error") (PVar "ok")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EMethodRef "display") (EBinOp "+" (EVar "errWeight") (EVar "okWeight")))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EVar "errWeight"))) (ELit (LString " then Err ("))) (EApp (EMethodRef "display") (EVar "error"))) (ELit (LString ") else Ok ("))) (EApp (EMethodRef "display") (EVar "ok"))) (ELit (LString ")"))))
(DFunDef false "renderResultChoice" (PWild PWild (PVar "error") PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "Err (")) (EApp (EMethodRef "display") (EVar "error"))) (ELit (LString ")"))))
(DTypeSig false "renderResultByDepth" (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderResultByDepth" ((PVar "nonce") (PVar "env") (PVar "err") (PVar "ok") (PVar "error") (PVar "okExpr")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EApp (EVar "renderResultChoice") (EVar "nonce")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (ELit (LInt 0))) (EVar "err")) (EVar "ok"))) (EVar "error")) (EVar "okExpr"))) (EApp (EApp (EApp (EApp (EVar "renderResultChoice") (EVar "nonce")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EVar "env")) (EVar "maxGenDepth")) (EVar "err")) (EVar "ok"))) (EVar "error")) (EVar "okExpr"))))
(DTypeSig false "customDrawExpr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "customDrawExpr" ((PVar "nonce") (PVar "core")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  let caller = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()\n  let _ = "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState (!"))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state)\n  let x = "))) (EApp (EMethodRef "display") (EVar "core"))) (ELit (LString ".arbitrary ()\n  let next = "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()\n  let _ = "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state := next\n  let _ = "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState caller\n  x"))))
(DTypeSig false "stringExpr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "stringExpr" ((PVar "nonce") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "string ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose (if depth >= "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "maxGenDepth")))) (ELit (LString " then 1 else 11))"))))
(DTypeSig false "renderListByDepth" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListByDepth" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "env") (PVar "p") (PVar "child")) (EIf (EApp (EApp (EVar "listBoundDecays") (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoiceN") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EVar "listLenMax")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(if depth >= ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "listLenMax")))) (ELit (LString " then 1 else "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "listLenMax") (ELit (LInt 1)))))) (ELit (LString " - depth)")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListByDepthFlat") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "env")) (EVar "p")) (EVar "child"))))
(DTypeSig false "renderListByDepthFlat" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListByDepthFlat" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "env") (PVar "p") (PVar "child")) (EApp (EApp (EVar "byDepth") (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoice") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (ELit (LInt 0))) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoice") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EApp (EApp (EApp (EVar "listLengthBound") (EVar "env")) (EVar "maxGenDepth")) (EVar "p")))))
(DTypeSig false "renderListChoice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "renderListChoice" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "child") (PVar "bound")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderListChoiceN") (EVar "nonce")) (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (EApp (EVar "intToString") (EBinOp "+" (EVar "bound") (ELit (LInt 1))))))
(DTypeSig false "renderListChoiceN" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "renderListChoiceN" ((PVar "nonce") (PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "count")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "choose "))) (EApp (EMethodRef "display") (EDictApp "count"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EVar "renderListArms") (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (ELit (LInt 0))))) (ELit (LString ""))))
(DTypeSig false "renderListArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "renderListArms" ((PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "n")) (EIf (EBinOp ">" (EVar "n") (EVar "bound")) (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderListArms" ((PVar "open") (PVar "close") (PVar "child") (PVar "bound") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "n") (EVar "bound")) (ELit (LString "_")) (EApp (EVar "intToString") (EVar "n"))))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "open"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "repeatString") (EVar "child")) (EVar "n"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "close"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EVar "renderListArms") (EVar "open")) (EVar "close")) (EVar "child")) (EVar "bound")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (ELit (LString ""))))
(DTypeSig false "repeatString" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "repeatString" (PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "repeatString" ((PVar "x") (PVar "n")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "repeatString") (EVar "x")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "qualifiedCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "qualifiedCtor" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "moduleAlias") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (arm (PCon "Some" (PVar "alias")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "ctor"))))
(DTypeSig false "hasNamedField" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyCon "Bool")))
(DFunDef false "hasNamedField" ((PList)) (EVar "False"))
(DFunDef false "hasNamedField" ((PCons (PTuple (PCon "Some" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "hasNamedField" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasNamedField") (EVar "rest")))
(DTypeSig false "namedAssignments" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "namedAssignments" ((PList) PWild) (EListLit))
(DFunDef false "namedAssignments" (PWild (PList)) (EListLit))
(DFunDef false "namedAssignments" ((PCons (PTuple (PCon "Some" (PVar "name")) PWild) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "value"))) (ELit (LString ""))) (EApp (EApp (EVar "namedAssignments") (EVar "rest")) (EVar "values"))))
(DFunDef false "namedAssignments" ((PCons (PTuple (PCon "None") PWild) (PVar "rest")) (PCons PWild (PVar "values"))) (EApp (EApp (EVar "namedAssignments") (EVar "rest")) (EVar "values")))
(DTypeSig false "paren" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "paren" ((PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ")"))))
(DTypeSig false "shrinkNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "shrinkNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString "_shrink_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "displayNodeName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "displayNodeName" ((PVar "prefix") (PVar "ident")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString "_display_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ident")))) (ELit (LString ""))))
(DTypeSig false "graphShrinkRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphShrinkRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "[]")))))
(DTypeSig false "graphDisplayRef" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "graphDisplayRef" ((PCon "NativeGraph" (PVar "nodes") PWild PWild) (PVar "prefix") (PVar "plan") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "genPlanWord") (EVar "plan"))) (EVar "nodes")) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") PWild PWild)) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "\"<unavailable>\"")))))
(DTypeSig false "graphAuxLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphAuxLines" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PCon "NativeGraph" (PVar "nodes") (PVar "order") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EApp (EVar "reverseL") (EVar "order"))))
(DTypeSig false "graphAuxLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GraphNode")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "graphAuxLinesGo" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphAuxLinesGo" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "core") (PVar "prefix") (PVar "nodes") (PCons (PVar "word") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "nodes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))) (arm (PCon "Some" (PCon "GraphNode" (PVar "ident") (PVar "plan") PWild)) () (EBlock (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "NativeGraph") (EVar "nodes")) (EListLit)) (ELit (LInt 0)))) (DoExpr (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString " -> List ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " value = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "value"))))) (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "planSourceTy") (EVar "nonce")) (EVar "modules")) (EVar "plan")))) (ELit (LString " -> String"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "displayNodeName") (EVar "prefix")) (EVar "ident")))) (ELit (LString " value = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "displayNodeBody") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "value"))))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphAuxLinesGo") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "core")) (EVar "prefix")) (EVar "nodes")) (EVar "rest"))))))))
(DTypeSig false "candidateNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GInt") (PVar "name")) (EApp (EVar "nativeIntCandidates") (EVar "name")))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GBool") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " then [False] else []"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GFloat") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " == 0.0 then [] else [0.0, "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " / 2.0]"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GChar") PWild) (ELit (LString "[]")))
(DFunDef false "candidateNodeBody" ((PVar "nonce") PWild PWild PWild PWild PWild (PCon "GString") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " == \"\" then [] else ["))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".stringSlice 0 ("))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".stringLength "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " / 2) "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "]"))))
(DFunDef false "candidateNodeBody" (PWild PWild PWild PWild PWild PWild (PCon "GUnit") PWild) (ELit (LString "[]")))
(DFunDef false "candidateNodeBody" (PWild PWild PWild (PVar "core") PWild PWild (PCon "GCustom" PWild) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "core"))) (ELit (LString ".shrink "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GList") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GArray") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "p")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GOption") (EVar "p")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PAs "result" (PCon "GResult" (PVar "err") (PVar "ok"))) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "err")) (EVar "ok")) (EVar "name")) (EApp (EVar "shrinkActions") (EVar "result"))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps")) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ps")) (EVar "name")) (EApp (EVar "shrinkActions") (EApp (EVar "GTuple") (EVar "ps")))))
(DFunDef false "candidateNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") PWild (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidates") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name")))
(DTypeSig false "displayNodeBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GInt") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".intToString "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild PWild PWild (PCon "GBool") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " then \"True\" else \"False\""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GFloat") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GChar") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild PWild PWild (PCon "GString") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".debug "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild PWild PWild (PCon "GUnit") PWild) (ELit (LString "\"()\"")))
(DFunDef false "displayNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PCon "GCustom" (PAs "custom" (PCon "CustomPlan" (PVar "key") PWild PWild))) (PVar "name")) (EMatch (EApp (EApp (EVar "customStructuralPlan") (EVar "env")) (EVar "custom")) (arm (PCon "Some" (PVar "plan")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplay") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name"))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "\"<")) (EApp (EMethodRef "display") (EApp (EVar "typeKeyName") (EVar "key")))) (ELit (LString ">\""))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild (PVar "graph") (PVar "prefix") (PCon "GList" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"[\" ++ ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings \", \" ("))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (x => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString ") "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ") ++ \"]\""))))
(DFunDef false "displayNodeBody" ((PVar "nonce") PWild PWild (PVar "graph") (PVar "prefix") (PCon "GArray" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"[|\" ++ ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "join_strings \", \" ("))) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (x => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString ") ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ")) ++ \"|]\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GOption" (PVar "p")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  None => \"None\"\n  Some x => \"Some (\" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "p")) (ELit (LString "x"))))) (ELit (LString " ++ \")\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  Err x => \"Err (\" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "err")) (ELit (LString "x"))))) (ELit (LString " ++ \")\"\n  Ok x => \"Ok (\" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "ok")) (ELit (LString "x"))))) (ELit (LString " ++ \")\""))))
(DFunDef false "displayNodeBody" (PWild PWild PWild (PVar "graph") (PVar "prefix") (PCon "GTuple" (PVar "ps")) (PVar "name")) (EBlock (DoLet false false (PVar "vars") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "ps")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "vars")))) (ELit (LString ") => \"(\" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplays") (EVar "graph")) (EVar "prefix")) (EVar "ps")) (EVar "vars")))) (ELit (LString " ++ \")\""))))))
(DFunDef false "displayNodeBody" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PAs "plan" (PCon "GNominal" (PVar "key") PWild)) (PVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplay") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "key")) (EVar "name")))
(DTypeSig false "nativeIntCandidates" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nativeIntCandidates" ((PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " == 0 then [] else ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "nativeIntStep") (EVar "name"))) (EVar "intShrinkSteps"))))) (ELit (LString "]"))))
(DTypeSig false "nativeIntStep" (TyFun (TyCon "String") (TyFun (TyCon "IntShrinkStep") (TyCon "String"))))
(DFunDef false "nativeIntStep" (PWild (PCon "IntToZero")) (ELit (LString "0")))
(DFunDef false "nativeIntStep" ((PVar "name") (PCon "IntHalf")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " / 2"))))
(DFunDef false "nativeIntStep" ((PVar "name") (PCon "IntTowardZero")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " + (if "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " > 0 then -1 else 1)"))))
(DTypeSig false "joinCandidateFamilies" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCandidateFamilies" ((PList)) (ELit (LString "[]")))
(DFunDef false "joinCandidateFamilies" ((PList (PVar "family"))) (EVar "family"))
(DFunDef false "joinCandidateFamilies" ((PCons (PVar "family") (PVar "families"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "family"))) (ELit (LString " ++ "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EVar "families")))) (ELit (LString ""))))
(DTypeSig false "graphListCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphListCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DTypeSig false "graphListCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphListCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "DeleteElements") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each (x => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ") "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphListCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphListCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions")))
(DTypeSig false "graphArrayCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphArrayCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DTypeSig false "graphArrayCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphArrayCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "DeleteElements") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayFromList ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "delete_each ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "))"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".arrayFromList ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "replace_each (x => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ") ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "array_to_list "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "))"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions"))))
(DFunDef false "graphArrayCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphArrayCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "name")) (EVar "actions")))
(DTypeSig false "graphOptionCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphOptionCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "name") (PVar "actions")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  None => []\n  Some x => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))) (ELit (LString ""))))
(DTypeSig false "graphOptionCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "graphOptionCandidateFamilies" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons (PCon "ReplaceEarlierNullary") (PVar "actions"))) (EBinOp "::" (ELit (LString "[None]")) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map Some ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ")"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions"))))
(DFunDef false "graphOptionCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphOptionCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "actions")))
(DTypeSig false "graphResultCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))
(DFunDef false "graphResultCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "err") (PVar "ok") (PVar "name") (PVar "actions")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  Err x => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "err")) (ELit (LString "Err"))) (EVar "actions"))))) (ELit (LString "\n  Ok x => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ok")) (ELit (LString "Ok"))) (EVar "actions"))))) (ELit (LString ""))))
(DTypeSig false "graphResultCandidateFamilies" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "graphResultCandidateFamilies" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "graphResultCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "tag") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map "))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (ELit (LString "x"))))) (ELit (LString ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "tag")) (EVar "actions"))))
(DFunDef false "graphResultCandidateFamilies" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "tag") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphResultCandidateFamilies") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "tag")) (EVar "actions")))
(DTypeSig false "graphTupleCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String"))))))))
(DFunDef false "graphTupleCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "name") (PVar "actions")) (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "plans")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n  ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "values")))) (ELit (LString ") => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values")) (EVar "values")) (EVar "actions")))) (ELit (LString ""))))))
(DTypeSig false "graphTupleCandidatesByActions" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))
(DFunDef false "graphTupleCandidatesByActions" (PWild PWild PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphTupleCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "all") (PVar "values") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidateLists") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EDictApp "all")) (EVar "values")) (ELit (LInt 0))))) (ELit (LString " ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EDictApp "all")) (EVar "values")) (EVar "actions")))) (ELit (LString ""))))
(DFunDef false "graphTupleCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "plans") (PVar "all") (PVar "values") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EDictApp "all")) (EVar "values")) (EVar "actions")))
(DTypeSig false "graphTupleCandidateLists" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") PWild PWild (PList) PWild PWild PWild) (ELit (LString "[]")))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PVar "all") (PCons (PVar "value") (PVar "values")) (PVar "index")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (candidate => ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EApp (EVar "replaceName") (EMethodRef "index")) (ELit (LString "candidate"))) (EDictApp "all"))))) (ELit (LString ")) ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ") ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphTupleCandidateLists") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EDictApp "all")) (EVar "values")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "graphTupleCandidateLists" ((PVar "nonce") PWild PWild PWild PWild PWild PWild) (ELit (LString "[]")))
(DTypeSig false "graphNominalCandidates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "graphNominalCandidates" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "key") (PVar "name")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Err" PWild) () (ELit (LString "[]"))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArms") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EVar "None"))))) (ELit (LString ""))) (ELit (LString "[]"))))))
(DTypeSig false "graphNominalCandidateArms" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyApp (TyCon "List") (TyCon "String"))))))))))))
(DFunDef false "graphNominalCandidateArms" (PWild PWild PWild PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "graphNominalCandidateArms" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PCons (PVar "ctor") (PVar "ctors")) (PVar "earlier")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArm") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "earlier")) (EVar "ctor")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalCandidateArms") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner")) (EVar "ctors")) (EApp (EApp (EVar "nextEarlierNullary") (EVar "earlier")) (EVar "ctor")))))
(DTypeSig false "nextEarlierNullary" (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyCon "PlanCtor") (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "nextEarlierNullary" ((PCon "None") (PAs "ctor" (PCon "PlanCtor" PWild PWild (PList)))) (EApp (EVar "Some") (EVar "ctor")))
(DFunDef false "nextEarlierNullary" ((PVar "earlier") (PCon "PlanCtor" PWild PWild (PList))) (EVar "earlier"))
(DFunDef false "nextEarlierNullary" ((PVar "earlier") PWild) (EVar "earlier"))
(DTypeSig false "graphNominalCandidateArm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyCon "PlanCtor") (TyCon "String")))))))))))
(DFunDef false "graphNominalCandidateArm" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PVar "earlier") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "  _ => []"))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoLet false false (PVar "replacements") (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalReplacementByActions") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")) (EApp (EVar "shrinkActions") (EVar "plan")))) (DoExpr (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " } => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "fields")) (EVar "fields")) (EVar "values")) (EVar "values")) (EVar "True")) (ELit (LInt 0))) (EApp (EVar "shrinkActions") (EVar "plan"))))))) (ELit (LString ""))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "values")))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "joinCandidateFamilies") (EListLit (EVar "replacements") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EVar "fields")) (EVar "fields")) (EVar "values")) (EVar "values")) (EVar "False")) (ELit (LInt 0))) (EApp (EVar "shrinkActions") (EVar "plan"))))))) (ELit (LString ""))))))))))
(DTypeSig false "graphNominalReplacementByActions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))
(DFunDef false "graphNominalReplacementByActions" (PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphNominalReplacementByActions" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "earlier") (PCons (PCon "ReplaceEarlierNullary") PWild)) (EApp (EApp (EApp (EApp (EVar "graphNominalReplacement") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")))
(DFunDef false "graphNominalReplacementByActions" ((PVar "nonce") (PVar "modules") (PVar "owner") (PVar "earlier") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalReplacementByActions") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "earlier")) (EVar "actions")))
(DTypeSig false "graphNominalReplacement" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "PlanCtor")) (TyCon "String"))))))
(DFunDef false "graphNominalReplacement" (PWild PWild PWild (PCon "None")) (ELit (LString "[]")))
(DFunDef false "graphNominalReplacement" ((PVar "nonce") (PVar "modules") (PVar "owner") (PCon "Some" (PCon "PlanCtor" (PVar "source") PWild (PList)))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source")))) (ELit (LString "]"))))
(DFunDef false "graphNominalReplacement" (PWild PWild PWild (PCon "Some" PWild)) (ELit (LString "[]")))
(DTypeSig false "graphNominalFieldCandidatesByActions" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ShrinkAction")) (TyCon "String")))))))))))))
(DFunDef false "graphNominalFieldCandidatesByActions" (PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild (PList)) (ELit (LString "[]")))
(DFunDef false "graphNominalFieldCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PVar "fields") (PVar "allValues") (PVar "values") (PVar "named") (PVar "index") (PCons (PCon "ShrinkChildren") (PVar "actions"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EDictApp "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EMethodRef "index")))) (ELit (LString " ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EDictApp "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EMethodRef "index")) (EVar "actions")))) (ELit (LString ""))))
(DFunDef false "graphNominalFieldCandidatesByActions" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PVar "fields") (PVar "allValues") (PVar "values") (PVar "named") (PVar "index") (PCons PWild (PVar "actions"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidatesByActions") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EDictApp "all")) (EVar "fields")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EMethodRef "index")) (EVar "actions")))
(DTypeSig false "graphNominalFieldCandidates" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyCon "String"))))))))))))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") PWild PWild PWild PWild (PList) PWild PWild PWild PWild) (ELit (LString "[]")))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") (PVar "graph") (PVar "prefix") (PVar "ref") (PVar "all") (PCons (PTuple PWild (PVar "plan")) (PVar "rest")) (PVar "allValues") (PCons (PVar "value") (PVar "values")) (PVar "named") (PVar "index")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "coreAlias") (EVar "nonce")))) (ELit (LString ".map (candidate => "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "rebuildCtor") (EVar "ref")) (EDictApp "all")) (EApp (EApp (EApp (EVar "replaceName") (EMethodRef "index")) (ELit (LString "candidate"))) (EVar "allValues"))) (EVar "named")))) (ELit (LString ") ("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ") ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalFieldCandidates") (EVar "nonce")) (EVar "graph")) (EVar "prefix")) (EVar "ref")) (EDictApp "all")) (EVar "rest")) (EVar "allValues")) (EVar "values")) (EVar "named")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "graphNominalFieldCandidates" ((PVar "nonce") PWild PWild PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "[]")))
(DTypeSig false "graphJoinDisplays" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphJoinDisplays" (PWild PWild (PList) PWild) (ELit (LString "\"\"")))
(DFunDef false "graphJoinDisplays" ((PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")) (EApp (EApp (EApp (EApp (EVar "graphJoinDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values"))))
(DFunDef false "graphJoinDisplays" (PWild PWild PWild PWild) (ELit (LString "\"\"")))
(DTypeSig false "graphJoinDisplaysTail" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphJoinDisplaysTail" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphJoinDisplaysTail" ((PVar "graph") (PVar "prefix") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \", \" ++ ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "plans")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphJoinDisplaysTail" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "graphNominalDisplay" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "graphNominalDisplay" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PCon "TypeKey" (PVar "typeName") (PVar "origin")) (PVar "name")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EApp (EApp (EVar "TypeKey") (EVar "typeName")) (EVar "origin"))) (arm (PCon "Err" PWild) () (ELit (LString "\"<unavailable>\""))) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalCtorsVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "match ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphNominalDisplayArm") (EVar "nonce")) (EVar "modules")) (EVar "env")) (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "owner"))) (EVar "ctors"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"<")) (EApp (EMethodRef "display") (EVar "typeName"))) (ELit (LString ">\"")))))))
(DTypeSig false "graphNominalDisplayArm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyFun (TyCon "PlanCtor") (TyCon "String"))))))))))
(DFunDef false "graphNominalDisplayArm" ((PVar "nonce") (PVar "modules") (PVar "env") (PVar "graph") (PVar "prefix") (PVar "plan") (PVar "owner") (PAs "ctor" (PCon "PlanCtor" (PVar "source") PWild PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "plan")) (EVar "ctor")) (arm (PCon "Err" PWild) () (ELit (LString "  _ => \"<unavailable>\""))) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PVar "values") (EApp (EVar "tupleVars") (EApp (EVar "listLen") (EVar "fields")))) (DoLet false false (PVar "ref") (EApp (EApp (EApp (EApp (EVar "qualifiedCtor") (EVar "nonce")) (EVar "modules")) (EVar "owner")) (EVar "source"))) (DoLet false false (PVar "text") (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "source"))) (ELit (LString " { \" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplays") (EVar "graph")) (EVar "prefix")) (EVar "fields")) (EVar "values")))) (ELit (LString " ++ \" }\""))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "source"))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "source"))) (ELit (LString " (\" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphJoinDisplays") (EVar "graph")) (EVar "prefix")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "fields"))) (EVar "values")))) (ELit (LString " ++ \")\"")))))) (DoLet false false (PVar "pat") (EIf (EApp (EVar "hasNamedField") (EVar "fields")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "values")) (ELit (LInt 0))) (EVar "ref") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "values")))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "pat"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString ""))))))))
(DTypeSig false "graphNamedDisplays" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphNamedDisplays" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphNamedDisplays" ((PVar "graph") (PVar "prefix") (PCons (PTuple (PCon "Some" (PVar "field")) (PVar "plan")) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString " = \" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphNamedDisplays" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "graphNamedDisplaysTail" (TyFun (TyCon "NativeGraph") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "graphNamedDisplaysTail" (PWild PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "graphNamedDisplaysTail" ((PVar "graph") (PVar "prefix") (PCons (PTuple (PCon "Some" (PVar "field")) (PVar "plan")) (PVar "rest")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \", \" ++ \"")) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString " = \" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EVar "prefix")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphNamedDisplaysTail") (EVar "graph")) (EVar "prefix")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))
(DFunDef false "graphNamedDisplaysTail" (PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "plannedRunLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "plannedRunLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  if ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases <= 0 then (True, \"\") else")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedBindings") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0)))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    let ok = ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))))) (EApp (EApp (EApp (EApp (EVar "plannedFailureLines") (EVar "nonce")) (EVar "i")) (EVar "ps")) (EVar "plans"))) (EListLit (ELit (LString "")))))
(DTypeSig false "plannedBindings" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedBindings" ((PVar "nonce") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" PWild PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    let ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (ELit (LString "0"))))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedBindings") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DFunDef false "plannedBindings" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "slotName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "slotName" ((PVar "nonce") (PVar "i") (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "arg_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "paramSlots" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "paramSlots" ((PVar "nonce") (PVar "i") (PVar "ps")) (EApp (EApp (EApp (EApp (EVar "paramSlotsGo") (EVar "nonce")) (EVar "i")) (EVar "ps")) (ELit (LInt 0))))
(DTypeSig false "paramSlotsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "paramSlotsGo" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "paramSlotsGo" ((PVar "nonce") (PVar "i") (PCons PWild (PVar "rest")) (PVar "j")) (EBinOp "::" (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j")) (EApp (EApp (EApp (EApp (EVar "paramSlotsGo") (EVar "nonce")) (EVar "i")) (EVar "rest")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DTypeSig false "plannedFailureLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "plannedFailureLines" ((PVar "nonce") (PVar "i") (PList) PWild) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    if ok then ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases - 1) else (False, \"counterexample\")")))))
(DFunDef false "plannedFailureLines" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "plans")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    if ok then ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "cases - 1) else "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "plannedShrinkStart") (EVar "nonce")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString "")))))
(DTypeSig false "plannedShrinkStart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "plannedShrinkStart" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "plans")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " 100 "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))))
(DTypeSig false "shrinkName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "shrinkName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "shrink_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "plannedShrinkLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "plannedShrinkLines" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "plannedShrinkLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTopLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0)))))
(DTypeSig false "shrinkTopLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "shrinkTopLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EBlock (DoLet false false (PVar "startCandidates") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateExprAt") (EVar "nonce")) (EVar "graph")) (EVar "i")) (ELit (LInt 0))) (EApp (EApp (EVar "nthPlan") (ELit (LInt 0))) (EVar "plans"))) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (ELit (LInt 0))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString " ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  if ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel <= 0 then (False, "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlots") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString " ++ \" (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)\") else "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (ELit (LInt 0))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EMethodRef "display") (EVar "startCandidates"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))))) (ELit (LString ""))) (ELit (LString ""))))))
(DTypeSig false "shrinkTryName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "shrinkTryName" ((PVar "nonce") (PVar "i") (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "try_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "shrinkTryLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "shrinkTryLines" ((PVar "nonce") PWild PWild PWild (PList) PWild PWild) (EListLit))
(DFunDef false "shrinkTryLines" ((PVar "nonce") PWild PWild PWild (PVar "ps") PWild (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "listLen") (EVar "ps"))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "shrinkTryLines" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") (PVar "j")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLine") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EVar "j")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkTryLines") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))
(DTypeSig false "shrinkTryLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "shrinkTryLine" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans") (PVar "j")) (EBlock (DoLet false false (PVar "current") (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))) (DoLet false false (PVar "plan") (EApp (EApp (EVar "nthPlan") (EVar "j")) (EVar "plans"))) (DoLet false false (PVar "params") (EApp (EApp (EApp (EVar "paramSlots") (EVar "nonce")) (EVar "i")) (EVar "ps"))) (DoLet false false (PVar "after") (EIf (EBinOp ">=" (EBinOp "+" (EVar "j") (ELit (LInt 1))) (EApp (EVar "listLen") (EVar "ps"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(False, ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlots") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")))) (ELit (LString ")"))) (EBlock (DoLet false false (PVar "nextCandidates") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "candidateExprAt") (EVar "nonce")) (EVar "graph")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EApp (EVar "nthPlan") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "plans"))) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EMethodRef "display") (EVar "nextCandidates"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString ""))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidates "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString " ="))) (EBinOp "++" (EBinOp "++" (ELit (LString "  match ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidates"))) (EBinOp "++" (EBinOp "++" (ELit (LString "    [] => ")) (EApp (EMethodRef "display") (EVar "after"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "candidate :: "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "rest =>"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      if ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "replaceName") (EVar "j")) (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "candidate")))) (EVar "params"))))) (ELit (LString " then "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "shrinkTryName") (EVar "nonce")) (EVar "i")) (EVar "j")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel "))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "rest "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "params")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      else ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "shrinkName") (EVar "nonce")) (EVar "i")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "fuel - 1) "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "replaceName") (EVar "j")) (EApp (EApp (EVar "generatedName") (EVar "nonce")) (ELit (LString "candidate")))) (EVar "params"))))) (ELit (LString ""))) (ELit (LString ""))))))
(DTypeSig false "nthPlan" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "GenPlan"))))
(DFunDef false "nthPlan" ((PLit (LInt 0)) (PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "nthPlan" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "nthPlan") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))
(DFunDef false "nthPlan" (PWild (PList)) (EVar "GUnit"))
(DTypeSig false "candidateExprAt" (TyFun (TyCon "String") (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "String") (TyCon "String"))))))))
(DFunDef false "candidateExprAt" ((PVar "nonce") (PVar "graph") PWild PWild (PVar "plan") (PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphShrinkRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "replaceName" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "replaceName" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceName" ((PLit (LInt 0)) (PVar "replacement") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "replacement") (EVar "rest")))
(DFunDef false "replaceName" ((PVar "n") (PVar "replacement") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "replaceName") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "replacement")) (EVar "rest"))))
(DTypeSig false "plannedDetailSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))))
(DFunDef false "plannedDetailSlots" (PWild PWild PWild PWild (PList) PWild) (ELit (LString "\"counterexample\"")))
(DFunDef false "plannedDetailSlots" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PVar "ps") (PVar "plans")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsGo") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "ps")) (EVar "plans")) (ELit (LInt 0))))
(DTypeSig false "plannedDetailSlotsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "plannedDetailSlotsGo" (PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "\"counterexample\"")))
(DFunDef false "plannedDetailSlotsGo" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" (PVar "name") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = \" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsTail") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "plannedDetailSlotsGo" (PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "\"counterexample\"")))
(DTypeSig false "plannedDetailSlotsTail" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "NativeGraph") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "String")))))))))
(DFunDef false "plannedDetailSlotsTail" (PWild PWild PWild PWild (PList) PWild PWild) (ELit (LString "")))
(DFunDef false "plannedDetailSlotsTail" ((PVar "nonce") (PVar "modules") (PVar "graph") (PVar "i") (PCons (PCon "PropParam" (PVar "name") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans")) (PVar "j")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ++ \"\\n\" ++ \"")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = \" ++ "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "graphDisplayRef") (EVar "graph")) (EApp (EVar "genNodePrefix") (EVar "nonce"))) (EVar "plan")) (EApp (EApp (EApp (EVar "slotName") (EVar "nonce")) (EVar "i")) (EVar "j"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "plannedDetailSlotsTail") (EVar "nonce")) (EVar "modules")) (EVar "graph")) (EVar "i")) (EVar "rest")) (EVar "plans")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString ""))))
(DFunDef false "plannedDetailSlotsTail" (PWild PWild PWild PWild PWild PWild PWild) (ELit (LString "")))
(DTypeSig false "tupleVars" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tupleVars" ((PVar "n")) (EApp (EApp (EVar "tupleVarsGo") (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "tupleVarsGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tupleVarsGo" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "v")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))) (EApp (EApp (EVar "tupleVarsGo") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "rebuildCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyCon "String"))))))
(DFunDef false "rebuildCtor" ((PVar "ref") (PVar "fields") (PVar "values") (PVar "named")) (EIf (EVar "named") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "namedAssignments") (EVar "fields")) (EVar "values"))))) (ELit (LString " }"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ref"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "paren")) (EVar "values"))))) (ELit (LString "")))))
(DTypeSig false "plannedMainLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NativePlanOutcome")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedMainLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "plannedMainLines" ((PVar "nonce") (PCons (PCon "NativeRunnable" (PCon "DProp" PWild PWild (PVar "params") PWild) (PVar "r") (PVar "plans")) (PVar "rest")) (PVar "i")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "startTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "state := (("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString " % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ") + "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ") % "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "structuralRngModulus")))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let caller = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".setSeed "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "custom_state := "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".randomState ()"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".restoreRandomState caller"))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let seed = ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "propRequestSeed") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "seedTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".intToString seed")))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let (ok, detail) = ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "runName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "propRequestCases") (EVar "r"))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "boolTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (EBinOp "++" (EApp (EVar "coreAlias") (EVar "nonce")) (ELit (LString ".debug ok")))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeAlias") (EVar "nonce")))) (ELit (LString ".putStrLn \""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "sentinelFor") (EVar "nonce")) (EApp (EVar "detailTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "valuePrintExprWith") (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".putStrLn")))) (EBinOp "++" (EApp (EVar "runtimeAlias") (EVar "nonce")) (ELit (LString ".debugStringLit")))) (ELit (LString "detail"))))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "plannedMainLines" ((PVar "nonce") (PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EApp (EVar "plannedMainLines") (EVar "nonce")) (EVar "rest")) (EVar "i")))
(DTypeSig false "probeTargetSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "probeTargetSource" ((PVar "target") (PVar "src")) (EIf (EBinOp "==" (EApp (EVar "baseOf") (EVar "target")) (ELit (LString "core.mdk"))) (ELit (LString "")) (EApp (EVar "renameUserMain") (EVar "src"))))
(DTypeSig false "fnName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "fnName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "prop_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "runName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "runName" ((PVar "nonce") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "generatedPrefix") (EVar "nonce")))) (ELit (LString "run_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "fnLines" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fnLines" ((PVar "nonce") (PVar "i") (PVar "ps") (PVar "body")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "fnName") (EVar "nonce")) (EVar "i")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "paramName")) (EVar "ps"))))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EVar "body")))) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig false "paramName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "paramName" ((PCon "PropParam" (PVar "n") PWild PWild)) (EVar "n"))
