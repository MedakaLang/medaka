# META
source_lines=182
stages=DESUGAR,MARK
# SOURCE
-- Checked capability data contains no inference cells or query functions.
import frontend.ast.{TyConOrigin(..)}
import types.effect_domain.{Param(..), domainKey, isSubTop}
import support.util.{lenKey}
import map as M
import map.{Map(..)}
import list.{mapAccumL}

public export data EntryKey = EntryKey { moduleId : String, binding : String }
public export data InvocationProtocol = HostInvocation | ExecutedMain
public export data ManifestRequest = ManifestRequest {
  entry : EntryKey,
  protocol : InvocationProtocol,
}
public export data ManifestSelector =
  | EntryOverPrelude String InvocationProtocol
  | ExactEntry EntryKey InvocationProtocol
public export data ManifestRequirement =
  | RawUnchecked
  | CheckedEntry EntryKey InvocationProtocol
public export data ManifestLookup =
  | NotRequested
  | RequestedMissing ManifestRequest
  | Published CapabilityManifest
public export data FrozenVariable = FrozenVariable {
  localId : Int,
  domainTop : Param,
  patternOnly : Bool,
  sourceName : Option String,
}
public export data FrozenAuthority =
  | FrozenConst Param
  | FrozenVar FrozenVariable
  | FrozenJoin (List FrozenAuthority)
  | FrozenProduct (List (String, FrozenAuthority))
public export data FrozenAtom = FrozenAtom {
  label : String,
  origin : TyConOrigin,
  domainTop : Param,
  authority : FrozenAuthority,
}
public export data CapabilityManifest = CapabilityManifest {
  request : ManifestRequest,
  atoms : List FrozenAtom,
}
public export data ManifestDefect = ManifestDefect String

export
entryKeyEqual : EntryKey -> EntryKey -> Bool
entryKeyEqual a b = a.moduleId == b.moduleId && a.binding == b.binding

protocolEqual : InvocationProtocol -> InvocationProtocol -> Bool
protocolEqual HostInvocation HostInvocation = True
protocolEqual ExecutedMain ExecutedMain = True
protocolEqual _ _ = False

export
requestEqual : ManifestRequest -> ManifestRequest -> Bool
requestEqual a b =
  entryKeyEqual a.entry b.entry && protocolEqual a.protocol b.protocol

export
lookupManifest : ManifestRequest ->
  List ManifestRequest ->
  List CapabilityManifest ->
  ManifestLookup
lookupManifest request selected manifests =
  if any (requestEqual request) selected then
    findManifest request manifests
  else
    NotRequested

findManifest : ManifestRequest -> List CapabilityManifest -> ManifestLookup
findManifest request [] = RequestedMissing request
findManifest request (m :: rest) =
  if requestEqual request m.request then
    Published m
  else
    findManifest request rest

export
validateManifest : CapabilityManifest -> List ManifestDefect
validateManifest manifest =
  let (_, defects) = mapAccumL validateAtom (Tip, Tip) manifest.atoms
  problem (manifest.request.entry.binding == "") "empty entry binding"
    ++ flatMap identity defects

problem : Bool -> String -> List ManifestDefect
problem True message = [ManifestDefect message]
problem False _ = []

validateAtom : (Map String Unit, Map Int FrozenVariable) ->
  FrozenAtom ->
  ((Map String Unit, Map Int FrozenVariable), List ManifestDefect)
validateAtom (labels, variables) atom =
  let origin = match atom.origin
    OriginModule m => "module:" ++ lenKey m
    OriginBuiltin => "builtin:"
    OriginUnresolved => "unresolved:"
  let key = origin ++ lenKey atom.label
  let (more, defects) =
    validateAuthority atom.domainTop variables atom.authority
  (
    (M.set key () labels, more),
    problem (atom.label == "") "empty effect label"
      ++ problem (M.has key labels) "duplicate effect identity"
      ++ topProblems atom.domainTop
      ++ defects,
  )

