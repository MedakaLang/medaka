# META
source_lines=187
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{
  TabKey, Ns(..), TyConOrigin(..), tabKeyOf, tabKeyEq, lookupTab
}
import types.tc_types.{
  TcEnv(..), ModuleCtx(..), InvocationView(..), PublishedInvocationView(..),
  DriveOutputs(..), Polarity(..), Kind(..)
}
import types.publish.{PubScheme(..), freezePub, zonkScheme, emptyZonk}
import types.repr.{Scheme(..), Mono(..), normalize, spineParts}
import types.effect_authority.{Authority(..), authNorm, authvarId}
import types.effect_invocation.{InvocationOps, Variance(..)}
import types.manifest_publish.{InvocationOwner(..)}
import types.registry.{spRows}
import types.capability_manifest.{
  ManifestSelector(..), EntryKey, InvocationProtocol(..)
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup}
import support.util.{listLen, maxI}
import list.{get, range}
import map as IdMap

export
recordInvocationView : TcEnv -> Unit
recordInvocationView env =
  let universe =
    flatMap
      (cands =>
        map
          (c => match c
            (_, _, sch) => sch)
          cands)
      (IdMap.values
        (spRows env.teDyn.dcModule.mcGraph.crossRun.universeCtorPop.value))
  env.teDyn.dcModule.mcCells.invocationViewRef :=
    InvocationView
      (IdMap.values env.teCtors ++ universe)
      env.teDyn.dcModule.mcCells.dataParamPolarityRef.value
      env.teDyn.dcModule.mcCells.dataParamKindsRef.value

export
frozenInvocationView : InvocationView -> InvocationView
frozenInvocationView (InvocationView ctors pols kinds) =
  InvocationView (map (c => snd (zonkScheme emptyZonk c)) ctors) pols kinds

export
publishInvocationView : InvocationView -> PublishedInvocationView
publishInvocationView (InvocationView ctors pols kinds) =
  PublishedInvocationView (map (c => freezePub c []) ctors) pols kinds

export
readInvocationView : PublishedInvocationView -> InvocationView
readInvocationView (PublishedInvocationView ctors pols kinds) =
  frozenInvocationView (InvocationView (map (c => c.psScheme) ctors) pols kinds)

export
requestedViewModules : List ManifestSelector -> OrdMap Unit
requestedViewModules =
  fold
    (mods selector => match selector
      ExactEntry key _ => omInsert key.moduleId () mods
      EntryOverPrelude _ _ => mods)
    omEmpty

export
requestedWrapperViewModules : List ManifestSelector ->
  Option EntryKey ->
  OrdMap Unit
requestedWrapperViewModules selectors driver =
  let modules = requestedViewModules selectors
  let executed =
    any
      (selector => match selector
        ExactEntry _ ExecutedMain => True
        EntryOverPrelude _ ExecutedMain => True
        _ => False)
      selectors
  if executed then
    option modules (key => omInsert (key : EntryKey).moduleId () modules) driver
  else
    modules

export
invocationResolver : (InvocationView -> InvocationOps) ->
  List (InvocationOwner, InvocationView) ->
  InvocationOwner ->
  Option InvocationOps
invocationResolver makeOps views =
  let index = IdMap.fromList views
  mid => map makeOps (IdMap.get mid index)

-- A slot's variance, read as invariant where its parameter is an effect row
-- or an authority: an index is invariant (EFFECTS-SEMANTICS §6.4), whatever
-- the variance table computed for it.
export
slotVariances : Option (List Polarity) ->
  Option (List Kind) ->
  Option (List Variance)
slotVariances None None = None
slotVariances pols kinds =
  let ps = optionOr [] pols
  let ks = optionOr [] kinds
  Some
    (map
      (i => slotVariance (get i ps) (get i ks))
      (range 0 (maxI (listLen ps) (listLen ks))))

slotVariance : Option Polarity -> Option Kind -> Variance
slotVariance _ (Some KRow) = VInv
slotVariance _ (Some (KAuth _ _)) = VInv
slotVariance (Some p) _ = varianceOf p
slotVariance None _ = VInv

varianceOf : Polarity -> Variance
varianceOf PCo = VCo
varianceOf PContra = VContra
varianceOf PInv = VInv
-- never published (`publishedPolarity`); read as the phantom it means
varianceOf PPhantom = VCo

