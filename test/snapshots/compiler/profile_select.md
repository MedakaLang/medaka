# META
source_lines=64
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/profile_select.mdk — which target profile a verb typechecks
-- under: `--target` first, then the `[target] profile` of the project holding
-- the entry, then none.  Every verb that typechecks selects through here, and
-- the selection is published on `selectedProfile`, the Ref the typechecker's
-- IO join and the target refusal read.
import toml.{parse as parseToml}
import support.manifest.{targetProfile, statesTargetSection}
import support.path.{dirOf}
import types.target_profile.{TargetProfile, selectProfile, selectedProfile}
import driver.loader.{findProjectRoot}

-- The `medaka.toml` of the project holding `entry`.  The walk-up starts from
-- the entry's absolute directory: a relative entry's directory is `.`, whose
-- parent is itself.
export
manifestPathOf : String -> <IO> Option String
manifestPathOf entry =
  map (++ "/medaka.toml") (findProjectRoot (canonicalizePath (dirOf entry)))

-- The manifest's `[target] profile` for the project holding `entry`; `Err`
-- when a manifest exists but its `[target]` cannot be read.  A manifest the
-- TOML reader rejects with no `[target]` header reads as no target: its other
-- readers judge it.
export
manifestProfileOf : String -> <IO> Result String (Option String)
manifestProfileOf entry = match manifestPathOf entry
  None => Ok None
  Some path =>
    let read = match readFile path
      Err e => Err e
      Ok text => match parseToml text
        Err e =>
          if statesTargetSection text then
            Err "not valid TOML: \{e}"
          else
            Ok None
        Ok doc => targetProfile doc
    mapErr (why => "cannot read `[target]` in \{path}: \{why}") read

-- The profile for `entry`: `flagValue` (`--target`) over the manifest.  A name
-- the profile table does not know is an `Err`.
export
selectProjectProfile : Option String ->
  String ->
  <IO> Result String (Option TargetProfile)
selectProjectProfile flagValue entry =
  let fromManifest = match flagValue
    Some _ => Ok None
    None => manifestProfileOf entry
  andThen fromManifest (selectProfile flagValue)

-- Select and publish: after the call the typechecker reads the profile for
-- `entry`, or no profile when it cannot be read.  A long-lived process calls
-- this once per analysis, so a failed selection must not leave the previous
-- project's profile behind.
export
carryProjectProfile : Option String -> String -> <IO> Result String Unit
carryProjectProfile flagValue entry = match selectProjectProfile flagValue entry
  Ok p =>
    selectedProfile := p
    Ok ()
  Err m =>
    selectedProfile := None
    Err m
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "parse" false "parseToml"))))
(DUse false (UseGroup ("support" "manifest") ((mem "targetProfile" false) (mem "statesTargetSection" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "selectProfile" false) (mem "selectedProfile" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DTypeSig true "manifestPathOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "manifestPathOf" ((PVar "entry")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "_s") (ELit (LString "/medaka.toml"))))) (EApp (EVar "findProjectRoot") (EApp (EVar "canonicalizePath") (EApp (EVar "dirOf") (EVar "entry"))))))
(DTypeSig true "manifestProfileOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "manifestProfileOf" ((PVar "entry")) (EMatch (EApp (EVar "manifestPathOf") (EVar "entry")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "read") (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "parseToml") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EVar "statesTargetSection") (EVar "text")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "not valid TOML: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "None")))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "targetProfile") (EVar "doc"))))))) (DoExpr (EApp (EApp (EVar "mapErr") (ELam ((PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read `[target]` in ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ""))))) (EVar "read")))))))
(DTypeSig true "selectProjectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))))
(DFunDef false "selectProjectProfile" ((PVar "flagValue") (PVar "entry")) (EBlock (DoLet false false (PVar "fromManifest") (EMatch (EVar "flagValue") (arm (PCon "Some" PWild) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "None") () (EApp (EVar "manifestProfileOf") (EVar "entry"))))) (DoExpr (EApp (EApp (EVar "andThen") (EVar "fromManifest")) (EApp (EVar "selectProfile") (EVar "flagValue"))))))
(DTypeSig true "carryProjectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "carryProjectProfile" ((PVar "flagValue") (PVar "entry")) (EMatch (EApp (EApp (EVar "selectProjectProfile") (EVar "flagValue")) (EVar "entry")) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "p"))) (DoExpr (EApp (EVar "Ok") (ELit LUnit))))) (arm (PCon "Err" (PVar "m")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None"))) (DoExpr (EApp (EVar "Err") (EVar "m")))))))
# MARK
(DUse false (UseGroup ("toml") ((mem "parse" false "parseToml"))))
(DUse false (UseGroup ("support" "manifest") ((mem "targetProfile" false) (mem "statesTargetSection" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "selectProfile" false) (mem "selectedProfile" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DTypeSig true "manifestPathOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "manifestPathOf" ((PVar "entry")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "_s") (ELit (LString "/medaka.toml"))))) (EApp (EVar "findProjectRoot") (EApp (EVar "canonicalizePath") (EApp (EVar "dirOf") (EVar "entry"))))))
(DTypeSig true "manifestProfileOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "manifestProfileOf" ((PVar "entry")) (EMatch (EApp (EVar "manifestPathOf") (EVar "entry")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false (PVar "read") (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "parseToml") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EVar "statesTargetSection") (EVar "text")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "not valid TOML: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "None")))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "targetProfile") (EVar "doc"))))))) (DoExpr (EApp (EApp (EVar "mapErr") (ELam ((PVar "why")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read `[target]` in ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ""))))) (EVar "read")))))))
(DTypeSig true "selectProjectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))))
(DFunDef false "selectProjectProfile" ((PVar "flagValue") (PVar "entry")) (EBlock (DoLet false false (PVar "fromManifest") (EMatch (EVar "flagValue") (arm (PCon "Some" PWild) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "None") () (EApp (EVar "manifestProfileOf") (EVar "entry"))))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EVar "fromManifest")) (EApp (EVar "selectProfile") (EVar "flagValue"))))))
(DTypeSig true "carryProjectProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "carryProjectProfile" ((PVar "flagValue") (PVar "entry")) (EMatch (EApp (EApp (EVar "selectProjectProfile") (EVar "flagValue")) (EVar "entry")) (arm (PCon "Ok" (PVar "p")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "p"))) (DoExpr (EApp (EVar "Ok") (ELit LUnit))))) (arm (PCon "Err" (PVar "m")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "None"))) (DoExpr (EApp (EVar "Err") (EVar "m")))))))
