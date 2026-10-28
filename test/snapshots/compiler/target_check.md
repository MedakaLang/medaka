# META
source_lines=510
stages=DESUGAR,MARK
# SOURCE
import support.diag_codes.{DiagCode(..)}
import types.capability_manifest.{
  CapabilityManifest(..), ManifestRequest(..), ManifestLookup(..),
  InvocationProtocol(..), FrozenAtom(..), lookupManifest
}
import types.capability_policy.{manifestAllowed}
import driver.main_autoprint.{mainEntryKey}
import tools.check_policy.{frozenAtomText}
-- compiler/tools/target_check.mdk — does a program fit a target profile?
-- Three rules.  The entry's invocation summary, cut to the labels a profile
-- gates, is judged by the same subsumption `check-policy` uses, and a refusal
-- becomes one located `T-TARGET-CAPABILITY` diagnostic.  Every user extern
-- the program reaches must be bound for the host the profile calls foreign
-- code through, else it is a `T-TARGET-NO-BINDING` diagnostic located at the
-- declaration.  And every built-in the program reaches must be provided by the
-- profile's column of the extern catalog, else it is a `T-TARGET-NOT-PROVIDED`
-- diagnostic located at the binding that names it.
import backend.emit_target.{Backend(..), profileColumn}
import frontend.ast.{
  Decl(..),
  ExternBind(..),
  ExternDecl(..),
  LetBind(..),
  Loc(..),
  TyConOrigin(..),
  externBindings,
  letBindName,
}
import frontend.marker.{declRefs}
import backend.core_validate.{unprovidedOn, isUnprovidedOn}
import backend.extern_catalog.{GapKind(..), gapKindName}
import types.target_profile.{
  TargetProfile,
  buildable,
  lookupProfile,
  profileName,
  profileNames,
  profileGrants,
  profileBindingHost,
  isGatedLabel,
  reachesLabel,
  runProfile,
}
import ir.dce.{ReachRoots(..), reachedExternChains, reachedExternRoutes}
import types.effect_policy.{
  PolicyVerdict(..), policyRefusals, buildCallGraph, fnEffectsTable, viaChain
}
import types.repr.{Scheme}
import types.effect_rows.{
  Atom, atomLabel, atomLabelOf, effLabelOrigin, renderAtom
}
import tools.check_policy.{TargetInputs(..)}
import types.tc_types.{DriveOutputs(..)}
import driver.diagnostics.{
  Diag(..),
  Severity(..),
  mkDiag,
  cjFoldIntoFile,
  ppDiagCliLines,
  readFileSafe,
  srcLinesArr,
}
import support.util.{lookupAssoc, joinWith, dedup, dedupBy, contains, anyList}
import string.{trim}
import list.{lookup}

export
targetCapabilityCode : DiagCode
targetCapabilityCode = TTargetCapability

export
targetNoBindingCode : DiagCode
targetNoBindingCode = TTargetNoBinding

export
targetNotProvidedCode : DiagCode
targetNotProvidedCode = TTargetNotProvided

-- The refusals of the program whose entry file is `file`; `[]` admits it.
-- `paths` maps each module to its file, where a refused extern is located.  A
-- program with no `main` of its own has no entry to judge, and that is a
-- refusal too.  A reached extern with no binding for the profile's host is the
-- verdict, one diagnostic per declaration; the entry's capability refusal is
-- reported only when no declaration is refused.  The two meet on `FFI`, which
-- `eval/run` alone withholds, so the declaration names the cause where the
-- entry's row would only name the label.  A reached built-in the profile does
-- not provide is judged only when the capability rule admits the entry: a
-- withheld label already names why the built-in cannot run there.
export
targetRefusal : TargetProfile ->
  String ->
  List (String, String) ->
  TargetInputs ->
  List Diag
targetRefusal profile file paths analysis =
  match lookupAssoc "main" analysis.tiSchemes
    None => [missingEntryDiag profile file]
    Some sch =>
      let bound = bindingRefusals profile paths analysis
      match capabilityRefusal profile analysis sch
        Some d => match bound
          [] => [d]
          ds => ds
        None => bound ++ builtinRefusals profile paths analysis

-- The file a target refusal is located in: a refused extern's module, else
-- the entry.
export
targetDiagFile : String -> Diag -> String
targetDiagFile entry (Diag _ _ _ (Some (Loc f _ _ _ _)) _ _) =
  if f == "" then entry else f
targetDiagFile entry _ = entry

-- One refusal as the verbs print it, against the source of its file.
export
ppTargetDiag : String -> String -> Diag -> <IO> String
ppTargetDiag entry entrySrc d =
  let file = targetDiagFile entry d
  let src = if file == entry then entrySrc else readFileSafe file
  ppDiagCliLines (srcLinesArr src) file d

-- The refusals folded into a JSON report's per-file triples: each into its
-- file's triple, or into a new one for a file the report has none for.
export
foldTargetDiags : String ->
  String ->
  List Diag ->
  List (String, String, List Diag) ->
  <IO> List (String, String, List Diag)
foldTargetDiags _ _ [] triples = triples
foldTargetDiags entry entrySrc (d :: ds) triples =
  let file = targetDiagFile entry d
  let folded =
    if anyList ((p, _, _) => p == file) triples then
      cjFoldIntoFile file [d] triples
    else
      let src = if file == entry then entrySrc else readFileSafe file
      triples ++ [(file, src, [d])]
  foldTargetDiags entry entrySrc ds folded

-- The entry's refusal, or `None` when `main` performs nothing the profile
-- withholds.  The entry judged is the one the drivers run: a value `main` they
-- print performs what the `println` applied to it performs.
capabilityRefusal : TargetProfile -> TargetInputs -> Scheme -> Option Diag
capabilityRefusal profile analysis sch =
  let request = ManifestRequest {
    entry = mainEntryKey analysis.tiModules,
    protocol = ExecutedMain,
  }
  match (lookupManifest
    request
    analysis.tiOutputs.doManifestRequests
    analysis.tiOutputs.doManifests)
    Published manifest => manifestCapabilityRefusal profile analysis manifest
    _ =>
      Some
        (mkDiag
          SevError
          targetCapabilityCode
          "missing checked ExecutedMain manifest"
          (entryLoc analysis.tiEntryDecls))

manifestCapabilityRefusal : TargetProfile ->
  TargetInputs ->
  CapabilityManifest ->
  Option Diag