-- Every constructor under its result head: the head's arguments as the
-- constructor declares them, and its field types.
export
ctorsByHead : (Mono -> String) ->
  List Scheme ->
  OrdMap (List (List Mono, List Mono))
ctorsByHead headKey schemes =
  fold
    (acc sch => match sch
      Forall _ _ _ _ _ mono =>
        let (fieldTys, result) = arrowParts mono
        let (h, params) = spineParts result
        let key = headKey h
        omInsert key ((params, fieldTys) :: optionOr [] (omLookup key acc)) acc)
    omEmpty
    schemes

export
authorityParamSubst : List Mono -> List Mono -> List (Int, Authority)
authorityParamSubst (p :: ps) (a :: rest) = match (normalize p, normalize a)
  (TAuth q, TAuth actual) => match authNorm q
    AVar cell => (authvarId cell, actual) :: authorityParamSubst ps rest
    _ => authorityParamSubst ps rest
  _ => authorityParamSubst ps rest
authorityParamSubst _ _ = []

arrowParts : Mono -> (List Mono, Mono)
arrowParts m = match normalize m
  TFun dom _ res =>
    let (rest, result) = arrowParts res
    (dom :: rest, result)
  other => ([], other)

-- The same read against an EXPLICIT table — the form `inferParamPolarities`
-- uses, so the graph-wide seed builder (`declEnvPolarityChain`) and the per-run
-- reader apply the SAME write-channel seed.  Two copies of the seed is exactly
-- the drift this split exists to prevent.
export
paramPolaritiesIn : List (TabKey, List Polarity) ->
  TabKey ->
  Option (List Polarity)
paramPolaritiesIn tab key
  | tabKeyEq key (tabKeyOf NsType OriginBuiltin "Ref") = Some [PInv]
  | tabKeyEq key (tabKeyOf NsType OriginBuiltin "Array") = Some [PInv]
  | otherwise = lookupTab key tab

export
frozenInvocationOps : (DriveOutputs -> InvocationOps) ->
  DriveOutputs ->
  InvocationView ->
  InvocationOps
frozenInvocationOps makeOps outputs view =
  makeOps { outputs | doInvocationView = frozenInvocationView view }

export
completionInvocationViews : ModuleCtx ->
  InvocationView ->
  List (String, InvocationView) ->
  List (InvocationOwner, InvocationView)