topProblems : Param -> List ManifestDefect
topProblems top =
  problem (not (isSubTop top)) "domainTop is not a domain top"
    ++ paramProblems top

paramProblems : Param -> List ManifestDefect
paramProblems (PProduct axes) =
  axisNames (map fst axes) ++ flatMap (a => paramProblems (snd a)) axes
paramProblems _ = []

axisNames : List String -> List ManifestDefect
axisNames names =
  let (_, defects) =
    mapAccumL
      (seen name => (
        M.set name () seen,
        problem (name == "" || M.has name seen) "empty or repeated product axis",
      ))
      Tip
      names
  flatMap identity defects

validateAuthority : Param ->
  Map Int FrozenVariable ->
  FrozenAuthority ->
  (Map Int FrozenVariable, List ManifestDefect)
validateAuthority top variables (FrozenConst p) = (
  variables,
  problem (domainKey top /= domainKey p) "constant domain mismatch"
    ++ paramProblems p,
)
validateAuthority top variables (FrozenVar v) =
  let metadata = match M.get v.localId variables
    None => []
    Some previous =>
      problem
        (domainKey previous.domainTop /= domainKey v.domainTop
          || previous.patternOnly /= v.patternOnly
          || previous.sourceName /= v.sourceName)
        "inconsistent frozen variable metadata"
  (
    M.set v.localId v variables,
    problem (v.localId < 0) "negative frozen variable id"
      ++ problem
        (domainKey top /= domainKey v.domainTop)
        "variable domain mismatch"
      ++ topProblems v.domainTop
      ++ metadata,
  )
validateAuthority top variables (FrozenJoin members) =
  let (more, defects) = mapAccumL (validateAuthority top) variables members
  (more, flatMap identity defects)
validateAuthority (PProduct schema) variables (FrozenProduct axes) =
  let (more, defects) = validateAxes schema variables axes
  (more, axisNames (map fst axes) ++ defects)
validateAuthority _ variables (FrozenProduct _) =
  (variables, [ManifestDefect "product authority in non-product domain"])

validateAxes : List (String, Param) ->
  Map Int FrozenVariable ->
  List (String, FrozenAuthority) ->
  (Map Int FrozenVariable, List ManifestDefect)
validateAxes [] variables [] = (variables, [])
validateAxes ((name, top) :: schema) variables ((axis, authority) :: rest) =
  let (more, defects) = validateAuthority top variables authority
  let (done, later) = validateAxes schema more rest
  (
    done,
    problem (name /= axis) "product axis order mismatch" ++ defects ++ later,
  )
