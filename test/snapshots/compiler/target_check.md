# META
source_lines=302
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/target_check.mdk — does a program fit a target profile?
-- Two rules.  The entry's invocation summary, cut to the labels a profile
-- gates, is judged by the same subsumption `check-policy` uses, and a refusal
-- becomes one located `T-TARGET-CAPABILITY` diagnostic.  And every user extern
-- the program reaches must be bound for the host the profile calls foreign
-- code through, else it is a `T-TARGET-NO-BINDING` diagnostic located at the
-- declaration.
import frontend.ast.{
  Decl(..),
  ExternBind(..),
  ExternDecl(..),
  Loc(..),
  TyConOrigin(..),
  externBindings,
}
import types.target_profile.{
  TargetProfile,
  profileName,
  profileGrants,
  profileBindingHost,
  isGatedLabel,
  reachesLabel,
}
import ir.dce.{reachedExternChains}
import types.effect_policy.{
  PolicyVerdict(..), policyRefusals, buildCallGraph, fnEffectsTable, viaChain
}
import types.effect_invocation.{invocationSummary}
import types.repr.{Scheme}
import types.effect_rows.{
  Atom, atomLabel, atomLabelOf, effLabelOrigin, renderAtom
}
import tools.check_policy.{TargetInputs(..)}
import driver.diagnostics.{
  Diag(..),
  Severity(..),
  mkDiag,
  cjFoldIntoFile,
  ppDiagCliLines,
  readFileSafe,
  srcLinesArr,
}
import support.util.{lookupAssoc, joinWith, dedup, contains, anyList}
import string.{trim}
import list.{lookup}

export
targetCapabilityCode : String
targetCapabilityCode = "T-TARGET-CAPABILITY"

export
targetNoBindingCode : String
targetNoBindingCode = "T-TARGET-NO-BINDING"

-- The refusals of the program whose entry file is `file`; `[]` admits it.
-- `paths` maps each module to its file, where a refused extern is located.  A
-- program with no `main` of its own has no entry to judge, and that is a
-- refusal too.  A reached extern with no binding for the profile's host is the
-- verdict, one diagnostic per declaration; the entry's capability refusal is
-- reported only when no declaration is refused.  The two meet on `FFI`, which
-- `eval/run` alone withholds, so the declaration names the cause where the
-- entry's row would only name the label.
export
targetRefusal : TargetProfile ->
  String ->
  List (String, String) ->
  TargetInputs ->
  List Diag
targetRefusal profile file paths analysis =
  match lookupAssoc "main" analysis.tiSchemes
    None => [missingEntryDiag profile file]
    Some sch => match bindingRefusals profile paths analysis
      [] => match capabilityRefusal profile analysis sch
        Some d => [d]
        None => []
      ds => ds

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
  let printed = match analysis.tiAutoPrintCall
    Some call => invocationSummary analysis.tiOps call
    None => []
  let summary = invocationSummary analysis.tiOps sch ++ printed
  let atoms = filter isGatedAtom summary
  let unjoined = filter (unjoinedIo profile) summary
  let ioLabels = match unjoined
    [] => []
    _ => ["IO"]
  match policyRefusals atoms (profileGrants profile)
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
  let userExterns =
    flatMap
      ((mid, decls) =>
        map
          (ed => (mid, ed))
          (filter
            (ed => not (contains ed.edName analysis.tiCatalogExterns))
            (externDecls decls)))
      analysis.tiModules
  match userExterns
    [] => []
    _ =>
      let chains = reachedExternChains analysis.tiCore analysis.tiModules
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
isGatedAtom : Atom -> Bool
isGatedAtom a = match effLabelOrigin (atomLabelOf a)
  OriginModule _ => False
  _ => isGatedLabel (atomLabel a)

-- The one `IO` the typechecker cannot refuse: an `IO` performed under an `IO`
-- bound, on a profile whose join is empty.  Nothing performed as `IO` runs
-- there.
unjoinedIo : TargetProfile -> Atom -> Bool
unjoinedIo profile a = match effLabelOrigin (atomLabelOf a)
  OriginModule _ => False
  _ => atomLabel a == "IO" && not (reachesLabel profile "IO")