manifestCapabilityRefusal profile analysis manifest =
  let summary = manifest.atoms
  let atoms = filter isGatedAtom summary
  let unjoined = filter (unjoinedIo profile) summary
  let ioLabels = match unjoined
    [] => []
    _ => ["IO"]
  match (manifestAllowed
    analysis.tiOutputs.doEffectDomains
    { manifest | atoms = atoms }
    (profileGrants profile))
    PolicyAdmitted => match unjoined
      [] => None
      _ => Some (refusalDiag profile analysis unjoined ioLabels [])
    PolicyRefused labels lines =>
      Some
        (refusalDiag
          profile
          analysis
          (atoms ++ unjoined)
          (dedup labels ++ ioLabels)
          lines)

-- ── the binding rule ────────────────────────────────────────────────────────
-- Every user extern of every module that the program reaches (`dce`'s reach,
-- over the whole program the drive read, each reference resolved to the
-- declaration it denotes) and that has no binding for the profile's host.  A
-- catalog extern declared again runs the built-in, so it is not judged here.
-- A program declaring no user extern skips the reach.
bindingRefusals : TargetProfile ->
  List (String, String) ->
  TargetInputs ->
  List Diag
bindingRefusals profile paths analysis =
  let builtins = map (ed => ed.edName) (externDecls analysis.tiRuntime)
  let userExterns =
    flatMap
      ((mid, decls) =>
        map
          (ed => (mid, ed))
          (filter
            (ed => not (contains ed.edName builtins))
            (externDecls decls)))
      analysis.tiModules
  match userExterns
    [] => []
    _ =>
      let chains = reachedExternChains None analysis.tiCore analysis.tiModules
      filterMap (unboundReached profile paths chains) userExterns

externDecls : List Decl -> List ExternDecl
externDecls [] = []
externDecls ((DAttrib _ d) :: rest) = externDecls (d :: rest)
externDecls ((DExtern ed) :: rest) = ed :: externDecls rest
externDecls (_ :: rest) = externDecls rest

-- The refusal of a declaration of the module `mid` that is reached and not
-- bound for the profile's host, located in the module's file.
unboundReached : TargetProfile ->
  List (String, String) ->
  List ((String, String), List String) ->
  (String, ExternDecl) ->
  Option Diag
unboundReached profile paths chains (mid, ed) =
  match lookup (mid, ed.edName) chains
    None => None
    Some chain =>
      let bound = match profileBindingHost profile
        Some h => anyList (b => b.ebHost == h) (externBindings ed)
        None => False
      if bound then
        None
      else
        Some (noBindingDiag profile (lookupAssoc mid paths) (ed, chain))

noBindingDiag : TargetProfile ->
  Option String ->
  (ExternDecl, List String) ->
  Diag
noBindingDiag profile path (ed, chain) =
  let hosts = joinWith ", " (map (b => "`\{b.ebHost}`") (externBindings ed))
  let target = profileName profile
  let why = match profileBindingHost profile
    Some h =>
      "has no binding for the host `\{h}`, which the target `\{target}` calls foreign code through (it binds \{hosts}); add a `bind \{h}` clause or build for a target whose host it binds"
    None =>
      "the target `\{target}` calls foreign code through no host (it binds \{hosts}); build for a target whose host it binds"
  mkDiag
    SevError
    targetNoBindingCode
    "the extern `\{ed.edName}` is reached\{reachRoute chain}, and \{why}"
    (Some (inFile path ed.edLoc))

-- ── the built-in rule ───────────────────────────────────────────────────────
-- Every built-in the program reaches whose catalog row gives the profile's
-- column (`profileColumn`) no lowering, one diagnostic per built-in.  A
-- built-in is an extern of `stdlib/runtime.mdk`, which every module sees
-- without an import, or a module's declaration of one again, which runs it.
-- The reach is the binding rule's, with the runtime as a module of its own,
-- so a local binder spelled like a built-in reaches nothing.  An emitter's
-- column is judged over what the emitter lowers, every impl among it; the
-- interpreter's over what it evaluates, an impl only once a reached call can
-- dispatch to it (`reachRootsOf`).  `stdlib/core.mdk` names no built-in that
-- any column leaves unprovided (`core_validate_test`), so a program none of
-- whose modules names one skips the reach.
builtinRefusals : TargetProfile ->
  List (String, String) ->
  TargetInputs ->
  List Diag
builtinRefusals profile paths analysis =
  let column = profileColumn profile
  let named =
    anyList
      ((_, decls) =>
        anyList (d => anyList (isUnprovidedOn column) (declRefs d)) decls)
      analysis.tiModules
  if named then
    let routes =
      reachedExternRoutes
        (reachRootsOf column)
        (Some (runtimeUnit, analysis.tiRuntime))
        analysis.tiCore
        analysis.tiModules
    filterMap
      (unprovidedReached profile paths analysis)
      (dedupBy (r => snd (fst r)) routes)
  else
    []

-- What a column's reach starts from: what its programs run.
reachRootsOf : Backend -> ReachRoots
reachRootsOf LlvmBackend = EmittedRoots
reachRootsOf WasmBackend = EmittedRoots
reachRootsOf EvalBackend = DispatchedRoots

-- The module id the runtime's declarations are scoped under in the reach.  No
-- import path spells it, so a user module named `runtime` keeps its own names
-- apart from the built-ins.
runtimeUnit : String
runtimeUnit = "<runtime>"

unprovidedReached : TargetProfile ->
  List (String, String) ->
  TargetInputs ->
  ((String, String), List (String, String)) ->
  Option Diag
unprovidedReached profile paths analysis ((_, name), route) =
  let column = profileColumn profile
  map
    ((kind, why) =>
      mkDiag
        SevError
        targetNotProvidedCode
        "the built-in `\{name}` is reached\{reachRoute (map snd route)}, and the target `\{profileName profile}` does not provide it (\{gapKindName kind}: \{why}): \{gapCause kind}\{gapAdvice profile column kind name}"
        (namingBindingLoc paths analysis route))
    (unprovidedOn column name)

-- Whether the program or the compiler is at fault, by the row's gap kind.
gapCause : GapKind -> String
gapCause GapPermanent = "the target cannot provide it, by design"
gapCause GapBug = "this is a gap in the compiler, not in the program"
gapCause GapTodo = "no backend provides it yet"
gapCause GapDead = "no backend lowers it"
gapCause GapUnported = "its lowering for this backend is not written yet"

-- What the user can do instead, when a target `medaka build` emits for
-- provides the built-in.  The interpreter judges `medaka run` whatever its
-- target, so its advice is to build.  An emitter's is to choose another
-- target, except for a gap the compiler owes (`GapBug`), which no choice of
-- target remedies.
gapAdvice : TargetProfile -> Backend -> GapKind -> String -> String
gapAdvice profile EvalBackend _ name = runAdvice profile name
gapAdvice _ _ GapBug _ = ""
gapAdvice _ _ _ name =
  if emitterProvides name then "; choose a target that provides it" else ""

