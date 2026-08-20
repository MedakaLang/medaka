# META
source_lines=362
stages=DESUGAR,MARK
# SOURCE
-- X-0D's additive elaboration-to-engine comparison carrier (#1399).
--
-- This module deliberately does NOT define ValidSemanticProgram. The draft is
-- visible, non-authoritative, and consumed only by its structural probe. It
-- inventories the semantic inputs today's emitters receive through CProgram or
-- install* hooks while the authoritative identity/type/call/evidence producers
-- are still landing. Physical emitters must not import this module.

import frontend.ast.{Decl}
import ir.core_ir.{CProgram(..)}
import ir.core_ir_lower.{
  lowerProgramEmit,
  returnsSelfTable,
  selfFnParamTable,
  methodIfaceTable,
  methodConstraintIfaces,
  ctorFieldTypeNames,
  declSigTypeNames,
}
import ir.core_ir_sexp.{cprogramToSexp}
import ir.dce.{dceFilter}
import ir.sexp.{boolStr, node, slist}
import support.util.{escStr, listLen}

-- Provenance is typed rather than free-form so producer changes move the draft
-- schema instead of silently changing a comment or diagnostic string.
public export data DraftProducer =
  | ProducerLoadedRuntime
  | ProducerElaborateModules
  | ProducerLowerProgramEmit
  | ProducerReturnsSelfTable
  | ProducerSelfFnParamTable
  | ProducerMethodIfaceTable
  | ProducerMethodConstraintIfaces
  | ProducerCtorFieldTypeNames
  | ProducerDeclSigTypeNames
  | ProducerMainScheme
  | ProducerIdentityVisibility
  | ProducerRuntimeTypes
  | ProducerCallShapes
  | ProducerEvidence
  | ProducerMethodDispositions
  | ProducerCapabilityManifest
deriving (Eq, Debug)

public export data DraftPopulation =
  | PopulationRuntimeDecls
  | PopulationElaboratedPrelude
  | PopulationElaboratedModules
  | PopulationPostDceEmitCore
  | PopulationElaboratedGraph
  | PopulationRuntimeAndGraph
  | PopulationEntryScheme
deriving (Eq, Debug)

public export data DraftObservation a =
  | DraftObservation DraftProducer DraftPopulation a

-- Preserve source-unit partitions as ordered rows. In particular, do not put
-- legacy spelling-keyed facts in a Map: duplicate spellings are evidence for
-- X-I/X-E, not entries to overwrite.
public export data DraftModule = DraftModule String (List Decl)
public export data DraftRows a = DraftRows String (List a)

public export data DraftFact =
  | FactRuntimeProjection
  | FactPreludeProjection
  | FactModuleProjection
  | FactLegacyCore
  | FactReturnsSelf
  | FactSelfFnParams
  | FactMethodIface
  | FactMethodConstraints
  | FactCtorFieldTypes
  | FactDeclSigTypes
  | FactMainIsUnit
  | FactMainIsFloat
  | FactIdentityVisibility
  | FactRuntimeTypes
  | FactCallShapes
  | FactEvidence
  | FactMethodDispositions
  | FactCapabilityManifest
deriving (Eq, Debug)

public export data DraftPending = DraftPending DraftFact DraftProducer String

public export data DraftComparison =
  | DraftMatch
  | DraftDifferent
deriving (Eq, Debug)

public export data DraftReceipt =
  | DraftReceipt DraftFact DraftProducer DraftPopulation DraftComparison

-- Positional on purpose. Record field labels are a program-global namespace in
-- current Medaka, and this migration carrier must not add another collision
-- surface while owner-qualified FieldId is still pending.
public export data DraftSemanticProgram =
  | DraftSemanticProgram (DraftObservation (List Decl)) (DraftObservation (List Decl)) (DraftObservation (List DraftModule)) (DraftObservation CProgram) (DraftObservation (List (DraftRows ((String, String), Bool)))) (DraftObservation (List (DraftRows ((String, String), List Int)))) (DraftObservation (List (DraftRows (String, (String, Int))))) (DraftObservation (List (DraftRows (String, List String)))) (DraftObservation (List (DraftRows (String, List String)))) (DraftObservation (List (DraftRows (String, (List String, String))))) (DraftObservation Bool) (DraftObservation Bool) (List DraftPending)

moduleOf : (String, List Decl) -> DraftModule
moduleOf (mid, decls) = DraftModule mid decls

rowsOf : (List Decl -> List a) -> DraftModule -> DraftRows a
rowsOf f (DraftModule mid decls) = DraftRows mid (f decls)

rowsFor : (List Decl -> List a) -> List DraftModule -> List (DraftRows a)
rowsFor f modules = map (rowsOf f) modules

semanticModules : List Decl -> List (String, List Decl) -> List DraftModule
semanticModules coreD modules = DraftModule "core" coreD :: map moduleOf modules

pendingFacts : List DraftPending
pendingFacts = [
  DraftPending FactIdentityVisibility ProducerIdentityVisibility "X-I.P and #1115",
  DraftPending FactRuntimeTypes ProducerRuntimeTypes "X-T.P / #353",
  DraftPending FactCallShapes ProducerCallShapes "X-C.P / #1318 -> #1137",
  DraftPending FactEvidence ProducerEvidence "X-E.P / #993, #1113, #1082",
  DraftPending FactMethodDispositions ProducerMethodDispositions "X-E.P / A-3 #1112",
  DraftPending FactCapabilityManifest ProducerCapabilityManifest "effects manifest producer",
]

export
buildDraftSemanticProgram : List Decl -> List Decl -> List (String, List Decl) -> Bool -> Bool -> DraftSemanticProgram
buildDraftSemanticProgram runtimeDecls coreD modules mainIsUnit mainIsFloat =
  let allDecls = dceFilter (coreD ++ flatMap snd modules)
  let semMods = semanticModules coreD modules
  let sigMods = DraftModule "runtime" runtimeDecls :: semMods
  DraftSemanticProgram
    (DraftObservation ProducerLoadedRuntime PopulationRuntimeDecls runtimeDecls)
    (DraftObservation
      ProducerElaborateModules
      PopulationElaboratedPrelude
      coreD)
    (DraftObservation
      ProducerElaborateModules
      PopulationElaboratedModules
      (map moduleOf modules))
    (DraftObservation
      ProducerLowerProgramEmit
      PopulationPostDceEmitCore
      (lowerProgramEmit allDecls))
    (DraftObservation
      ProducerReturnsSelfTable
      PopulationElaboratedGraph
      (rowsFor returnsSelfTable semMods))
    (DraftObservation
      ProducerSelfFnParamTable
      PopulationElaboratedGraph
      (rowsFor selfFnParamTable semMods))
    (DraftObservation
      ProducerMethodIfaceTable
      PopulationElaboratedGraph
      (rowsFor methodIfaceTable semMods))
    (DraftObservation
      ProducerMethodConstraintIfaces
      PopulationElaboratedGraph
      (rowsFor methodConstraintIfaces semMods))
    (DraftObservation
      ProducerCtorFieldTypeNames
      PopulationElaboratedGraph
      (rowsFor ctorFieldTypeNames semMods))
    (DraftObservation
      ProducerDeclSigTypeNames
      PopulationRuntimeAndGraph
      (rowsFor declSigTypeNames sigMods))
    (DraftObservation ProducerMainScheme PopulationEntryScheme mainIsUnit)
    (DraftObservation ProducerMainScheme PopulationEntryScheme mainIsFloat)
    pendingFacts

flattenRows : List (DraftRows a) -> List a
flattenRows [] = []
flattenRows ((DraftRows _ rows)::rest) = rows ++ flattenRows rest

receipt : DraftFact -> DraftProducer -> DraftPopulation -> Bool -> DraftReceipt
receipt fact producer population same = DraftReceipt
  fact
  producer
  population
  (if same then DraftMatch else DraftDifferent)

observationMetadataMatches : DraftProducer -> DraftPopulation -> DraftProducer -> DraftPopulation -> Bool
observationMetadataMatches expectedProducer expectedPopulation actualProducer actualPopulation = expectedProducer == actualProducer && expectedPopulation == actualPopulation

modulesSexp : List DraftModule -> String
modulesSexp modules = slist (map draftModulePayloadSexp modules)

-- `ir.sexp.programToSexp` intentionally rejects post-typecheck EMethodAt, so
-- compare the executable projection with the same typed Core serializer used
-- by the primary structural probe. Declaration-only facts are compared by the
-- dedicated rows below rather than hidden behind this projection.
draftModulePayloadSexp : DraftModule -> String
draftModulePayloadSexp (DraftModule mid decls) =
  node "module" [escStr mid, cprogramToSexp (lowerProgramEmit decls)]

draftModuleSexp : DraftModule -> String
draftModuleSexp (DraftModule mid decls) =
  node "module" [escStr mid, intToString (listLen decls)]

-- These are transport receipts only: they prove each NAMED projection consumed
-- by today's emit seam was copied with the expected provenance and population.
-- The three declaration-envelope receipts compare module identity/order plus
-- typed Core projections; declaration-only semantic inputs are checked by their
-- dedicated table receipts. This is not a faithful typed-AST equality claim,
-- and none of it certifies that a legacy answer is semantically correct. Future
-- .P stages add independent producer observations and semantic comparisons.
export
compareDraftSemanticProgram : DraftSemanticProgram -> List Decl -> List Decl -> List (String, List Decl) -> Bool -> Bool -> List DraftReceipt
compareDraftSemanticProgram (DraftSemanticProgram (DraftObservation runtimeProducer runtimePopulation draftRuntime) (DraftObservation coreProducer corePopulation draftCore) (DraftObservation modulesProducer modulesPopulation draftModules) (DraftObservation legacyCoreProducer legacyCorePopulation draftLegacyCore) (DraftObservation returnsSelfProducer returnsSelfPopulation draftReturnsSelf) (DraftObservation selfFnProducer selfFnPopulation draftSelfFnParams) (DraftObservation methodIfaceProducer methodIfacePopulation draftMethodIface) (DraftObservation methodConstraintsProducer methodConstraintsPopulation draftMethodConstraints) (DraftObservation ctorFieldsProducer ctorFieldsPopulation draftCtorFieldTypes) (DraftObservation declSigsProducer declSigsPopulation draftDeclSigTypes) (DraftObservation mainUnitProducer mainUnitPopulation draftMainIsUnit) (DraftObservation mainFloatProducer mainFloatPopulation draftMainIsFloat) _) runtimeDecls coreD modules mainIsUnit mainIsFloat =
  let allDecls = dceFilter (coreD ++ flatMap snd modules)
  [
    receipt FactRuntimeProjection ProducerLoadedRuntime PopulationRuntimeDecls (observationMetadataMatches ProducerLoadedRuntime PopulationRuntimeDecls runtimeProducer runtimePopulation && modulesSexp [DraftModule "runtime" draftRuntime] == modulesSexp [DraftModule "runtime" runtimeDecls]),
    receipt FactPreludeProjection ProducerElaborateModules PopulationElaboratedPrelude (observationMetadataMatches ProducerElaborateModules PopulationElaboratedPrelude coreProducer corePopulation && modulesSexp [DraftModule "core" draftCore] == modulesSexp [DraftModule "core" coreD]),
    receipt FactModuleProjection ProducerElaborateModules PopulationElaboratedModules (observationMetadataMatches ProducerElaborateModules PopulationElaboratedModules modulesProducer modulesPopulation && modulesSexp draftModules == modulesSexp (map moduleOf modules)),
    receipt FactLegacyCore ProducerLowerProgramEmit PopulationPostDceEmitCore (observationMetadataMatches ProducerLowerProgramEmit PopulationPostDceEmitCore legacyCoreProducer legacyCorePopulation && cprogramToSexp draftLegacyCore == cprogramToSexp (lowerProgramEmit allDecls)),
    receipt FactReturnsSelf ProducerReturnsSelfTable PopulationElaboratedGraph (observationMetadataMatches ProducerReturnsSelfTable PopulationElaboratedGraph returnsSelfProducer returnsSelfPopulation && flattenRows draftReturnsSelf == returnsSelfTable allDecls),
    receipt FactSelfFnParams ProducerSelfFnParamTable PopulationElaboratedGraph (observationMetadataMatches ProducerSelfFnParamTable PopulationElaboratedGraph selfFnProducer selfFnPopulation && flattenRows draftSelfFnParams == selfFnParamTable allDecls),
    receipt FactMethodIface ProducerMethodIfaceTable PopulationElaboratedGraph (observationMetadataMatches ProducerMethodIfaceTable PopulationElaboratedGraph methodIfaceProducer methodIfacePopulation && flattenRows draftMethodIface == methodIfaceTable allDecls),
    receipt FactMethodConstraints ProducerMethodConstraintIfaces PopulationElaboratedGraph (observationMetadataMatches ProducerMethodConstraintIfaces PopulationElaboratedGraph methodConstraintsProducer methodConstraintsPopulation && flattenRows draftMethodConstraints == methodConstraintIfaces allDecls),
    receipt FactCtorFieldTypes ProducerCtorFieldTypeNames PopulationElaboratedGraph (observationMetadataMatches ProducerCtorFieldTypeNames PopulationElaboratedGraph ctorFieldsProducer ctorFieldsPopulation && flattenRows draftCtorFieldTypes == ctorFieldTypeNames allDecls),
    receipt FactDeclSigTypes ProducerDeclSigTypeNames PopulationRuntimeAndGraph (observationMetadataMatches ProducerDeclSigTypeNames PopulationRuntimeAndGraph declSigsProducer declSigsPopulation && flattenRows draftDeclSigTypes == declSigTypeNames runtimeDecls ++ declSigTypeNames allDecls),
    receipt FactMainIsUnit ProducerMainScheme PopulationEntryScheme (observationMetadataMatches ProducerMainScheme PopulationEntryScheme mainUnitProducer mainUnitPopulation && draftMainIsUnit == mainIsUnit),
    receipt FactMainIsFloat ProducerMainScheme PopulationEntryScheme (observationMetadataMatches ProducerMainScheme PopulationEntryScheme mainFloatProducer mainFloatPopulation && draftMainIsFloat == mainIsFloat),
  ]