refusalDiag : TargetProfile ->
  TargetInputs ->
  List Atom ->
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
  let refused = filter (a => contains (atomLabel a) labels) atoms
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
    "`main` performs <\{joinWith ", " (map renderAtom refused)}>\{route}, and the target `\{profileName profile}` does not grant \{joinWith ", " (map withheldName labels)}\{notProven}\{printed}"
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "externBindings" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false) (mem "profileGrants" false) (mem "profileBindingHost" false) (mem "isGatedLabel" false) (mem "reachesLabel" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "reachedExternChains" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "TargetInputs" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false) (mem "cjFoldIntoFile" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "String"))
(DFunDef false "targetCapabilityCode" () (ELit (LString "T-TARGET-CAPABILITY")))
(DTypeSig true "targetNoBindingCode" (TyCon "String"))
(DFunDef false "targetNoBindingCode" () (ELit (LString "T-TARGET-NO-BINDING")))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "paths") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "tiSchemes")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EApp (EVar "bindingRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis")) (arm (PList) () (EMatch (EApp (EApp (EApp (EVar "capabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "sch")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))) (arm (PVar "ds") () (EVar "ds"))))))
(DTypeSig true "targetDiagFile" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "targetDiagFile" ((PVar "entry") (PCon "Diag" PWild PWild PWild (PCon "Some" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) PWild PWild)) (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "entry") (EVar "f")))
(DFunDef false "targetDiagFile" ((PVar "entry") PWild) (EVar "entry"))
(DTypeSig true "ppTargetDiag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "ppTargetDiag" ((PVar "entry") (PVar "entrySrc") (PVar "d")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "d")))))
(DTypeSig true "foldTargetDiags" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "foldTargetDiags" (PWild PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "foldTargetDiags" ((PVar "entry") (PVar "entrySrc") (PCons (PVar "d") (PVar "ds")) (PVar "triples")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "folded") (EIf (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "file")))) (EVar "triples")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "file")) (EListLit (EVar "d"))) (EVar "triples")) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (EVar "src") (EListLit (EVar "d"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EVar "entrySrc")) (EVar "ds")) (EVar "folded")))))
(DTypeSig false "capabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "capabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "sch")) (EBlock (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" (PVar "call")) () (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "tiOps")) (EVar "call"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "summary") (EBinOp "++" (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "tiOps")) (EVar "sch")) (EVar "printed"))) (DoLet false false (PVar "atoms") (EApp (EApp (EVar "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EVar "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "atoms")) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))
(DTypeSig false "bindingRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "bindingRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "userExterns") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "map") (ELam ((PVar "ed")) (ETuple (EVar "mid") (EVar "ed")))) (EApp (EApp (EVar "filter") (ELam ((PVar "ed")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "ed") "edName")) (EFieldAccess (EVar "analysis") "tiCatalogExterns"))))) (EApp (EVar "externDecls") (EVar "decls")))))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EMatch (EVar "userExterns") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "chains") (EApp (EApp (EVar "reachedExternChains") (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "unboundReached") (EVar "profile")) (EVar "paths")) (EVar "chains"))) (EVar "userExterns")))))))))
(DTypeSig false "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDecls") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
(DTypeSig false "unboundReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "ExternDecl")) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unboundReached" ((PVar "profile") (PVar "paths") (PVar "chains") (PTuple (PVar "mid") (PVar "ed"))) (EMatch (EApp (EApp (EVar "lookup") (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName"))) (EVar "chains")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "chain")) () (EBlock (DoLet false false (PVar "bound") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "ed")))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "bound") (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "noBindingDiag") (EVar "profile")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (ETuple (EVar "ed") (EVar "chain"))))))))))
(DTypeSig false "noBindingDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Diag")))))
(DFunDef false "noBindingDiag" ((PVar "profile") (PVar "path") (PTuple (PVar "ed") (PVar "chain"))) (EBlock (DoLet false false (PVar "hosts") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EFieldAccess (EVar "b") "ebHost"))) (ELit (LString "`"))))) (EApp (EVar "externBindings") (EVar "ed"))))) (DoLet false false (PVar "target") (EApp (EVar "profileName") (EVar "profile"))) (DoLet false false (PVar "why") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "has no binding for the host `")) (EApp (EVar "display") (EVar "h"))) (ELit (LString "`, which the target `"))) (EApp (EVar "display") (EVar "target"))) (ELit (LString "` calls foreign code through (it binds "))) (EApp (EVar "display") (EVar "hosts"))) (ELit (LString "); add a `bind "))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` clause or build for a target whose host it binds")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the target `")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "` calls foreign code through no host (it binds "))) (EApp (EVar "display") (EVar "hosts"))) (ELit (LString "); build for a target whose host it binds")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNoBindingCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the extern `")) (EApp (EVar "display") (EFieldAccess (EVar "ed") "edName"))) (ELit (LString "` is reached"))) (EApp (EVar "display") (EApp (EVar "reachRoute") (EVar "chain")))) (ELit (LString ", and "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EVar "path")) (EFieldAccess (EVar "ed") "edLoc")))))))
(DTypeSig false "reachRoute" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "reachRoute" ((PList PWild)) (ELit (LString " from an impl method, interface default or top-level let group")))
(DFunDef false "reachRoute" ((PCons (PLit (LString "main")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EBinOp "::" (ELit (LString "main")) (EVar "rest"))))) (ELit (LString "`"))))
(DFunDef false "reachRoute" ((PVar "chain")) (EBinOp "++" (EBinOp "++" (ELit (LString " from an impl method, interface default or top-level let group, via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`"))))
(DTypeSig false "inFile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "inFile" ((PCon "Some" (PVar "f")) (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DFunDef false "inFile" ((PCon "None") (PVar "l")) (EVar "l"))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EApp (EVar "atomLabel") (EVar "a"))))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Atom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "tiEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "tiSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EVar "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EVar "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls"))))))
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "externBindings" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false) (mem "profileGrants" false) (mem "profileBindingHost" false) (mem "isGatedLabel" false) (mem "reachesLabel" false))))
(DUse false (UseGroup ("ir" "dce") ((mem "reachedExternChains" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "TargetInputs" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false) (mem "cjFoldIntoFile" false) (mem "ppDiagCliLines" false) (mem "readFileSafe" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "String"))
(DFunDef false "targetCapabilityCode" () (ELit (LString "T-TARGET-CAPABILITY")))
(DTypeSig true "targetNoBindingCode" (TyCon "String"))
(DFunDef false "targetNoBindingCode" () (ELit (LString "T-TARGET-NO-BINDING")))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "paths") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "tiSchemes")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EApp (EVar "bindingRefusals") (EVar "profile")) (EVar "paths")) (EVar "analysis")) (arm (PList) () (EMatch (EApp (EApp (EApp (EVar "capabilityRefusal") (EVar "profile")) (EVar "analysis")) (EVar "sch")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))) (arm (PVar "ds") () (EVar "ds"))))))
(DTypeSig true "targetDiagFile" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "targetDiagFile" ((PVar "entry") (PCon "Diag" PWild PWild PWild (PCon "Some" (PCon "Loc" (PVar "f") PWild PWild PWild PWild)) PWild PWild)) (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "entry") (EVar "f")))
(DFunDef false "targetDiagFile" ((PVar "entry") PWild) (EVar "entry"))
(DTypeSig true "ppTargetDiag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "ppTargetDiag" ((PVar "entry") (PVar "entrySrc") (PVar "d")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "d")))))
(DTypeSig true "foldTargetDiags" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "foldTargetDiags" (PWild PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "foldTargetDiags" ((PVar "entry") (PVar "entrySrc") (PCons (PVar "d") (PVar "ds")) (PVar "triples")) (EBlock (DoLet false false (PVar "file") (EApp (EApp (EVar "targetDiagFile") (EVar "entry")) (EVar "d"))) (DoLet false false (PVar "folded") (EIf (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "file")))) (EVar "triples")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "file")) (EListLit (EVar "d"))) (EVar "triples")) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "file") (EVar "entry")) (EVar "entrySrc") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (EVar "src") (EListLit (EVar "d"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EVar "entrySrc")) (EVar "ds")) (EVar "folded")))))
(DTypeSig false "capabilityRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "capabilityRefusal" ((PVar "profile") (PVar "analysis") (PVar "sch")) (EBlock (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" (PVar "call")) () (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "tiOps")) (EVar "call"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "summary") (EBinOp "++" (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "tiOps")) (EVar "sch")) (EVar "printed"))) (DoLet false false (PVar "atoms") (EApp (EApp (EMethodRef "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EMethodRef "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "atoms")) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))
(DTypeSig false "bindingRefusals" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "TargetInputs") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "bindingRefusals" ((PVar "profile") (PVar "paths") (PVar "analysis")) (EBlock (DoLet false false (PVar "userExterns") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ed")) (ETuple (EVar "mid") (EVar "ed")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "ed")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "ed") "edName")) (EFieldAccess (EVar "analysis") "tiCatalogExterns"))))) (EApp (EVar "externDecls") (EVar "decls")))))) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EMatch (EVar "userExterns") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "chains") (EApp (EApp (EVar "reachedExternChains") (EFieldAccess (EVar "analysis") "tiCore")) (EFieldAccess (EVar "analysis") "tiModules"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "unboundReached") (EVar "profile")) (EVar "paths")) (EVar "chains"))) (EVar "userExterns")))))))))
(DTypeSig false "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ExternDecl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externDecls") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (EVar "ed") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
(DTypeSig false "unboundReached" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "ExternDecl")) (TyApp (TyCon "Option") (TyCon "Diag")))))))
(DFunDef false "unboundReached" ((PVar "profile") (PVar "paths") (PVar "chains") (PTuple (PVar "mid") (PVar "ed"))) (EMatch (EApp (EApp (EVar "lookup") (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName"))) (EVar "chains")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "chain")) () (EBlock (DoLet false false (PVar "bound") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "ed")))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "bound") (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "noBindingDiag") (EVar "profile")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "paths"))) (ETuple (EVar "ed") (EVar "chain"))))))))))
(DTypeSig false "noBindingDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Diag")))))
(DFunDef false "noBindingDiag" ((PVar "profile") (PVar "path") (PTuple (PVar "ed") (PVar "chain"))) (EBlock (DoLet false false (PVar "hosts") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "ebHost"))) (ELit (LString "`"))))) (EApp (EVar "externBindings") (EVar "ed"))))) (DoLet false false (PVar "target") (EApp (EVar "profileName") (EVar "profile"))) (DoLet false false (PVar "why") (EMatch (EApp (EVar "profileBindingHost") (EVar "profile")) (arm (PCon "Some" (PVar "h")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "has no binding for the host `")) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "`, which the target `"))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "` calls foreign code through (it binds "))) (EApp (EMethodRef "display") (EVar "hosts"))) (ELit (LString "); add a `bind "))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` clause or build for a target whose host it binds")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the target `")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "` calls foreign code through no host (it binds "))) (EApp (EMethodRef "display") (EVar "hosts"))) (ELit (LString "); build for a target whose host it binds")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetNoBindingCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the extern `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "ed") "edName"))) (ELit (LString "` is reached"))) (EApp (EMethodRef "display") (EApp (EVar "reachRoute") (EVar "chain")))) (ELit (LString ", and "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EVar "inFile") (EVar "path")) (EFieldAccess (EVar "ed") "edLoc")))))))
(DTypeSig false "reachRoute" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "reachRoute" ((PList PWild)) (ELit (LString " from an impl method, interface default or top-level let group")))
(DFunDef false "reachRoute" ((PCons (PLit (LString "main")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EBinOp "::" (ELit (LString "main")) (EVar "rest"))))) (ELit (LString "`"))))
(DFunDef false "reachRoute" ((PVar "chain")) (EBinOp "++" (EBinOp "++" (ELit (LString " from an impl method, interface default or top-level let group, via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`"))))
(DTypeSig false "inFile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "inFile" ((PCon "Some" (PVar "f")) (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DFunDef false "inFile" ((PCon "None") (PVar "l")) (EVar "l"))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EApp (EVar "atomLabel") (EVar "a"))))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Atom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "TargetInputs") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "tiEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "tiSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "tiAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EMethodRef "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "tiEntryDecls"))))))
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
