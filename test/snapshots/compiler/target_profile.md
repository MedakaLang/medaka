# META
source_lines=254
stages=DESUGAR,MARK
# SOURCE
-- The one table of target profiles: a profile is a backend, the host ABI that
-- backend lowers to, and the grant set of effect labels the host can honour.
-- Design: docs/design/TARGETS-DESIGN.md §8.1.
--
-- A grant is written the way `check-policy` writes a policy entry: a label and
-- its domain, the label's whole domain being `EPTop`.  `native` and `wasm` are
-- aliases of a row, never rows of their own.

import frontend.ast.{EffParamTy(..)}
import support.ordmap.{OrdMap, omEmpty, omFromPairs, omLookup}
import support.util.{isNonEmptyL}
import string.{join}

public export data Backend =
  | BackendLlvm
  | BackendWasmgc
  | BackendEval
  deriving (Eq, Debug)

-- name, backend, host ABI, grants.
public export data TargetProfile =
  TargetProfile String Backend String (List (String, EffParamTy))

export
profileName : TargetProfile -> String
profileName (TargetProfile n _ _ _) = n

export
profileBackend : TargetProfile -> Backend
profileBackend (TargetProfile _ b _ _) = b

profileAbi : TargetProfile -> String
profileAbi (TargetProfile _ _ a _) = a

export
profileGrants : TargetProfile -> List (String, EffParamTy)
profileGrants (TargetProfile _ _ _ g) = g

-- The host a foreign call is bound to under the profile, as an extern's `bind`
-- clause names it: `c` on llvm, `js` on wasmgc.  The interpreter binds foreign
-- calls to no host.
export
profileBindingHost : TargetProfile -> Option String
profileBindingHost p = match profileBackend p
  BackendLlvm => Some "c"
  BackendWasmgc => Some "js"
  BackendEval => None

-- Does the profile grant any part of this label's domain?
grantsLabel : TargetProfile -> String -> Bool
grantsLabel p label = any (g => fst g == label) (profileGrants p)

-- Can a program performing this label run under the profile?  `IO` is the
-- join of the host labels the profile grants (`ioJoinGrants`), so it is
-- reached exactly when that join is non-empty.
export
reachesLabel : TargetProfile -> String -> Bool
reachesLabel p "IO" = isNonEmptyL (ioJoinGrants (Some p))
reachesLabel p label = grantsLabel p label

-- The labels of an extern the profile does not reach.  A program using the
-- extern performs every label it declares, so the extern is usable under the
-- profile exactly when this is empty.
export
withheldLabels : TargetProfile -> List String -> List String
withheldLabels p labels = filter (l => not (reachesLabel p l)) labels

export
backendName : Backend -> String
backendName BackendLlvm = "llvm"
backendName BackendWasmgc = "wasmgc"
backendName BackendEval = "eval"

-- Each label granted over its whole domain.
wholeDomain : List String -> List (String, EffParamTy)
wholeDomain labels = map (l => (l, EPTop)) labels

