# META
source_lines=179
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-destructure-in-param: a single-arm irrefutable `match` on a bare parameter. Destructure in the parameter position.

import frontend.ast.{
  Loc(..), Pat(..), RecPatField(..), Arm(..), Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{allList, isEmptyL}
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
  factOracle,
  mkRule,
}
import tools.lint_shared.{
  armToClause,
  ctorIsSingle,
  declLocList,
  matchBodyOnBareParam,
  ruleNameDestructureInParam,
  wholeWordIn,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameDestructureInParam,
      summary =
        "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position",
      doc =
        "A function body that is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple, record, single-constructor) can destructure in the parameter position.\n\nBefore:\n  f p = match p\n    (a, b) => a + b\nAfter:\n  f (a, b) = a + b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleDestructureInParam
    (Some destructureInParamFix)

-- ── rule: destructure-in-param ────────────────────────────────────────────────
-- The single-arm sibling of `rule-match-on-param`.  A `DFunDef _ name pats body`
-- whose body is a ONE-arm, guard-free `match <p>` over a bare parameter `p`, where
-- the arm pattern is an IRREFUTABLE destructuring pattern (a tuple, or a record /
-- single-payload / nullary constructor of a SINGLE-constructor type) and the arm
-- body does NOT reference `p` anywhere else (Medaka has no as-patterns, so hoisting
-- the pattern into the parameter position drops `p`'s binding).  In that case
-- prefer destructuring directly in the parameter position:
--   `f q = match q { AggQuery { from = t, … } => body }`
--     → `f (AggQuery { from = t, … }) = body`.
-- Irrefutability is proved via the Tier-0 `Oracle`: a constructor whose type has
-- exactly ONE constructor is irrefutable; an unknown ctor (e.g. an imported type
-- not declared in this file) is treated as NOT provably irrefutable → SKIP.  This
-- is deliberately conservative: false negatives are fine, false positives corrupt
-- code (they could turn a total match into a partial function clause).
ruleDestructureInParam : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleDestructureInParam _ _ facts pos prog =
  let orc = factOracle facts
  flatMap (destructureDeclL orc) (declLocList pos prog)

destructureDeclL : Oracle -> (Decl, Option Loc) -> List Finding
destructureDeclL orc (d, loc) = match d
  DFunDef _ name pats body _ _ => destructureFinding orc loc name pats body
  _ => []

destructureFinding : Oracle ->
  Option Loc ->
  String ->
  List Pat ->
  Expr ->
  List Finding
destructureFinding orc loc name pats body = match matchBodyOnBareParam pats body
  Some (p, _, arms) => destructureArmsFinding orc loc name p arms
  None => []

destructureArmsFinding : Oracle ->
  Option Loc ->
  String ->
  String ->
  List Arm ->
  List Finding
destructureArmsFinding orc loc name p [arm] =
  if destructureArmFires orc p arm then
    [
      Finding {
        rule = ruleNameDestructureInParam,
        message =
          "function '\{name}' destructures parameter '\{p}' via a single-arm irrefutable `match`. Destructure it directly in the parameter position",
        severity = SevWarning,
        loc = loc,
      },
    ]
  else
    []
destructureArmsFinding _ _ _ _ _ = []

-- the single arm can be hoisted iff: guard-free, its pattern is an irrefutable
-- destructuring pattern (not a bare var/wild/literal), and the arm body does NOT
-- otherwise mention the scrutinee param (conservative printed whole-word scan —
-- over-bail only, matching `armMentionsParam`).
destructureArmFires : Oracle -> String -> Arm -> Bool
destructureArmFires orc p (Arm pat guards body) =
  isEmptyL guards
    && destructurablePat orc pat
    && not (wholeWordIn p (exprToString body))

-- the TOP pattern is a real destructuring pattern (tuple / record / single-ctor
-- constructor) whose sub-patterns are all irrefutable.  Bare var/wild (pointless
-- to hoist), literals, `::`/`[…]` list patterns and ranges are excluded.
destructurablePat : Oracle -> Pat -> Bool
destructurablePat orc (PTuple ps) = allList (patIrrefutable orc) ps
destructurablePat orc (PCon c ps) =
  ctorIsSingle orc c && allList (patIrrefutable orc) ps
destructurablePat orc (PRec c fs _) =
  ctorIsSingle orc c && allList (recPatFieldIrrefutable orc) fs
destructurablePat _ _ = False

-- irrefutability of an arbitrary (possibly nested) pattern.  A var/wildcard binds
-- unconditionally; a tuple is irrefutable iff every element is; a constructor /
-- record iff its type is single-ctor AND every sub-pattern is; literals, `::`,
-- list and range patterns are refutable.
patIrrefutable : Oracle -> Pat -> Bool
patIrrefutable _ (PVar _ _ _) = True
patIrrefutable _ PWild = True
patIrrefutable orc (PTuple ps) = allList (patIrrefutable orc) ps
patIrrefutable orc (PCon c ps) =
  ctorIsSingle orc c && allList (patIrrefutable orc) ps
patIrrefutable orc (PRec c fs _) =
  ctorIsSingle orc c && allList (recPatFieldIrrefutable orc) fs
patIrrefutable orc (PAs _ _ _ p) = patIrrefutable orc p
patIrrefutable _ _ = False

recPatFieldIrrefutable : Oracle -> RecPatField -> Bool
recPatFieldIrrefutable _ (RecPatField _ _ _ None) = True
recPatFieldIrrefutable orc (RecPatField _ _ _ (Some p)) = patIrrefutable orc p

-- ── destructure-in-param autofixer ────────────────────────────────────────────
-- Reuses the shared `matchBodyOnBareParam` detector and the shared `armToClause`
-- pattern-hoist transform (the N = 1 case).  The `destructureArmFires` gate has
-- already proved the pattern irrefutable and the param unreferenced, so
-- `armToClause`'s PWild re-bind special-case never triggers here.
destructureInParamFix : Oracle -> Decl -> Option (List Decl)
destructureInParamFix orc (DFunDef vis name pats body _ _) =
  match matchBodyOnBareParam pats body
    Some (p, k, arms) => destructureInParamFixArms orc vis name pats p k arms
    None => None
destructureInParamFix _ _ = None

destructureInParamFixArms : Oracle ->
  Bool ->
  String ->
  List Pat ->
  String ->
  Int ->
  List Arm ->
  Option (List Decl)
destructureInParamFixArms orc vis name pats p k [arm] =
  if destructureArmFires orc p arm then
    Some [armToClause vis name p pats k arm]
  else
    None
destructureInParamFixArms _ _ _ _ _ _ _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factOracle" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "armToClause" false) (mem "ctorIsSingle" false) (mem "declLocList" false) (mem "matchBodyOnBareParam" false) (mem "ruleNameDestructureInParam" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "summary" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "doc" (ELit (LString "A function body that is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple, record, single-constructor) can destructure in the parameter position.\n\nBefore:\n  f p = match p\n    (a, b) => a + b\nAfter:\n  f (a, b) = a + b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDestructureInParam")) (EApp (EVar "Some") (EVar "destructureInParamFix"))))
(DTypeSig false "ruleDestructureInParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDestructureInParam" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "destructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "destructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "destructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body"))) (arm PWild () (EListLit))))
(DTypeSig false "destructureFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") PWild (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureArmsFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "p")) (EVar "arms"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "destructureArmsFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureArmsFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "p") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDestructureInParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' destructures parameter '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' via a single-arm irrefutable `match`. Destructure it directly in the parameter position")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit)))
(DFunDef false "destructureArmsFinding" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "destructureArmFires" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool")))))
(DFunDef false "destructureArmFires" ((PVar "orc") (PVar "p") (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "guards")) (EApp (EApp (EVar "destructurablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))))
(DTypeSig false "destructurablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "destructurablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "patIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patIrrefutable" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIrrefutable" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DFunDef false "patIrrefutable" (PWild PWild) (EVar "False"))
(DTypeSig false "recPatFieldIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldIrrefutable" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recPatFieldIrrefutable" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DTypeSig false "destructureInParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "destructureInParamFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "destructureInParamFixArms") (EVar "orc")) (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "destructureInParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "destructureInParamFixArms" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "destructureInParamFixArms" ((PVar "orc") (PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k")) (EVar "arm")))) (EVar "None")))
(DFunDef false "destructureInParamFixArms" (PWild PWild PWild PWild PWild PWild PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factOracle" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "armToClause" false) (mem "ctorIsSingle" false) (mem "declLocList" false) (mem "matchBodyOnBareParam" false) (mem "ruleNameDestructureInParam" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "summary" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "doc" (ELit (LString "A function body that is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple, record, single-constructor) can destructure in the parameter position.\n\nBefore:\n  f p = match p\n    (a, b) => a + b\nAfter:\n  f (a, b) = a + b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDestructureInParam")) (EApp (EVar "Some") (EVar "destructureInParamFix"))))
(DTypeSig false "ruleDestructureInParam" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDestructureInParam" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "destructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "destructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "destructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body"))) (arm PWild () (EListLit))))
(DTypeSig false "destructureFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") PWild (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureArmsFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "p")) (EVar "arms"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "destructureArmsFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureArmsFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "p") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDestructureInParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' destructures parameter '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' via a single-arm irrefutable `match`. Destructure it directly in the parameter position")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit)))
(DFunDef false "destructureArmsFinding" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "destructureArmFires" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool")))))
(DFunDef false "destructureArmFires" ((PVar "orc") (PVar "p") (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "guards")) (EApp (EApp (EVar "destructurablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))))
(DTypeSig false "destructurablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "destructurablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "patIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patIrrefutable" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIrrefutable" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DFunDef false "patIrrefutable" (PWild PWild) (EVar "False"))
(DTypeSig false "recPatFieldIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldIrrefutable" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recPatFieldIrrefutable" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DTypeSig false "destructureInParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "destructureInParamFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") PWild PWild)) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "destructureInParamFixArms") (EVar "orc")) (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "destructureInParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "destructureInParamFixArms" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "destructureInParamFixArms" ((PVar "orc") (PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k")) (EVar "arm")))) (EVar "None")))
(DFunDef false "destructureInParamFixArms" (PWild PWild PWild PWild PWild PWild PWild) (EVar "None"))