runAdvice : TargetProfile -> String -> String
runAdvice profile name =
  if emitterProvides name then match runTargetOf profile
    Some t =>
      if isUnprovidedOn (profileColumn t) name then
        runBuildAdvice
      else
        "; `medaka run` evaluates the program with the interpreter whatever its target, so `medaka build --target \{profileName t}` runs it on `\{profileName t}`"
    None => runBuildAdvice
  else
    ""

runBuildAdvice : String
runBuildAdvice =
  "; `medaka run` evaluates the program with the interpreter, so build it for a target that provides it"

emitterProvides : String -> Bool
emitterProvides name =
  not (isUnprovidedOn LlvmBackend name && isUnprovidedOn WasmBackend name)

-- The target `t` of `medaka run --target t` when `profile` is the
-- interpreter's profile narrowed to it (`runProfile`).
runTargetOf : TargetProfile -> Option TargetProfile
runTargetOf profile =
  match filter (narrowsTo profile) (filterMap profileNamed profileNames)
    t :: _ => Some t
    [] => None

narrowsTo : TargetProfile -> TargetProfile -> Bool
narrowsTo profile t =
  buildable t && profileName (runProfile (Some t)) == profileName profile

profileNamed : String -> Option TargetProfile
profileNamed n = match lookupProfile n
  Ok p => Some p
  Err _ => None

-- The definition of the last binding on the route before the built-in, in
-- its module's file; the entry's when the route has no such binding.
namingBindingLoc : List (String, String) ->
  TargetInputs ->
  List (String, String) ->
  Option Loc
namingBindingLoc paths analysis route =
  match bindingDefinitionLoc paths analysis route
    Some l => Some l
    None => entryLoc analysis.tiEntryDecls

bindingDefinitionLoc : List (String, String) ->
  TargetInputs ->
  List (String, String) ->
  Option Loc
bindingDefinitionLoc paths analysis route = do
  (mid, n) <- lastBindingStep route
  decls <- lookup mid analysis.tiModules
  l <- definitionLoc n decls
  Some (inFile (lookupAssoc mid paths) l)

lastBindingStep : List (String, String) -> Option (String, String)
lastBindingStep [step, _] = Some step
lastBindingStep (_ :: rest) = lastBindingStep rest
lastBindingStep [] = None

definitionLoc : String -> List Decl -> Option Loc
definitionLoc _ [] = None
definitionLoc n ((DAttrib _ d) :: rest) = definitionLoc n (d :: rest)
definitionLoc n ((DFunDef _ m _ _ l _) :: rest) =
  if m == n then Some l else definitionLoc n rest
definitionLoc n ((DLetGroup _ binds) :: rest) =
  match filter (b => letBindName b == n) binds
    (LetBind _ _ l _) :: _ => Some l
    [] => definitionLoc n rest
definitionLoc n (_ :: rest) = definitionLoc n rest

-- How a reached name is reached: from `main`, or from a body the program
-- emits whatever `main` calls.
reachRoute : List String -> String
reachRoute [_] =
  " from an impl method, interface default or top-level let group"
reachRoute ("main" :: rest) = " via `\{joinWith " → " ("main" :: rest)}`"
reachRoute chain =
  " from an impl method, interface default or top-level let group, via `\{joinWith " → " chain}`"

inFile : Option String -> Loc -> Loc
inFile (Some f) (Loc _ sl sc el ec) = Loc f sl sc el ec
inFile None l = l

-- A label a user module declares is never a host capability, whatever it is
-- spelled: only a builtin host label or `FFI` is gated.  An `IO` atom is left
-- to the typechecker: `check`, `run` and `build` select the profile before
-- they typecheck, and the typechecker bounds every `IO` by that profile's join
-- (`ioJoinGrants`).  `unjoinedIo` is the one exception.
isGatedAtom : FrozenAtom -> Bool
isGatedAtom a = match a.origin
  OriginModule _ => False
  _ => isGatedLabel a.label

-- The one `IO` the typechecker cannot refuse: an `IO` performed under an `IO`
-- bound, on a profile whose join is empty.  Nothing performed as `IO` runs
-- there.
unjoinedIo : TargetProfile -> FrozenAtom -> Bool
unjoinedIo profile a = match a.origin
  OriginModule _ => False
  _ => a.label == "IO" && not (reachesLabel profile "IO")

refusalDiag : TargetProfile ->
  TargetInputs ->
  List FrozenAtom ->
  List String ->
  List String ->
  Diag
refusalDiag profile analysis atoms labels lines =
  let chain =
    viaChain
      (buildCallGraph analysis.tiEntryDecls)
      (fnEffectsTable analysis.tiSchemes)
      "main"
      (firstOr "" labels)
  let refused = filter (a => contains a.label labels) atoms
  let route = match chain
    _ :: _ :: _ => " via `\{joinWith " → " chain}`"
    _ => ""
  let notProven = stringConcat (map (l => "; " ++ trim l) lines)
  let printed = match analysis.tiAutoPrintCall
    Some _ =>
      "; `main` is a value other than `Unit`, so it is printed with `println`"
    None => ""
  mkDiag
    SevError
    targetCapabilityCode
    "`main` performs <\{joinWith ", " (map frozenAtomText refused)}>\{route}, and the target `\{profileName profile}` does not grant \{joinWith ", " (map withheldName labels)}\{notProven}\{printed}"
    (entryLoc analysis.tiEntryDecls)

-- `IO` is refused only when the profile grants no host label for it to join.
withheldName : String -> String
withheldName "IO" = "any host label for `IO` to join"
withheldName label = label

missingEntryDiag : TargetProfile -> String -> Diag
missingEntryDiag profile file =
  mkDiag
    SevError
    targetCapabilityCode
    "no `main` entry found, so there is nothing to check against the target `\{profileName profile}`; add `main = ...`"
    (Some (Loc file 1 0 1 0))

-- Where the entry is declared: its signature, which is where its row is
-- written, else its definition.
entryLoc : List Decl -> Option Loc
entryLoc decls = match mainSigLoc decls
  Some l => Some l
  None => mainDefLoc decls

mainSigLoc : List Decl -> Option Loc
mainSigLoc [] = None
mainSigLoc ((DAttrib _ d) :: rest) = mainSigLoc (d :: rest)
mainSigLoc ((DTypeSig _ "main" _ l) :: _) = Some l
mainSigLoc (_ :: rest) = mainSigLoc rest