-- The eleven host labels: the labels `IO` is the join of, and with `FFI` the
-- only labels a profile gates.  `FFI` is not one of them: an `<IO>` bound must not
-- subsume an `<FFI>`-performing body, because FFI crosses a trust boundary the alias
-- is not meant to paper over (#2071).
export
hostLabels : List String
hostLabels = [
  "Stdout",
  "Stderr",
  "Stdin",
  "Clock",
  "Env",
  "Exec",
  "Rand",
  "FileRead",
  "FileWrite",
  "Net",
  "Signal",
]

-- What `IO` joins under a profile: its grants of host labels, each with the
-- parameter it grants.  With no profile it is every host label over its whole
-- domain.
export
ioJoinGrants : Option TargetProfile -> List (String, EffParamTy)
ioJoinGrants None = wholeDomain hostLabels
ioJoinGrants (Some p) =
  filter (g => any (== fst g) hostLabels) (profileGrants p)

-- `wasmgc/edge` grants `Net` over its whole domain, so its `IO` join carries it:
-- the host's `net` slice serves `fetchText`, and the socket externs stay
-- unprovided on wasm. `wasmgc/node` and `wasmgc/browser-worker` do not grant it.
-- `wasmgc/wasi-p2` is a seam with nothing built, so it grants no host label.
-- Every profile with a host grants `FFI`, and `eval/run` does not: whether a
-- foreign call can run is the extern's binding for the profile's host
-- (`profileBindingHost`), judged by the target check.
profileRows : List TargetProfile
profileRows = [
  TargetProfile
    "llvm/native-posix"
    BackendLlvm
    "C symbols"
    (wholeDomain (hostLabels ++ ["FFI"])),
  evalRunProfile,
  TargetProfile
    "wasmgc/node"
    BackendWasmgc
    "env"
    (wholeDomain [
      "Stdout",
      "Stderr",
      "Stdin",
      "Clock",
      "Env",
      "Rand",
      "FileRead",
      "FileWrite",
      "FFI",
    ]),
  TargetProfile
    "wasmgc/browser-worker"
    BackendWasmgc
    "env"
    (wholeDomain [
      "Stdout", "Stderr", "Clock", "Rand", "FileRead", "FileWrite", "FFI"
    ]),
  TargetProfile
    "wasmgc/edge"
    BackendWasmgc
    "env"
    (wholeDomain ["Stdout", "Stderr", "Clock", "Rand", "Net", "FFI"]),
  TargetProfile "wasmgc/wasi-p2" BackendWasmgc "WIT" (wholeDomain ["FFI"]),
]

evalRunProfile : TargetProfile
evalRunProfile =
  TargetProfile
    "eval/run"
    BackendEval
    "ioExternBindings"
    (wholeDomain hostLabels)

aliasRows : List (String, String)
aliasRows = [("native", "llvm/native-posix"), ("wasm", "wasmgc/node")]

-- Keyed by every name a user can write: each profile's own and each alias.
profileIndex : OrdMap TargetProfile
profileIndex =
  omFromPairs (map (p => (profileName p, p)) profileRows) omEmpty
    |> withAliases aliasRows

withAliases : List (String, String) ->
  OrdMap TargetProfile ->
  OrdMap TargetProfile
withAliases aliases idx =
  omFromPairs (filterMap (a => aliased a idx) aliases) idx

aliased : (String, String) ->
  OrdMap TargetProfile ->
  Option (String, TargetProfile)
aliased (alias, target) idx = map (p => (alias, p)) (omLookup target idx)

-- The profile names, in table order.
export
profileNames : List String
profileNames = map profileName profileRows

-- Every name a user can write: the profile names, then the aliases.
knownNames : List String
knownNames = profileNames ++ map fst aliasRows

export
lookupProfile : String -> Result String TargetProfile
lookupProfile name = match omLookup name profileIndex
  Some p => Ok p
  None => Err "unknown target `\{name}` (known: \{join ", " knownNames})"

-- The profile a verb carries: the flag wins over the manifest's
-- `[target] profile`; with neither, there is none.
export
selectProfile : Option String ->
  Option String ->
  Result String (Option TargetProfile)
selectProfile (Some flag) _ = map Some (lookupProfile flag)
selectProfile None (Some fromManifest) = map Some (lookupProfile fromManifest)
selectProfile None None = Ok None

-- Can `medaka build` emit for this profile?
export
buildable : TargetProfile -> Bool
buildable p = profileBackend p /= BackendEval

export
buildableNames : List String
buildableNames =
  filter
    (n => match lookupProfile n
      Ok p => buildable p
      Err _ => False)
    knownNames

-- Is this label one a profile gates: a host label or `FFI`?  `IO` is not, since
-- under a profile it joins only what the profile grants (`ioJoinGrants`).  Any
-- other label is a user effect, admitted on every profile.
export
isGatedLabel : String -> Bool
isGatedLabel l = l == "FFI" || any (== l) hostLabels

-- What `medaka run` checks against: the interpreter's grants, narrowed to the
-- labels the selected profile also grants.  `eval/run` grants each of its
-- labels over the whole domain, so the selected profile's own entries for
-- those labels are the intersection.
export
runProfile : Option TargetProfile -> TargetProfile
runProfile None = evalRunProfile
runProfile (Some p) =
  if profileName p == profileName evalRunProfile then
    p
  else
    TargetProfile
      "\{profileName evalRunProfile} ∩ \{profileName p}"
      BackendEval
      (profileAbi evalRunProfile)
      (filter (g => grantsLabel evalRunProfile (fst g)) (profileGrants p))

-- The profile `check`, `run` and `build` resolved from `--target` or the
-- manifest.  `build` always selects one, so its emitter child always checks.
export
selectedProfile : Ref (Option TargetProfile)
selectedProfile = Ref None

-- How `build` hands its emitter child the selected profile's name.  A child
-- started without it checks nothing, as every direct caller of an emit entry
-- expects.
export
targetProfileEnv : String
targetProfileEnv = "MEDAKA_TARGET_PROFILE"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "isNonEmptyL" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DData Public "Backend" () ((variant "BackendLlvm" (ConPos)) (variant "BackendWasmgc" (ConPos)) (variant "BackendEval" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Backend")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "BackendLlvm") (PCon "BackendLlvm")) () (EVar "True")) (arm (PTuple (PCon "BackendWasmgc") (PCon "BackendWasmgc")) () (EVar "True")) (arm (PTuple (PCon "BackendEval") (PCon "BackendEval")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Backend")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "BackendLlvm") () (ELit (LString "BackendLlvm"))) (arm (PCon "BackendWasmgc") () (ELit (LString "BackendWasmgc"))) (arm (PCon "BackendEval") () (ELit (LString "BackendEval")))))))
(DData Public "TargetProfile" () ((variant "TargetProfile" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))) ())
(DTypeSig true "profileName" (TyFun (TyCon "TargetProfile") (TyCon "String")))
(DFunDef false "profileName" ((PCon "TargetProfile" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "profileBackend" (TyFun (TyCon "TargetProfile") (TyCon "Backend")))
(DFunDef false "profileBackend" ((PCon "TargetProfile" PWild (PVar "b") PWild PWild)) (EVar "b"))
(DTypeSig false "profileAbi" (TyFun (TyCon "TargetProfile") (TyCon "String")))
(DFunDef false "profileAbi" ((PCon "TargetProfile" PWild PWild (PVar "a") PWild)) (EVar "a"))
(DTypeSig true "profileGrants" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "profileGrants" ((PCon "TargetProfile" PWild PWild PWild (PVar "g"))) (EVar "g"))
(DTypeSig true "profileBindingHost" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "profileBindingHost" ((PVar "p")) (EMatch (EApp (EVar "profileBackend") (EVar "p")) (arm (PCon "BackendLlvm") () (EApp (EVar "Some") (ELit (LString "c")))) (arm (PCon "BackendWasmgc") () (EApp (EVar "Some") (ELit (LString "js")))) (arm (PCon "BackendEval") () (EVar "None"))))
(DTypeSig false "grantsLabel" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantsLabel" ((PVar "p") (PVar "label")) (EApp (EApp (EVar "any") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "fst") (EVar "g")) (EVar "label")))) (EApp (EVar "profileGrants") (EVar "p"))))
(DTypeSig true "reachesLabel" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "reachesLabel" ((PVar "p") (PLit (LString "IO"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "ioJoinGrants") (EApp (EVar "Some") (EVar "p")))))
(DFunDef false "reachesLabel" ((PVar "p") (PVar "label")) (EApp (EApp (EVar "grantsLabel") (EVar "p")) (EVar "label")))
(DTypeSig true "withheldLabels" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "withheldLabels" ((PVar "p") (PVar "labels")) (EApp (EApp (EVar "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "p")) (EVar "l"))))) (EVar "labels")))
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "BackendLlvm")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "BackendWasmgc")) (ELit (LString "wasmgc")))
(DFunDef false "backendName" ((PCon "BackendEval")) (ELit (LString "eval")))
(DTypeSig false "wholeDomain" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "wholeDomain" ((PVar "labels")) (EApp (EApp (EVar "map") (ELam ((PVar "l")) (ETuple (EVar "l") (EVar "EPTop")))) (EVar "labels")))
(DTypeSig true "hostLabels" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hostLabels" () (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "Net")) (ELit (LString "Signal"))))
(DTypeSig true "ioJoinGrants" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "ioJoinGrants" ((PCon "None")) (EApp (EVar "wholeDomain") (EVar "hostLabels")))
(DFunDef false "ioJoinGrants" ((PCon "Some" (PVar "p"))) (EApp (EApp (EVar "filter") (ELam ((PVar "g")) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EApp (EVar "fst") (EVar "g"))))) (EVar "hostLabels")))) (EApp (EVar "profileGrants") (EVar "p"))))
(DTypeSig false "profileRows" (TyApp (TyCon "List") (TyCon "TargetProfile")))
(DFunDef false "profileRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "llvm/native-posix"))) (EVar "BackendLlvm")) (ELit (LString "C symbols"))) (EApp (EVar "wholeDomain") (EBinOp "++" (EVar "hostLabels") (EListLit (ELit (LString "FFI")))))) (EVar "evalRunProfile") (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/node"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/browser-worker"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Clock")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/edge"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Clock")) (ELit (LString "Rand")) (ELit (LString "Net")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/wasi-p2"))) (EVar "BackendWasmgc")) (ELit (LString "WIT"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "FFI")))))))
(DTypeSig false "evalRunProfile" (TyCon "TargetProfile"))
(DFunDef false "evalRunProfile" () (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "eval/run"))) (EVar "BackendEval")) (ELit (LString "ioExternBindings"))) (EApp (EVar "wholeDomain") (EVar "hostLabels"))))
(DTypeSig false "aliasRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "aliasRows" () (EListLit (ETuple (ELit (LString "native")) (ELit (LString "llvm/native-posix"))) (ETuple (ELit (LString "wasm")) (ELit (LString "wasmgc/node")))))
(DTypeSig false "profileIndex" (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")))
(DFunDef false "profileIndex" () (EBinOp "|>" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "profileName") (EVar "p")) (EVar "p")))) (EVar "profileRows"))) (EVar "omEmpty")) (EApp (EVar "withAliases") (EVar "aliasRows"))))
(DTypeSig false "withAliases" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")) (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")))))
(DFunDef false "withAliases" ((PVar "aliases") (PVar "idx")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "filterMap") (ELam ((PVar "a")) (EApp (EApp (EVar "aliased") (EVar "a")) (EVar "idx")))) (EVar "aliases"))) (EVar "idx")))
(DTypeSig false "aliased" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TargetProfile"))))))
(DFunDef false "aliased" ((PTuple (PVar "alias") (PVar "target")) (PVar "idx")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "alias") (EVar "p")))) (EApp (EApp (EVar "omLookup") (EVar "target")) (EVar "idx"))))
(DTypeSig true "profileNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "profileNames" () (EApp (EApp (EVar "map") (EVar "profileName")) (EVar "profileRows")))
(DTypeSig false "knownNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "knownNames" () (EBinOp "++" (EVar "profileNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "aliasRows"))))
(DTypeSig true "lookupProfile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TargetProfile"))))
(DFunDef false "lookupProfile" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "profileIndex")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Ok") (EVar "p"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown target `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` (known: "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "knownNames")))) (ELit (LString ")")))))))
(DTypeSig true "selectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile"))))))
(DFunDef false "selectProfile" ((PCon "Some" (PVar "flag")) PWild) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "flag"))))
(DFunDef false "selectProfile" ((PCon "None") (PCon "Some" (PVar "fromManifest"))) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "fromManifest"))))
(DFunDef false "selectProfile" ((PCon "None") (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DTypeSig true "buildable" (TyFun (TyCon "TargetProfile") (TyCon "Bool")))
(DFunDef false "buildable" ((PVar "p")) (EBinOp "/=" (EApp (EVar "profileBackend") (EVar "p")) (EVar "BackendEval")))
(DTypeSig true "buildableNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "buildableNames" () (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EMatch (EApp (EVar "lookupProfile") (EVar "n")) (arm (PCon "Ok" (PVar "p")) () (EApp (EVar "buildable") (EVar "p"))) (arm (PCon "Err" PWild) () (EVar "False"))))) (EVar "knownNames")))
(DTypeSig true "isGatedLabel" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isGatedLabel" ((PVar "l")) (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString "FFI"))) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "hostLabels"))))
(DTypeSig true "runProfile" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyCon "TargetProfile")))
(DFunDef false "runProfile" ((PCon "None")) (EVar "evalRunProfile"))
(DFunDef false "runProfile" ((PCon "Some" (PVar "p"))) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EApp (EVar "profileName") (EVar "evalRunProfile"))) (EVar "p") (EApp (EApp (EApp (EApp (EVar "TargetProfile") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "evalRunProfile")))) (ELit (LString " ∩ "))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "p")))) (ELit (LString "")))) (EVar "BackendEval")) (EApp (EVar "profileAbi") (EVar "evalRunProfile"))) (EApp (EApp (EVar "filter") (ELam ((PVar "g")) (EApp (EApp (EVar "grantsLabel") (EVar "evalRunProfile")) (EApp (EVar "fst") (EVar "g"))))) (EApp (EVar "profileGrants") (EVar "p"))))))
(DTypeSig true "selectedProfile" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "selectedProfile" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "targetProfileEnv" (TyCon "String"))
(DFunDef false "targetProfileEnv" () (ELit (LString "MEDAKA_TARGET_PROFILE")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "isNonEmptyL" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DData Public "Backend" () ((variant "BackendLlvm" (ConPos)) (variant "BackendWasmgc" (ConPos)) (variant "BackendEval" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Backend")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "BackendLlvm") (PCon "BackendLlvm")) () (EVar "True")) (arm (PTuple (PCon "BackendWasmgc") (PCon "BackendWasmgc")) () (EVar "True")) (arm (PTuple (PCon "BackendEval") (PCon "BackendEval")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Backend")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "BackendLlvm") () (ELit (LString "BackendLlvm"))) (arm (PCon "BackendWasmgc") () (ELit (LString "BackendWasmgc"))) (arm (PCon "BackendEval") () (ELit (LString "BackendEval")))))))
(DData Public "TargetProfile" () ((variant "TargetProfile" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))) ())
(DTypeSig true "profileName" (TyFun (TyCon "TargetProfile") (TyCon "String")))
(DFunDef false "profileName" ((PCon "TargetProfile" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "profileBackend" (TyFun (TyCon "TargetProfile") (TyCon "Backend")))
(DFunDef false "profileBackend" ((PCon "TargetProfile" PWild (PVar "b") PWild PWild)) (EVar "b"))
(DTypeSig false "profileAbi" (TyFun (TyCon "TargetProfile") (TyCon "String")))
(DFunDef false "profileAbi" ((PCon "TargetProfile" PWild PWild (PVar "a") PWild)) (EVar "a"))
(DTypeSig true "profileGrants" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "profileGrants" ((PCon "TargetProfile" PWild PWild PWild (PVar "g"))) (EVar "g"))
(DTypeSig true "profileBindingHost" (TyFun (TyCon "TargetProfile") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "profileBindingHost" ((PVar "p")) (EMatch (EApp (EVar "profileBackend") (EVar "p")) (arm (PCon "BackendLlvm") () (EApp (EVar "Some") (ELit (LString "c")))) (arm (PCon "BackendWasmgc") () (EApp (EVar "Some") (ELit (LString "js")))) (arm (PCon "BackendEval") () (EVar "None"))))
(DTypeSig false "grantsLabel" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantsLabel" ((PVar "p") (PVar "label")) (EApp (EApp (EDictApp "any") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "fst") (EVar "g")) (EVar "label")))) (EApp (EVar "profileGrants") (EVar "p"))))
(DTypeSig true "reachesLabel" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "reachesLabel" ((PVar "p") (PLit (LString "IO"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "ioJoinGrants") (EApp (EVar "Some") (EVar "p")))))
(DFunDef false "reachesLabel" ((PVar "p") (PVar "label")) (EApp (EApp (EVar "grantsLabel") (EVar "p")) (EVar "label")))
(DTypeSig true "withheldLabels" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "withheldLabels" ((PVar "p") (PVar "labels")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "p")) (EVar "l"))))) (EVar "labels")))
(DTypeSig true "backendName" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "backendName" ((PCon "BackendLlvm")) (ELit (LString "llvm")))
(DFunDef false "backendName" ((PCon "BackendWasmgc")) (ELit (LString "wasmgc")))
(DFunDef false "backendName" ((PCon "BackendEval")) (ELit (LString "eval")))
(DTypeSig false "wholeDomain" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "wholeDomain" ((PVar "labels")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (ETuple (EVar "l") (EVar "EPTop")))) (EVar "labels")))
(DTypeSig true "hostLabels" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hostLabels" () (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "Net")) (ELit (LString "Signal"))))
(DTypeSig true "ioJoinGrants" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "ioJoinGrants" ((PCon "None")) (EApp (EVar "wholeDomain") (EVar "hostLabels")))
(DFunDef false "ioJoinGrants" ((PCon "Some" (PVar "p"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "g")) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EApp (EVar "fst") (EVar "g"))))) (EVar "hostLabels")))) (EApp (EVar "profileGrants") (EVar "p"))))
(DTypeSig false "profileRows" (TyApp (TyCon "List") (TyCon "TargetProfile")))
(DFunDef false "profileRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "llvm/native-posix"))) (EVar "BackendLlvm")) (ELit (LString "C symbols"))) (EApp (EVar "wholeDomain") (EBinOp "++" (EVar "hostLabels") (EListLit (ELit (LString "FFI")))))) (EVar "evalRunProfile") (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/node"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/browser-worker"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Clock")) (ELit (LString "Rand")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/edge"))) (EVar "BackendWasmgc")) (ELit (LString "env"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Clock")) (ELit (LString "Rand")) (ELit (LString "Net")) (ELit (LString "FFI"))))) (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "wasmgc/wasi-p2"))) (EVar "BackendWasmgc")) (ELit (LString "WIT"))) (EApp (EVar "wholeDomain") (EListLit (ELit (LString "FFI")))))))
(DTypeSig false "evalRunProfile" (TyCon "TargetProfile"))
(DFunDef false "evalRunProfile" () (EApp (EApp (EApp (EApp (EVar "TargetProfile") (ELit (LString "eval/run"))) (EVar "BackendEval")) (ELit (LString "ioExternBindings"))) (EApp (EVar "wholeDomain") (EVar "hostLabels"))))
(DTypeSig false "aliasRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "aliasRows" () (EListLit (ETuple (ELit (LString "native")) (ELit (LString "llvm/native-posix"))) (ETuple (ELit (LString "wasm")) (ELit (LString "wasmgc/node")))))
(DTypeSig false "profileIndex" (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")))
(DFunDef false "profileIndex" () (EBinOp "|>" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "profileName") (EVar "p")) (EVar "p")))) (EVar "profileRows"))) (EVar "omEmpty")) (EApp (EVar "withAliases") (EVar "aliasRows"))))
(DTypeSig false "withAliases" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")) (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")))))
(DFunDef false "withAliases" ((PVar "aliases") (PVar "idx")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "a")) (EApp (EApp (EVar "aliased") (EVar "a")) (EVar "idx")))) (EVar "aliases"))) (EVar "idx")))
(DTypeSig false "aliased" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "TargetProfile")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "TargetProfile"))))))
(DFunDef false "aliased" ((PTuple (PVar "alias") (PVar "target")) (PVar "idx")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "alias") (EVar "p")))) (EApp (EApp (EVar "omLookup") (EVar "target")) (EVar "idx"))))
(DTypeSig true "profileNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "profileNames" () (EApp (EApp (EMethodRef "map") (EVar "profileName")) (EVar "profileRows")))
(DTypeSig false "knownNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "knownNames" () (EBinOp "++" (EVar "profileNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "aliasRows"))))
(DTypeSig true "lookupProfile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TargetProfile"))))
(DFunDef false "lookupProfile" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "profileIndex")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Ok") (EVar "p"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown target `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` (known: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EVar "knownNames")))) (ELit (LString ")")))))))
(DTypeSig true "selectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile"))))))
(DFunDef false "selectProfile" ((PCon "Some" (PVar "flag")) PWild) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "flag"))))
(DFunDef false "selectProfile" ((PCon "None") (PCon "Some" (PVar "fromManifest"))) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "fromManifest"))))
(DFunDef false "selectProfile" ((PCon "None") (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DTypeSig true "buildable" (TyFun (TyCon "TargetProfile") (TyCon "Bool")))
(DFunDef false "buildable" ((PVar "p")) (EBinOp "/=" (EApp (EVar "profileBackend") (EVar "p")) (EVar "BackendEval")))
(DTypeSig true "buildableNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "buildableNames" () (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EMatch (EApp (EVar "lookupProfile") (EVar "n")) (arm (PCon "Ok" (PVar "p")) () (EApp (EVar "buildable") (EVar "p"))) (arm (PCon "Err" PWild) () (EVar "False"))))) (EVar "knownNames")))
(DTypeSig true "isGatedLabel" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isGatedLabel" ((PVar "l")) (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString "FFI"))) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "hostLabels"))))
(DTypeSig true "runProfile" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyCon "TargetProfile")))
(DFunDef false "runProfile" ((PCon "None")) (EVar "evalRunProfile"))
(DFunDef false "runProfile" ((PCon "Some" (PVar "p"))) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EApp (EVar "profileName") (EVar "evalRunProfile"))) (EVar "p") (EApp (EApp (EApp (EApp (EVar "TargetProfile") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "evalRunProfile")))) (ELit (LString " ∩ "))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "p")))) (ELit (LString "")))) (EVar "BackendEval")) (EApp (EVar "profileAbi") (EVar "evalRunProfile"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "g")) (EApp (EApp (EVar "grantsLabel") (EVar "evalRunProfile")) (EApp (EVar "fst") (EVar "g"))))) (EApp (EVar "profileGrants") (EVar "p"))))))
(DTypeSig true "selectedProfile" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "TargetProfile"))))
(DFunDef false "selectedProfile" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "targetProfileEnv" (TyCon "String"))
(DFunDef false "targetProfileEnv" () (ELit (LString "MEDAKA_TARGET_PROFILE")))
