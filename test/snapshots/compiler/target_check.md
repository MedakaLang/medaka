# META
source_lines=138
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/target_check.mdk — does a program's entry fit a target
-- profile?  The entry's invocation summary, cut to the labels a profile gates,
-- is judged by the same subsumption `check-policy` uses, and a refusal becomes
-- one located `T-TARGET-CAPABILITY` diagnostic.
import frontend.ast.{Decl(..), Loc(..), TyConOrigin(..)}
import types.target_profile.{
  TargetProfile, profileName, profileGrants, isGatedLabel, reachesLabel
}
import types.effect_policy.{
  PolicyVerdict(..), policyRefusals, buildCallGraph, fnEffectsTable, viaChain
}
import types.effect_invocation.{invocationSummary}
import types.effect_rows.{
  Atom, atomLabel, atomLabelOf, effLabelOrigin, renderAtom
}
import tools.check_policy.{EntryAnalysis(..)}
import driver.diagnostics.{Diag(..), Severity(..), mkDiag}
import support.util.{lookupAssoc, joinWith, dedup, contains}
import string.{trim}

export
targetCapabilityCode : String
targetCapabilityCode = "T-TARGET-CAPABILITY"

-- The refusal of the program whose entry file is `file`, or `None` when its
-- `main` performs nothing the profile withholds.  A program with no `main` of
-- its own has no entry to judge, and that is a refusal too.  The entry judged
-- is the one the drivers run: a value `main` they print performs what the
-- `println` applied to it performs.
export
targetRefusal : TargetProfile -> String -> EntryAnalysis -> Option Diag
targetRefusal profile file analysis =
  match lookupAssoc "main" analysis.eaSchemes
    None => Some (missingEntryDiag profile file)
    Some sch =>
      let printed = match analysis.eaAutoPrintCall
        Some call => invocationSummary analysis.eaOps call
        None => []
      let summary = invocationSummary analysis.eaOps sch ++ printed
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
  EntryAnalysis ->
  List Atom ->
  List String ->
  List String ->
  Diag