completionInvocationViews entry core views =
  (ShippedPrelude, core)
    :: map ((mid, view) => (SourceModule mid, view)) views
      ++ [
        (
          SourceModule entry.mcCells.currentModuleRef.value,
          entry.mcCells.invocationViewRef.value,
        ),
      ]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "Ns" true) (mem "TyConOrigin" true) (mem "tabKeyOf" false) (mem "tabKeyEq" false) (mem "lookupTab" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "TcEnv" true) (mem "ModuleCtx" true) (mem "InvocationView" true) (mem "PublishedInvocationView" true) (mem "DriveOutputs" true) (mem "Polarity" true) (mem "Kind" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "freezePub" false) (mem "zonkScheme" false) (mem "emptyZonk" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authNorm" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false) (mem "Variance" true))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "InvocationOwner" true))))
(DUse false (UseGroup ("types" "registry") ((mem "spRows" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "ManifestSelector" true) (mem "EntryKey" false) (mem "InvocationProtocol" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "maxI" false))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "range" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "recordInvocationView" (TyFun (TyCon "TcEnv") (TyCon "Unit")))
(DFunDef false "recordInvocationView" ((PVar "env")) (EBlock (DoLet false false (PVar "universe") (EApp (EApp (EVar "flatMap") (ELam ((PVar "cands")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PTuple PWild PWild (PVar "sch")) () (EVar "sch"))))) (EVar "cands")))) (EApp (EVar "IdMap.values") (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "invocationViewRef")) (EApp (EApp (EApp (EVar "InvocationView") (EBinOp "++" (EApp (EVar "IdMap.values") (EFieldAccess (EVar "env") "teCtors")) (EVar "universe"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamKindsRef") "value"))))))
(DTypeSig true "frozenInvocationView" (TyFun (TyCon "InvocationView") (TyCon "InvocationView")))
(DFunDef false "frozenInvocationView" ((PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EApp (EApp (EVar "InvocationView") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "c"))))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds")))
(DTypeSig true "publishInvocationView" (TyFun (TyCon "InvocationView") (TyCon "PublishedInvocationView")))
(DFunDef false "publishInvocationView" ((PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EApp (EApp (EVar "PublishedInvocationView") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "freezePub") (EVar "c")) (EListLit)))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds")))
(DTypeSig true "readInvocationView" (TyFun (TyCon "PublishedInvocationView") (TyCon "InvocationView")))
(DFunDef false "readInvocationView" ((PCon "PublishedInvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EVar "frozenInvocationView") (EApp (EApp (EApp (EVar "InvocationView") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EFieldAccess (EVar "c") "psScheme"))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds"))))
(DTypeSig true "requestedViewModules" (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "requestedViewModules" () (EApp (EApp (EVar "fold") (ELam ((PVar "mods") (PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" (PVar "key") PWild) () (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "key") "moduleId")) (ELit LUnit)) (EVar "mods"))) (arm (PCon "EntryOverPrelude" PWild PWild) () (EVar "mods"))))) (EVar "omEmpty")))
(DTypeSig true "requestedWrapperViewModules" (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyFun (TyApp (TyCon "Option") (TyCon "EntryKey")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "requestedWrapperViewModules" ((PVar "selectors") (PVar "driver")) (EBlock (DoLet false false (PVar "modules") (EApp (EVar "requestedViewModules") (EVar "selectors"))) (DoLet false false (PVar "executed") (EApp (EApp (EVar "any") (ELam ((PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" PWild (PCon "ExecutedMain")) () (EVar "True")) (arm (PCon "EntryOverPrelude" PWild (PCon "ExecutedMain")) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "selectors"))) (DoExpr (EIf (EVar "executed") (EApp (EApp (EApp (EVar "option") (EVar "modules")) (ELam ((PVar "key")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EAnnot (EVar "key") (TyCon "EntryKey")) "moduleId")) (ELit LUnit)) (EVar "modules")))) (EVar "driver")) (EVar "modules")))))
(DTypeSig true "invocationResolver" (TyFun (TyFun (TyCon "InvocationView") (TyCon "InvocationOps")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InvocationOwner") (TyCon "InvocationView"))) (TyFun (TyCon "InvocationOwner") (TyApp (TyCon "Option") (TyCon "InvocationOps"))))))
(DFunDef false "invocationResolver" ((PVar "makeOps") (PVar "views")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "IdMap.fromList") (EVar "views"))) (DoExpr (ELam ((PVar "mid")) (EApp (EApp (EVar "map") (EVar "makeOps")) (EApp (EApp (EVar "IdMap.get") (EVar "mid")) (EVar "index")))))))
(DTypeSig true "slotVariances" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))))
(DFunDef false "slotVariances" ((PCon "None") (PCon "None")) (EVar "None"))
(DFunDef false "slotVariances" ((PVar "pols") (PVar "kinds")) (EBlock (DoLet false false (PVar "ps") (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "pols"))) (DoLet false false (PVar "ks") (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "kinds"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "slotVariance") (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps"))) (EApp (EApp (EVar "get") (EVar "i")) (EVar "ks"))))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EApp (EVar "maxI") (EApp (EVar "listLen") (EVar "ps"))) (EApp (EVar "listLen") (EVar "ks")))))))))
(DTypeSig false "slotVariance" (TyFun (TyApp (TyCon "Option") (TyCon "Polarity")) (TyFun (TyApp (TyCon "Option") (TyCon "Kind")) (TyCon "Variance"))))
(DFunDef false "slotVariance" (PWild (PCon "Some" (PCon "KRow"))) (EVar "VInv"))
(DFunDef false "slotVariance" (PWild (PCon "Some" (PCon "KAuth" PWild PWild))) (EVar "VInv"))
(DFunDef false "slotVariance" ((PCon "Some" (PVar "p")) PWild) (EApp (EVar "varianceOf") (EVar "p")))
(DFunDef false "slotVariance" ((PCon "None") PWild) (EVar "VInv"))
(DTypeSig false "varianceOf" (TyFun (TyCon "Polarity") (TyCon "Variance")))
(DFunDef false "varianceOf" ((PCon "PCo")) (EVar "VCo"))
(DFunDef false "varianceOf" ((PCon "PContra")) (EVar "VContra"))
(DFunDef false "varianceOf" ((PCon "PInv")) (EVar "VInv"))
(DFunDef false "varianceOf" ((PCon "PPhantom")) (EVar "VCo"))
(DTypeSig true "ctorsByHead" (TyFun (TyFun (TyCon "Mono") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Scheme")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "ctorsByHead" ((PVar "headKey") (PVar "schemes")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "sch")) (EMatch (EVar "sch") (arm (PCon "Forall" PWild PWild PWild PWild PWild (PVar "mono")) () (EBlock (DoLet false false (PTuple (PVar "fieldTys") (PVar "result")) (EApp (EVar "arrowParts") (EVar "mono"))) (DoLet false false (PTuple (PVar "h") (PVar "params")) (EApp (EVar "spineParts") (EVar "result"))) (DoLet false false (PVar "key") (EApp (EVar "headKey") (EVar "h"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "params") (EVar "fieldTys")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc"))))) (EVar "acc")))))))) (EVar "omEmpty")) (EVar "schemes")))
(DTypeSig true "authorityParamSubst" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))
(DFunDef false "authorityParamSubst" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "normalize") (EVar "p")) (EApp (EVar "normalize") (EVar "a"))) (arm (PTuple (PCon "TAuth" (PVar "q")) (PCon "TAuth" (PVar "actual"))) () (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "::" (ETuple (EApp (EVar "authvarId") (EVar "cell")) (EVar "actual")) (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest"))))) (arm PWild () (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest")))))
(DFunDef false "authorityParamSubst" (PWild PWild) (EListLit))
(DTypeSig false "arrowParts" (TyFun (TyCon "Mono") (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "arrowParts" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") PWild (PVar "res")) () (EBlock (DoLet false false (PTuple (PVar "rest") (PVar "result")) (EApp (EVar "arrowParts") (EVar "res"))) (DoExpr (ETuple (EBinOp "::" (EVar "dom") (EVar "rest")) (EVar "result"))))) (arm (PVar "other") () (ETuple (EListLit) (EVar "other")))))
(DTypeSig true "paramPolaritiesIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))))))
(DFunDef false "paramPolaritiesIn" ((PVar "tab") (PVar "key")) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Ref")))) (EApp (EVar "Some") (EListLit (EVar "PInv"))) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Array")))) (EApp (EVar "Some") (EListLit (EVar "PInv"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "tab")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "frozenInvocationOps" (TyFun (TyFun (TyCon "DriveOutputs") (TyCon "InvocationOps")) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "InvocationView") (TyCon "InvocationOps")))))
(DFunDef false "frozenInvocationOps" ((PVar "makeOps") (PVar "outputs") (PVar "view")) (EApp (EVar "makeOps") (ERecordUpdate (EVar "outputs") ((fa "doInvocationView" (EApp (EVar "frozenInvocationView") (EVar "view")))))))
(DTypeSig true "completionInvocationViews" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "InvocationView") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView"))) (TyApp (TyCon "List") (TyTuple (TyCon "InvocationOwner") (TyCon "InvocationView")))))))
(DFunDef false "completionInvocationViews" ((PVar "entry") (PVar "core") (PVar "views")) (EBinOp "::" (ETuple (EVar "ShippedPrelude") (EVar "core")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") (PVar "view"))) (ETuple (EApp (EVar "SourceModule") (EVar "mid")) (EVar "view")))) (EVar "views")) (EListLit (ETuple (EApp (EVar "SourceModule") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "entry") "mcCells") "currentModuleRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "entry") "mcCells") "invocationViewRef") "value"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "Ns" true) (mem "TyConOrigin" true) (mem "tabKeyOf" false) (mem "tabKeyEq" false) (mem "lookupTab" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "TcEnv" true) (mem "ModuleCtx" true) (mem "InvocationView" true) (mem "PublishedInvocationView" true) (mem "DriveOutputs" true) (mem "Polarity" true) (mem "Kind" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "freezePub" false) (mem "zonkScheme" false) (mem "emptyZonk" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false) (mem "spineParts" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authNorm" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false) (mem "Variance" true))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "InvocationOwner" true))))
(DUse false (UseGroup ("types" "registry") ((mem "spRows" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "ManifestSelector" true) (mem "EntryKey" false) (mem "InvocationProtocol" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "maxI" false))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "range" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "recordInvocationView" (TyFun (TyCon "TcEnv") (TyCon "Unit")))
(DFunDef false "recordInvocationView" ((PVar "env")) (EBlock (DoLet false false (PVar "universe") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "cands")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PTuple PWild PWild (PVar "sch")) () (EVar "sch"))))) (EVar "cands")))) (EApp (EVar "IdMap.values") (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "invocationViewRef")) (EApp (EApp (EApp (EVar "InvocationView") (EBinOp "++" (EApp (EVar "IdMap.values") (EFieldAccess (EVar "env") "teCtors")) (EVar "universe"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamKindsRef") "value"))))))
(DTypeSig true "frozenInvocationView" (TyFun (TyCon "InvocationView") (TyCon "InvocationView")))
(DFunDef false "frozenInvocationView" ((PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EApp (EApp (EVar "InvocationView") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "c"))))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds")))
(DTypeSig true "publishInvocationView" (TyFun (TyCon "InvocationView") (TyCon "PublishedInvocationView")))
(DFunDef false "publishInvocationView" ((PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EApp (EApp (EVar "PublishedInvocationView") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "freezePub") (EVar "c")) (EListLit)))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds")))
(DTypeSig true "readInvocationView" (TyFun (TyCon "PublishedInvocationView") (TyCon "InvocationView")))
(DFunDef false "readInvocationView" ((PCon "PublishedInvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds"))) (EApp (EVar "frozenInvocationView") (EApp (EApp (EApp (EVar "InvocationView") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EFieldAccess (EVar "c") "psScheme"))) (EVar "ctors"))) (EVar "pols")) (EVar "kinds"))))
(DTypeSig true "requestedViewModules" (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "requestedViewModules" () (EApp (EApp (EMethodRef "fold") (ELam ((PVar "mods") (PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" (PVar "key") PWild) () (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "key") "moduleId")) (ELit LUnit)) (EVar "mods"))) (arm (PCon "EntryOverPrelude" PWild PWild) () (EVar "mods"))))) (EVar "omEmpty")))
(DTypeSig true "requestedWrapperViewModules" (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyFun (TyApp (TyCon "Option") (TyCon "EntryKey")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "requestedWrapperViewModules" ((PVar "selectors") (PVar "driver")) (EBlock (DoLet false false (PVar "modules") (EApp (EVar "requestedViewModules") (EVar "selectors"))) (DoLet false false (PVar "executed") (EApp (EApp (EDictApp "any") (ELam ((PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" PWild (PCon "ExecutedMain")) () (EVar "True")) (arm (PCon "EntryOverPrelude" PWild (PCon "ExecutedMain")) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "selectors"))) (DoExpr (EIf (EVar "executed") (EApp (EApp (EApp (EVar "option") (EVar "modules")) (ELam ((PVar "key")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EAnnot (EVar "key") (TyCon "EntryKey")) "moduleId")) (ELit LUnit)) (EVar "modules")))) (EVar "driver")) (EVar "modules")))))
(DTypeSig true "invocationResolver" (TyFun (TyFun (TyCon "InvocationView") (TyCon "InvocationOps")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "InvocationOwner") (TyCon "InvocationView"))) (TyFun (TyCon "InvocationOwner") (TyApp (TyCon "Option") (TyCon "InvocationOps"))))))
(DFunDef false "invocationResolver" ((PVar "makeOps") (PVar "views")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "IdMap.fromList") (EVar "views"))) (DoExpr (ELam ((PVar "mid")) (EApp (EApp (EMethodRef "map") (EVar "makeOps")) (EApp (EApp (EVar "IdMap.get") (EVar "mid")) (EMethodRef "index")))))))
(DTypeSig true "slotVariances" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Variance"))))))
(DFunDef false "slotVariances" ((PCon "None") (PCon "None")) (EVar "None"))
(DFunDef false "slotVariances" ((PVar "pols") (PVar "kinds")) (EBlock (DoLet false false (PVar "ps") (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "pols"))) (DoLet false false (PVar "ks") (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "kinds"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "slotVariance") (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps"))) (EApp (EApp (EVar "get") (EVar "i")) (EVar "ks"))))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EApp (EVar "maxI") (EApp (EVar "listLen") (EVar "ps"))) (EApp (EVar "listLen") (EVar "ks")))))))))
(DTypeSig false "slotVariance" (TyFun (TyApp (TyCon "Option") (TyCon "Polarity")) (TyFun (TyApp (TyCon "Option") (TyCon "Kind")) (TyCon "Variance"))))
(DFunDef false "slotVariance" (PWild (PCon "Some" (PCon "KRow"))) (EVar "VInv"))
(DFunDef false "slotVariance" (PWild (PCon "Some" (PCon "KAuth" PWild PWild))) (EVar "VInv"))
(DFunDef false "slotVariance" ((PCon "Some" (PVar "p")) PWild) (EApp (EVar "varianceOf") (EVar "p")))
(DFunDef false "slotVariance" ((PCon "None") PWild) (EVar "VInv"))
(DTypeSig false "varianceOf" (TyFun (TyCon "Polarity") (TyCon "Variance")))
(DFunDef false "varianceOf" ((PCon "PCo")) (EVar "VCo"))
(DFunDef false "varianceOf" ((PCon "PContra")) (EVar "VContra"))
(DFunDef false "varianceOf" ((PCon "PInv")) (EVar "VInv"))
(DFunDef false "varianceOf" ((PCon "PPhantom")) (EVar "VCo"))
(DTypeSig true "ctorsByHead" (TyFun (TyFun (TyCon "Mono") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Scheme")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "ctorsByHead" ((PVar "headKey") (PVar "schemes")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "sch")) (EMatch (EVar "sch") (arm (PCon "Forall" PWild PWild PWild PWild PWild (PVar "mono")) () (EBlock (DoLet false false (PTuple (PVar "fieldTys") (PVar "result")) (EApp (EVar "arrowParts") (EVar "mono"))) (DoLet false false (PTuple (PVar "h") (PVar "params")) (EApp (EVar "spineParts") (EVar "result"))) (DoLet false false (PVar "key") (EApp (EVar "headKey") (EVar "h"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "params") (EVar "fieldTys")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc"))))) (EVar "acc")))))))) (EVar "omEmpty")) (EVar "schemes")))
(DTypeSig true "authorityParamSubst" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))
(DFunDef false "authorityParamSubst" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EMatch (ETuple (EApp (EVar "normalize") (EVar "p")) (EApp (EVar "normalize") (EVar "a"))) (arm (PTuple (PCon "TAuth" (PVar "q")) (PCon "TAuth" (PVar "actual"))) () (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "::" (ETuple (EApp (EVar "authvarId") (EVar "cell")) (EVar "actual")) (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest"))))) (arm PWild () (EApp (EApp (EVar "authorityParamSubst") (EVar "ps")) (EVar "rest")))))
(DFunDef false "authorityParamSubst" (PWild PWild) (EListLit))
(DTypeSig false "arrowParts" (TyFun (TyCon "Mono") (TyTuple (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "arrowParts" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" (PVar "dom") PWild (PVar "res")) () (EBlock (DoLet false false (PTuple (PVar "rest") (PVar "result")) (EApp (EVar "arrowParts") (EVar "res"))) (DoExpr (ETuple (EBinOp "::" (EVar "dom") (EVar "rest")) (EVar "result"))))) (arm (PVar "other") () (ETuple (EListLit) (EVar "other")))))
(DTypeSig true "paramPolaritiesIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Polarity")))) (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))))))
(DFunDef false "paramPolaritiesIn" ((PVar "tab") (PVar "key")) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Ref")))) (EApp (EVar "Some") (EListLit (EVar "PInv"))) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Array")))) (EApp (EVar "Some") (EListLit (EVar "PInv"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "tab")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "frozenInvocationOps" (TyFun (TyFun (TyCon "DriveOutputs") (TyCon "InvocationOps")) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "InvocationView") (TyCon "InvocationOps")))))
(DFunDef false "frozenInvocationOps" ((PVar "makeOps") (PVar "outputs") (PVar "view")) (EApp (EVar "makeOps") (ERecordUpdate (EVar "outputs") ((fa "doInvocationView" (EApp (EVar "frozenInvocationView") (EVar "view")))))))
(DTypeSig true "completionInvocationViews" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "InvocationView") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView"))) (TyApp (TyCon "List") (TyTuple (TyCon "InvocationOwner") (TyCon "InvocationView")))))))
(DFunDef false "completionInvocationViews" ((PVar "entry") (PVar "core") (PVar "views")) (EBinOp "::" (ETuple (EVar "ShippedPrelude") (EVar "core")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") (PVar "view"))) (ETuple (EApp (EVar "SourceModule") (EVar "mid")) (EVar "view")))) (EVar "views")) (EListLit (ETuple (EApp (EVar "SourceModule") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "entry") "mcCells") "currentModuleRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "entry") "mcCells") "invocationViewRef") "value"))))))
