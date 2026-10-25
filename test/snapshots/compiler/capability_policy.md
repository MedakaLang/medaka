# META
source_lines=173
stages=DESUGAR,MARK
# SOURCE
-- Admission compares a frozen demand with constant grants; it never solves cells.
import frontend.ast.{EffParamTy, TyConOrigin(..)}
import types.capability_manifest.{
  CapabilityManifest, FrozenAtom(..), FrozenAuthority(..), FrozenVariable
}
import types.effect_domain.{
  Param(..), dsub, dsubAny, dantichain, domainKey, isSubTop, subTopOf
}
import types.effect_param_decode.{decodeWrittenParam, dtopIn}
import types.effect_rows.{EffLabel(..)}
import types.target_profile.{hostLabels}
import support.util.{filterList, joinWith, allList, anyList}
import map as M
import map.{Map(..)}

public export data PolicyVerdict =
  | PolicyAdmitted
  | PolicyRefused (List String) (List String)
public export data Permit = Permitted | Forbidden | Malformed String

export
manifestAllowed : List (String, Param) ->
  CapabilityManifest ->
  List (String, EffParamTy) ->
  PolicyVerdict
manifestAllowed domains manifest policy =
  let judgments = map (a => (a, permitFrozen domains a policy)) manifest.atoms
  let refused =
    filterList
      (j => match snd j
        Permitted => False
        _ => True)
      judgments
  match refused
    [] => PolicyAdmitted
    _ =>
      PolicyRefused
        (map (j => (fst j).label) refused)
        (flatMap malformedLine judgments
          ++ flatMap (notProvenLine policy) judgments)

malformedLine : (FrozenAtom, Permit) -> List String
malformedLine (a, Malformed message) =
  ["   policy entry for \{a.label}: \{message}\n"]
malformedLine _ = []

export
permitFrozen : List (String, Param) ->
  FrozenAtom ->
  List (String, EffParamTy) ->
  Permit
permitFrozen domains atom policy = match (
  atom.label == "IO",
  entriesFor atom policy,
)
  (True, []) =>
    firstNotPermitted
      (map
        (label =>
          permitFrozen
            domains
            FrozenAtom {
              label = label,
              origin = OriginBuiltin,
              domainTop = dtopIn domains (EffLabel label OriginBuiltin),
              authority =
                FrozenConst (dtopIn domains (EffLabel label OriginBuiltin)),
            }
            policy)
        hostLabels)
  (_, []) => Forbidden
  (_, written) =>
    match (allOk
      (map
        (decodeWrittenParam domains (EffLabel atom.label atom.origin))
        written))
      Err message => Malformed message
      Ok grants =>
        if within atom.authority (dantichain grants) then
          Permitted
        else
          Forbidden

-- A symbolic tuple needs one covering tuple. Constant products may instead be
-- covered together by several grants through the domain's exact union rule.
within : FrozenAuthority -> List Param -> Bool
within (FrozenJoin members) grants = allList (m => within m grants) members
within (FrozenConst p) grants = dsubAny p grants
within authority grants = anyList (withinOne authority) grants

withinOne : FrozenAuthority -> Param -> Bool
withinOne _ grant
  | isSubTop grant = True
withinOne (FrozenVar _) _ = False
withinOne (FrozenProduct axes) (PProduct schema) = axesWithin axes schema
withinOne (FrozenConst p) grant = dsub p grant
withinOne (FrozenJoin members) grant = allList (m => withinOne m grant) members
withinOne _ _ = False

axesWithin : List (String, FrozenAuthority) -> List (String, Param) -> Bool
axesWithin [] [] = True
axesWithin ((name, authority) :: rest) ((axis, grant) :: schema) =
  name == axis
    && domainKey (authorityTop authority) == domainKey grant
    && within authority [grant]
    && axesWithin rest schema
axesWithin _ _ = False

authorityTop : FrozenAuthority -> Param
authorityTop (FrozenConst p) = subTopOf p
authorityTop (FrozenVar v) = v.domainTop
authorityTop (FrozenProduct axes) =
  PProduct (map (a => (fst a, authorityTop (snd a))) axes)
authorityTop (FrozenJoin (m :: _)) = authorityTop m
authorityTop (FrozenJoin []) = PUnit