validateAxes _ variables _ =
  (variables, [ManifestDefect "product axis schema mismatch"])
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "domainKey" false) (mem "isSubTop" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DData Public "EntryKey" () ((variant "EntryKey" (ConNamed (field "moduleId" (TyCon "String")) (field "binding" (TyCon "String"))))) ())
(DData Public "InvocationProtocol" () ((variant "HostInvocation" (ConPos)) (variant "ExecutedMain" (ConPos))) ())
(DData Public "ManifestRequest" () ((variant "ManifestRequest" (ConNamed (field "entry" (TyCon "EntryKey")) (field "protocol" (TyCon "InvocationProtocol"))))) ())
(DData Public "ManifestSelector" () ((variant "EntryOverPrelude" (ConPos (TyCon "String") (TyCon "InvocationProtocol"))) (variant "ExactEntry" (ConPos (TyCon "EntryKey") (TyCon "InvocationProtocol")))) ())
(DData Public "ManifestRequirement" () ((variant "RawUnchecked" (ConPos)) (variant "CheckedEntry" (ConPos (TyCon "EntryKey") (TyCon "InvocationProtocol")))) ())
(DData Public "ManifestLookup" () ((variant "NotRequested" (ConPos)) (variant "RequestedMissing" (ConPos (TyCon "ManifestRequest"))) (variant "Published" (ConPos (TyCon "CapabilityManifest")))) ())
(DData Public "FrozenVariable" () ((variant "FrozenVariable" (ConNamed (field "localId" (TyCon "Int")) (field "domainTop" (TyCon "Param")) (field "patternOnly" (TyCon "Bool")) (field "sourceName" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DData Public "FrozenAuthority" () ((variant "FrozenConst" (ConPos (TyCon "Param"))) (variant "FrozenVar" (ConPos (TyCon "FrozenVariable"))) (variant "FrozenJoin" (ConPos (TyApp (TyCon "List") (TyCon "FrozenAuthority")))) (variant "FrozenProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority")))))) ())
(DData Public "FrozenAtom" () ((variant "FrozenAtom" (ConNamed (field "label" (TyCon "String")) (field "origin" (TyCon "TyConOrigin")) (field "domainTop" (TyCon "Param")) (field "authority" (TyCon "FrozenAuthority"))))) ())
(DData Public "CapabilityManifest" () ((variant "CapabilityManifest" (ConNamed (field "request" (TyCon "ManifestRequest")) (field "atoms" (TyApp (TyCon "List") (TyCon "FrozenAtom")))))) ())
(DData Public "ManifestDefect" () ((variant "ManifestDefect" (ConPos (TyCon "String")))) ())
(DTypeSig true "entryKeyEqual" (TyFun (TyCon "EntryKey") (TyFun (TyCon "EntryKey") (TyCon "Bool"))))
(DFunDef false "entryKeyEqual" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "moduleId") (EFieldAccess (EVar "b") "moduleId")) (EBinOp "==" (EFieldAccess (EVar "a") "binding") (EFieldAccess (EVar "b") "binding"))))
(DTypeSig false "protocolEqual" (TyFun (TyCon "InvocationProtocol") (TyFun (TyCon "InvocationProtocol") (TyCon "Bool"))))
(DFunDef false "protocolEqual" ((PCon "HostInvocation") (PCon "HostInvocation")) (EVar "True"))
(DFunDef false "protocolEqual" ((PCon "ExecutedMain") (PCon "ExecutedMain")) (EVar "True"))
(DFunDef false "protocolEqual" (PWild PWild) (EVar "False"))
(DTypeSig true "requestEqual" (TyFun (TyCon "ManifestRequest") (TyFun (TyCon "ManifestRequest") (TyCon "Bool"))))
(DFunDef false "requestEqual" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "entryKeyEqual") (EFieldAccess (EVar "a") "entry")) (EFieldAccess (EVar "b") "entry")) (EApp (EApp (EVar "protocolEqual") (EFieldAccess (EVar "a") "protocol")) (EFieldAccess (EVar "b") "protocol"))))
(DTypeSig true "lookupManifest" (TyFun (TyCon "ManifestRequest") (TyFun (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyCon "ManifestLookup")))))
(DFunDef false "lookupManifest" ((PVar "request") (PVar "selected") (PVar "manifests")) (EIf (EApp (EApp (EVar "any") (EApp (EVar "requestEqual") (EVar "request"))) (EVar "selected")) (EApp (EApp (EVar "findManifest") (EVar "request")) (EVar "manifests")) (EVar "NotRequested")))
(DTypeSig false "findManifest" (TyFun (TyCon "ManifestRequest") (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyCon "ManifestLookup"))))
(DFunDef false "findManifest" ((PVar "request") (PList)) (EApp (EVar "RequestedMissing") (EVar "request")))
(DFunDef false "findManifest" ((PVar "request") (PCons (PVar "m") (PVar "rest"))) (EIf (EApp (EApp (EVar "requestEqual") (EVar "request")) (EFieldAccess (EVar "m") "request")) (EApp (EVar "Published") (EVar "m")) (EApp (EApp (EVar "findManifest") (EVar "request")) (EVar "rest"))))
(DTypeSig true "validateManifest" (TyFun (TyCon "CapabilityManifest") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "validateManifest" ((PVar "manifest")) (EBlock (DoLet false false (PTuple PWild (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "validateAtom")) (ETuple (EVar "Tip") (EVar "Tip"))) (EFieldAccess (EVar "manifest") "atoms"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "binding") (ELit (LString "")))) (ELit (LString "empty entry binding"))) (EApp (EApp (EVar "flatMap") (EVar "identity")) (EVar "defects"))))))
(DTypeSig false "problem" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ManifestDefect")))))
(DFunDef false "problem" ((PCon "True") (PVar "message")) (EListLit (EApp (EVar "ManifestDefect") (EVar "message"))))
(DFunDef false "problem" ((PCon "False") PWild) (EListLit))
(DTypeSig false "validateAtom" (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable"))) (TyFun (TyCon "FrozenAtom") (TyTuple (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable"))) (TyApp (TyCon "List") (TyCon "ManifestDefect"))))))
(DFunDef false "validateAtom" ((PTuple (PVar "labels") (PVar "variables")) (PVar "atom")) (EBlock (DoLet false false (PVar "origin") (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (ELit (LString "module:")) (EApp (EVar "lenKey") (EVar "m")))) (arm (PCon "OriginBuiltin") () (ELit (LString "builtin:"))) (arm (PCon "OriginUnresolved") () (ELit (LString "unresolved:"))))) (DoLet false false (PVar "key") (EBinOp "++" (EVar "origin") (EApp (EVar "lenKey") (EFieldAccess (EVar "atom") "label")))) (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAuthority") (EFieldAccess (EVar "atom") "domainTop")) (EVar "variables")) (EFieldAccess (EVar "atom") "authority"))) (DoExpr (ETuple (ETuple (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (ELit LUnit)) (EVar "labels")) (EVar "more")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "==" (EFieldAccess (EVar "atom") "label") (ELit (LString "")))) (ELit (LString "empty effect label"))) (EApp (EApp (EVar "problem") (EApp (EApp (EVar "M.has") (EVar "key")) (EVar "labels"))) (ELit (LString "duplicate effect identity")))) (EApp (EVar "topProblems") (EFieldAccess (EVar "atom") "domainTop"))) (EVar "defects"))))))
(DTypeSig false "topProblems" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "topProblems" ((PVar "top")) (EBinOp "++" (EApp (EApp (EVar "problem") (EApp (EVar "not") (EApp (EVar "isSubTop") (EVar "top")))) (ELit (LString "domainTop is not a domain top"))) (EApp (EVar "paramProblems") (EVar "top"))))
(DTypeSig false "paramProblems" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "paramProblems" ((PCon "PProduct" (PVar "axes"))) (EBinOp "++" (EApp (EVar "axisNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "axes"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EApp (EVar "paramProblems") (EApp (EVar "snd") (EVar "a"))))) (EVar "axes"))))
(DFunDef false "paramProblems" (PWild) (EListLit))
(DTypeSig false "axisNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "axisNames" ((PVar "names")) (EBlock (DoLet false false (PTuple PWild (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "seen") (PVar "name")) (ETuple (EApp (EApp (EApp (EVar "M.set") (EVar "name")) (ELit LUnit)) (EVar "seen")) (EApp (EApp (EVar "problem") (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EApp (EVar "M.has") (EVar "name")) (EVar "seen")))) (ELit (LString "empty or repeated product axis")))))) (EVar "Tip")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "flatMap") (EVar "identity")) (EVar "defects")))))
(DTypeSig false "validateAuthority" (TyFun (TyCon "Param") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyCon "FrozenAuthority") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "ManifestDefect")))))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenConst" (PVar "p"))) (ETuple (EVar "variables") (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "/=" (EApp (EVar "domainKey") (EVar "top")) (EApp (EVar "domainKey") (EVar "p")))) (ELit (LString "constant domain mismatch"))) (EApp (EVar "paramProblems") (EVar "p")))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenVar" (PVar "v"))) (EBlock (DoLet false false (PVar "metadata") (EMatch (EApp (EApp (EVar "M.get") (EFieldAccess (EVar "v") "localId")) (EVar "variables")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "previous")) () (EApp (EApp (EVar "problem") (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EApp (EVar "domainKey") (EFieldAccess (EVar "previous") "domainTop")) (EApp (EVar "domainKey") (EFieldAccess (EVar "v") "domainTop"))) (EBinOp "/=" (EFieldAccess (EVar "previous") "patternOnly") (EFieldAccess (EVar "v") "patternOnly"))) (EBinOp "/=" (EFieldAccess (EVar "previous") "sourceName") (EFieldAccess (EVar "v") "sourceName")))) (ELit (LString "inconsistent frozen variable metadata")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "M.set") (EFieldAccess (EVar "v") "localId")) (EVar "v")) (EVar "variables")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "<" (EFieldAccess (EVar "v") "localId") (ELit (LInt 0)))) (ELit (LString "negative frozen variable id"))) (EApp (EApp (EVar "problem") (EBinOp "/=" (EApp (EVar "domainKey") (EVar "top")) (EApp (EVar "domainKey") (EFieldAccess (EVar "v") "domainTop")))) (ELit (LString "variable domain mismatch")))) (EApp (EVar "topProblems") (EFieldAccess (EVar "v") "domainTop"))) (EVar "metadata"))))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenJoin" (PVar "members"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (EApp (EVar "validateAuthority") (EVar "top"))) (EVar "variables")) (EVar "members"))) (DoExpr (ETuple (EVar "more") (EApp (EApp (EVar "flatMap") (EVar "identity")) (EVar "defects"))))))
(DFunDef false "validateAuthority" ((PCon "PProduct" (PVar "schema")) (PVar "variables") (PCon "FrozenProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAxes") (EVar "schema")) (EVar "variables")) (EVar "axes"))) (DoExpr (ETuple (EVar "more") (EBinOp "++" (EApp (EVar "axisNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "axes"))) (EVar "defects"))))))
(DFunDef false "validateAuthority" (PWild (PVar "variables") (PCon "FrozenProduct" PWild)) (ETuple (EVar "variables") (EListLit (EApp (EVar "ManifestDefect") (ELit (LString "product authority in non-product domain"))))))
(DTypeSig false "validateAxes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "ManifestDefect")))))))
(DFunDef false "validateAxes" ((PList) (PVar "variables") (PList)) (ETuple (EVar "variables") (EListLit)))
(DFunDef false "validateAxes" ((PCons (PTuple (PVar "name") (PVar "top")) (PVar "schema")) (PVar "variables") (PCons (PTuple (PVar "axis") (PVar "authority")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAuthority") (EVar "top")) (EVar "variables")) (EVar "authority"))) (DoLet false false (PTuple (PVar "done") (PVar "later")) (EApp (EApp (EApp (EVar "validateAxes") (EVar "schema")) (EVar "more")) (EVar "rest"))) (DoExpr (ETuple (EVar "done") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "/=" (EVar "name") (EVar "axis"))) (ELit (LString "product axis order mismatch"))) (EVar "defects")) (EVar "later"))))))
(DFunDef false "validateAxes" (PWild (PVar "variables") PWild) (ETuple (EVar "variables") (EListLit (EApp (EVar "ManifestDefect") (ELit (LString "product axis schema mismatch"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "domainKey" false) (mem "isSubTop" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DData Public "EntryKey" () ((variant "EntryKey" (ConNamed (field "moduleId" (TyCon "String")) (field "binding" (TyCon "String"))))) ())
(DData Public "InvocationProtocol" () ((variant "HostInvocation" (ConPos)) (variant "ExecutedMain" (ConPos))) ())
(DData Public "ManifestRequest" () ((variant "ManifestRequest" (ConNamed (field "entry" (TyCon "EntryKey")) (field "protocol" (TyCon "InvocationProtocol"))))) ())
(DData Public "ManifestSelector" () ((variant "EntryOverPrelude" (ConPos (TyCon "String") (TyCon "InvocationProtocol"))) (variant "ExactEntry" (ConPos (TyCon "EntryKey") (TyCon "InvocationProtocol")))) ())
(DData Public "ManifestRequirement" () ((variant "RawUnchecked" (ConPos)) (variant "CheckedEntry" (ConPos (TyCon "EntryKey") (TyCon "InvocationProtocol")))) ())
(DData Public "ManifestLookup" () ((variant "NotRequested" (ConPos)) (variant "RequestedMissing" (ConPos (TyCon "ManifestRequest"))) (variant "Published" (ConPos (TyCon "CapabilityManifest")))) ())
(DData Public "FrozenVariable" () ((variant "FrozenVariable" (ConNamed (field "localId" (TyCon "Int")) (field "domainTop" (TyCon "Param")) (field "patternOnly" (TyCon "Bool")) (field "sourceName" (TyApp (TyCon "Option") (TyCon "String")))))) ())
(DData Public "FrozenAuthority" () ((variant "FrozenConst" (ConPos (TyCon "Param"))) (variant "FrozenVar" (ConPos (TyCon "FrozenVariable"))) (variant "FrozenJoin" (ConPos (TyApp (TyCon "List") (TyCon "FrozenAuthority")))) (variant "FrozenProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority")))))) ())
(DData Public "FrozenAtom" () ((variant "FrozenAtom" (ConNamed (field "label" (TyCon "String")) (field "origin" (TyCon "TyConOrigin")) (field "domainTop" (TyCon "Param")) (field "authority" (TyCon "FrozenAuthority"))))) ())
(DData Public "CapabilityManifest" () ((variant "CapabilityManifest" (ConNamed (field "request" (TyCon "ManifestRequest")) (field "atoms" (TyApp (TyCon "List") (TyCon "FrozenAtom")))))) ())
(DData Public "ManifestDefect" () ((variant "ManifestDefect" (ConPos (TyCon "String")))) ())
(DTypeSig true "entryKeyEqual" (TyFun (TyCon "EntryKey") (TyFun (TyCon "EntryKey") (TyCon "Bool"))))
(DFunDef false "entryKeyEqual" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "moduleId") (EFieldAccess (EVar "b") "moduleId")) (EBinOp "==" (EFieldAccess (EVar "a") "binding") (EFieldAccess (EVar "b") "binding"))))
(DTypeSig false "protocolEqual" (TyFun (TyCon "InvocationProtocol") (TyFun (TyCon "InvocationProtocol") (TyCon "Bool"))))
(DFunDef false "protocolEqual" ((PCon "HostInvocation") (PCon "HostInvocation")) (EVar "True"))
(DFunDef false "protocolEqual" ((PCon "ExecutedMain") (PCon "ExecutedMain")) (EVar "True"))
(DFunDef false "protocolEqual" (PWild PWild) (EVar "False"))
(DTypeSig true "requestEqual" (TyFun (TyCon "ManifestRequest") (TyFun (TyCon "ManifestRequest") (TyCon "Bool"))))
(DFunDef false "requestEqual" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "entryKeyEqual") (EFieldAccess (EVar "a") "entry")) (EFieldAccess (EVar "b") "entry")) (EApp (EApp (EVar "protocolEqual") (EFieldAccess (EVar "a") "protocol")) (EFieldAccess (EVar "b") "protocol"))))
(DTypeSig true "lookupManifest" (TyFun (TyCon "ManifestRequest") (TyFun (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyCon "ManifestLookup")))))
(DFunDef false "lookupManifest" ((PVar "request") (PVar "selected") (PVar "manifests")) (EIf (EApp (EApp (EDictApp "any") (EApp (EVar "requestEqual") (EVar "request"))) (EVar "selected")) (EApp (EApp (EVar "findManifest") (EVar "request")) (EVar "manifests")) (EVar "NotRequested")))
(DTypeSig false "findManifest" (TyFun (TyCon "ManifestRequest") (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyCon "ManifestLookup"))))
(DFunDef false "findManifest" ((PVar "request") (PList)) (EApp (EVar "RequestedMissing") (EVar "request")))
(DFunDef false "findManifest" ((PVar "request") (PCons (PVar "m") (PVar "rest"))) (EIf (EApp (EApp (EVar "requestEqual") (EVar "request")) (EFieldAccess (EVar "m") "request")) (EApp (EVar "Published") (EVar "m")) (EApp (EApp (EVar "findManifest") (EVar "request")) (EVar "rest"))))
(DTypeSig true "validateManifest" (TyFun (TyCon "CapabilityManifest") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "validateManifest" ((PVar "manifest")) (EBlock (DoLet false false (PTuple PWild (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "validateAtom")) (ETuple (EVar "Tip") (EVar "Tip"))) (EFieldAccess (EVar "manifest") "atoms"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "binding") (ELit (LString "")))) (ELit (LString "empty entry binding"))) (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EVar "defects"))))))
(DTypeSig false "problem" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ManifestDefect")))))
(DFunDef false "problem" ((PCon "True") (PVar "message")) (EListLit (EApp (EVar "ManifestDefect") (EVar "message"))))
(DFunDef false "problem" ((PCon "False") PWild) (EListLit))
(DTypeSig false "validateAtom" (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable"))) (TyFun (TyCon "FrozenAtom") (TyTuple (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable"))) (TyApp (TyCon "List") (TyCon "ManifestDefect"))))))
(DFunDef false "validateAtom" ((PTuple (PVar "labels") (PVar "variables")) (PVar "atom")) (EBlock (DoLet false false (PVar "origin") (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (ELit (LString "module:")) (EApp (EVar "lenKey") (EVar "m")))) (arm (PCon "OriginBuiltin") () (ELit (LString "builtin:"))) (arm (PCon "OriginUnresolved") () (ELit (LString "unresolved:"))))) (DoLet false false (PVar "key") (EBinOp "++" (EVar "origin") (EApp (EVar "lenKey") (EFieldAccess (EVar "atom") "label")))) (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAuthority") (EFieldAccess (EVar "atom") "domainTop")) (EVar "variables")) (EFieldAccess (EVar "atom") "authority"))) (DoExpr (ETuple (ETuple (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (ELit LUnit)) (EVar "labels")) (EVar "more")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "==" (EFieldAccess (EVar "atom") "label") (ELit (LString "")))) (ELit (LString "empty effect label"))) (EApp (EApp (EVar "problem") (EApp (EApp (EVar "M.has") (EVar "key")) (EVar "labels"))) (ELit (LString "duplicate effect identity")))) (EApp (EVar "topProblems") (EFieldAccess (EVar "atom") "domainTop"))) (EVar "defects"))))))
(DTypeSig false "topProblems" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "topProblems" ((PVar "top")) (EBinOp "++" (EApp (EApp (EVar "problem") (EApp (EVar "not") (EApp (EVar "isSubTop") (EVar "top")))) (ELit (LString "domainTop is not a domain top"))) (EApp (EVar "paramProblems") (EVar "top"))))
(DTypeSig false "paramProblems" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "paramProblems" ((PCon "PProduct" (PVar "axes"))) (EBinOp "++" (EApp (EVar "axisNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "axes"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EApp (EVar "paramProblems") (EApp (EVar "snd") (EVar "a"))))) (EVar "axes"))))
(DFunDef false "paramProblems" (PWild) (EListLit))
(DTypeSig false "axisNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ManifestDefect"))))
(DFunDef false "axisNames" ((PVar "names")) (EBlock (DoLet false false (PTuple PWild (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (ELam ((PVar "seen") (PVar "name")) (ETuple (EApp (EApp (EApp (EVar "M.set") (EVar "name")) (ELit LUnit)) (EVar "seen")) (EApp (EApp (EVar "problem") (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EApp (EVar "M.has") (EVar "name")) (EVar "seen")))) (ELit (LString "empty or repeated product axis")))))) (EVar "Tip")) (EVar "names"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EVar "defects")))))
(DTypeSig false "validateAuthority" (TyFun (TyCon "Param") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyCon "FrozenAuthority") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "ManifestDefect")))))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenConst" (PVar "p"))) (ETuple (EVar "variables") (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "/=" (EApp (EVar "domainKey") (EVar "top")) (EApp (EVar "domainKey") (EVar "p")))) (ELit (LString "constant domain mismatch"))) (EApp (EVar "paramProblems") (EVar "p")))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenVar" (PVar "v"))) (EBlock (DoLet false false (PVar "metadata") (EMatch (EApp (EApp (EVar "M.get") (EFieldAccess (EVar "v") "localId")) (EVar "variables")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "previous")) () (EApp (EApp (EVar "problem") (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EApp (EVar "domainKey") (EFieldAccess (EVar "previous") "domainTop")) (EApp (EVar "domainKey") (EFieldAccess (EVar "v") "domainTop"))) (EBinOp "/=" (EFieldAccess (EVar "previous") "patternOnly") (EFieldAccess (EVar "v") "patternOnly"))) (EBinOp "/=" (EFieldAccess (EVar "previous") "sourceName") (EFieldAccess (EVar "v") "sourceName")))) (ELit (LString "inconsistent frozen variable metadata")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "M.set") (EFieldAccess (EVar "v") "localId")) (EVar "v")) (EVar "variables")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "<" (EFieldAccess (EVar "v") "localId") (ELit (LInt 0)))) (ELit (LString "negative frozen variable id"))) (EApp (EApp (EVar "problem") (EBinOp "/=" (EApp (EVar "domainKey") (EVar "top")) (EApp (EVar "domainKey") (EFieldAccess (EVar "v") "domainTop")))) (ELit (LString "variable domain mismatch")))) (EApp (EVar "topProblems") (EFieldAccess (EVar "v") "domainTop"))) (EVar "metadata"))))))
(DFunDef false "validateAuthority" ((PVar "top") (PVar "variables") (PCon "FrozenJoin" (PVar "members"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "mapAccumL") (EApp (EVar "validateAuthority") (EVar "top"))) (EVar "variables")) (EVar "members"))) (DoExpr (ETuple (EVar "more") (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EVar "defects"))))))
(DFunDef false "validateAuthority" ((PCon "PProduct" (PVar "schema")) (PVar "variables") (PCon "FrozenProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAxes") (EVar "schema")) (EVar "variables")) (EVar "axes"))) (DoExpr (ETuple (EVar "more") (EBinOp "++" (EApp (EVar "axisNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "axes"))) (EVar "defects"))))))
(DFunDef false "validateAuthority" (PWild (PVar "variables") (PCon "FrozenProduct" PWild)) (ETuple (EVar "variables") (EListLit (EApp (EVar "ManifestDefect") (ELit (LString "product authority in non-product domain"))))))
(DTypeSig false "validateAxes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority"))) (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyCon "List") (TyCon "ManifestDefect")))))))
(DFunDef false "validateAxes" ((PList) (PVar "variables") (PList)) (ETuple (EVar "variables") (EListLit)))
(DFunDef false "validateAxes" ((PCons (PTuple (PVar "name") (PVar "top")) (PVar "schema")) (PVar "variables") (PCons (PTuple (PVar "axis") (PVar "authority")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "defects")) (EApp (EApp (EApp (EVar "validateAuthority") (EVar "top")) (EVar "variables")) (EVar "authority"))) (DoLet false false (PTuple (PVar "done") (PVar "later")) (EApp (EApp (EApp (EVar "validateAxes") (EVar "schema")) (EVar "more")) (EVar "rest"))) (DoExpr (ETuple (EVar "done") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "problem") (EBinOp "/=" (EVar "name") (EVar "axis"))) (ELit (LString "product axis order mismatch"))) (EVar "defects")) (EVar "later"))))))
(DFunDef false "validateAxes" (PWild (PVar "variables") PWild) (ETuple (EVar "variables") (EListLit (EApp (EVar "ManifestDefect") (ELit (LString "product axis schema mismatch"))))))