dropFirstRows : List (DraftRows a) -> List (DraftRows a)
dropFirstRows [] = []
dropFirstRows ((DraftRows mid [])::rest) =
  DraftRows mid [] :: dropFirstRows rest
dropFirstRows ((DraftRows mid (_::rows))::rest) = DraftRows mid rows :: rest

-- Test-only negative seam. Draft constructors are intentionally public during
-- migration; this named helper keeps the probe's malformed-field control small.
export
draftWithoutFirstMethodIface : DraftSemanticProgram -> DraftSemanticProgram
draftWithoutFirstMethodIface (DraftSemanticProgram runtimeD coreD modules legacyCore returnsSelf selfFnParams (DraftObservation producer population methodIface) methodConstraints ctorFieldTypes declSigTypes mainIsUnit mainIsFloat pending) = DraftSemanticProgram runtimeD coreD modules legacyCore returnsSelf selfFnParams (DraftObservation producer population (dropFirstRows methodIface)) methodConstraints ctorFieldTypes declSigTypes mainIsUnit mainIsFloat pending

-- Provenance is part of the compared field, not decorative output.
export
draftWithWrongMethodIfaceProvenance : DraftSemanticProgram -> DraftSemanticProgram
draftWithWrongMethodIfaceProvenance (DraftSemanticProgram runtimeD coreD modules legacyCore returnsSelf selfFnParams (DraftObservation _ _ methodIface) methodConstraints ctorFieldTypes declSigTypes mainIsUnit mainIsFloat pending) = DraftSemanticProgram runtimeD coreD modules legacyCore returnsSelf selfFnParams (DraftObservation ProducerRuntimeTypes PopulationRuntimeDecls methodIface) methodConstraints ctorFieldTypes declSigTypes mainIsUnit mainIsFloat pending

producerSexp : DraftProducer -> String
producerSexp ProducerLoadedRuntime = "loader:runtime"
producerSexp ProducerElaborateModules = "elaborateModules"
producerSexp ProducerLowerProgramEmit = "lowerProgramEmit"
producerSexp ProducerReturnsSelfTable = "returnsSelfTable"
producerSexp ProducerSelfFnParamTable = "selfFnParamTable"
producerSexp ProducerMethodIfaceTable = "methodIfaceTable"
producerSexp ProducerMethodConstraintIfaces = "methodConstraintIfaces"
producerSexp ProducerCtorFieldTypeNames = "ctorFieldTypeNames"
producerSexp ProducerDeclSigTypeNames = "declSigTypeNames"
producerSexp ProducerMainScheme = "mainScheme"
producerSexp ProducerIdentityVisibility = "X-I.P"
producerSexp ProducerRuntimeTypes = "X-T.P"
producerSexp ProducerCallShapes = "X-C.P"
producerSexp ProducerEvidence = "X-E.P:evidence"
producerSexp ProducerMethodDispositions = "X-E.P:dispositions"
producerSexp ProducerCapabilityManifest = "effects:manifest"

populationSexp : DraftPopulation -> String
populationSexp PopulationRuntimeDecls = "runtime-decls"
populationSexp PopulationElaboratedPrelude = "elaborated-prelude"
populationSexp PopulationElaboratedModules = "elaborated-modules"
populationSexp PopulationPostDceEmitCore = "post-dce-emit-core"
populationSexp PopulationElaboratedGraph = "elaborated-graph"
populationSexp PopulationRuntimeAndGraph = "runtime-and-elaborated-graph"
populationSexp PopulationEntryScheme = "entry-scheme"

factSexp : DraftFact -> String
factSexp FactRuntimeProjection = "runtime-emitter-projection"
factSexp FactPreludeProjection = "prelude-emitter-projection"
factSexp FactModuleProjection = "module-emitter-projection"
factSexp FactLegacyCore = "legacy-core"
factSexp FactReturnsSelf = "returns-self"
factSexp FactSelfFnParams = "self-fn-params"
factSexp FactMethodIface = "method-iface"
factSexp FactMethodConstraints = "method-constraints"
factSexp FactCtorFieldTypes = "ctor-field-types"
factSexp FactDeclSigTypes = "decl-sig-types"
factSexp FactMainIsUnit = "main-is-unit"
factSexp FactMainIsFloat = "main-is-float"
factSexp FactIdentityVisibility = "identity-visibility"
factSexp FactRuntimeTypes = "runtime-types"
factSexp FactCallShapes = "call-shapes"
factSexp FactEvidence = "evidence"
factSexp FactMethodDispositions = "method-dispositions"
factSexp FactCapabilityManifest = "capability-manifest"

comparisonSexp : DraftComparison -> String
comparisonSexp DraftMatch = "MATCH"
comparisonSexp DraftDifferent = "DIFFERENT"

pendingSexp : DraftPending -> String
pendingSexp (DraftPending fact producer dependency) =
  node "pending" [factSexp fact, producerSexp producer, escStr dependency]

receiptSexp : DraftReceipt -> String
receiptSexp (DraftReceipt fact producer population comparison) = node
  "receipt"
  [
    factSexp fact,
    producerSexp producer,
    populationSexp population,
    comparisonSexp comparison,
  ]

rowsSummary : List (DraftRows a) -> String
rowsSummary rows = slist (map rowSummary rows)

rowSummary : DraftRows a -> String
rowSummary (DraftRows mid values) =
  node "rows" [escStr mid, intToString (listLen values)]

cprogramSummary : CProgram -> String
cprogramSummary (CProgram binds ctorArities ctorTypes impls) = node
  "CProgramSummary"
  [
    intToString (listLen binds),
    intToString (listLen ctorArities),
    intToString (listLen ctorTypes),
    intToString (listLen impls),
  ]

observationSexp : DraftProducer -> DraftPopulation -> String -> String
observationSexp producer population payload =
  node "observed" [producerSexp producer, populationSexp population, payload]

declObservationSexp : DraftObservation (List Decl) -> String
declObservationSexp (DraftObservation producer population decls) =
  observationSexp producer population (intToString (listLen decls))

moduleObservationSexp : DraftObservation (List DraftModule) -> String
moduleObservationSexp (DraftObservation producer population modules) =
  observationSexp producer population (slist (map draftModuleSexp modules))

coreObservationSexp : DraftObservation CProgram -> String
coreObservationSexp (DraftObservation producer population program) =
  observationSexp producer population (cprogramSummary program)

rowsObservationSexp : DraftObservation (List (DraftRows a)) -> String
rowsObservationSexp (DraftObservation producer population rows) =
  observationSexp producer population (rowsSummary rows)

boolObservationSexp : DraftObservation Bool -> String
boolObservationSexp (DraftObservation producer population value) =
  observationSexp producer population (boolStr value)

differentCount : List DraftReceipt -> Int
differentCount [] = 0
differentCount ((DraftReceipt _ _ _ DraftDifferent)::rest) =
  1 + differentCount rest
differentCount (_::rest) = differentCount rest

