# META
source_lines=104
stages=DESUGAR,MARK
# SOURCE
-- This is the only bridge from checked authority cells to capability data.
import types.capability_manifest.{
  EntryKey,
  ManifestRequest,
  InvocationProtocol(..),
  CapabilityManifest(..),
  FrozenAtom(..),
  FrozenAuthority(..),
  FrozenVariable(..),
  ManifestDefect,
  validateManifest,
}
import types.effect_invocation.{InvocationOps, invocationSummary}
import types.repr.{Scheme}
import types.effect_authority.{Authority(..), Authvar(..), authNorm, authvarId}
import types.effect_rows.{Atom(..), EffLabel(..), atomsUnion}
import types.effect_param_decode.{dtopIn}
import types.effect_domain.{Param}
import list.{mapAccumL}
import map as M
import map.{Map(..)}

public export data ManifestEntryInput = ManifestEntryInput {
  request : ManifestRequest,
  scheme : Scheme,
  wrappers : List (EntryKey, Scheme),
}

export
publishManifests : List (String, Param) ->
  InvocationOps ->
  List ManifestEntryInput ->
  Result (List ManifestDefect) (List CapabilityManifest)
publishManifests domains ops inputs =
  let (_, manifests) =
    mapAccumL
      (state input =>
        let atoms = invocationSummary ops input.scheme
        let charged = match input.request.protocol
          HostInvocation => atoms
          ExecutedMain =>
            fold
              (acc wrapper =>
                atomsUnion acc (invocationSummary ops (snd wrapper)))
              atoms
              input.wrappers
        let (more, frozen) = freezeAtomsWith domains state charged
        (more, CapabilityManifest { request = input.request, atoms = frozen }))
      Tip
      inputs
  match flatMap validateManifest manifests
    [] => Ok manifests
    defects => Err defects

-- Compatibility callers freeze their atom batch with the same identity rules.
export
freezeAtoms : List (String, Param) -> List Atom -> List FrozenAtom
freezeAtoms domains atoms = snd (freezeAtomsWith domains Tip atoms)

freezeAtomsWith : List (String, Param) ->
  Map Int FrozenVariable ->
  List Atom ->
  (Map Int FrozenVariable, List FrozenAtom)
freezeAtomsWith domains = mapAccumL
  (state (Atom (EffLabel label origin) authority) =>
    let (more, frozen) = freezeAuthority state (authNorm authority)
    (
      more,
      FrozenAtom {
        label = label,
        origin = origin,
        domainTop = dtopIn domains (EffLabel label origin),
        authority = frozen,
      },
    ))

freezeAuthority : Map Int FrozenVariable ->
  Authority ->
  (Map Int FrozenVariable, FrozenAuthority)
freezeAuthority state (AConst p) = (state, FrozenConst p)
freezeAuthority state (AJoin members) =
  let (more, frozen) = mapAccumL freezeAuthority state members
  (more, FrozenJoin frozen)
freezeAuthority state (AProduct axes) =
  let (more, frozen) =
    mapAccumL
      (s (name, authority) =>
        let (next, value) = freezeAuthority s authority
        (next, (name, value)))
      state
      axes
  (more, FrozenProduct frozen)
freezeAuthority state (AVar cell) = match !cell
  ALink _ _ target => freezeAuthority state (authNorm target)
  AUnbound _ _ top pattern name => match M.get (authvarId cell) state
    Some variable => (state, FrozenVar variable)
    None =>
      let variable = FrozenVariable {
        localId = M.size state,
        domainTop = top,
        patternOnly = pattern,
        sourceName = name,
      }
      (M.set (authvarId cell) variable state, FrozenVar variable)