firstNotPermitted : List Permit -> Permit
firstNotPermitted [] = Permitted
firstNotPermitted (Permitted :: rest) = firstNotPermitted rest
firstNotPermitted (p :: _) = p

entriesFor : FrozenAtom -> List (String, EffParamTy) -> List EffParamTy
entriesFor atom policy =
  let qualified = match atom.origin
    OriginModule m => "\{m}.\{atom.label}"
    _ => atom.label
  match entriesUnder qualified policy
    [] => entriesUnder atom.label policy
    entries => entries

entriesUnder : String -> List (String, EffParamTy) -> List EffParamTy
entriesUnder key policy =
  map snd (filterList (entry => fst entry == key) policy)

notProvenLine : List (String, EffParamTy) -> (FrozenAtom, Permit) -> List String
notProvenLine policy (atom, Forbidden) =
  let vars = M.values (variablesInto atom.authority Tip)
  match (vars, entriesFor atom policy)
    ([], _) => []
    (_, []) => []
    _ =>
      let demands =
        joinWith ", " (map (v => "\{atom.label} \{variableName v}") vars)
      ["   not proven: \{demands} (\{variablesWhy vars})\n"]
notProvenLine _ _ = []

variablesInto : FrozenAuthority ->
  Map Int FrozenVariable ->
  Map Int FrozenVariable
variablesInto (FrozenVar v) vars = M.set v.localId v vars
variablesInto (FrozenJoin members) vars =
  fold (acc m => variablesInto m acc) vars members
variablesInto (FrozenProduct axes) vars =
  fold (acc a => variablesInto (snd a) acc) vars axes
variablesInto _ vars = vars

variableName : FrozenVariable -> String
variableName v = match v.sourceName
  Some name => name
  None => "k" ++ intToString v.localId

variablesWhy : List FrozenVariable -> String
variablesWhy vars =
  let names = map (v => "`" ++ variableName v ++ "`") vars
  match names
    [one] => "authority variable \{one}"
    _ => "authority variables \{joinWith ", " names}"