-- Compact by design: the existing typed Core dump remains the detailed
-- structural receipt. This dump exposes populations, source-unit row counts,
-- pending producers, and exact transport-comparison verdicts without copying a
-- full prelude-sized CProgram into a second golden family.
export
draftSemanticProgramToSexp : DraftSemanticProgram -> List DraftReceipt -> String
draftSemanticProgramToSexp (DraftSemanticProgram runtimeD coreD modules legacyCore returnsSelf selfFnParams methodIface methodConstraints ctorFieldTypes declSigTypes mainIsUnit mainIsFloat pending) receipts = node "DraftSemanticProgram" [node "runtime" [declObservationSexp runtimeD], node "prelude" [declObservationSexp coreD], node "modules" [moduleObservationSexp modules], node "legacy-core" [coreObservationSexp legacyCore], node "returns-self" [rowsObservationSexp returnsSelf], node "self-fn-params" [rowsObservationSexp selfFnParams], node "method-iface" [rowsObservationSexp methodIface], node "method-constraints" [rowsObservationSexp methodConstraints], node "ctor-field-types" [rowsObservationSexp ctorFieldTypes], node "decl-sig-types" [rowsObservationSexp declSigTypes], node "main-is-unit" [boolObservationSexp mainIsUnit], node "main-is-float" [boolObservationSexp mainIsFloat], node "pending-facts" [slist (map pendingSexp pending)], node "transport-receipts" [slist (map receiptSexp receipts)], node "summary" [node "receipts" [intToString (listLen receipts)], node "different" [intToString (differentCount receipts)]]]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerProgramEmit" false) (mem "returnsSelfTable" false) (mem "selfFnParamTable" false) (mem "methodIfaceTable" false) (mem "methodConstraintIfaces" false) (mem "ctorFieldTypeNames" false) (mem "declSigTypeNames" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "dceFilter" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "listLen" false))))
(DData Public "DraftProducer" () ((variant "ProducerLoadedRuntime" (ConPos)) (variant "ProducerElaborateModules" (ConPos)) (variant "ProducerLowerProgramEmit" (ConPos)) (variant "ProducerReturnsSelfTable" (ConPos)) (variant "ProducerSelfFnParamTable" (ConPos)) (variant "ProducerMethodIfaceTable" (ConPos)) (variant "ProducerMethodConstraintIfaces" (ConPos)) (variant "ProducerCtorFieldTypeNames" (ConPos)) (variant "ProducerDeclSigTypeNames" (ConPos)) (variant "ProducerMainScheme" (ConPos)) (variant "ProducerIdentityVisibility" (ConPos)) (variant "ProducerRuntimeTypes" (ConPos)) (variant "ProducerCallShapes" (ConPos)) (variant "ProducerEvidence" (ConPos)) (variant "ProducerMethodDispositions" (ConPos)) (variant "ProducerCapabilityManifest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftProducer")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ProducerLoadedRuntime") (PCon "ProducerLoadedRuntime")) () (EVar "True")) (arm (PTuple (PCon "ProducerElaborateModules") (PCon "ProducerElaborateModules")) () (EVar "True")) (arm (PTuple (PCon "ProducerLowerProgramEmit") (PCon "ProducerLowerProgramEmit")) () (EVar "True")) (arm (PTuple (PCon "ProducerReturnsSelfTable") (PCon "ProducerReturnsSelfTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerSelfFnParamTable") (PCon "ProducerSelfFnParamTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodIfaceTable") (PCon "ProducerMethodIfaceTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodConstraintIfaces") (PCon "ProducerMethodConstraintIfaces")) () (EVar "True")) (arm (PTuple (PCon "ProducerCtorFieldTypeNames") (PCon "ProducerCtorFieldTypeNames")) () (EVar "True")) (arm (PTuple (PCon "ProducerDeclSigTypeNames") (PCon "ProducerDeclSigTypeNames")) () (EVar "True")) (arm (PTuple (PCon "ProducerMainScheme") (PCon "ProducerMainScheme")) () (EVar "True")) (arm (PTuple (PCon "ProducerIdentityVisibility") (PCon "ProducerIdentityVisibility")) () (EVar "True")) (arm (PTuple (PCon "ProducerRuntimeTypes") (PCon "ProducerRuntimeTypes")) () (EVar "True")) (arm (PTuple (PCon "ProducerCallShapes") (PCon "ProducerCallShapes")) () (EVar "True")) (arm (PTuple (PCon "ProducerEvidence") (PCon "ProducerEvidence")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodDispositions") (PCon "ProducerMethodDispositions")) () (EVar "True")) (arm (PTuple (PCon "ProducerCapabilityManifest") (PCon "ProducerCapabilityManifest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftProducer")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ProducerLoadedRuntime") () (ELit (LString "ProducerLoadedRuntime"))) (arm (PCon "ProducerElaborateModules") () (ELit (LString "ProducerElaborateModules"))) (arm (PCon "ProducerLowerProgramEmit") () (ELit (LString "ProducerLowerProgramEmit"))) (arm (PCon "ProducerReturnsSelfTable") () (ELit (LString "ProducerReturnsSelfTable"))) (arm (PCon "ProducerSelfFnParamTable") () (ELit (LString "ProducerSelfFnParamTable"))) (arm (PCon "ProducerMethodIfaceTable") () (ELit (LString "ProducerMethodIfaceTable"))) (arm (PCon "ProducerMethodConstraintIfaces") () (ELit (LString "ProducerMethodConstraintIfaces"))) (arm (PCon "ProducerCtorFieldTypeNames") () (ELit (LString "ProducerCtorFieldTypeNames"))) (arm (PCon "ProducerDeclSigTypeNames") () (ELit (LString "ProducerDeclSigTypeNames"))) (arm (PCon "ProducerMainScheme") () (ELit (LString "ProducerMainScheme"))) (arm (PCon "ProducerIdentityVisibility") () (ELit (LString "ProducerIdentityVisibility"))) (arm (PCon "ProducerRuntimeTypes") () (ELit (LString "ProducerRuntimeTypes"))) (arm (PCon "ProducerCallShapes") () (ELit (LString "ProducerCallShapes"))) (arm (PCon "ProducerEvidence") () (ELit (LString "ProducerEvidence"))) (arm (PCon "ProducerMethodDispositions") () (ELit (LString "ProducerMethodDispositions"))) (arm (PCon "ProducerCapabilityManifest") () (ELit (LString "ProducerCapabilityManifest")))))))
(DData Public "DraftPopulation" () ((variant "PopulationRuntimeDecls" (ConPos)) (variant "PopulationElaboratedPrelude" (ConPos)) (variant "PopulationElaboratedModules" (ConPos)) (variant "PopulationPostDceEmitCore" (ConPos)) (variant "PopulationElaboratedGraph" (ConPos)) (variant "PopulationRuntimeAndGraph" (ConPos)) (variant "PopulationEntryScheme" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftPopulation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PopulationRuntimeDecls") (PCon "PopulationRuntimeDecls")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedPrelude") (PCon "PopulationElaboratedPrelude")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedModules") (PCon "PopulationElaboratedModules")) () (EVar "True")) (arm (PTuple (PCon "PopulationPostDceEmitCore") (PCon "PopulationPostDceEmitCore")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedGraph") (PCon "PopulationElaboratedGraph")) () (EVar "True")) (arm (PTuple (PCon "PopulationRuntimeAndGraph") (PCon "PopulationRuntimeAndGraph")) () (EVar "True")) (arm (PTuple (PCon "PopulationEntryScheme") (PCon "PopulationEntryScheme")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftPopulation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PopulationRuntimeDecls") () (ELit (LString "PopulationRuntimeDecls"))) (arm (PCon "PopulationElaboratedPrelude") () (ELit (LString "PopulationElaboratedPrelude"))) (arm (PCon "PopulationElaboratedModules") () (ELit (LString "PopulationElaboratedModules"))) (arm (PCon "PopulationPostDceEmitCore") () (ELit (LString "PopulationPostDceEmitCore"))) (arm (PCon "PopulationElaboratedGraph") () (ELit (LString "PopulationElaboratedGraph"))) (arm (PCon "PopulationRuntimeAndGraph") () (ELit (LString "PopulationRuntimeAndGraph"))) (arm (PCon "PopulationEntryScheme") () (ELit (LString "PopulationEntryScheme")))))))
(DData Public "DraftObservation" ("a") ((variant "DraftObservation" (ConPos (TyCon "DraftProducer") (TyCon "DraftPopulation") (TyVar "a")))) ())
(DData Public "DraftModule" () ((variant "DraftModule" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Public "DraftRows" ("a") ((variant "DraftRows" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyVar "a"))))) ())
(DData Public "DraftFact" () ((variant "FactRuntimeProjection" (ConPos)) (variant "FactPreludeProjection" (ConPos)) (variant "FactModuleProjection" (ConPos)) (variant "FactLegacyCore" (ConPos)) (variant "FactReturnsSelf" (ConPos)) (variant "FactSelfFnParams" (ConPos)) (variant "FactMethodIface" (ConPos)) (variant "FactMethodConstraints" (ConPos)) (variant "FactCtorFieldTypes" (ConPos)) (variant "FactDeclSigTypes" (ConPos)) (variant "FactMainIsUnit" (ConPos)) (variant "FactMainIsFloat" (ConPos)) (variant "FactIdentityVisibility" (ConPos)) (variant "FactRuntimeTypes" (ConPos)) (variant "FactCallShapes" (ConPos)) (variant "FactEvidence" (ConPos)) (variant "FactMethodDispositions" (ConPos)) (variant "FactCapabilityManifest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FactRuntimeProjection") (PCon "FactRuntimeProjection")) () (EVar "True")) (arm (PTuple (PCon "FactPreludeProjection") (PCon "FactPreludeProjection")) () (EVar "True")) (arm (PTuple (PCon "FactModuleProjection") (PCon "FactModuleProjection")) () (EVar "True")) (arm (PTuple (PCon "FactLegacyCore") (PCon "FactLegacyCore")) () (EVar "True")) (arm (PTuple (PCon "FactReturnsSelf") (PCon "FactReturnsSelf")) () (EVar "True")) (arm (PTuple (PCon "FactSelfFnParams") (PCon "FactSelfFnParams")) () (EVar "True")) (arm (PTuple (PCon "FactMethodIface") (PCon "FactMethodIface")) () (EVar "True")) (arm (PTuple (PCon "FactMethodConstraints") (PCon "FactMethodConstraints")) () (EVar "True")) (arm (PTuple (PCon "FactCtorFieldTypes") (PCon "FactCtorFieldTypes")) () (EVar "True")) (arm (PTuple (PCon "FactDeclSigTypes") (PCon "FactDeclSigTypes")) () (EVar "True")) (arm (PTuple (PCon "FactMainIsUnit") (PCon "FactMainIsUnit")) () (EVar "True")) (arm (PTuple (PCon "FactMainIsFloat") (PCon "FactMainIsFloat")) () (EVar "True")) (arm (PTuple (PCon "FactIdentityVisibility") (PCon "FactIdentityVisibility")) () (EVar "True")) (arm (PTuple (PCon "FactRuntimeTypes") (PCon "FactRuntimeTypes")) () (EVar "True")) (arm (PTuple (PCon "FactCallShapes") (PCon "FactCallShapes")) () (EVar "True")) (arm (PTuple (PCon "FactEvidence") (PCon "FactEvidence")) () (EVar "True")) (arm (PTuple (PCon "FactMethodDispositions") (PCon "FactMethodDispositions")) () (EVar "True")) (arm (PTuple (PCon "FactCapabilityManifest") (PCon "FactCapabilityManifest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FactRuntimeProjection") () (ELit (LString "FactRuntimeProjection"))) (arm (PCon "FactPreludeProjection") () (ELit (LString "FactPreludeProjection"))) (arm (PCon "FactModuleProjection") () (ELit (LString "FactModuleProjection"))) (arm (PCon "FactLegacyCore") () (ELit (LString "FactLegacyCore"))) (arm (PCon "FactReturnsSelf") () (ELit (LString "FactReturnsSelf"))) (arm (PCon "FactSelfFnParams") () (ELit (LString "FactSelfFnParams"))) (arm (PCon "FactMethodIface") () (ELit (LString "FactMethodIface"))) (arm (PCon "FactMethodConstraints") () (ELit (LString "FactMethodConstraints"))) (arm (PCon "FactCtorFieldTypes") () (ELit (LString "FactCtorFieldTypes"))) (arm (PCon "FactDeclSigTypes") () (ELit (LString "FactDeclSigTypes"))) (arm (PCon "FactMainIsUnit") () (ELit (LString "FactMainIsUnit"))) (arm (PCon "FactMainIsFloat") () (ELit (LString "FactMainIsFloat"))) (arm (PCon "FactIdentityVisibility") () (ELit (LString "FactIdentityVisibility"))) (arm (PCon "FactRuntimeTypes") () (ELit (LString "FactRuntimeTypes"))) (arm (PCon "FactCallShapes") () (ELit (LString "FactCallShapes"))) (arm (PCon "FactEvidence") () (ELit (LString "FactEvidence"))) (arm (PCon "FactMethodDispositions") () (ELit (LString "FactMethodDispositions"))) (arm (PCon "FactCapabilityManifest") () (ELit (LString "FactCapabilityManifest")))))))
(DData Public "DraftPending" () ((variant "DraftPending" (ConPos (TyCon "DraftFact") (TyCon "DraftProducer") (TyCon "String")))) ())
(DData Public "DraftComparison" () ((variant "DraftMatch" (ConPos)) (variant "DraftDifferent" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftComparison")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DraftMatch") (PCon "DraftMatch")) () (EVar "True")) (arm (PTuple (PCon "DraftDifferent") (PCon "DraftDifferent")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftComparison")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DraftMatch") () (ELit (LString "DraftMatch"))) (arm (PCon "DraftDifferent") () (ELit (LString "DraftDifferent")))))))
(DData Public "DraftReceipt" () ((variant "DraftReceipt" (ConPos (TyCon "DraftFact") (TyCon "DraftProducer") (TyCon "DraftPopulation") (TyCon "DraftComparison")))) ())
(DData Public "DraftSemanticProgram" () ((variant "DraftSemanticProgram" (ConPos (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "DraftModule"))) (TyApp (TyCon "DraftObservation") (TyCon "CProgram")) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyApp (TyCon "List") (TyCon "DraftPending"))))) ())
(DTypeSig false "moduleOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "DraftModule")))
(DFunDef false "moduleOf" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "DraftModule") (EVar "mid")) (EVar "decls")))
(DTypeSig false "rowsOf" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "DraftModule") (TyApp (TyCon "DraftRows") (TyVar "a")))))
(DFunDef false "rowsOf" ((PVar "f") (PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EApp (EVar "f") (EVar "decls"))))
(DTypeSig false "rowsFor" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "DraftModule")) (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))))))
(DFunDef false "rowsFor" ((PVar "f") (PVar "modules")) (EApp (EApp (EVar "map") (EApp (EVar "rowsOf") (EVar "f"))) (EVar "modules")))
(DTypeSig false "semanticModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "DraftModule")))))
(DFunDef false "semanticModules" ((PVar "coreD") (PVar "modules")) (EBinOp "::" (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "coreD")) (EApp (EApp (EVar "map") (EVar "moduleOf")) (EVar "modules"))))
(DTypeSig false "pendingFacts" (TyApp (TyCon "List") (TyCon "DraftPending")))
(DFunDef false "pendingFacts" () (EListLit (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactIdentityVisibility")) (EVar "ProducerIdentityVisibility")) (ELit (LString "X-I.P and #1115"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactRuntimeTypes")) (EVar "ProducerRuntimeTypes")) (ELit (LString "X-T.P / #353"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactCallShapes")) (EVar "ProducerCallShapes")) (ELit (LString "X-C.P / #1318 -> #1137"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactEvidence")) (EVar "ProducerEvidence")) (ELit (LString "X-E.P / #993, #1113, #1082"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactMethodDispositions")) (EVar "ProducerMethodDispositions")) (ELit (LString "X-E.P / A-3 #1112"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactCapabilityManifest")) (EVar "ProducerCapabilityManifest")) (ELit (LString "effects manifest producer")))))
(DTypeSig true "buildDraftSemanticProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "DraftSemanticProgram")))))))
(DFunDef false "buildDraftSemanticProgram" ((PVar "runtimeDecls") (PVar "coreD") (PVar "modules") (PVar "mainIsUnit") (PVar "mainIsFloat")) (EBlock (DoLet false false (PVar "allDecls") (EApp (EVar "dceFilter") (EBinOp "++" (EVar "coreD") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))))) (DoLet false false (PVar "semMods") (EApp (EApp (EVar "semanticModules") (EVar "coreD")) (EVar "modules"))) (DoLet false false (PVar "sigMods") (EBinOp "::" (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "runtimeDecls")) (EVar "semMods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EVar "runtimeDecls"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EVar "coreD"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EApp (EApp (EVar "map") (EVar "moduleOf")) (EVar "modules")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EApp (EVar "lowerProgramEmit") (EVar "allDecls")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "returnsSelfTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "selfFnParamTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "methodIfaceTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "methodConstraintIfaces")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "ctorFieldTypeNames")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EApp (EApp (EVar "rowsFor") (EVar "declSigTypeNames")) (EVar "sigMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainIsUnit"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainIsFloat"))) (EVar "pendingFacts")))))
(DTypeSig false "flattenRows" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "flattenRows" ((PList)) (EListLit))
(DFunDef false "flattenRows" ((PCons (PCon "DraftRows" PWild (PVar "rows")) (PVar "rest"))) (EBinOp "++" (EVar "rows") (EApp (EVar "flattenRows") (EVar "rest"))))
(DTypeSig false "receipt" (TyFun (TyCon "DraftFact") (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "Bool") (TyCon "DraftReceipt"))))))
(DFunDef false "receipt" ((PVar "fact") (PVar "producer") (PVar "population") (PVar "same")) (EApp (EApp (EApp (EApp (EVar "DraftReceipt") (EVar "fact")) (EVar "producer")) (EVar "population")) (EIf (EVar "same") (EVar "DraftMatch") (EVar "DraftDifferent"))))
(DTypeSig false "observationMetadataMatches" (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyCon "Bool"))))))
(DFunDef false "observationMetadataMatches" ((PVar "expectedProducer") (PVar "expectedPopulation") (PVar "actualProducer") (PVar "actualPopulation")) (EBinOp "&&" (EBinOp "==" (EVar "expectedProducer") (EVar "actualProducer")) (EBinOp "==" (EVar "expectedPopulation") (EVar "actualPopulation"))))
(DTypeSig false "modulesSexp" (TyFun (TyApp (TyCon "List") (TyCon "DraftModule")) (TyCon "String")))
(DFunDef false "modulesSexp" ((PVar "modules")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "draftModulePayloadSexp")) (EVar "modules"))))
(DTypeSig false "draftModulePayloadSexp" (TyFun (TyCon "DraftModule") (TyCon "String")))
(DFunDef false "draftModulePayloadSexp" ((PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgramEmit") (EVar "decls"))))))
(DTypeSig false "draftModuleSexp" (TyFun (TyCon "DraftModule") (TyCon "String")))
(DFunDef false "draftModuleSexp" ((PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "decls"))))))
(DTypeSig true "compareDraftSemanticProgram" (TyFun (TyCon "DraftSemanticProgram") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "DraftReceipt")))))))))
(DFunDef false "compareDraftSemanticProgram" ((PCon "DraftSemanticProgram" (PCon "DraftObservation" (PVar "runtimeProducer") (PVar "runtimePopulation") (PVar "draftRuntime")) (PCon "DraftObservation" (PVar "coreProducer") (PVar "corePopulation") (PVar "draftCore")) (PCon "DraftObservation" (PVar "modulesProducer") (PVar "modulesPopulation") (PVar "draftModules")) (PCon "DraftObservation" (PVar "legacyCoreProducer") (PVar "legacyCorePopulation") (PVar "draftLegacyCore")) (PCon "DraftObservation" (PVar "returnsSelfProducer") (PVar "returnsSelfPopulation") (PVar "draftReturnsSelf")) (PCon "DraftObservation" (PVar "selfFnProducer") (PVar "selfFnPopulation") (PVar "draftSelfFnParams")) (PCon "DraftObservation" (PVar "methodIfaceProducer") (PVar "methodIfacePopulation") (PVar "draftMethodIface")) (PCon "DraftObservation" (PVar "methodConstraintsProducer") (PVar "methodConstraintsPopulation") (PVar "draftMethodConstraints")) (PCon "DraftObservation" (PVar "ctorFieldsProducer") (PVar "ctorFieldsPopulation") (PVar "draftCtorFieldTypes")) (PCon "DraftObservation" (PVar "declSigsProducer") (PVar "declSigsPopulation") (PVar "draftDeclSigTypes")) (PCon "DraftObservation" (PVar "mainUnitProducer") (PVar "mainUnitPopulation") (PVar "draftMainIsUnit")) (PCon "DraftObservation" (PVar "mainFloatProducer") (PVar "mainFloatPopulation") (PVar "draftMainIsFloat")) PWild) (PVar "runtimeDecls") (PVar "coreD") (PVar "modules") (PVar "mainIsUnit") (PVar "mainIsFloat")) (EBlock (DoLet false false (PVar "allDecls") (EApp (EVar "dceFilter") (EBinOp "++" (EVar "coreD") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactRuntimeProjection")) (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EVar "runtimeProducer")) (EVar "runtimePopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "draftRuntime")))) (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "runtimeDecls"))))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactPreludeProjection")) (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EVar "coreProducer")) (EVar "corePopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "draftCore")))) (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "coreD"))))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactModuleProjection")) (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EVar "modulesProducer")) (EVar "modulesPopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EVar "draftModules")) (EApp (EVar "modulesSexp") (EApp (EApp (EVar "map") (EVar "moduleOf")) (EVar "modules")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactLegacyCore")) (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EVar "legacyCoreProducer")) (EVar "legacyCorePopulation")) (EBinOp "==" (EApp (EVar "cprogramToSexp") (EVar "draftLegacyCore")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgramEmit") (EVar "allDecls")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactReturnsSelf")) (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EVar "returnsSelfProducer")) (EVar "returnsSelfPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftReturnsSelf")) (EApp (EVar "returnsSelfTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactSelfFnParams")) (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EVar "selfFnProducer")) (EVar "selfFnPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftSelfFnParams")) (EApp (EVar "selfFnParamTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMethodIface")) (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EVar "methodIfaceProducer")) (EVar "methodIfacePopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftMethodIface")) (EApp (EVar "methodIfaceTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMethodConstraints")) (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EVar "methodConstraintsProducer")) (EVar "methodConstraintsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftMethodConstraints")) (EApp (EVar "methodConstraintIfaces") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactCtorFieldTypes")) (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EVar "ctorFieldsProducer")) (EVar "ctorFieldsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftCtorFieldTypes")) (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactDeclSigTypes")) (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EVar "declSigsProducer")) (EVar "declSigsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftDeclSigTypes")) (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMainIsUnit")) (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainUnitProducer")) (EVar "mainUnitPopulation")) (EBinOp "==" (EVar "draftMainIsUnit") (EVar "mainIsUnit")))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMainIsFloat")) (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainFloatProducer")) (EVar "mainFloatPopulation")) (EBinOp "==" (EVar "draftMainIsFloat") (EVar "mainIsFloat"))))))))
(DTypeSig false "dropFirstRows" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a")))))
(DFunDef false "dropFirstRows" ((PList)) (EListLit))
(DFunDef false "dropFirstRows" ((PCons (PCon "DraftRows" (PVar "mid") (PList)) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EListLit)) (EApp (EVar "dropFirstRows") (EVar "rest"))))
(DFunDef false "dropFirstRows" ((PCons (PCon "DraftRows" (PVar "mid") (PCons PWild (PVar "rows"))) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EVar "rows")) (EVar "rest")))
(DTypeSig true "draftWithoutFirstMethodIface" (TyFun (TyCon "DraftSemanticProgram") (TyCon "DraftSemanticProgram")))
(DFunDef false "draftWithoutFirstMethodIface" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "methodIface")) (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EVar "runtimeD")) (EVar "coreD")) (EVar "modules")) (EVar "legacyCore")) (EVar "returnsSelf")) (EVar "selfFnParams")) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "producer")) (EVar "population")) (EApp (EVar "dropFirstRows") (EVar "methodIface")))) (EVar "methodConstraints")) (EVar "ctorFieldTypes")) (EVar "declSigTypes")) (EVar "mainIsUnit")) (EVar "mainIsFloat")) (EVar "pending")))
(DTypeSig true "draftWithWrongMethodIfaceProvenance" (TyFun (TyCon "DraftSemanticProgram") (TyCon "DraftSemanticProgram")))
(DFunDef false "draftWithWrongMethodIfaceProvenance" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PCon "DraftObservation" PWild PWild (PVar "methodIface")) (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EVar "runtimeD")) (EVar "coreD")) (EVar "modules")) (EVar "legacyCore")) (EVar "returnsSelf")) (EVar "selfFnParams")) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerRuntimeTypes")) (EVar "PopulationRuntimeDecls")) (EVar "methodIface"))) (EVar "methodConstraints")) (EVar "ctorFieldTypes")) (EVar "declSigTypes")) (EVar "mainIsUnit")) (EVar "mainIsFloat")) (EVar "pending")))
(DTypeSig false "producerSexp" (TyFun (TyCon "DraftProducer") (TyCon "String")))
(DFunDef false "producerSexp" ((PCon "ProducerLoadedRuntime")) (ELit (LString "loader:runtime")))
(DFunDef false "producerSexp" ((PCon "ProducerElaborateModules")) (ELit (LString "elaborateModules")))
(DFunDef false "producerSexp" ((PCon "ProducerLowerProgramEmit")) (ELit (LString "lowerProgramEmit")))
(DFunDef false "producerSexp" ((PCon "ProducerReturnsSelfTable")) (ELit (LString "returnsSelfTable")))
(DFunDef false "producerSexp" ((PCon "ProducerSelfFnParamTable")) (ELit (LString "selfFnParamTable")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodIfaceTable")) (ELit (LString "methodIfaceTable")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodConstraintIfaces")) (ELit (LString "methodConstraintIfaces")))
(DFunDef false "producerSexp" ((PCon "ProducerCtorFieldTypeNames")) (ELit (LString "ctorFieldTypeNames")))
(DFunDef false "producerSexp" ((PCon "ProducerDeclSigTypeNames")) (ELit (LString "declSigTypeNames")))
(DFunDef false "producerSexp" ((PCon "ProducerMainScheme")) (ELit (LString "mainScheme")))
(DFunDef false "producerSexp" ((PCon "ProducerIdentityVisibility")) (ELit (LString "X-I.P")))
(DFunDef false "producerSexp" ((PCon "ProducerRuntimeTypes")) (ELit (LString "X-T.P")))
(DFunDef false "producerSexp" ((PCon "ProducerCallShapes")) (ELit (LString "X-C.P")))
(DFunDef false "producerSexp" ((PCon "ProducerEvidence")) (ELit (LString "X-E.P:evidence")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodDispositions")) (ELit (LString "X-E.P:dispositions")))
(DFunDef false "producerSexp" ((PCon "ProducerCapabilityManifest")) (ELit (LString "effects:manifest")))
(DTypeSig false "populationSexp" (TyFun (TyCon "DraftPopulation") (TyCon "String")))
(DFunDef false "populationSexp" ((PCon "PopulationRuntimeDecls")) (ELit (LString "runtime-decls")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedPrelude")) (ELit (LString "elaborated-prelude")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedModules")) (ELit (LString "elaborated-modules")))
(DFunDef false "populationSexp" ((PCon "PopulationPostDceEmitCore")) (ELit (LString "post-dce-emit-core")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedGraph")) (ELit (LString "elaborated-graph")))
(DFunDef false "populationSexp" ((PCon "PopulationRuntimeAndGraph")) (ELit (LString "runtime-and-elaborated-graph")))
(DFunDef false "populationSexp" ((PCon "PopulationEntryScheme")) (ELit (LString "entry-scheme")))
(DTypeSig false "factSexp" (TyFun (TyCon "DraftFact") (TyCon "String")))
(DFunDef false "factSexp" ((PCon "FactRuntimeProjection")) (ELit (LString "runtime-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactPreludeProjection")) (ELit (LString "prelude-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactModuleProjection")) (ELit (LString "module-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactLegacyCore")) (ELit (LString "legacy-core")))
(DFunDef false "factSexp" ((PCon "FactReturnsSelf")) (ELit (LString "returns-self")))
(DFunDef false "factSexp" ((PCon "FactSelfFnParams")) (ELit (LString "self-fn-params")))
(DFunDef false "factSexp" ((PCon "FactMethodIface")) (ELit (LString "method-iface")))
(DFunDef false "factSexp" ((PCon "FactMethodConstraints")) (ELit (LString "method-constraints")))
(DFunDef false "factSexp" ((PCon "FactCtorFieldTypes")) (ELit (LString "ctor-field-types")))
(DFunDef false "factSexp" ((PCon "FactDeclSigTypes")) (ELit (LString "decl-sig-types")))
(DFunDef false "factSexp" ((PCon "FactMainIsUnit")) (ELit (LString "main-is-unit")))
(DFunDef false "factSexp" ((PCon "FactMainIsFloat")) (ELit (LString "main-is-float")))
(DFunDef false "factSexp" ((PCon "FactIdentityVisibility")) (ELit (LString "identity-visibility")))
(DFunDef false "factSexp" ((PCon "FactRuntimeTypes")) (ELit (LString "runtime-types")))
(DFunDef false "factSexp" ((PCon "FactCallShapes")) (ELit (LString "call-shapes")))
(DFunDef false "factSexp" ((PCon "FactEvidence")) (ELit (LString "evidence")))
(DFunDef false "factSexp" ((PCon "FactMethodDispositions")) (ELit (LString "method-dispositions")))
(DFunDef false "factSexp" ((PCon "FactCapabilityManifest")) (ELit (LString "capability-manifest")))
(DTypeSig false "comparisonSexp" (TyFun (TyCon "DraftComparison") (TyCon "String")))
(DFunDef false "comparisonSexp" ((PCon "DraftMatch")) (ELit (LString "MATCH")))
(DFunDef false "comparisonSexp" ((PCon "DraftDifferent")) (ELit (LString "DIFFERENT")))
(DTypeSig false "pendingSexp" (TyFun (TyCon "DraftPending") (TyCon "String")))
(DFunDef false "pendingSexp" ((PCon "DraftPending" (PVar "fact") (PVar "producer") (PVar "dependency"))) (EApp (EApp (EVar "node") (ELit (LString "pending"))) (EListLit (EApp (EVar "factSexp") (EVar "fact")) (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "escStr") (EVar "dependency")))))
(DTypeSig false "receiptSexp" (TyFun (TyCon "DraftReceipt") (TyCon "String")))
(DFunDef false "receiptSexp" ((PCon "DraftReceipt" (PVar "fact") (PVar "producer") (PVar "population") (PVar "comparison"))) (EApp (EApp (EVar "node") (ELit (LString "receipt"))) (EListLit (EApp (EVar "factSexp") (EVar "fact")) (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "populationSexp") (EVar "population")) (EApp (EVar "comparisonSexp") (EVar "comparison")))))
(DTypeSig false "rowsSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyCon "String")))
(DFunDef false "rowsSummary" ((PVar "rows")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "rowSummary")) (EVar "rows"))))
(DTypeSig false "rowSummary" (TyFun (TyApp (TyCon "DraftRows") (TyVar "a")) (TyCon "String")))
(DFunDef false "rowSummary" ((PCon "DraftRows" (PVar "mid") (PVar "values"))) (EApp (EApp (EVar "node") (ELit (LString "rows"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "values"))))))
(DTypeSig false "cprogramSummary" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramSummary" ((PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorTypes") (PVar "impls"))) (EApp (EApp (EVar "node") (ELit (LString "CProgramSummary"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "binds"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ctorArities"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ctorTypes"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "impls"))))))
(DTypeSig false "observationSexp" (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "observationSexp" ((PVar "producer") (PVar "population") (PVar "payload")) (EApp (EApp (EVar "node") (ELit (LString "observed"))) (EListLit (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "populationSexp") (EVar "population")) (EVar "payload"))))
(DTypeSig false "declObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "declObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "decls"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "decls")))))
(DTypeSig false "moduleObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "DraftModule"))) (TyCon "String")))
(DFunDef false "moduleObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "modules"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "draftModuleSexp")) (EVar "modules")))))
(DTypeSig false "coreObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyCon "CProgram")) (TyCon "String")))
(DFunDef false "coreObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "program"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "cprogramSummary") (EVar "program"))))
(DTypeSig false "rowsObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a")))) (TyCon "String")))
(DFunDef false "rowsObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "rows"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "rowsSummary") (EVar "rows"))))
(DTypeSig false "boolObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyCon "String")))
(DFunDef false "boolObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "value"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "boolStr") (EVar "value"))))
(DTypeSig false "differentCount" (TyFun (TyApp (TyCon "List") (TyCon "DraftReceipt")) (TyCon "Int")))
(DFunDef false "differentCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "differentCount" ((PCons (PCon "DraftReceipt" PWild PWild PWild (PCon "DraftDifferent")) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "differentCount") (EVar "rest"))))
(DFunDef false "differentCount" ((PCons PWild (PVar "rest"))) (EApp (EVar "differentCount") (EVar "rest")))
(DTypeSig true "draftSemanticProgramToSexp" (TyFun (TyCon "DraftSemanticProgram") (TyFun (TyApp (TyCon "List") (TyCon "DraftReceipt")) (TyCon "String"))))
(DFunDef false "draftSemanticProgramToSexp" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PVar "methodIface") (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending")) (PVar "receipts")) (EApp (EApp (EVar "node") (ELit (LString "DraftSemanticProgram"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "runtime"))) (EListLit (EApp (EVar "declObservationSexp") (EVar "runtimeD")))) (EApp (EApp (EVar "node") (ELit (LString "prelude"))) (EListLit (EApp (EVar "declObservationSexp") (EVar "coreD")))) (EApp (EApp (EVar "node") (ELit (LString "modules"))) (EListLit (EApp (EVar "moduleObservationSexp") (EVar "modules")))) (EApp (EApp (EVar "node") (ELit (LString "legacy-core"))) (EListLit (EApp (EVar "coreObservationSexp") (EVar "legacyCore")))) (EApp (EApp (EVar "node") (ELit (LString "returns-self"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "returnsSelf")))) (EApp (EApp (EVar "node") (ELit (LString "self-fn-params"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "selfFnParams")))) (EApp (EApp (EVar "node") (ELit (LString "method-iface"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "methodIface")))) (EApp (EApp (EVar "node") (ELit (LString "method-constraints"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "methodConstraints")))) (EApp (EApp (EVar "node") (ELit (LString "ctor-field-types"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "ctorFieldTypes")))) (EApp (EApp (EVar "node") (ELit (LString "decl-sig-types"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "declSigTypes")))) (EApp (EApp (EVar "node") (ELit (LString "main-is-unit"))) (EListLit (EApp (EVar "boolObservationSexp") (EVar "mainIsUnit")))) (EApp (EApp (EVar "node") (ELit (LString "main-is-float"))) (EListLit (EApp (EVar "boolObservationSexp") (EVar "mainIsFloat")))) (EApp (EApp (EVar "node") (ELit (LString "pending-facts"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "pendingSexp")) (EVar "pending"))))) (EApp (EApp (EVar "node") (ELit (LString "transport-receipts"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "receiptSexp")) (EVar "receipts"))))) (EApp (EApp (EVar "node") (ELit (LString "summary"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "receipts"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "receipts"))))) (EApp (EApp (EVar "node") (ELit (LString "different"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "differentCount") (EVar "receipts"))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerProgramEmit" false) (mem "returnsSelfTable" false) (mem "selfFnParamTable" false) (mem "methodIfaceTable" false) (mem "methodConstraintIfaces" false) (mem "ctorFieldTypeNames" false) (mem "declSigTypeNames" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "dceFilter" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "listLen" false))))
(DData Public "DraftProducer" () ((variant "ProducerLoadedRuntime" (ConPos)) (variant "ProducerElaborateModules" (ConPos)) (variant "ProducerLowerProgramEmit" (ConPos)) (variant "ProducerReturnsSelfTable" (ConPos)) (variant "ProducerSelfFnParamTable" (ConPos)) (variant "ProducerMethodIfaceTable" (ConPos)) (variant "ProducerMethodConstraintIfaces" (ConPos)) (variant "ProducerCtorFieldTypeNames" (ConPos)) (variant "ProducerDeclSigTypeNames" (ConPos)) (variant "ProducerMainScheme" (ConPos)) (variant "ProducerIdentityVisibility" (ConPos)) (variant "ProducerRuntimeTypes" (ConPos)) (variant "ProducerCallShapes" (ConPos)) (variant "ProducerEvidence" (ConPos)) (variant "ProducerMethodDispositions" (ConPos)) (variant "ProducerCapabilityManifest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftProducer")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ProducerLoadedRuntime") (PCon "ProducerLoadedRuntime")) () (EVar "True")) (arm (PTuple (PCon "ProducerElaborateModules") (PCon "ProducerElaborateModules")) () (EVar "True")) (arm (PTuple (PCon "ProducerLowerProgramEmit") (PCon "ProducerLowerProgramEmit")) () (EVar "True")) (arm (PTuple (PCon "ProducerReturnsSelfTable") (PCon "ProducerReturnsSelfTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerSelfFnParamTable") (PCon "ProducerSelfFnParamTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodIfaceTable") (PCon "ProducerMethodIfaceTable")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodConstraintIfaces") (PCon "ProducerMethodConstraintIfaces")) () (EVar "True")) (arm (PTuple (PCon "ProducerCtorFieldTypeNames") (PCon "ProducerCtorFieldTypeNames")) () (EVar "True")) (arm (PTuple (PCon "ProducerDeclSigTypeNames") (PCon "ProducerDeclSigTypeNames")) () (EVar "True")) (arm (PTuple (PCon "ProducerMainScheme") (PCon "ProducerMainScheme")) () (EVar "True")) (arm (PTuple (PCon "ProducerIdentityVisibility") (PCon "ProducerIdentityVisibility")) () (EVar "True")) (arm (PTuple (PCon "ProducerRuntimeTypes") (PCon "ProducerRuntimeTypes")) () (EVar "True")) (arm (PTuple (PCon "ProducerCallShapes") (PCon "ProducerCallShapes")) () (EVar "True")) (arm (PTuple (PCon "ProducerEvidence") (PCon "ProducerEvidence")) () (EVar "True")) (arm (PTuple (PCon "ProducerMethodDispositions") (PCon "ProducerMethodDispositions")) () (EVar "True")) (arm (PTuple (PCon "ProducerCapabilityManifest") (PCon "ProducerCapabilityManifest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftProducer")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ProducerLoadedRuntime") () (ELit (LString "ProducerLoadedRuntime"))) (arm (PCon "ProducerElaborateModules") () (ELit (LString "ProducerElaborateModules"))) (arm (PCon "ProducerLowerProgramEmit") () (ELit (LString "ProducerLowerProgramEmit"))) (arm (PCon "ProducerReturnsSelfTable") () (ELit (LString "ProducerReturnsSelfTable"))) (arm (PCon "ProducerSelfFnParamTable") () (ELit (LString "ProducerSelfFnParamTable"))) (arm (PCon "ProducerMethodIfaceTable") () (ELit (LString "ProducerMethodIfaceTable"))) (arm (PCon "ProducerMethodConstraintIfaces") () (ELit (LString "ProducerMethodConstraintIfaces"))) (arm (PCon "ProducerCtorFieldTypeNames") () (ELit (LString "ProducerCtorFieldTypeNames"))) (arm (PCon "ProducerDeclSigTypeNames") () (ELit (LString "ProducerDeclSigTypeNames"))) (arm (PCon "ProducerMainScheme") () (ELit (LString "ProducerMainScheme"))) (arm (PCon "ProducerIdentityVisibility") () (ELit (LString "ProducerIdentityVisibility"))) (arm (PCon "ProducerRuntimeTypes") () (ELit (LString "ProducerRuntimeTypes"))) (arm (PCon "ProducerCallShapes") () (ELit (LString "ProducerCallShapes"))) (arm (PCon "ProducerEvidence") () (ELit (LString "ProducerEvidence"))) (arm (PCon "ProducerMethodDispositions") () (ELit (LString "ProducerMethodDispositions"))) (arm (PCon "ProducerCapabilityManifest") () (ELit (LString "ProducerCapabilityManifest")))))))
(DData Public "DraftPopulation" () ((variant "PopulationRuntimeDecls" (ConPos)) (variant "PopulationElaboratedPrelude" (ConPos)) (variant "PopulationElaboratedModules" (ConPos)) (variant "PopulationPostDceEmitCore" (ConPos)) (variant "PopulationElaboratedGraph" (ConPos)) (variant "PopulationRuntimeAndGraph" (ConPos)) (variant "PopulationEntryScheme" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftPopulation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PopulationRuntimeDecls") (PCon "PopulationRuntimeDecls")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedPrelude") (PCon "PopulationElaboratedPrelude")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedModules") (PCon "PopulationElaboratedModules")) () (EVar "True")) (arm (PTuple (PCon "PopulationPostDceEmitCore") (PCon "PopulationPostDceEmitCore")) () (EVar "True")) (arm (PTuple (PCon "PopulationElaboratedGraph") (PCon "PopulationElaboratedGraph")) () (EVar "True")) (arm (PTuple (PCon "PopulationRuntimeAndGraph") (PCon "PopulationRuntimeAndGraph")) () (EVar "True")) (arm (PTuple (PCon "PopulationEntryScheme") (PCon "PopulationEntryScheme")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftPopulation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PopulationRuntimeDecls") () (ELit (LString "PopulationRuntimeDecls"))) (arm (PCon "PopulationElaboratedPrelude") () (ELit (LString "PopulationElaboratedPrelude"))) (arm (PCon "PopulationElaboratedModules") () (ELit (LString "PopulationElaboratedModules"))) (arm (PCon "PopulationPostDceEmitCore") () (ELit (LString "PopulationPostDceEmitCore"))) (arm (PCon "PopulationElaboratedGraph") () (ELit (LString "PopulationElaboratedGraph"))) (arm (PCon "PopulationRuntimeAndGraph") () (ELit (LString "PopulationRuntimeAndGraph"))) (arm (PCon "PopulationEntryScheme") () (ELit (LString "PopulationEntryScheme")))))))
(DData Public "DraftObservation" ("a") ((variant "DraftObservation" (ConPos (TyCon "DraftProducer") (TyCon "DraftPopulation") (TyVar "a")))) ())
(DData Public "DraftModule" () ((variant "DraftModule" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Public "DraftRows" ("a") ((variant "DraftRows" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyVar "a"))))) ())
(DData Public "DraftFact" () ((variant "FactRuntimeProjection" (ConPos)) (variant "FactPreludeProjection" (ConPos)) (variant "FactModuleProjection" (ConPos)) (variant "FactLegacyCore" (ConPos)) (variant "FactReturnsSelf" (ConPos)) (variant "FactSelfFnParams" (ConPos)) (variant "FactMethodIface" (ConPos)) (variant "FactMethodConstraints" (ConPos)) (variant "FactCtorFieldTypes" (ConPos)) (variant "FactDeclSigTypes" (ConPos)) (variant "FactMainIsUnit" (ConPos)) (variant "FactMainIsFloat" (ConPos)) (variant "FactIdentityVisibility" (ConPos)) (variant "FactRuntimeTypes" (ConPos)) (variant "FactCallShapes" (ConPos)) (variant "FactEvidence" (ConPos)) (variant "FactMethodDispositions" (ConPos)) (variant "FactCapabilityManifest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "FactRuntimeProjection") (PCon "FactRuntimeProjection")) () (EVar "True")) (arm (PTuple (PCon "FactPreludeProjection") (PCon "FactPreludeProjection")) () (EVar "True")) (arm (PTuple (PCon "FactModuleProjection") (PCon "FactModuleProjection")) () (EVar "True")) (arm (PTuple (PCon "FactLegacyCore") (PCon "FactLegacyCore")) () (EVar "True")) (arm (PTuple (PCon "FactReturnsSelf") (PCon "FactReturnsSelf")) () (EVar "True")) (arm (PTuple (PCon "FactSelfFnParams") (PCon "FactSelfFnParams")) () (EVar "True")) (arm (PTuple (PCon "FactMethodIface") (PCon "FactMethodIface")) () (EVar "True")) (arm (PTuple (PCon "FactMethodConstraints") (PCon "FactMethodConstraints")) () (EVar "True")) (arm (PTuple (PCon "FactCtorFieldTypes") (PCon "FactCtorFieldTypes")) () (EVar "True")) (arm (PTuple (PCon "FactDeclSigTypes") (PCon "FactDeclSigTypes")) () (EVar "True")) (arm (PTuple (PCon "FactMainIsUnit") (PCon "FactMainIsUnit")) () (EVar "True")) (arm (PTuple (PCon "FactMainIsFloat") (PCon "FactMainIsFloat")) () (EVar "True")) (arm (PTuple (PCon "FactIdentityVisibility") (PCon "FactIdentityVisibility")) () (EVar "True")) (arm (PTuple (PCon "FactRuntimeTypes") (PCon "FactRuntimeTypes")) () (EVar "True")) (arm (PTuple (PCon "FactCallShapes") (PCon "FactCallShapes")) () (EVar "True")) (arm (PTuple (PCon "FactEvidence") (PCon "FactEvidence")) () (EVar "True")) (arm (PTuple (PCon "FactMethodDispositions") (PCon "FactMethodDispositions")) () (EVar "True")) (arm (PTuple (PCon "FactCapabilityManifest") (PCon "FactCapabilityManifest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "FactRuntimeProjection") () (ELit (LString "FactRuntimeProjection"))) (arm (PCon "FactPreludeProjection") () (ELit (LString "FactPreludeProjection"))) (arm (PCon "FactModuleProjection") () (ELit (LString "FactModuleProjection"))) (arm (PCon "FactLegacyCore") () (ELit (LString "FactLegacyCore"))) (arm (PCon "FactReturnsSelf") () (ELit (LString "FactReturnsSelf"))) (arm (PCon "FactSelfFnParams") () (ELit (LString "FactSelfFnParams"))) (arm (PCon "FactMethodIface") () (ELit (LString "FactMethodIface"))) (arm (PCon "FactMethodConstraints") () (ELit (LString "FactMethodConstraints"))) (arm (PCon "FactCtorFieldTypes") () (ELit (LString "FactCtorFieldTypes"))) (arm (PCon "FactDeclSigTypes") () (ELit (LString "FactDeclSigTypes"))) (arm (PCon "FactMainIsUnit") () (ELit (LString "FactMainIsUnit"))) (arm (PCon "FactMainIsFloat") () (ELit (LString "FactMainIsFloat"))) (arm (PCon "FactIdentityVisibility") () (ELit (LString "FactIdentityVisibility"))) (arm (PCon "FactRuntimeTypes") () (ELit (LString "FactRuntimeTypes"))) (arm (PCon "FactCallShapes") () (ELit (LString "FactCallShapes"))) (arm (PCon "FactEvidence") () (ELit (LString "FactEvidence"))) (arm (PCon "FactMethodDispositions") () (ELit (LString "FactMethodDispositions"))) (arm (PCon "FactCapabilityManifest") () (ELit (LString "FactCapabilityManifest")))))))
(DData Public "DraftPending" () ((variant "DraftPending" (ConPos (TyCon "DraftFact") (TyCon "DraftProducer") (TyCon "String")))) ())
(DData Public "DraftComparison" () ((variant "DraftMatch" (ConPos)) (variant "DraftDifferent" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DraftComparison")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "DraftMatch") (PCon "DraftMatch")) () (EVar "True")) (arm (PTuple (PCon "DraftDifferent") (PCon "DraftDifferent")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "DraftComparison")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "DraftMatch") () (ELit (LString "DraftMatch"))) (arm (PCon "DraftDifferent") () (ELit (LString "DraftDifferent")))))))
(DData Public "DraftReceipt" () ((variant "DraftReceipt" (ConPos (TyCon "DraftFact") (TyCon "DraftProducer") (TyCon "DraftPopulation") (TyCon "DraftComparison")))) ())
(DData Public "DraftSemanticProgram" () ((variant "DraftSemanticProgram" (ConPos (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "DraftModule"))) (TyApp (TyCon "DraftObservation") (TyCon "CProgram")) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))) (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyApp (TyCon "List") (TyCon "DraftPending"))))) ())
(DTypeSig false "moduleOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "DraftModule")))
(DFunDef false "moduleOf" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "DraftModule") (EVar "mid")) (EVar "decls")))
(DTypeSig false "rowsOf" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "DraftModule") (TyApp (TyCon "DraftRows") (TyVar "a")))))
(DFunDef false "rowsOf" ((PVar "f") (PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EApp (EVar "f") (EVar "decls"))))
(DTypeSig false "rowsFor" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "DraftModule")) (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))))))
(DFunDef false "rowsFor" ((PVar "f") (PVar "modules")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rowsOf") (EVar "f"))) (EVar "modules")))
(DTypeSig false "semanticModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "DraftModule")))))
(DFunDef false "semanticModules" ((PVar "coreD") (PVar "modules")) (EBinOp "::" (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "coreD")) (EApp (EApp (EMethodRef "map") (EVar "moduleOf")) (EVar "modules"))))
(DTypeSig false "pendingFacts" (TyApp (TyCon "List") (TyCon "DraftPending")))
(DFunDef false "pendingFacts" () (EListLit (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactIdentityVisibility")) (EVar "ProducerIdentityVisibility")) (ELit (LString "X-I.P and #1115"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactRuntimeTypes")) (EVar "ProducerRuntimeTypes")) (ELit (LString "X-T.P / #353"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactCallShapes")) (EVar "ProducerCallShapes")) (ELit (LString "X-C.P / #1318 -> #1137"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactEvidence")) (EVar "ProducerEvidence")) (ELit (LString "X-E.P / #993, #1113, #1082"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactMethodDispositions")) (EVar "ProducerMethodDispositions")) (ELit (LString "X-E.P / A-3 #1112"))) (EApp (EApp (EApp (EVar "DraftPending") (EVar "FactCapabilityManifest")) (EVar "ProducerCapabilityManifest")) (ELit (LString "effects manifest producer")))))
(DTypeSig true "buildDraftSemanticProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "DraftSemanticProgram")))))))
(DFunDef false "buildDraftSemanticProgram" ((PVar "runtimeDecls") (PVar "coreD") (PVar "modules") (PVar "mainIsUnit") (PVar "mainIsFloat")) (EBlock (DoLet false false (PVar "allDecls") (EApp (EVar "dceFilter") (EBinOp "++" (EVar "coreD") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))))) (DoLet false false (PVar "semMods") (EApp (EApp (EVar "semanticModules") (EVar "coreD")) (EVar "modules"))) (DoLet false false (PVar "sigMods") (EBinOp "::" (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "runtimeDecls")) (EVar "semMods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EVar "runtimeDecls"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EVar "coreD"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EApp (EApp (EMethodRef "map") (EVar "moduleOf")) (EVar "modules")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EApp (EVar "lowerProgramEmit") (EVar "allDecls")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "returnsSelfTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "selfFnParamTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "methodIfaceTable")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "methodConstraintIfaces")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EApp (EApp (EVar "rowsFor") (EVar "ctorFieldTypeNames")) (EVar "semMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EApp (EApp (EVar "rowsFor") (EVar "declSigTypeNames")) (EVar "sigMods")))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainIsUnit"))) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainIsFloat"))) (EVar "pendingFacts")))))
(DTypeSig false "flattenRows" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "flattenRows" ((PList)) (EListLit))
(DFunDef false "flattenRows" ((PCons (PCon "DraftRows" PWild (PVar "rows")) (PVar "rest"))) (EBinOp "++" (EVar "rows") (EApp (EVar "flattenRows") (EVar "rest"))))
(DTypeSig false "receipt" (TyFun (TyCon "DraftFact") (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "Bool") (TyCon "DraftReceipt"))))))
(DFunDef false "receipt" ((PVar "fact") (PVar "producer") (PVar "population") (PVar "same")) (EApp (EApp (EApp (EApp (EVar "DraftReceipt") (EVar "fact")) (EVar "producer")) (EVar "population")) (EIf (EVar "same") (EVar "DraftMatch") (EVar "DraftDifferent"))))
(DTypeSig false "observationMetadataMatches" (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyCon "Bool"))))))
(DFunDef false "observationMetadataMatches" ((PVar "expectedProducer") (PVar "expectedPopulation") (PVar "actualProducer") (PVar "actualPopulation")) (EBinOp "&&" (EBinOp "==" (EVar "expectedProducer") (EVar "actualProducer")) (EBinOp "==" (EVar "expectedPopulation") (EVar "actualPopulation"))))
(DTypeSig false "modulesSexp" (TyFun (TyApp (TyCon "List") (TyCon "DraftModule")) (TyCon "String")))
(DFunDef false "modulesSexp" ((PVar "modules")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "draftModulePayloadSexp")) (EVar "modules"))))
(DTypeSig false "draftModulePayloadSexp" (TyFun (TyCon "DraftModule") (TyCon "String")))
(DFunDef false "draftModulePayloadSexp" ((PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgramEmit") (EVar "decls"))))))
(DTypeSig false "draftModuleSexp" (TyFun (TyCon "DraftModule") (TyCon "String")))
(DFunDef false "draftModuleSexp" ((PCon "DraftModule" (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "decls"))))))
(DTypeSig true "compareDraftSemanticProgram" (TyFun (TyCon "DraftSemanticProgram") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "DraftReceipt")))))))))
(DFunDef false "compareDraftSemanticProgram" ((PCon "DraftSemanticProgram" (PCon "DraftObservation" (PVar "runtimeProducer") (PVar "runtimePopulation") (PVar "draftRuntime")) (PCon "DraftObservation" (PVar "coreProducer") (PVar "corePopulation") (PVar "draftCore")) (PCon "DraftObservation" (PVar "modulesProducer") (PVar "modulesPopulation") (PVar "draftModules")) (PCon "DraftObservation" (PVar "legacyCoreProducer") (PVar "legacyCorePopulation") (PVar "draftLegacyCore")) (PCon "DraftObservation" (PVar "returnsSelfProducer") (PVar "returnsSelfPopulation") (PVar "draftReturnsSelf")) (PCon "DraftObservation" (PVar "selfFnProducer") (PVar "selfFnPopulation") (PVar "draftSelfFnParams")) (PCon "DraftObservation" (PVar "methodIfaceProducer") (PVar "methodIfacePopulation") (PVar "draftMethodIface")) (PCon "DraftObservation" (PVar "methodConstraintsProducer") (PVar "methodConstraintsPopulation") (PVar "draftMethodConstraints")) (PCon "DraftObservation" (PVar "ctorFieldsProducer") (PVar "ctorFieldsPopulation") (PVar "draftCtorFieldTypes")) (PCon "DraftObservation" (PVar "declSigsProducer") (PVar "declSigsPopulation") (PVar "draftDeclSigTypes")) (PCon "DraftObservation" (PVar "mainUnitProducer") (PVar "mainUnitPopulation") (PVar "draftMainIsUnit")) (PCon "DraftObservation" (PVar "mainFloatProducer") (PVar "mainFloatPopulation") (PVar "draftMainIsFloat")) PWild) (PVar "runtimeDecls") (PVar "coreD") (PVar "modules") (PVar "mainIsUnit") (PVar "mainIsFloat")) (EBlock (DoLet false false (PVar "allDecls") (EApp (EVar "dceFilter") (EBinOp "++" (EVar "coreD") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactRuntimeProjection")) (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerLoadedRuntime")) (EVar "PopulationRuntimeDecls")) (EVar "runtimeProducer")) (EVar "runtimePopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "draftRuntime")))) (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "runtime"))) (EVar "runtimeDecls"))))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactPreludeProjection")) (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedPrelude")) (EVar "coreProducer")) (EVar "corePopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "draftCore")))) (EApp (EVar "modulesSexp") (EListLit (EApp (EApp (EVar "DraftModule") (ELit (LString "core"))) (EVar "coreD"))))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactModuleProjection")) (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerElaborateModules")) (EVar "PopulationElaboratedModules")) (EVar "modulesProducer")) (EVar "modulesPopulation")) (EBinOp "==" (EApp (EVar "modulesSexp") (EVar "draftModules")) (EApp (EVar "modulesSexp") (EApp (EApp (EMethodRef "map") (EVar "moduleOf")) (EVar "modules")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactLegacyCore")) (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerLowerProgramEmit")) (EVar "PopulationPostDceEmitCore")) (EVar "legacyCoreProducer")) (EVar "legacyCorePopulation")) (EBinOp "==" (EApp (EVar "cprogramToSexp") (EVar "draftLegacyCore")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgramEmit") (EVar "allDecls")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactReturnsSelf")) (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerReturnsSelfTable")) (EVar "PopulationElaboratedGraph")) (EVar "returnsSelfProducer")) (EVar "returnsSelfPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftReturnsSelf")) (EApp (EVar "returnsSelfTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactSelfFnParams")) (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerSelfFnParamTable")) (EVar "PopulationElaboratedGraph")) (EVar "selfFnProducer")) (EVar "selfFnPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftSelfFnParams")) (EApp (EVar "selfFnParamTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMethodIface")) (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMethodIfaceTable")) (EVar "PopulationElaboratedGraph")) (EVar "methodIfaceProducer")) (EVar "methodIfacePopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftMethodIface")) (EApp (EVar "methodIfaceTable") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMethodConstraints")) (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMethodConstraintIfaces")) (EVar "PopulationElaboratedGraph")) (EVar "methodConstraintsProducer")) (EVar "methodConstraintsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftMethodConstraints")) (EApp (EVar "methodConstraintIfaces") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactCtorFieldTypes")) (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerCtorFieldTypeNames")) (EVar "PopulationElaboratedGraph")) (EVar "ctorFieldsProducer")) (EVar "ctorFieldsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftCtorFieldTypes")) (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls"))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactDeclSigTypes")) (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerDeclSigTypeNames")) (EVar "PopulationRuntimeAndGraph")) (EVar "declSigsProducer")) (EVar "declSigsPopulation")) (EBinOp "==" (EApp (EVar "flattenRows") (EVar "draftDeclSigTypes")) (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls")))))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMainIsUnit")) (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainUnitProducer")) (EVar "mainUnitPopulation")) (EBinOp "==" (EVar "draftMainIsUnit") (EVar "mainIsUnit")))) (EApp (EApp (EApp (EApp (EVar "receipt") (EVar "FactMainIsFloat")) (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "observationMetadataMatches") (EVar "ProducerMainScheme")) (EVar "PopulationEntryScheme")) (EVar "mainFloatProducer")) (EVar "mainFloatPopulation")) (EBinOp "==" (EVar "draftMainIsFloat") (EVar "mainIsFloat"))))))))
(DTypeSig false "dropFirstRows" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a")))))
(DFunDef false "dropFirstRows" ((PList)) (EListLit))
(DFunDef false "dropFirstRows" ((PCons (PCon "DraftRows" (PVar "mid") (PList)) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EListLit)) (EApp (EVar "dropFirstRows") (EVar "rest"))))
(DFunDef false "dropFirstRows" ((PCons (PCon "DraftRows" (PVar "mid") (PCons PWild (PVar "rows"))) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DraftRows") (EVar "mid")) (EVar "rows")) (EVar "rest")))
(DTypeSig true "draftWithoutFirstMethodIface" (TyFun (TyCon "DraftSemanticProgram") (TyCon "DraftSemanticProgram")))
(DFunDef false "draftWithoutFirstMethodIface" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "methodIface")) (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EVar "runtimeD")) (EVar "coreD")) (EVar "modules")) (EVar "legacyCore")) (EVar "returnsSelf")) (EVar "selfFnParams")) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "producer")) (EVar "population")) (EApp (EVar "dropFirstRows") (EVar "methodIface")))) (EVar "methodConstraints")) (EVar "ctorFieldTypes")) (EVar "declSigTypes")) (EVar "mainIsUnit")) (EVar "mainIsFloat")) (EVar "pending")))
(DTypeSig true "draftWithWrongMethodIfaceProvenance" (TyFun (TyCon "DraftSemanticProgram") (TyCon "DraftSemanticProgram")))
(DFunDef false "draftWithWrongMethodIfaceProvenance" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PCon "DraftObservation" PWild PWild (PVar "methodIface")) (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DraftSemanticProgram") (EVar "runtimeD")) (EVar "coreD")) (EVar "modules")) (EVar "legacyCore")) (EVar "returnsSelf")) (EVar "selfFnParams")) (EApp (EApp (EApp (EVar "DraftObservation") (EVar "ProducerRuntimeTypes")) (EVar "PopulationRuntimeDecls")) (EVar "methodIface"))) (EVar "methodConstraints")) (EVar "ctorFieldTypes")) (EVar "declSigTypes")) (EVar "mainIsUnit")) (EVar "mainIsFloat")) (EVar "pending")))
(DTypeSig false "producerSexp" (TyFun (TyCon "DraftProducer") (TyCon "String")))
(DFunDef false "producerSexp" ((PCon "ProducerLoadedRuntime")) (ELit (LString "loader:runtime")))
(DFunDef false "producerSexp" ((PCon "ProducerElaborateModules")) (ELit (LString "elaborateModules")))
(DFunDef false "producerSexp" ((PCon "ProducerLowerProgramEmit")) (ELit (LString "lowerProgramEmit")))
(DFunDef false "producerSexp" ((PCon "ProducerReturnsSelfTable")) (ELit (LString "returnsSelfTable")))
(DFunDef false "producerSexp" ((PCon "ProducerSelfFnParamTable")) (ELit (LString "selfFnParamTable")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodIfaceTable")) (ELit (LString "methodIfaceTable")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodConstraintIfaces")) (ELit (LString "methodConstraintIfaces")))
(DFunDef false "producerSexp" ((PCon "ProducerCtorFieldTypeNames")) (ELit (LString "ctorFieldTypeNames")))
(DFunDef false "producerSexp" ((PCon "ProducerDeclSigTypeNames")) (ELit (LString "declSigTypeNames")))
(DFunDef false "producerSexp" ((PCon "ProducerMainScheme")) (ELit (LString "mainScheme")))
(DFunDef false "producerSexp" ((PCon "ProducerIdentityVisibility")) (ELit (LString "X-I.P")))
(DFunDef false "producerSexp" ((PCon "ProducerRuntimeTypes")) (ELit (LString "X-T.P")))
(DFunDef false "producerSexp" ((PCon "ProducerCallShapes")) (ELit (LString "X-C.P")))
(DFunDef false "producerSexp" ((PCon "ProducerEvidence")) (ELit (LString "X-E.P:evidence")))
(DFunDef false "producerSexp" ((PCon "ProducerMethodDispositions")) (ELit (LString "X-E.P:dispositions")))
(DFunDef false "producerSexp" ((PCon "ProducerCapabilityManifest")) (ELit (LString "effects:manifest")))
(DTypeSig false "populationSexp" (TyFun (TyCon "DraftPopulation") (TyCon "String")))
(DFunDef false "populationSexp" ((PCon "PopulationRuntimeDecls")) (ELit (LString "runtime-decls")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedPrelude")) (ELit (LString "elaborated-prelude")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedModules")) (ELit (LString "elaborated-modules")))
(DFunDef false "populationSexp" ((PCon "PopulationPostDceEmitCore")) (ELit (LString "post-dce-emit-core")))
(DFunDef false "populationSexp" ((PCon "PopulationElaboratedGraph")) (ELit (LString "elaborated-graph")))
(DFunDef false "populationSexp" ((PCon "PopulationRuntimeAndGraph")) (ELit (LString "runtime-and-elaborated-graph")))
(DFunDef false "populationSexp" ((PCon "PopulationEntryScheme")) (ELit (LString "entry-scheme")))
(DTypeSig false "factSexp" (TyFun (TyCon "DraftFact") (TyCon "String")))
(DFunDef false "factSexp" ((PCon "FactRuntimeProjection")) (ELit (LString "runtime-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactPreludeProjection")) (ELit (LString "prelude-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactModuleProjection")) (ELit (LString "module-emitter-projection")))
(DFunDef false "factSexp" ((PCon "FactLegacyCore")) (ELit (LString "legacy-core")))
(DFunDef false "factSexp" ((PCon "FactReturnsSelf")) (ELit (LString "returns-self")))
(DFunDef false "factSexp" ((PCon "FactSelfFnParams")) (ELit (LString "self-fn-params")))
(DFunDef false "factSexp" ((PCon "FactMethodIface")) (ELit (LString "method-iface")))
(DFunDef false "factSexp" ((PCon "FactMethodConstraints")) (ELit (LString "method-constraints")))
(DFunDef false "factSexp" ((PCon "FactCtorFieldTypes")) (ELit (LString "ctor-field-types")))
(DFunDef false "factSexp" ((PCon "FactDeclSigTypes")) (ELit (LString "decl-sig-types")))
(DFunDef false "factSexp" ((PCon "FactMainIsUnit")) (ELit (LString "main-is-unit")))
(DFunDef false "factSexp" ((PCon "FactMainIsFloat")) (ELit (LString "main-is-float")))
(DFunDef false "factSexp" ((PCon "FactIdentityVisibility")) (ELit (LString "identity-visibility")))
(DFunDef false "factSexp" ((PCon "FactRuntimeTypes")) (ELit (LString "runtime-types")))
(DFunDef false "factSexp" ((PCon "FactCallShapes")) (ELit (LString "call-shapes")))
(DFunDef false "factSexp" ((PCon "FactEvidence")) (ELit (LString "evidence")))
(DFunDef false "factSexp" ((PCon "FactMethodDispositions")) (ELit (LString "method-dispositions")))
(DFunDef false "factSexp" ((PCon "FactCapabilityManifest")) (ELit (LString "capability-manifest")))
(DTypeSig false "comparisonSexp" (TyFun (TyCon "DraftComparison") (TyCon "String")))
(DFunDef false "comparisonSexp" ((PCon "DraftMatch")) (ELit (LString "MATCH")))
(DFunDef false "comparisonSexp" ((PCon "DraftDifferent")) (ELit (LString "DIFFERENT")))
(DTypeSig false "pendingSexp" (TyFun (TyCon "DraftPending") (TyCon "String")))
(DFunDef false "pendingSexp" ((PCon "DraftPending" (PVar "fact") (PVar "producer") (PVar "dependency"))) (EApp (EApp (EVar "node") (ELit (LString "pending"))) (EListLit (EApp (EVar "factSexp") (EVar "fact")) (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "escStr") (EVar "dependency")))))
(DTypeSig false "receiptSexp" (TyFun (TyCon "DraftReceipt") (TyCon "String")))
(DFunDef false "receiptSexp" ((PCon "DraftReceipt" (PVar "fact") (PVar "producer") (PVar "population") (PVar "comparison"))) (EApp (EApp (EVar "node") (ELit (LString "receipt"))) (EListLit (EApp (EVar "factSexp") (EVar "fact")) (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "populationSexp") (EVar "population")) (EApp (EVar "comparisonSexp") (EVar "comparison")))))
(DTypeSig false "rowsSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a"))) (TyCon "String")))
(DFunDef false "rowsSummary" ((PVar "rows")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "rowSummary")) (EVar "rows"))))
(DTypeSig false "rowSummary" (TyFun (TyApp (TyCon "DraftRows") (TyVar "a")) (TyCon "String")))
(DFunDef false "rowSummary" ((PCon "DraftRows" (PVar "mid") (PVar "values"))) (EApp (EApp (EVar "node") (ELit (LString "rows"))) (EListLit (EApp (EVar "escStr") (EVar "mid")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "values"))))))
(DTypeSig false "cprogramSummary" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramSummary" ((PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorTypes") (PVar "impls"))) (EApp (EApp (EVar "node") (ELit (LString "CProgramSummary"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "binds"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ctorArities"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ctorTypes"))) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "impls"))))))
(DTypeSig false "observationSexp" (TyFun (TyCon "DraftProducer") (TyFun (TyCon "DraftPopulation") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "observationSexp" ((PVar "producer") (PVar "population") (PVar "payload")) (EApp (EApp (EVar "node") (ELit (LString "observed"))) (EListLit (EApp (EVar "producerSexp") (EVar "producer")) (EApp (EVar "populationSexp") (EVar "population")) (EVar "payload"))))
(DTypeSig false "declObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "declObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "decls"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "decls")))))
(DTypeSig false "moduleObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyCon "DraftModule"))) (TyCon "String")))
(DFunDef false "moduleObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "modules"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "draftModuleSexp")) (EVar "modules")))))
(DTypeSig false "coreObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyCon "CProgram")) (TyCon "String")))
(DFunDef false "coreObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "program"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "cprogramSummary") (EVar "program"))))
(DTypeSig false "rowsObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyApp (TyCon "List") (TyApp (TyCon "DraftRows") (TyVar "a")))) (TyCon "String")))
(DFunDef false "rowsObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "rows"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "rowsSummary") (EVar "rows"))))
(DTypeSig false "boolObservationSexp" (TyFun (TyApp (TyCon "DraftObservation") (TyCon "Bool")) (TyCon "String")))
(DFunDef false "boolObservationSexp" ((PCon "DraftObservation" (PVar "producer") (PVar "population") (PVar "value"))) (EApp (EApp (EApp (EVar "observationSexp") (EVar "producer")) (EVar "population")) (EApp (EVar "boolStr") (EVar "value"))))
(DTypeSig false "differentCount" (TyFun (TyApp (TyCon "List") (TyCon "DraftReceipt")) (TyCon "Int")))
(DFunDef false "differentCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "differentCount" ((PCons (PCon "DraftReceipt" PWild PWild PWild (PCon "DraftDifferent")) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "differentCount") (EVar "rest"))))
(DFunDef false "differentCount" ((PCons PWild (PVar "rest"))) (EApp (EVar "differentCount") (EVar "rest")))
(DTypeSig true "draftSemanticProgramToSexp" (TyFun (TyCon "DraftSemanticProgram") (TyFun (TyApp (TyCon "List") (TyCon "DraftReceipt")) (TyCon "String"))))
(DFunDef false "draftSemanticProgramToSexp" ((PCon "DraftSemanticProgram" (PVar "runtimeD") (PVar "coreD") (PVar "modules") (PVar "legacyCore") (PVar "returnsSelf") (PVar "selfFnParams") (PVar "methodIface") (PVar "methodConstraints") (PVar "ctorFieldTypes") (PVar "declSigTypes") (PVar "mainIsUnit") (PVar "mainIsFloat") (PVar "pending")) (PVar "receipts")) (EApp (EApp (EVar "node") (ELit (LString "DraftSemanticProgram"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "runtime"))) (EListLit (EApp (EVar "declObservationSexp") (EVar "runtimeD")))) (EApp (EApp (EVar "node") (ELit (LString "prelude"))) (EListLit (EApp (EVar "declObservationSexp") (EVar "coreD")))) (EApp (EApp (EVar "node") (ELit (LString "modules"))) (EListLit (EApp (EVar "moduleObservationSexp") (EVar "modules")))) (EApp (EApp (EVar "node") (ELit (LString "legacy-core"))) (EListLit (EApp (EVar "coreObservationSexp") (EVar "legacyCore")))) (EApp (EApp (EVar "node") (ELit (LString "returns-self"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "returnsSelf")))) (EApp (EApp (EVar "node") (ELit (LString "self-fn-params"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "selfFnParams")))) (EApp (EApp (EVar "node") (ELit (LString "method-iface"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "methodIface")))) (EApp (EApp (EVar "node") (ELit (LString "method-constraints"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "methodConstraints")))) (EApp (EApp (EVar "node") (ELit (LString "ctor-field-types"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "ctorFieldTypes")))) (EApp (EApp (EVar "node") (ELit (LString "decl-sig-types"))) (EListLit (EApp (EVar "rowsObservationSexp") (EVar "declSigTypes")))) (EApp (EApp (EVar "node") (ELit (LString "main-is-unit"))) (EListLit (EApp (EVar "boolObservationSexp") (EVar "mainIsUnit")))) (EApp (EApp (EVar "node") (ELit (LString "main-is-float"))) (EListLit (EApp (EVar "boolObservationSexp") (EVar "mainIsFloat")))) (EApp (EApp (EVar "node") (ELit (LString "pending-facts"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "pendingSexp")) (EVar "pending"))))) (EApp (EApp (EVar "node") (ELit (LString "transport-receipts"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "receiptSexp")) (EVar "receipts"))))) (EApp (EApp (EVar "node") (ELit (LString "summary"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "receipts"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "receipts"))))) (EApp (EApp (EVar "node") (ELit (LString "different"))) (EListLit (EApp (EVar "intToString") (EApp (EVar "differentCount") (EVar "receipts"))))))))))
