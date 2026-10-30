# META
source_lines=165
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-match-on-param: a function whose whole body is a `match` on one of its own bare parameters (STYLE §8).

import frontend.ast.{
  Loc(..), Pat(..), Arm(..), ImplMethod(..), Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, anyList, isNonEmptyL}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  mkRule,
}
import tools.lint_shared.{
  armToClause,
  declLocList,
  isBareParam,
  matchBodyOnBareParam,
  patIsWild,
  ruleNameMatchParam,
  unwrapLoc,
  wholeWordIn,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameMatchParam,
      summary =
        "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)",
      doc =
        "A function whose whole body is a `match` on one of its own parameters is clearer as several clauses: the patterns move into the parameter position and the extra indentation level goes away. This enforces STYLE section 8, a repository taste ruling.\n\nBefore:\n  len xs = match xs\n    [] => 0\n    _ :: t => 1 + len t\nAfter:\n  len [] = 0\n  len (_ :: t) = 1 + len t",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleMatchOnParam
    (Some matchParamFix)

-- ── rule: match-on-param (STYLE §8) ───────────────────────────────────────────
-- A `DFunDef _ name pats body` (or an impl method) whose body is a `match` with
-- ≥2 arms over an `EVar p` where `p` is a bare `PVar p` parameter.  Single-arm
-- matches are skipped (STYLE's "when not to convert").
ruleMatchOnParam : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleMatchOnParam _ _ _ pos prog = flatMap matchParamDeclL (declLocList pos prog)

matchParamDeclL : (Decl, Option Loc) -> List Finding
matchParamDeclL (d, loc) = matchParamDecl loc d

matchParamDecl : Option Loc -> Decl -> List Finding
matchParamDecl loc (DFunDef _ name pats body _ _) =
  matchParamFinding loc name pats body
matchParamDecl loc (DImpl { methods, ... }) =
  flatMap (matchParamMethod loc) methods
matchParamDecl loc (DAttrib _ d) = matchParamDecl loc d
matchParamDecl _ _ = []

matchParamMethod : Option Loc -> ImplMethod -> List Finding
matchParamMethod loc (ImplMethod name pats body) =
  matchParamFinding loc name pats body

matchParamFinding : Option Loc -> String -> List Pat -> Expr -> List Finding
matchParamFinding loc name pats body = match unwrapLoc body
  EMatch scrut arms => matchParamArms loc name pats scrut arms
  _ => []

matchParamArms : Option Loc ->
  String ->
  List Pat ->
  Expr ->
  List Arm ->
  List Finding
matchParamArms loc name pats scrut arms
  | listLen arms < 2 = []
  | otherwise = match unwrapLoc scrut
    EVar p => matchParamHit loc name pats p
    _ => []

matchParamHit : Option Loc -> String -> List Pat -> String -> List Finding
matchParamHit loc name pats p
  | anyList (isBareParam p) pats = [
    Finding {
      rule = ruleNameMatchParam,
      message =
        "function '\{name}' matches on parameter '\{p}' — use a multi-clause function definition",
      severity = SevWarning,
      loc = loc,
    },
  ]
  | otherwise = []

-- ── §8 autofixer (Task A) ──────────────────────────────────────────────────────
-- Rewrites `f x = match x { p1 => e1; p2 => e2 }` → `f p1 = e1` / `f p2 = e2`.
-- Safe subset only — returns `None` (rule still warns) unless ALL hold:
--   * the decl is a bare `DFunDef` (not attributed: splitting an attributed fn
--     into clauses would duplicate/move the attribute),
--   * its body (under `ELoc`) is an `EMatch` on a bare param `p` with ≥2 arms,
--   * NO arm has a guard — function-clause guards don't round-trip through
--     `DFunDef` (no guard slot),
--   * NO arm with a NON-wildcard pattern references the scrutinee param `p` —
--     after the rewrite `p` is replaced by the arm pattern, so a non-wildcard arm
--     body still mentioning `p` would be left unbound (e.g.
--     `f x = match x { Some v => g x }`).  A `PWild` arm referencing `p` is the
--     EXCEPTION: it is rewritten with `PVar p` (not `_`), which re-binds the
--     scrutinee, so it converts safely.  We test the reference by a conservative
--     whole-word scan of the PRINTED arm body: the printer renders every `EVar p`
--     as the token `p`, so a real reference is never missed (the scan can only
--     over-bail, which is safe).
matchParamFix : Oracle -> Decl -> Option (List Decl)
matchParamFix _ (DFunDef vis name pats body _ _) =
  match matchBodyOnBareParam pats body
    Some (p, k, arms) => matchParamFixArms vis name pats p k arms
    None => None
matchParamFix _ _ = None

matchParamFixArms : Bool ->
  String ->
  List Pat ->
  String ->
  Int ->
  List Arm ->
  Option (List Decl)
matchParamFixArms vis name pats p k arms
  | listLen arms < 2 = None
  | anyList armHasGuard arms = None
  | anyList (armUnsafeMention p) arms = None
  | otherwise = Some (map (armToClause vis name p pats k) arms)

-- an arm with any guard qualifier (refutable bind or boolean) can't be a clause
armHasGuard : Arm -> Bool
armHasGuard (Arm _ guards _) = isNonEmptyL guards

-- does the arm body still reference the scrutinee param (conservative, printed)
armMentionsParam : String -> Arm -> Bool
armMentionsParam p (Arm _ _ body) = wholeWordIn p (exprToString body)

-- an arm that mentions the scrutinee but CAN'T be safely re-bound.  A `PWild`
-- arm can: we re-emit the clause pattern as `PVar p`, re-binding the scrutinee
-- so the body's reference stays valid.  Any non-wildcard pattern (`c::rest`, or
-- a bare `PVar y` that renames) can't re-bind `p`, so we keep the conservative
-- bail there.
armUnsafeMention : String -> Arm -> Bool
armUnsafeMention p arm = armMentionsParam p arm && not (armPatIsWild arm)

armPatIsWild : Arm -> Bool
armPatIsWild (Arm pat _ _) = patIsWild pat
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "armToClause" false) (mem "declLocList" false) (mem "isBareParam" false) (mem "matchBodyOnBareParam" false) (mem "patIsWild" false) (mem "ruleNameMatchParam" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchParam")) (fa "summary" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "doc" (ELit (LString "A function whose whole body is a `match` on one of its own parameters is clearer as several clauses: the patterns move into the parameter position and the extra indentation level goes away. This enforces STYLE section 8, a repository taste ruling.\n\nBefore:\n  len xs = match xs\n    [] => 0\n    _ :: t => 1 + len t\nAfter:\n  len [] = 0\n  len (_ :: t) = 1 + len t"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchOnParam")) (EApp (EVar "Some") (EVar "matchParamFix"))))
(DTypeSig false "ruleMatchOnParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMatchOnParam" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "matchParamDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "matchParamDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "matchParamDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DTypeSig false "matchParamDecl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "matchParamMethod") (EVar "loc"))) (EVar "methods")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DFunDef false "matchParamDecl" (PWild PWild) (EListLit))
(DTypeSig false "matchParamMethod" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamMethod" ((PVar "loc") (PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DTypeSig false "matchParamFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamFinding" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchParamArms") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "scrut")) (EVar "arms"))) (arm PWild () (EListLit))))
(DTypeSig false "matchParamArms" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchParamArms" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "scrut") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "matchParamHit") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "p"))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamHit" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamHit" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "p")) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "isBareParam") (EVar "p"))) (EVar "pats")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' matches on parameter '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' — use a multi-clause function definition")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchParamFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchParamFixArms") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "matchParamFixArms" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "matchParamFixArms" ((PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EVar "armHasGuard")) (EVar "arms")) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "armUnsafeMention") (EVar "p"))) (EVar "arms")) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k"))) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" PWild (PVar "guards") PWild)) (EApp (EVar "isNonEmptyL") (EVar "guards")))
(DTypeSig false "armMentionsParam" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armMentionsParam" ((PVar "p") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))
(DTypeSig false "armUnsafeMention" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armUnsafeMention" ((PVar "p") (PVar "arm")) (EBinOp "&&" (EApp (EApp (EVar "armMentionsParam") (EVar "p")) (EVar "arm")) (EApp (EVar "not") (EApp (EVar "armPatIsWild") (EVar "arm")))))
(DTypeSig false "armPatIsWild" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armPatIsWild" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "patIsWild") (EVar "pat")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "armToClause" false) (mem "declLocList" false) (mem "isBareParam" false) (mem "matchBodyOnBareParam" false) (mem "patIsWild" false) (mem "ruleNameMatchParam" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchParam")) (fa "summary" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "doc" (ELit (LString "A function whose whole body is a `match` on one of its own parameters is clearer as several clauses: the patterns move into the parameter position and the extra indentation level goes away. This enforces STYLE section 8, a repository taste ruling.\n\nBefore:\n  len xs = match xs\n    [] => 0\n    _ :: t => 1 + len t\nAfter:\n  len [] = 0\n  len (_ :: t) = 1 + len t"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchOnParam")) (EApp (EVar "Some") (EVar "matchParamFix"))))
(DTypeSig false "ruleMatchOnParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMatchOnParam" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "matchParamDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "matchParamDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "matchParamDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DTypeSig false "matchParamDecl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "matchParamMethod") (EVar "loc"))) (EVar "methods")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DFunDef false "matchParamDecl" (PWild PWild) (EListLit))
(DTypeSig false "matchParamMethod" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamMethod" ((PVar "loc") (PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DTypeSig false "matchParamFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamFinding" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchParamArms") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "scrut")) (EVar "arms"))) (arm PWild () (EListLit))))
(DTypeSig false "matchParamArms" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchParamArms" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "scrut") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "matchParamHit") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "p"))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamHit" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamHit" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "p")) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "isBareParam") (EVar "p"))) (EVar "pats")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' matches on parameter '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' — use a multi-clause function definition")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchParamFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchParamFixArms") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "matchParamFixArms" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "matchParamFixArms" ((PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EVar "armHasGuard")) (EVar "arms")) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "armUnsafeMention") (EVar "p"))) (EVar "arms")) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k"))) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" PWild (PVar "guards") PWild)) (EApp (EVar "isNonEmptyL") (EVar "guards")))
(DTypeSig false "armMentionsParam" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armMentionsParam" ((PVar "p") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))
(DTypeSig false "armUnsafeMention" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armUnsafeMention" ((PVar "p") (PVar "arm")) (EBinOp "&&" (EApp (EApp (EVar "armMentionsParam") (EVar "p")) (EVar "arm")) (EApp (EVar "not") (EApp (EVar "armPatIsWild") (EVar "arm")))))
(DTypeSig false "armPatIsWild" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armPatIsWild" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "patIsWild") (EVar "pat")))