refusalDiag profile analysis atoms labels lines =
  let chain =
    viaChain
      (buildCallGraph analysis.eaEntryDecls)
      (fnEffectsTable analysis.eaSchemes)
      "main"
      (firstOr "" labels)
  let refused = filter (a => contains (atomLabel a) labels) atoms
  let route = match chain
    _ :: _ :: _ => " via `\{joinWith " → " chain}`"
    _ => ""
  let notProven = stringConcat (map (l => "; " ++ trim l) lines)
  let printed = match analysis.eaAutoPrintCall
    Some _ =>
      "; `main` is a value other than `Unit`, so it is printed with `println`"
    None => ""
  mkDiag
    SevError
    targetCapabilityCode
    "`main` performs <\{joinWith ", " (map renderAtom refused)}>\{route}, and the target `\{profileName profile}` does not grant \{joinWith ", " (map withheldName labels)}\{notProven}\{printed}"
    (entryLoc analysis.eaEntryDecls)

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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false) (mem "profileGrants" false) (mem "isGatedLabel" false) (mem "reachesLabel" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "EntryAnalysis" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "contains" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "String"))
(DFunDef false "targetCapabilityCode" () (ELit (LString "T-TARGET-CAPABILITY")))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyCon "EntryAnalysis") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "eaAutoPrintCall") (arm (PCon "Some" (PVar "call")) () (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "call"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "summary") (EBinOp "++" (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")) (EVar "printed"))) (DoLet false false (PVar "atoms") (EApp (EApp (EVar "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EVar "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "atoms")) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EApp (EVar "atomLabel") (EVar "a"))))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Atom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "EntryAnalysis") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "eaSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EVar "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "eaAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EVar "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "eaEntryDecls"))))))
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false) (mem "profileGrants" false) (mem "isGatedLabel" false) (mem "reachesLabel" false))))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomLabel" false) (mem "atomLabelOf" false) (mem "effLabelOrigin" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "EntryAnalysis" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "mkDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "joinWith" false) (mem "dedup" false) (mem "contains" false))))
(DUse false (UseGroup ("string") ((mem "trim" false))))
(DTypeSig true "targetCapabilityCode" (TyCon "String"))
(DFunDef false "targetCapabilityCode" () (ELit (LString "T-TARGET-CAPABILITY")))
(DTypeSig true "targetRefusal" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyFun (TyCon "EntryAnalysis") (TyApp (TyCon "Option") (TyCon "Diag"))))))
(DFunDef false "targetRefusal" ((PVar "profile") (PVar "file") (PVar "analysis")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EVar "missingEntryDiag") (EVar "profile")) (EVar "file")))) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "eaAutoPrintCall") (arm (PCon "Some" (PVar "call")) () (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "call"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "summary") (EBinOp "++" (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")) (EVar "printed"))) (DoLet false false (PVar "atoms") (EApp (EApp (EMethodRef "filter") (EVar "isGatedAtom")) (EVar "summary"))) (DoLet false false (PVar "unjoined") (EApp (EApp (EMethodRef "filter") (EApp (EVar "unjoinedIo") (EVar "profile"))) (EVar "summary"))) (DoLet false false (PVar "ioLabels") (EMatch (EVar "unjoined") (arm (PList) () (EListLit)) (arm PWild () (EListLit (ELit (LString "IO")))))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "atoms")) (EApp (EVar "profileGrants") (EVar "profile"))) (arm (PCon "PolicyAdmitted") () (EMatch (EVar "unjoined") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EVar "unjoined")) (EVar "ioLabels")) (EListLit)))))) (arm (PCon "PolicyRefused" (PVar "labels") (PVar "lines")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "refusalDiag") (EVar "profile")) (EVar "analysis")) (EBinOp "++" (EVar "atoms") (EVar "unjoined"))) (EBinOp "++" (EApp (EVar "dedup") (EVar "labels")) (EVar "ioLabels"))) (EVar "lines"))))))))))
(DTypeSig false "isGatedAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "isGatedAtom" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EApp (EVar "isGatedLabel") (EApp (EVar "atomLabel") (EVar "a"))))))
(DTypeSig false "unjoinedIo" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "Atom") (TyCon "Bool"))))
(DFunDef false "unjoinedIo" ((PVar "profile") (PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EVar "not") (EApp (EApp (EVar "reachesLabel") (EVar "profile")) (ELit (LString "IO"))))))))
(DTypeSig false "refusalDiag" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "EntryAnalysis") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Diag")))))))
(DFunDef false "refusalDiag" ((PVar "profile") (PVar "analysis") (PVar "atoms") (PVar "labels") (PVar "lines")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (EApp (EVar "fnEffectsTable") (EFieldAccess (EVar "analysis") "eaSchemes"))) (ELit (LString "main"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "labels")))) (DoLet false false (PVar "refused") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "a")) (EApp (EApp (EVar "contains") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "labels")))) (EVar "atoms"))) (DoLet false false (PVar "route") (EMatch (EVar "chain") (arm (PCons PWild (PCons PWild PWild)) () (EBinOp "++" (EBinOp "++" (ELit (LString " via `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain")))) (ELit (LString "`")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "notProven") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EBinOp "++" (ELit (LString "; ")) (EApp (EVar "trim") (EVar "l"))))) (EVar "lines")))) (DoLet false false (PVar "printed") (EMatch (EFieldAccess (EVar "analysis") "eaAutoPrintCall") (arm (PCon "Some" PWild) () (ELit (LString "; `main` is a value other than `Unit`, so it is printed with `println`"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "targetCapabilityCode")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` performs <")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "refused"))))) (ELit (LString ">"))) (EApp (EMethodRef "display") (EVar "route"))) (ELit (LString ", and the target `"))) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "withheldName")) (EVar "labels"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "notProven"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "printed"))) (ELit (LString "")))) (EApp (EVar "entryLoc") (EFieldAccess (EVar "analysis") "eaEntryDecls"))))))
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