# DESUGAR
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" false) (mem "ManifestRequest" false) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" true) (mem "ManifestDefect" false) (mem "validateManifest" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false) (mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authNorm" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "atomsUnion" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "ManifestEntryInput" () ((variant "ManifestEntryInput" (ConNamed (field "request" (TyCon "ManifestRequest")) (field "scheme" (TyCon "Scheme")) (field "wrappers" (TyApp (TyCon "List") (TyTuple (TyCon "EntryKey") (TyCon "Scheme"))))))) ())
(DTypeSig true "publishManifests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "InvocationOps") (TyFun (TyApp (TyCon "List") (TyCon "ManifestEntryInput")) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "ManifestDefect"))) (TyApp (TyCon "List") (TyCon "CapabilityManifest")))))))
(DFunDef false "publishManifests" ((PVar "domains") (PVar "ops") (PVar "inputs")) (EBlock (DoLet false false (PTuple PWild (PVar "manifests")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "state") (PVar "input")) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "invocationSummary") (EVar "ops")) (EFieldAccess (EVar "input") "scheme"))) (DoLet false false (PVar "charged") (EMatch (EFieldAccess (EFieldAccess (EVar "input") "request") "protocol") (arm (PCon "HostInvocation") () (EVar "atoms")) (arm (PCon "ExecutedMain") () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "wrapper")) (EApp (EApp (EVar "atomsUnion") (EVar "acc")) (EApp (EApp (EVar "invocationSummary") (EVar "ops")) (EApp (EVar "snd") (EVar "wrapper")))))) (EVar "atoms")) (EFieldAccess (EVar "input") "wrappers"))))) (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "freezeAtomsWith") (EVar "domains")) (EVar "state")) (EVar "charged"))) (DoExpr (ETuple (EVar "more") (ERecordCreate "CapabilityManifest" ((fa "request" (EFieldAccess (EVar "input") "request")) (fa "atoms" (EVar "frozen"))))))))) (EVar "Tip")) (EVar "inputs"))) (DoExpr (EMatch (EApp (EApp (EVar "flatMap") (EVar "validateManifest")) (EVar "manifests")) (arm (PList) () (EApp (EVar "Ok") (EVar "manifests"))) (arm (PVar "defects") () (EApp (EVar "Err") (EVar "defects")))))))
(DTypeSig true "freezeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "FrozenAtom")))))
(DFunDef false "freezeAtoms" ((PVar "domains") (PVar "atoms")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "freezeAtomsWith") (EVar "domains")) (EVar "Tip")) (EVar "atoms"))))
(DTypeSig false "freezeAtomsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "FrozenAtom")))))))
(DFunDef false "freezeAtomsWith" ((PVar "domains")) (EApp (EVar "mapAccumL") (ELam ((PVar "state") (PCon "Atom" (PCon "EffLabel" (PVar "label") (PVar "origin")) (PVar "authority"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EVar "freezeAuthority") (EVar "state")) (EApp (EVar "authNorm") (EVar "authority")))) (DoExpr (ETuple (EVar "more") (ERecordCreate "FrozenAtom" ((fa "label" (EVar "label")) (fa "origin" (EVar "origin")) (fa "domainTop" (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "origin")))) (fa "authority" (EVar "frozen"))))))))))
(DTypeSig false "freezeAuthority" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyCon "Authority") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyCon "FrozenAuthority")))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AConst" (PVar "p"))) (ETuple (EVar "state") (EApp (EVar "FrozenConst") (EVar "p"))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AJoin" (PVar "members"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "freezeAuthority")) (EVar "state")) (EVar "members"))) (DoExpr (ETuple (EVar "more") (EApp (EVar "FrozenJoin") (EVar "frozen"))))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "s") (PTuple (PVar "name") (PVar "authority"))) (EBlock (DoLet false false (PTuple (PVar "next") (PVar "value")) (EApp (EApp (EVar "freezeAuthority") (EVar "s")) (EVar "authority"))) (DoExpr (ETuple (EVar "next") (ETuple (EVar "name") (EVar "value"))))))) (EVar "state")) (EVar "axes"))) (DoExpr (ETuple (EVar "more") (EApp (EVar "FrozenProduct") (EVar "frozen"))))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "freezeAuthority") (EVar "state")) (EApp (EVar "authNorm") (EVar "target")))) (arm (PCon "AUnbound" PWild PWild (PVar "top") (PVar "pattern") (PVar "name")) () (EMatch (EApp (EApp (EVar "M.get") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "state")) (arm (PCon "Some" (PVar "variable")) () (ETuple (EVar "state") (EApp (EVar "FrozenVar") (EVar "variable")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "variable") (ERecordCreate "FrozenVariable" ((fa "localId" (EApp (EVar "M.size") (EVar "state"))) (fa "domainTop" (EVar "top")) (fa "patternOnly" (EVar "pattern")) (fa "sourceName" (EVar "name"))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "variable")) (EVar "state")) (EApp (EVar "FrozenVar") (EVar "variable"))))))))))
# MARK
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" false) (mem "ManifestRequest" false) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" true) (mem "ManifestDefect" false) (mem "validateManifest" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false) (mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authNorm" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "atomsUnion" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "ManifestEntryInput" () ((variant "ManifestEntryInput" (ConNamed (field "request" (TyCon "ManifestRequest")) (field "scheme" (TyCon "Scheme")) (field "wrappers" (TyApp (TyCon "List") (TyTuple (TyCon "EntryKey") (TyCon "Scheme"))))))) ())
(DTypeSig true "publishManifests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "InvocationOps") (TyFun (TyApp (TyCon "List") (TyCon "ManifestEntryInput")) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "ManifestDefect"))) (TyApp (TyCon "List") (TyCon "CapabilityManifest")))))))
(DFunDef false "publishManifests" ((PVar "domains") (PVar "ops") (PVar "inputs")) (EBlock (DoLet false false (PTuple PWild (PVar "manifests")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "state") (PVar "input")) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "invocationSummary") (EVar "ops")) (EFieldAccess (EVar "input") "scheme"))) (DoLet false false (PVar "charged") (EMatch (EFieldAccess (EFieldAccess (EVar "input") "request") "protocol") (arm (PCon "HostInvocation") () (EVar "atoms")) (arm (PCon "ExecutedMain") () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "wrapper")) (EApp (EApp (EVar "atomsUnion") (EVar "acc")) (EApp (EApp (EVar "invocationSummary") (EVar "ops")) (EApp (EVar "snd") (EVar "wrapper")))))) (EVar "atoms")) (EFieldAccess (EVar "input") "wrappers"))))) (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "freezeAtomsWith") (EVar "domains")) (EVar "state")) (EVar "charged"))) (DoExpr (ETuple (EVar "more") (ERecordCreate "CapabilityManifest" ((fa "request" (EFieldAccess (EVar "input") "request")) (fa "atoms" (EVar "frozen"))))))))) (EVar "Tip")) (EVar "inputs"))) (DoExpr (EMatch (EApp (EApp (EDictApp "flatMap") (EVar "validateManifest")) (EVar "manifests")) (arm (PList) () (EApp (EVar "Ok") (EVar "manifests"))) (arm (PVar "defects") () (EApp (EVar "Err") (EVar "defects")))))))
(DTypeSig true "freezeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "FrozenAtom")))))
(DFunDef false "freezeAtoms" ((PVar "domains") (PVar "atoms")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "freezeAtomsWith") (EVar "domains")) (EVar "Tip")) (EVar "atoms"))))
(DTypeSig false "freezeAtomsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "FrozenAtom")))))))
(DFunDef false "freezeAtomsWith" ((PVar "domains")) (EApp (EVar "mapAccumL") (ELam ((PVar "state") (PCon "Atom" (PCon "EffLabel" (PVar "label") (PVar "origin")) (PVar "authority"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EVar "freezeAuthority") (EVar "state")) (EApp (EVar "authNorm") (EVar "authority")))) (DoExpr (ETuple (EVar "more") (ERecordCreate "FrozenAtom" ((fa "label" (EVar "label")) (fa "origin" (EVar "origin")) (fa "domainTop" (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "origin")))) (fa "authority" (EVar "frozen"))))))))))
(DTypeSig false "freezeAuthority" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyCon "Authority") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyCon "FrozenAuthority")))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AConst" (PVar "p"))) (ETuple (EVar "state") (EApp (EVar "FrozenConst") (EVar "p"))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AJoin" (PVar "members"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "freezeAuthority")) (EVar "state")) (EVar "members"))) (DoExpr (ETuple (EVar "more") (EApp (EVar "FrozenJoin") (EVar "frozen"))))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "frozen")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "s") (PTuple (PVar "name") (PVar "authority"))) (EBlock (DoLet false false (PTuple (PVar "next") (PVar "value")) (EApp (EApp (EVar "freezeAuthority") (EVar "s")) (EVar "authority"))) (DoExpr (ETuple (EVar "next") (ETuple (EVar "name") (EVar "value"))))))) (EVar "state")) (EVar "axes"))) (DoExpr (ETuple (EVar "more") (EApp (EVar "FrozenProduct") (EVar "frozen"))))))
(DFunDef false "freezeAuthority" ((PVar "state") (PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "freezeAuthority") (EVar "state")) (EApp (EVar "authNorm") (EVar "target")))) (arm (PCon "AUnbound" PWild PWild (PVar "top") (PVar "pattern") (PVar "name")) () (EMatch (EApp (EApp (EVar "M.get") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "state")) (arm (PCon "Some" (PVar "variable")) () (ETuple (EVar "state") (EApp (EVar "FrozenVar") (EVar "variable")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "variable") (ERecordCreate "FrozenVariable" ((fa "localId" (EApp (EVar "M.size") (EVar "state"))) (fa "domainTop" (EVar "top")) (fa "patternOnly" (EVar "pattern")) (fa "sourceName" (EVar "name"))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "variable")) (EVar "state")) (EApp (EVar "FrozenVar") (EVar "variable"))))))))))