mainDefLoc : List Decl -> Option Loc
mainDefLoc [] = None
mainDefLoc ((DAttrib _ d) :: rest) = mainDefLoc (d :: rest)
mainDefLoc ((DFunDef _ "main" _ _ l _) :: _) = Some l
mainDefLoc (_ :: rest) = mainDefLoc rest

firstOr : String -> List String -> String
firstOr d [] = d
firstOr _ (x :: _) = x
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" true) (mem "ManifestRequest" true) (mem "ManifestLookup" true) (mem "InvocationProtocol" true) (mem "FrozenAtom" true) (mem "lookupManifest" false))))
(DUse false (UseGroup ("types" "capability_policy") ((mem "manifestAllowed" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "mainEntryKey" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "frozenAtomText" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "profileColumn" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "LetBind" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "externBindings" false) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "unprovidedOn" false) (mem "isUnprovidedOn" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "GapKind" true) (mem "gapKindName" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "buildable" false) (mem "lookupProfile" false) (mem "profileName" false) (mem "profileNames" false) (mem "profileGrants" false) (mem "profileBindingHost" false) (mem "isGatedLabel" false) (mem "reachesLabel" false) (mem "runProfile" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "ReachRoots" true) (mem "reachedExternChains" false) (mem "reachedExternRoutes" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "TargetInputs" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false) (mem "cjFoldIntoFile" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "dedupBy" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "DiagCode"))
(DFunDef false "targetCapabilityCode" () (EVar "TTargetCapability"))
(DTypeSig true "targetNoBindingCode" (TyCon "DiagCode"))
(DFunDef false "targetNoBindingCode" () (EVar "TTargetNoBinding"))
(DTypeSig true "targetNotProvidedCode" (TyCon "DiagCode"))
(DFunDef false "targetNotProvidedCode" () (EVar "TTargetNotProvided"))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "paths") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "tiSchemes")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EApp (EVar "bindingRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "capabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "sch")) (arm (PCon "Some" (PVar "d")) () (EMatch (EVar "bound") (arm (PList) () (EListLit (EVar "d"))) (arm (PVar "ds") () (EVar "ds")))) (arm (PCon "None") () (EBinOp "++" (EVar "bound") (EApp (EApp (EApp (EVar "builtinRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis"))))))))))
(DTypeSig true "targetDiagFile" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "targetDiagFile" ((PVar "entry") (PCon "Diag" PWild PWild PWild (PCon "Some" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) PWild PWild)) (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "entry") (EVar "f")))
(DFunDef false "targetDiagFile" ((PVar "entry") PWild) (EVar "entry"))
(DTypeSig true "ppTargetDiag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "ppTargetDiag" ((PVar "entry") (PVar "entrySrc") (PVar "d")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "d")))))
(DTypeSig true "foldTargetDiags" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "foldTargetDiags" (PWild PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "foldTargetDiags" ((PVar "entry") (PVar "entrySrc") (PCons (PVar "d") (PVar "ds")) (PVar "triples")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "folded") (EIf (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "file")))) (EVar "triples")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "file")) (EListLit (EVar "d"))) (EVar "triples")) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (EVar "src") (EListLit (EVar "d"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EVar "entrySrc")) (EVar "ds")) (EVar "folded")))))
(DTypeSig false "capabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "capabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "sch")) (EBlock (DoLet false false (PVar "request") (ERecordCreate "ManifestRequest" ((fa "entry" (EApp (EVar "mainEntryKey") (EFieldAccess (EVar "analysis") "tiModules"))) (fa "protocol" (EVar "ExecutedMain"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupManifest") (EVar "request")) (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doManifestRequests")) (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doManifests")) (arm (PCon "Published" (PVar "manifest")) () (EApp (EApp (EApp (EVar "manifestCapabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "manifest"))) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (ELit (LString "missing checked ExecutedMain manifest"))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls")))))))))
(DTypeSig false "manifestCapabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "CapabilityManifest") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "manifestCapabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "manifest")) (EBlock (DoLet false false (PVar "summary") (EFieldAccess (EVar "manifest") "atoms")) (DoLet false false (PVar "atoms") (EApp (EApp (EVar "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EVar "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "manifestAllowed") (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doEffectDomains")) (ERecordUpdate (EVar "manifest") ((fa "atoms" (EVar "atoms"))))) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))
(DTypeSig false "bindingRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "bindingRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "builtins") (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (EFieldAccess (EVar "ed") "edName"))) (EApp (EVar "externDecls") (EFieldAccess (EVar "analysis") "tiRuntime")))) (DoLet false false (PVar "userExterns") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (ETuple (EVar "mid") (EVar "ed")))) (EApp (EApp (EVar "filter") (ELam ((PVar "ed")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "ed") "edName")) (EVar "builtins"))))) (EApp (EVar "externDecls") (EVar "decls")))))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EMatch (EVar "userExterns") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "chains") (EApp (EApp (EApp (EVar "reachedExternChains") (EVar "None")) (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "unboundReached") (EVar "profile")) (EVar "paths")) (EVar "chains"))) (EVar "userExterns")))))))))
(DTypeSig false "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDecls") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
(DTypeSig false "unboundReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "ExternDecl")) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unboundReached" ((PVar "profile") (PVar "paths") (PVar "chains") (PTuple (PVar "mid") (PVar "ed"))) (EMatch (EApp (EApp (EVar "lookup") (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName"))) (EVar "chains")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "chain")) () (EBlock (DoLet false false (PVar "bound") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "ed")))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "bound") (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "noBindingDiag") (EVar "profile")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (ETuple (EVar "ed") (EVar "chain"))))))))))
(DTypeSig false "noBindingDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Diag")))))
(DFunDef false "noBindingDiag" ((PVar "profile") (PVar "path") (PTuple (PVar "ed") (PVar "chain"))) (EBlock (DoLet false false (PVar "hosts") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EFieldAccess (EVar "b") "ebHost"))) (ELit (LString "`"))))) (EApp (EVar "externBindings") (EVar "ed"))))) (DoLet false false (PVar "target") (EApp (EVar "profileName") (EVar "profile"))) (DoLet false false (PVar "why") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "has no binding for the host `")) (EApp (EVar "display") (EVar "h"))) (ELit (LString "`, which the target `"))) (EApp (EVar "display") (EVar "target"))) (ELit (LString "` calls foreign code through (it binds "))) (EApp (EVar "display") (EVar "hosts"))) (ELit (LString "); add a `bind "))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` clause or build for a target whose host it binds")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the target `")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "` calls foreign code through no host (it binds "))) (EApp (EVar "display") (EVar "hosts"))) (ELit (LString "); build for a target whose host it binds")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNoBindingCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the extern `")) (EApp (EVar "display") (EFieldAccess (EVar "ed") "edName"))) (ELit (LString "` is reached"))) (EApp (EVar "display") (EApp (EVar "reachRoute") (EVar "chain")))) (ELit (LString ", and "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EVar "path")) (EFieldAccess (EVar "ed") "edLoc")))))))
(DTypeSig false "builtinRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "builtinRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "column") (EApp (EVar "profileColumn") (EVar "profile"))) (DoLet false false (PVar "named") (EApp (EApp (EVar "anyList") (ELam ((PTuple PWild (PVar "decls"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "d")) (EApp (EApp (EVar "anyList") (EApp (EVar "isUnprovidedOn") (EVar "column"))) (EApp (EVar "declRefs") (EVar "d"))))) (EVar "decls")))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EIf (EVar "named") (EBlock (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EVar "reachedExternRoutes") (EApp (EVar "reachRootsOf") (EVar "column"))) (EApp (EVar "Some") (ETuple (EVar "runtimeUnit") (EFieldAccess (EVar "analysis") "tiRuntime")))) (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "unprovidedReached") (EVar "profile")) (EVar "paths")) (EVar "analysis"))) (EApp (EApp (EVar "dedupBy") (ELam ((PVar "r")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "r"))))) (EVar "routes"))))) (EListLit)))))
(DTypeSig false "reachRootsOf" (TyFun (TyCon "Backend") (TyCon "ReachRoots")))
(DFunDef false "reachRootsOf" ((PCon "LlvmBackend")) (EVar "EmittedRoots"))
(DFunDef false "reachRootsOf" ((PCon "WasmBackend")) (EVar "EmittedRoots"))
(DFunDef false "reachRootsOf" ((PCon "EvalBackend")) (EVar "DispatchedRoots"))
(DTypeSig false "runtimeUnit" (TyCon "String"))
(DFunDef false "runtimeUnit" () (ELit (LString "<runtime>")))
(DTypeSig false "unprovidedReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unprovidedReached" ((PVar "profile") (PVar "paths") (PVar "analysis") (PTuple (PTuple PWild (PVar "name")) (PVar "route"))) (EBlock (DoLet false false (PVar "column") (EApp (EVar "profileColumn") (EVar "profile"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "kind") (PVar "why"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNotProvidedCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the built-in `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is reached"))) (EApp (EVar "display") (EApp (EVar "reachRoute") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "route"))))) (ELit (LString ", and the target `"))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not provide it ("))) (EApp (EVar "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString "): "))) (EApp (EVar "display") (EApp (EVar "gapCause") (EVar "kind")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "gapAdvice") (EVar "profile")) (EVar "column")) (EVar "kind")) (EVar "name")))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "namingBindingLoc") (EVar "paths")) (EVar "analysis")) (EVar "route"))))) (EApp (EApp (EVar "unprovidedOn") (EVar "column")) (EVar "name"))))))
(DTypeSig false "gapCause" (TyFun (TyCon "GapKind") (TyCon "String")))
(DFunDef false "gapCause" ((PCon "GapPermanent")) (ELit (LString "the target cannot provide it, by design")))
(DFunDef false "gapCause" ((PCon "GapBug")) (ELit (LString "this is a gap in the compiler, not in the program")))
(DFunDef false "gapCause" ((PCon "GapTodo")) (ELit (LString "no backend provides it yet")))
(DFunDef false "gapCause" ((PCon "GapDead")) (ELit (LString "no backend lowers it")))
(DFunDef false "gapCause" ((PCon "GapUnported")) (ELit (LString "its lowering for this backend is not written yet")))
(DTypeSig false "gapAdvice" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Backend") (TyFun (TyCon "GapKind") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "gapAdvice" ((PVar "profile") (PCon "EvalBackend") PWild (PVar "name")) (EApp (EApp (EVar "runAdvice") (EVar "profile")) (EVar "name")))
(DFunDef false "gapAdvice" (PWild PWild (PCon "GapBug") PWild) (ELit (LString "")))
(DFunDef false "gapAdvice" (PWild PWild PWild (PVar "name")) (EIf (EApp (EVar "emitterProvides") (EVar "name")) (ELit (LString "; choose a target that provides it")) (ELit (LString ""))))
(DTypeSig false "runAdvice" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "runAdvice" ((PVar "profile") (PVar "name")) (EIf (EApp (EVar "emitterProvides") (EVar "name")) (EMatch (EApp (EVar "runTargetOf") (EVar "profile")) (arm (PCon "Some" (PVar "t")) () (EIf (EApp (EApp (EVar "isUnprovidedOn") (EApp (EVar "profileColumn") (EVar "t"))) (EVar "name")) (EVar "runBuildAdvice") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; `medaka run` evaluates the program with the interpreter whatever its target, so `medaka build --target ")) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "t")))) (ELit (LString "` runs it on `"))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "t")))) (ELit (LString "`"))))) (arm (PCon "None") () (EVar "runBuildAdvice"))) (ELit (LString ""))))
(DTypeSig false "runBuildAdvice" (TyCon "String"))
(DFunDef false "runBuildAdvice" () (ELit (LString "; `medaka run` evaluates the program with the interpreter, so build it for a target that provides it")))
(DTypeSig false "emitterProvides" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "emitterProvides" ((PVar "name")) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "isUnprovidedOn") (EVar "LlvmBackend")) (EVar "name")) (EApp (EApp (EVar "isUnprovidedOn") (EVar "WasmBackend")) (EVar "name")))))
(DTypeSig false "runTargetOf" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "runTargetOf" ((PVar "profile")) (EMatch (EApp (EApp (EVar "filter") (EApp (EVar "narrowsTo") (EVar "profile"))) (EApp (EApp (EVar "filterMap") (EVar "profileNamed")) (EVar "profileNames"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig false "narrowsTo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetProfile") (TyCon "Bool"))))
(DFunDef false "narrowsTo" ((PVar "profile") (PVar "t")) (EBinOp "&&" (EApp (EVar "buildable") (EVar "t")) (EBinOp "==" (EApp (EVar "profileName") (EApp (EVar "runProfile") (EApp (EVar "Some") (EVar "t")))) (EApp (EVar "profileName") (EVar "profile")))))
(DTypeSig false "profileNamed" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "profileNamed" ((PVar "n")) (EMatch (EApp (EVar "lookupProfile") (EVar "n")) (arm (PCon "Ok" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DTypeSig false "namingBindingLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "namingBindingLoc" ((PVar "paths") (PVar "analysis") (PVar "route")) (EMatch (EApp (EApp (EApp (EVar "bindingDefinitionLoc") (EVar "paths")) (EVar "analysis")) (EVar "route")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls")))))
(DTypeSig false "bindingDefinitionLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "bindingDefinitionLoc" ((PVar "paths") (PVar "analysis") (PVar "route")) (EApp (EApp (EVar "andThen") (EApp (EVar "lastBindingStep") (EVar "route"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "mid") (PVar "n")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "lookup") (EVar "mid")) (EFieldAccess (EVar "analysis") "tiModules"))) (ELam ((PVar "decls")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "decls"))) (ELam ((PVar "l")) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (EVar "l"))))))))))))
(DTypeSig false "lastBindingStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "lastBindingStep" ((PList (PVar "step") PWild)) (EApp (EVar "Some") (EVar "step")))
(DFunDef false "lastBindingStep" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastBindingStep") (EVar "rest")))
(DFunDef false "lastBindingStep" ((PList)) (EVar "None"))
(DTypeSig false "definitionLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "definitionLoc" (PWild (PList)) (EVar "None"))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild (PVar "l") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "l")) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest"))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "letBindName") (EVar "b")) (EVar "n")))) (EVar "binds")) (arm (PCons (PCon "LetBind" PWild PWild (PVar "l") PWild) PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest")))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest")))
(DTypeSig false "reachRoute" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "reachRoute" ((PList PWild)) (ELit (LString " from an impl method, interface default or top-level let group")))
(DFunDef false "reachRoute" ((PCons (PLit (LString "main")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EBinOp "::" (ELit (LString "main")) (EVar "rest"))))) (ELit (LString "`"))))
(DFunDef false "reachRoute" ((PVar "chain")) (EBinOp "++" (EBinOp "++" (ELit (LString " from an impl method, interface default or top-level let group, via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`"))))
(DTypeSig false "inFile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "inFile" ((PCon "Some" (PVar "f")) (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DFunDef false "inFile" ((PCon "None") (PVar "l")) (EVar "l"))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "FrozenAtom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "origin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EFieldAccess (EVar "a") "label")))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "FrozenAtom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "origin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "label") (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyCon "FrozenAtom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "tiEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "tiSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EVar "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "a") "label")) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "frozenAtomText")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EVar "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls"))))))
(DTypeSig false "withheldName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "withheldName" ((PLit (LString "IO"))) (ELit (LString "any host label for `IO` to join")))
(DFunDef false "withheldName" ((PVar "label")) (EVar "label"))
(DTypeSig false "missingEntryDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Diag"))))
(DFunDef false "missingEntryDiag" ((PVar "profile") (PVar "file")) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (ELit (LString "no `main` entry found, so there is nothing to check against the target `")) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "`; add `main = ...`")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))))
(DTypeSig false "entryLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "entryLoc" ((PVar "decls")) (EMatch (EApp (EVar "mainSigLoc") (EVar "decls")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "mainDefLoc") (EVar "decls")))))
(DTypeSig false "mainSigLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainSigLoc" ((PList)) (EVar "None"))
(DFunDef false "mainSigLoc" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainSigLoc") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainSigLoc" ((PCons (PCon "DTypeSig" PWild (PLit (LString "main")) PWild (PVar "l")) PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainSigLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainSigLoc") (EVar "rest")))
(DTypeSig false "mainDefLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainDefLoc" ((PList)) (EVar "None"))
(DFunDef false "mainDefLoc" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainDefLoc") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainDefLoc" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild (PVar "l") PWild) PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainDefLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainDefLoc") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" true) (mem "ManifestRequest" true) (mem "ManifestLookup" true) (mem "InvocationProtocol" true) (mem "FrozenAtom" true) (mem "lookupManifest" false))))
(DUse false (UseGroup ("types" "capability_policy") ((mem "manifestAllowed" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "mainEntryKey" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "frozenAtomText" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "profileColumn" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "LetBind" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "externBindings" false) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "unprovidedOn" false) (mem "isUnprovidedOn" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "GapKind" true) (mem "gapKindName" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "buildable" false) (mem "lookupProfile" false) (mem "profileName" false) (mem "profileNames" false) (mem "profileGrants" false) (mem "profileBindingHost" false) (mem "isGatedLabel" false) (mem "reachesLabel" false) (mem "runProfile" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "ReachRoots" true) (mem "reachedExternChains" false) (mem "reachedExternRoutes" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "TargetInputs" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false) (mem "cjFoldIntoFile" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "dedupBy" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "DiagCode"))
(DFunDef false "targetCapabilityCode" () (EVar "TTargetCapability"))
(DTypeSig true "targetNoBindingCode" (TyCon "DiagCode"))
(DFunDef false "targetNoBindingCode" () (EVar "TTargetNoBinding"))
(DTypeSig true "targetNotProvidedCode" (TyCon "DiagCode"))
(DFunDef false "targetNotProvidedCode" () (EVar "TTargetNotProvided"))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "paths") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "tiSchemes")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EApp (EVar "bindingRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "capabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "sch")) (arm (PCon "Some" (PVar "d")) () (EMatch (EVar "bound") (arm (PList) () (EListLit (EVar "d"))) (arm (PVar "ds") () (EVar "ds")))) (arm (PCon "None") () (EBinOp "++" (EVar "bound") (EApp (EApp (EApp (EVar "builtinRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis"))))))))))
(DTypeSig true "targetDiagFile" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "targetDiagFile" ((PVar "entry") (PCon "Diag" PWild PWild PWild (PCon "Some" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) PWild PWild)) (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "entry") (EVar "f")))
(DFunDef false "targetDiagFile" ((PVar "entry") PWild) (EVar "entry"))
(DTypeSig true "ppTargetDiag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "ppTargetDiag" ((PVar "entry") (PVar "entrySrc") (PVar "d")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "d")))))
(DTypeSig true "foldTargetDiags" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "foldTargetDiags" (PWild PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "foldTargetDiags" ((PVar "entry") (PVar "entrySrc") (PCons (PVar "d") (PVar "ds")) (PVar "triples")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "folded") (EIf (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "file")))) (EVar "triples")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "file")) (EListLit (EVar "d"))) (EVar "triples")) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (EVar "src") (EListLit (EVar "d"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EVar "entrySrc")) (EVar "ds")) (EVar "folded")))))
(DTypeSig false "capabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "capabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "sch")) (EBlock (DoLet false false (PVar "request") (ERecordCreate "ManifestRequest" ((fa "entry" (EApp (EVar "mainEntryKey") (EFieldAccess (EVar "analysis") "tiModules"))) (fa "protocol" (EVar "ExecutedMain"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupManifest") (EVar "request")) (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doManifestRequests")) (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doManifests")) (arm (PCon "Published" (PVar "manifest")) () (EApp (EApp (EApp (EVar "manifestCapabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "manifest"))) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (ELit (LString "missing checked ExecutedMain manifest"))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls")))))))))
(DTypeSig false "manifestCapabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "CapabilityManifest") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "manifestCapabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "manifest")) (EBlock (DoLet false false (PVar "summary") (EFieldAccess (EVar "manifest") "atoms")) (DoLet false false (PVar "atoms") (EApp (EApp (EMethodRef "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EMethodRef "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "manifestAllowed") (EFieldAccess (EFieldAccess (EVar "analysis") "tiOutputs") "doEffectDomains")) (ERecordUpdate (EVar "manifest") ((fa "atoms" (EVar "atoms"))))) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))
(DTypeSig false "bindingRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "bindingRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "builtins") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (EFieldAccess (EVar "ed") "edName"))) (EApp (EVar "externDecls") (EFieldAccess (EVar "analysis") "tiRuntime")))) (DoLet false false (PVar "userExterns") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (ETuple (EVar "mid") (EVar "ed")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "ed")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "ed") "edName")) (EVar "builtins"))))) (EApp (EVar "externDecls") (EVar "decls")))))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EMatch (EVar "userExterns") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "chains") (EApp (EApp (EApp (EVar "reachedExternChains") (EVar "None")) (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "unboundReached") (EVar "profile")) (EVar "paths")) (EVar "chains"))) (EVar "userExterns")))))))))
(DTypeSig false "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDecls") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
(DTypeSig false "unboundReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "ExternDecl")) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unboundReached" ((PVar "profile") (PVar "paths") (PVar "chains") (PTuple (PVar "mid") (PVar "ed"))) (EMatch (EApp (EApp (EVar "lookup") (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName"))) (EVar "chains")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "chain")) () (EBlock (DoLet false false (PVar "bound") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "ed")))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "bound") (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "noBindingDiag") (EVar "profile")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (ETuple (EVar "ed") (EVar "chain"))))))))))
(DTypeSig false "noBindingDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Diag")))))
(DFunDef false "noBindingDiag" ((PVar "profile") (PVar "path") (PTuple (PVar "ed") (PVar "chain"))) (EBlock (DoLet false false (PVar "hosts") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "ebHost"))) (ELit (LString "`"))))) (EApp (EVar "externBindings") (EVar "ed"))))) (DoLet false false (PVar "target") (EApp (EVar "profileName") (EVar "profile"))) (DoLet false false (PVar "why") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "has no binding for the host `")) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "`, which the target `"))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "` calls foreign code through (it binds "))) (EApp (EMethodRef "display") (EVar "hosts"))) (ELit (LString "); add a `bind "))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` clause or build for a target whose host it binds")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the target `")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "` calls foreign code through no host (it binds "))) (EApp (EMethodRef "display") (EVar "hosts"))) (ELit (LString "); build for a target whose host it binds")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNoBindingCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the extern `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "ed") "edName"))) (ELit (LString "` is reached"))) (EApp (EMethodRef "display") (EApp (EVar "reachRoute") (EVar "chain")))) (ELit (LString ", and "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EVar "path")) (EFieldAccess (EVar "ed") "edLoc")))))))
(DTypeSig false "builtinRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "builtinRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "column") (EApp (EVar "profileColumn") (EVar "profile"))) (DoLet false false (PVar "named") (EApp (EApp (EVar "anyList") (ELam ((PTuple PWild (PVar "decls"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "d")) (EApp (EApp (EVar "anyList") (EApp (EVar "isUnprovidedOn") (EVar "column"))) (EApp (EVar "declRefs") (EVar "d"))))) (EVar "decls")))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EIf (EVar "named") (EBlock (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EVar "reachedExternRoutes") (EApp (EVar "reachRootsOf") (EVar "column"))) (EApp (EVar "Some") (ETuple (EVar "runtimeUnit") (EFieldAccess (EVar "analysis") "tiRuntime")))) (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "unprovidedReached") (EVar "profile")) (EVar "paths")) (EVar "analysis"))) (EApp (EApp (EVar "dedupBy") (ELam ((PVar "r")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "r"))))) (EVar "routes"))))) (EListLit)))))
(DTypeSig false "reachRootsOf" (TyFun (TyCon "Backend") (TyCon "ReachRoots")))
(DFunDef false "reachRootsOf" ((PCon "LlvmBackend")) (EVar "EmittedRoots"))
(DFunDef false "reachRootsOf" ((PCon "WasmBackend")) (EVar "EmittedRoots"))
(DFunDef false "reachRootsOf" ((PCon "EvalBackend")) (EVar "DispatchedRoots"))
(DTypeSig false "runtimeUnit" (TyCon "String"))
(DFunDef false "runtimeUnit" () (ELit (LString "<runtime>")))
(DTypeSig false "unprovidedReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unprovidedReached" ((PVar "profile") (PVar "paths") (PVar "analysis") (PTuple (PTuple PWild (PVar "name")) (PVar "route"))) (EBlock (DoLet false false (PVar "column") (EApp (EVar "profileColumn") (EVar "profile"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "kind") (PVar "why"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNotProvidedCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the built-in `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is reached"))) (EApp (EMethodRef "display") (EApp (EVar "reachRoute") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "route"))))) (ELit (LString ", and the target `"))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not provide it ("))) (EApp (EMethodRef "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EApp (EVar "gapCause") (EVar "kind")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "gapAdvice") (EVar "profile")) (EVar "column")) (EVar "kind")) (EVar "name")))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "namingBindingLoc") (EVar "paths")) (EVar "analysis")) (EVar "route"))))) (EApp (EApp (EVar "unprovidedOn") (EVar "column")) (EVar "name"))))))
(DTypeSig false "gapCause" (TyFun (TyCon "GapKind") (TyCon "String")))
(DFunDef false "gapCause" ((PCon "GapPermanent")) (ELit (LString "the target cannot provide it, by design")))
(DFunDef false "gapCause" ((PCon "GapBug")) (ELit (LString "this is a gap in the compiler, not in the program")))
(DFunDef false "gapCause" ((PCon "GapTodo")) (ELit (LString "no backend provides it yet")))
(DFunDef false "gapCause" ((PCon "GapDead")) (ELit (LString "no backend lowers it")))
(DFunDef false "gapCause" ((PCon "GapUnported")) (ELit (LString "its lowering for this backend is not written yet")))
(DTypeSig false "gapAdvice" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Backend") (TyFun (TyCon "GapKind") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "gapAdvice" ((PVar "profile") (PCon "EvalBackend") PWild (PVar "name")) (EApp (EApp (EVar "runAdvice") (EVar "profile")) (EVar "name")))
(DFunDef false "gapAdvice" (PWild PWild (PCon "GapBug") PWild) (ELit (LString "")))
(DFunDef false "gapAdvice" (PWild PWild PWild (PVar "name")) (EIf (EApp (EVar "emitterProvides") (EVar "name")) (ELit (LString "; choose a target that provides it")) (ELit (LString ""))))
(DTypeSig false "runAdvice" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "runAdvice" ((PVar "profile") (PVar "name")) (EIf (EApp (EVar "emitterProvides") (EVar "name")) (EMatch (EApp (EVar "runTargetOf") (EVar "profile")) (arm (PCon "Some" (PVar "t")) () (EIf (EApp (EApp (EVar "isUnprovidedOn") (EApp (EVar "profileColumn") (EVar "t"))) (EVar "name")) (EVar "runBuildAdvice") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; `medaka run` evaluates the program with the interpreter whatever its target, so `medaka build --target ")) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "t")))) (ELit (LString "` runs it on `"))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "t")))) (ELit (LString "`"))))) (arm (PCon "None") () (EVar "runBuildAdvice"))) (ELit (LString ""))))
(DTypeSig false "runBuildAdvice" (TyCon "String"))
(DFunDef false "runBuildAdvice" () (ELit (LString "; `medaka run` evaluates the program with the interpreter, so build it for a target that provides it")))
(DTypeSig false "emitterProvides" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "emitterProvides" ((PVar "name")) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "isUnprovidedOn") (EVar "LlvmBackend")) (EVar "name")) (EApp (EApp (EVar "isUnprovidedOn") (EVar "WasmBackend")) (EVar "name")))))
(DTypeSig false "runTargetOf" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "runTargetOf" ((PVar "profile")) (EMatch (EApp (EApp (EMethodRef "filter") (EApp (EVar "narrowsTo") (EVar "profile"))) (EApp (EApp (EMethodRef "filterMap") (EVar "profileNamed")) (EVar "profileNames"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig false "narrowsTo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetProfile") (TyCon "Bool"))))
(DFunDef false "narrowsTo" ((PVar "profile") (PVar "t")) (EBinOp "&&" (EApp (EVar "buildable") (EVar "t")) (EBinOp "==" (EApp (EVar "profileName") (EApp (EVar "runProfile") (EApp (EVar "Some") (EVar "t")))) (EApp (EVar "profileName") (EVar "profile")))))
(DTypeSig false "profileNamed" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "profileNamed" ((PVar "n")) (EMatch (EApp (EVar "lookupProfile") (EVar "n")) (arm (PCon "Ok" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DTypeSig false "namingBindingLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "namingBindingLoc" ((PVar "paths") (PVar "analysis") (PVar "route")) (EMatch (EApp (EApp (EApp (EVar "bindingDefinitionLoc") (EVar "paths")) (EVar "analysis")) (EVar "route")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls")))))
(DTypeSig false "bindingDefinitionLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "bindingDefinitionLoc" ((PVar "paths") (PVar "analysis") (PVar "route")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "lastBindingStep") (EVar "route"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "mid") (PVar "n")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "lookup") (EVar "mid")) (EFieldAccess (EVar "analysis") "tiModules"))) (ELam ((PVar "decls")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "decls"))) (ELam ((PVar "l")) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (EVar "l"))))))))))))
(DTypeSig false "lastBindingStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "lastBindingStep" ((PList (PVar "step") PWild)) (EApp (EVar "Some") (EVar "step")))
(DFunDef false "lastBindingStep" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastBindingStep") (EVar "rest")))
(DFunDef false "lastBindingStep" ((PList)) (EVar "None"))
(DTypeSig false "definitionLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "definitionLoc" (PWild (PList)) (EVar "None"))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild (PVar "l") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "l")) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest"))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EMatch (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "letBindName") (EVar "b")) (EVar "n")))) (EVar "binds")) (arm (PCons (PCon "LetBind" PWild PWild (PVar "l") PWild) PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest")))))
(DFunDef false "definitionLoc" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definitionLoc") (EVar "n")) (EVar "rest")))
(DTypeSig false "reachRoute" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "reachRoute" ((PList PWild)) (ELit (LString " from an impl method, interface default or top-level let group")))
(DFunDef false "reachRoute" ((PCons (PLit (LString "main")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EBinOp "::" (ELit (LString "main")) (EVar "rest"))))) (ELit (LString "`"))))
(DFunDef false "reachRoute" ((PVar "chain")) (EBinOp "++" (EBinOp "++" (ELit (LString " from an impl method, interface default or top-level let group, via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`"))))
(DTypeSig false "inFile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "inFile" ((PCon "Some" (PVar "f")) (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DFunDef false "inFile" ((PCon "None") (PVar "l")) (EVar "l"))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "FrozenAtom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "origin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EFieldAccess (EVar "a") "label")))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "FrozenAtom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "origin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "label") (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyCon "FrozenAtom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "tiEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "tiSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "a") "label")) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "frozenAtomText")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EMethodRef "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls"))))))
(DTypeSig false "withheldName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "withheldName" ((PLit (LString "IO"))) (ELit (LString "any host label for `IO` to join")))
(DFunDef false "withheldName" ((PVar "label")) (EVar "label"))
(DTypeSig false "missingEntryDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Diag"))))
(DFunDef false "missingEntryDiag" ((PVar "profile") (PVar "file")) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (ELit (LString "no `main` entry found, so there is nothing to check against the target `")) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "`; add `main = ...`")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))))
(DTypeSig false "entryLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "entryLoc" ((PVar "decls")) (EMatch (EApp (EVar "mainSigLoc") (EVar "decls")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "mainDefLoc") (EVar "decls")))))
(DTypeSig false "mainSigLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainSigLoc" ((PList)) (EVar "None"))
(DFunDef false "mainSigLoc" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainSigLoc") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainSigLoc" ((PCons (PCon "DTypeSig" PWild (PLit (LString "main")) PWild (PVar "l")) PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainSigLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainSigLoc") (EVar "rest")))
(DTypeSig false "mainDefLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainDefLoc" ((PList)) (EVar "None"))
(DFunDef false "mainDefLoc" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "mainDefLoc") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "mainDefLoc" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild (PVar "l") PWild) PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainDefLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "mainDefLoc") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