export
allOk : List (Result String a) -> Result String (List a)
allOk [] = Ok []
allOk ((Err message) :: _) = Err message
allOk ((Ok value) :: rest) = map (value :: _) (allOk rest)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" false) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "dsub" false) (mem "dsubAny" false) (mem "dantichain" false) (mem "domainKey" false) (mem "isSubTop" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "decodeWrittenParam" false) (mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "joinWith" false) (mem "allList" false) (mem "anyList" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "PolicyVerdict" () ((variant "PolicyAdmitted" (ConPos)) (variant "PolicyRefused" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig true "manifestAllowed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "CapabilityManifest") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict")))))
(DFunDef false "manifestAllowed" ((PVar "domains") (PVar "manifest") (PVar "policy")) (EBlock (DoLet false false (PVar "judgments") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EVar "a") (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (EVar "a")) (EVar "policy"))))) (EFieldAccess (EVar "manifest") "atoms"))) (DoLet false false (PVar "refused") (EApp (EApp (EVar "filterList") (ELam ((PVar "j")) (EMatch (EApp (EVar "snd") (EVar "j")) (arm (PCon "Permitted") () (EVar "False")) (arm PWild () (EVar "True"))))) (EVar "judgments"))) (DoExpr (EMatch (EVar "refused") (arm (PList) () (EVar "PolicyAdmitted")) (arm PWild () (EApp (EApp (EVar "PolicyRefused") (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EFieldAccess (EApp (EVar "fst") (EVar "j")) "label"))) (EVar "refused"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "malformedLine")) (EVar "judgments")) (EApp (EApp (EVar "flatMap") (EApp (EVar "notProvenLine") (EVar "policy"))) (EVar "judgments")))))))))
(DTypeSig false "malformedLine" (TyFun (TyTuple (TyCon "FrozenAtom") (TyCon "Permit")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "malformedLine" ((PTuple (PVar "a") (PCon "Malformed" (PVar "message")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EVar "display") (EFieldAccess (EVar "a") "label"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "message"))) (ELit (LString "\n")))))
(DFunDef false "malformedLine" (PWild) (EListLit))
(DTypeSig true "permitFrozen" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "FrozenAtom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))))
(DFunDef false "permitFrozen" ((PVar "domains") (PVar "atom") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EFieldAccess (EVar "atom") "label") (ELit (LString "IO"))) (EApp (EApp (EVar "entriesFor") (EVar "atom")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "firstNotPermitted") (EApp (EApp (EVar "map") (ELam ((PVar "label")) (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (ERecordCreate "FrozenAtom" ((fa "label" (EVar "label")) (fa "origin" (EVar "OriginBuiltin")) (fa "domainTop" (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "OriginBuiltin")))) (fa "authority" (EApp (EVar "FrozenConst") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "OriginBuiltin")))))))) (EVar "policy")))) (EVar "hostLabels")))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EVar "map") (EApp (EApp (EVar "decodeWrittenParam") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "atom") "label")) (EFieldAccess (EVar "atom") "origin")))) (EVar "written"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Malformed") (EVar "message"))) (arm (PCon "Ok" (PVar "grants")) () (EIf (EApp (EApp (EVar "within") (EFieldAccess (EVar "atom") "authority")) (EApp (EVar "dantichain") (EVar "grants"))) (EVar "Permitted") (EVar "Forbidden")))))))
(DTypeSig false "within" (TyFun (TyCon "FrozenAuthority") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "within" ((PCon "FrozenJoin" (PVar "members")) (PVar "grants")) (EApp (EApp (EVar "allList") (ELam ((PVar "m")) (EApp (EApp (EVar "within") (EVar "m")) (EVar "grants")))) (EVar "members")))
(DFunDef false "within" ((PCon "FrozenConst" (PVar "p")) (PVar "grants")) (EApp (EApp (EVar "dsubAny") (EVar "p")) (EVar "grants")))
(DFunDef false "within" ((PVar "authority") (PVar "grants")) (EApp (EApp (EVar "anyList") (EApp (EVar "withinOne") (EVar "authority"))) (EVar "grants")))
(DTypeSig false "withinOne" (TyFun (TyCon "FrozenAuthority") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "withinOne" (PWild (PVar "grant")) (EIf (EApp (EVar "isSubTop") (EVar "grant")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "withinOne" ((PCon "FrozenVar" PWild) PWild) (EVar "False"))
(DFunDef false "withinOne" ((PCon "FrozenProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) (EApp (EApp (EVar "axesWithin") (EVar "axes")) (EVar "schema")))
(DFunDef false "withinOne" ((PCon "FrozenConst" (PVar "p")) (PVar "grant")) (EApp (EApp (EVar "dsub") (EVar "p")) (EVar "grant")))
(DFunDef false "withinOne" ((PCon "FrozenJoin" (PVar "members")) (PVar "grant")) (EApp (EApp (EVar "allList") (ELam ((PVar "m")) (EApp (EApp (EVar "withinOne") (EVar "m")) (EVar "grant")))) (EVar "members")))
(DFunDef false "withinOne" (PWild PWild) (EVar "False"))
(DTypeSig false "axesWithin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool"))))
(DFunDef false "axesWithin" ((PList) (PList)) (EVar "True"))
(DFunDef false "axesWithin" ((PCons (PTuple (PVar "name") (PVar "authority")) (PVar "rest")) (PCons (PTuple (PVar "axis") (PVar "grant")) (PVar "schema"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "axis")) (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authorityTop") (EVar "authority"))) (EApp (EVar "domainKey") (EVar "grant")))) (EApp (EApp (EVar "within") (EVar "authority")) (EListLit (EVar "grant")))) (EApp (EApp (EVar "axesWithin") (EVar "rest")) (EVar "schema"))))
(DFunDef false "axesWithin" (PWild PWild) (EVar "False"))
(DTypeSig false "authorityTop" (TyFun (TyCon "FrozenAuthority") (TyCon "Param")))
(DFunDef false "authorityTop" ((PCon "FrozenConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authorityTop" ((PCon "FrozenVar" (PVar "v"))) (EFieldAccess (EVar "v") "domainTop"))
(DFunDef false "authorityTop" ((PCon "FrozenProduct" (PVar "axes"))) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authorityTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DFunDef false "authorityTop" ((PCon "FrozenJoin" (PCons (PVar "m") PWild))) (EApp (EVar "authorityTop") (EVar "m")))
(DFunDef false "authorityTop" ((PCon "FrozenJoin" (PList))) (EVar "PUnit"))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "entriesFor" (TyFun (TyCon "FrozenAtom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesFor" ((PVar "atom") (PVar "policy")) (EBlock (DoLet false false (PVar "qualified") (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EFieldAccess (EVar "atom") "label"))) (ELit (LString "")))) (arm PWild () (EFieldAccess (EVar "atom") "label")))) (DoExpr (EMatch (EApp (EApp (EVar "entriesUnder") (EVar "qualified")) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EFieldAccess (EVar "atom") "label")) (EVar "policy"))) (arm (PVar "entries") () (EVar "entries"))))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "==" (EApp (EVar "fst") (EVar "entry")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "notProvenLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyTuple (TyCon "FrozenAtom") (TyCon "Permit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLine" ((PVar "policy") (PTuple (PVar "atom") (PCon "Forbidden"))) (EBlock (DoLet false false (PVar "vars") (EApp (EVar "M.values") (EApp (EApp (EVar "variablesInto") (EFieldAccess (EVar "atom") "authority")) (EVar "Tip")))) (DoExpr (EMatch (ETuple (EVar "vars") (EApp (EApp (EVar "entriesFor") (EVar "atom")) (EVar "policy"))) (arm (PTuple (PList) PWild) () (EListLit)) (arm (PTuple PWild (PList)) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "demands") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "atom") "label"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "variableName") (EVar "v")))) (ELit (LString ""))))) (EVar "vars")))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EVar "display") (EVar "demands"))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "variablesWhy") (EVar "vars")))) (ELit (LString ")\n")))))))))))
(DFunDef false "notProvenLine" (PWild PWild) (EListLit))
(DTypeSig false "variablesInto" (TyFun (TyCon "FrozenAuthority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")))))
(DFunDef false "variablesInto" ((PCon "FrozenVar" (PVar "v")) (PVar "vars")) (EApp (EApp (EApp (EVar "M.set") (EFieldAccess (EVar "v") "localId")) (EVar "v")) (EVar "vars")))
(DFunDef false "variablesInto" ((PCon "FrozenJoin" (PVar "members")) (PVar "vars")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EVar "variablesInto") (EVar "m")) (EVar "acc")))) (EVar "vars")) (EVar "members")))
(DFunDef false "variablesInto" ((PCon "FrozenProduct" (PVar "axes")) (PVar "vars")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "variablesInto") (EApp (EVar "snd") (EVar "a"))) (EVar "acc")))) (EVar "vars")) (EVar "axes")))
(DFunDef false "variablesInto" (PWild (PVar "vars")) (EVar "vars"))
(DTypeSig false "variableName" (TyFun (TyCon "FrozenVariable") (TyCon "String")))
(DFunDef false "variableName" ((PVar "v")) (EMatch (EFieldAccess (EVar "v") "sourceName") (arm (PCon "Some" (PVar "name")) () (EVar "name")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EFieldAccess (EVar "v") "localId"))))))
(DTypeSig false "variablesWhy" (TyFun (TyApp (TyCon "List") (TyCon "FrozenVariable")) (TyCon "String")))
(DFunDef false "variablesWhy" ((PVar "vars")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "variableName") (EVar "v"))) (ELit (LString "`"))))) (EVar "vars"))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EVar "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig true "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "message")) PWild)) (EApp (EVar "Err") (EVar "message")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "value") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" false) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "dsub" false) (mem "dsubAny" false) (mem "dantichain" false) (mem "domainKey" false) (mem "isSubTop" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "decodeWrittenParam" false) (mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "joinWith" false) (mem "allList" false) (mem "anyList" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "PolicyVerdict" () ((variant "PolicyAdmitted" (ConPos)) (variant "PolicyRefused" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig true "manifestAllowed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "CapabilityManifest") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict")))))
(DFunDef false "manifestAllowed" ((PVar "domains") (PVar "manifest") (PVar "policy")) (EBlock (DoLet false false (PVar "judgments") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EVar "a") (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (EVar "a")) (EVar "policy"))))) (EFieldAccess (EVar "manifest") "atoms"))) (DoLet false false (PVar "refused") (EApp (EApp (EVar "filterList") (ELam ((PVar "j")) (EMatch (EApp (EVar "snd") (EVar "j")) (arm (PCon "Permitted") () (EVar "False")) (arm PWild () (EVar "True"))))) (EVar "judgments"))) (DoExpr (EMatch (EVar "refused") (arm (PList) () (EVar "PolicyAdmitted")) (arm PWild () (EApp (EApp (EVar "PolicyRefused") (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EFieldAccess (EApp (EVar "fst") (EVar "j")) "label"))) (EVar "refused"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "malformedLine")) (EVar "judgments")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "notProvenLine") (EVar "policy"))) (EVar "judgments")))))))))
(DTypeSig false "malformedLine" (TyFun (TyTuple (TyCon "FrozenAtom") (TyCon "Permit")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "malformedLine" ((PTuple (PVar "a") (PCon "Malformed" (PVar "message")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "a") "label"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString "\n")))))
(DFunDef false "malformedLine" (PWild) (EListLit))
(DTypeSig true "permitFrozen" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "FrozenAtom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))))
(DFunDef false "permitFrozen" ((PVar "domains") (PVar "atom") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EFieldAccess (EVar "atom") "label") (ELit (LString "IO"))) (EApp (EApp (EVar "entriesFor") (EVar "atom")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "firstNotPermitted") (EApp (EApp (EMethodRef "map") (ELam ((PVar "label")) (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (ERecordCreate "FrozenAtom" ((fa "label" (EVar "label")) (fa "origin" (EVar "OriginBuiltin")) (fa "domainTop" (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "OriginBuiltin")))) (fa "authority" (EApp (EVar "FrozenConst") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EVar "label")) (EVar "OriginBuiltin")))))))) (EVar "policy")))) (EVar "hostLabels")))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "decodeWrittenParam") (EVar "domains")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "atom") "label")) (EFieldAccess (EVar "atom") "origin")))) (EVar "written"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Malformed") (EVar "message"))) (arm (PCon "Ok" (PVar "grants")) () (EIf (EApp (EApp (EVar "within") (EFieldAccess (EVar "atom") "authority")) (EApp (EVar "dantichain") (EVar "grants"))) (EVar "Permitted") (EVar "Forbidden")))))))
(DTypeSig false "within" (TyFun (TyCon "FrozenAuthority") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "within" ((PCon "FrozenJoin" (PVar "members")) (PVar "grants")) (EApp (EApp (EVar "allList") (ELam ((PVar "m")) (EApp (EApp (EVar "within") (EVar "m")) (EVar "grants")))) (EVar "members")))
(DFunDef false "within" ((PCon "FrozenConst" (PVar "p")) (PVar "grants")) (EApp (EApp (EVar "dsubAny") (EVar "p")) (EVar "grants")))
(DFunDef false "within" ((PVar "authority") (PVar "grants")) (EApp (EApp (EVar "anyList") (EApp (EVar "withinOne") (EVar "authority"))) (EVar "grants")))
(DTypeSig false "withinOne" (TyFun (TyCon "FrozenAuthority") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "withinOne" (PWild (PVar "grant")) (EIf (EApp (EVar "isSubTop") (EVar "grant")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "withinOne" ((PCon "FrozenVar" PWild) PWild) (EVar "False"))
(DFunDef false "withinOne" ((PCon "FrozenProduct" (PVar "axes")) (PCon "PProduct" (PVar "schema"))) (EApp (EApp (EVar "axesWithin") (EVar "axes")) (EVar "schema")))
(DFunDef false "withinOne" ((PCon "FrozenConst" (PVar "p")) (PVar "grant")) (EApp (EApp (EVar "dsub") (EVar "p")) (EVar "grant")))
(DFunDef false "withinOne" ((PCon "FrozenJoin" (PVar "members")) (PVar "grant")) (EApp (EApp (EVar "allList") (ELam ((PVar "m")) (EApp (EApp (EVar "withinOne") (EVar "m")) (EVar "grant")))) (EVar "members")))
(DFunDef false "withinOne" (PWild PWild) (EVar "False"))
(DTypeSig false "axesWithin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenAuthority"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool"))))
(DFunDef false "axesWithin" ((PList) (PList)) (EVar "True"))
(DFunDef false "axesWithin" ((PCons (PTuple (PVar "name") (PVar "authority")) (PVar "rest")) (PCons (PTuple (PVar "axis") (PVar "grant")) (PVar "schema"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "axis")) (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authorityTop") (EVar "authority"))) (EApp (EVar "domainKey") (EVar "grant")))) (EApp (EApp (EVar "within") (EVar "authority")) (EListLit (EVar "grant")))) (EApp (EApp (EVar "axesWithin") (EVar "rest")) (EVar "schema"))))
(DFunDef false "axesWithin" (PWild PWild) (EVar "False"))
(DTypeSig false "authorityTop" (TyFun (TyCon "FrozenAuthority") (TyCon "Param")))
(DFunDef false "authorityTop" ((PCon "FrozenConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authorityTop" ((PCon "FrozenVar" (PVar "v"))) (EFieldAccess (EVar "v") "domainTop"))
(DFunDef false "authorityTop" ((PCon "FrozenProduct" (PVar "axes"))) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authorityTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DFunDef false "authorityTop" ((PCon "FrozenJoin" (PCons (PVar "m") PWild))) (EApp (EVar "authorityTop") (EVar "m")))
(DFunDef false "authorityTop" ((PCon "FrozenJoin" (PList))) (EVar "PUnit"))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "entriesFor" (TyFun (TyCon "FrozenAtom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesFor" ((PVar "atom") (PVar "policy")) (EBlock (DoLet false false (PVar "qualified") (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EFieldAccess (EVar "atom") "label"))) (ELit (LString "")))) (arm PWild () (EFieldAccess (EVar "atom") "label")))) (DoExpr (EMatch (EApp (EApp (EVar "entriesUnder") (EVar "qualified")) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EFieldAccess (EVar "atom") "label")) (EVar "policy"))) (arm (PVar "entries") () (EVar "entries"))))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "==" (EApp (EVar "fst") (EVar "entry")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "notProvenLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyTuple (TyCon "FrozenAtom") (TyCon "Permit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLine" ((PVar "policy") (PTuple (PVar "atom") (PCon "Forbidden"))) (EBlock (DoLet false false (PVar "vars") (EApp (EVar "M.values") (EApp (EApp (EVar "variablesInto") (EFieldAccess (EVar "atom") "authority")) (EVar "Tip")))) (DoExpr (EMatch (ETuple (EVar "vars") (EApp (EApp (EVar "entriesFor") (EVar "atom")) (EVar "policy"))) (arm (PTuple (PList) PWild) () (EListLit)) (arm (PTuple PWild (PList)) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "demands") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "atom") "label"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "variableName") (EVar "v")))) (ELit (LString ""))))) (EVar "vars")))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EMethodRef "display") (EVar "demands"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "variablesWhy") (EVar "vars")))) (ELit (LString ")\n")))))))))))
(DFunDef false "notProvenLine" (PWild PWild) (EListLit))
(DTypeSig false "variablesInto" (TyFun (TyCon "FrozenAuthority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "FrozenVariable")))))
(DFunDef false "variablesInto" ((PCon "FrozenVar" (PVar "v")) (PVar "vars")) (EApp (EApp (EApp (EVar "M.set") (EFieldAccess (EVar "v") "localId")) (EVar "v")) (EVar "vars")))
(DFunDef false "variablesInto" ((PCon "FrozenJoin" (PVar "members")) (PVar "vars")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EVar "variablesInto") (EVar "m")) (EVar "acc")))) (EVar "vars")) (EVar "members")))
(DFunDef false "variablesInto" ((PCon "FrozenProduct" (PVar "axes")) (PVar "vars")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "variablesInto") (EApp (EVar "snd") (EVar "a"))) (EVar "acc")))) (EVar "vars")) (EVar "axes")))
(DFunDef false "variablesInto" (PWild (PVar "vars")) (EVar "vars"))
(DTypeSig false "variableName" (TyFun (TyCon "FrozenVariable") (TyCon "String")))
(DFunDef false "variableName" ((PVar "v")) (EMatch (EFieldAccess (EVar "v") "sourceName") (arm (PCon "Some" (PVar "name")) () (EVar "name")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EFieldAccess (EVar "v") "localId"))))))
(DTypeSig false "variablesWhy" (TyFun (TyApp (TyCon "List") (TyCon "FrozenVariable")) (TyCon "String")))
(DFunDef false "variablesWhy" ((PVar "vars")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "variableName") (EVar "v"))) (ELit (LString "`"))))) (EVar "vars"))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EMethodRef "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig true "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "message")) PWild)) (EApp (EVar "Err") (EVar "message")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "value")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "value") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
