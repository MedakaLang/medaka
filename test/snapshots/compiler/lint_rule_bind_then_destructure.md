# META
source_lines=211
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-bind-then-destructure: a do-bind immediately destructured by an irrefutable single-arm `match`. Inline the pattern into the bind.

-- ── rule: bind-then-destructure ───────────────────────────────────────────────
-- Inside any do/bare block, a `v <- e` bind immediately followed by a FINAL
-- statement `match v { pat => body }` (exactly one arm, no guards) where `pat` is
-- IRREFUTABLE (tuple/record/var/wildcard, recursively — OR a single-constructor
-- pattern `PCon c subps` where `c` is the SOLE constructor of its datatype, as
-- decided by the syntactic constructor `Oracle`, with all sub-patterns
-- recursively irrefutable) and `v` does NOT appear free in `body`.  Such a pair
-- is just `pat <- e` with `body` inlined.  Detection recurses into every nested
-- do/bare block in the decl body; the autofix is a pure AST rewrite (the
-- framework re-renders the returned Decl via the printer).
--
-- The `Oracle` is `frontend.exhaust.buildOracle` over the whole target file's
-- decls — a purely SYNTACTIC scan of constructor declarations (no typecheck),
-- so multi-ctor wrappers (`Some v <-`, `Ok x <-`, `Cons`/`Nil`) stay refutable
-- and are skipped, while genuine newtype/single-variant wrappers collapse.
--
-- `v`-not-free-in-`body` uses the same conservative printed whole-word scan the
-- §8 fixer relies on (`wholeWordIn`): it can only over-bail (suppress a real
-- finding), never produce an unsound fix.

import frontend.ast.{
  Loc(..), Pat(..), RecPatField(..), Arm(..), DoStmt(..), Expr(..), Decl(..)
}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{anyList, reverseL}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex(..),
  Visitor(..),
  mkVisitorRule,
  factOracle,
}
import tools.lint_shared.{
  ctorIsSingle,
  detApply,
  exprRuleFix,
  noExcl,
  ruleNameBindThenDestructure,
  unwrapLoc,
  wholeWordIn,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameBindThenDestructure,
      summary =
        "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind",
      doc =
        "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleBindThenDestructure
    (Some bindThenDestructureFix)

-- a pattern is irrefutable iff it is a var/wildcard, a tuple/record whose
-- sub-patterns are all themselves irrefutable, or a single-constructor pattern
-- (the constructor is the only one of its datatype, per the syntactic oracle)
-- whose sub-patterns are all irrefutable.  Everything else (multi-ctor, cons,
-- list, literal, range, as-pattern) is refutable for this rule's purposes.
irrefutablePat : Oracle -> Pat -> Bool
irrefutablePat _ (PVar _ _ _) = True
irrefutablePat _ PWild = True
irrefutablePat orc (PTuple ps) = not (anyList (refutablePat orc) ps)
irrefutablePat orc (PRec _ fields _) = not (anyList (refutableField orc) fields)
irrefutablePat orc (PCon c subps) =
  ctorIsSingle orc c && not (anyList (refutablePat orc) subps)
irrefutablePat _ _ = False

refutablePat : Oracle -> Pat -> Bool
refutablePat orc p = not (irrefutablePat orc p)

refutableField : Oracle -> RecPatField -> Bool
refutableField _ (RecPatField _ _ _ None) = False
refutableField orc (RecPatField _ _ _ (Some p)) = refutablePat orc p

-- the bound-var/pattern/expr/body of a collapsible bind-then-match tail, plus the
-- statements preceding it.  Returns None when the last two statements don't form
-- the irrefutable single-arm shape.
bindMatchTail : Oracle ->
  List DoStmt ->
  Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchTail orc stmts = match splitTail2 stmts
  Some (prefix, DoBind (PVar v _ _) boundE, DoExpr matchE) =>
    bindMatchArm orc prefix v boundE (unwrapLoc matchE)
  _ => None

bindMatchArm : Oracle ->
  List DoStmt ->
  String ->
  Expr ->
  Expr ->
  Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchArm orc prefix v boundE (EMatch scrut [Arm pat [] body])
  | scrutIsVar v (unwrapLoc scrut)
    && irrefutablePat orc pat
    && not (wholeWordIn v (exprToString body)) =
    Some (prefix, v, pat, boundE, body)
  | otherwise = None
bindMatchArm _ _ _ _ _ = None

scrutIsVar : String -> Expr -> Bool
scrutIsVar v (EVar w) = v == w
scrutIsVar _ _ = False

-- last two statements (prefix, second-to-last, last), or None if fewer than 2.
splitTail2 : List DoStmt -> Option (List DoStmt, DoStmt, DoStmt)
splitTail2 stmts = match reverseL stmts
  lst :: scd :: restRev => Some (reverseL restRev, scd, lst)
  _ => None

-- ── check ────────────────────────────────────────────────────────────────────
-- Only `do` and bare blocks can end in the shape, so only those are visited.
ruleBindThenDestructure : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleBindThenDestructure _ _ facts _ _ =
  [OnExpr [KDo, KBlock] (bindThenDestructureAt (factOracle facts))]

bindThenDestructureAt : Oracle -> Ctx -> Expr -> List Finding
bindThenDestructureAt orc ctx e = match blockStmts e
  Some stmts => match bindMatchTail orc stmts
    Some (_, v, _, _, _) => [bindDestructureFinding ctx.ctxDeclLoc v]
    None => []
  None => []

blockStmts : Expr -> Option (List DoStmt)
blockStmts (EDo _ stmts) = Some stmts
blockStmts (EBlock stmts) = Some stmts
blockStmts _ = None

bindDestructureFinding : Option Loc -> String -> Finding
bindDestructureFinding loc v = Finding {
  rule = ruleNameBindThenDestructure,
  message =
    "binds '"
      ++ v
      ++ "' then immediately destructures it in a final `match`. Inline the pattern into the bind",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

-- ── autofix ──────────────────────────────────────────────────────────────────
-- Bottom-up: every collapsible bind-then-match tail is inlined.
bindThenDestructureFix : Oracle -> Decl -> Option (List Decl)
bindThenDestructureFix orc d =
  exprRuleFix noExcl (detApply (bindThenDestructureRewrite orc)) d

-- Replace the last two statements of a do/bare block with `pat <- e` plus the
-- arm body's statements spliced inline.
bindThenDestructureRewrite : Oracle -> Expr -> Option Expr
bindThenDestructureRewrite orc (EDo d stmts) =
  map (collapsed => EDo d collapsed) (collapseTail orc (heraldOf d) stmts)
bindThenDestructureRewrite orc (EBlock stmts) =
  map (collapsed => EBlock collapsed) (collapseTail orc HeraldDo stmts)
bindThenDestructureRewrite _ _ = None

-- Which keyword heralds a block: `do`, or `defer` (the deferred flag of `EDo`).
data Herald = HeraldDo | HeraldDefer

heraldOf : Bool -> Herald
heraldOf True = HeraldDefer
heraldOf False = HeraldDo

collapseTail : Oracle -> Herald -> List DoStmt -> Option (List DoStmt)
collapseTail orc host stmts =
  map
    ((prefix, _, pat, boundE, body) =>
      prefix ++ (DoBind pat boundE :: bodyToStmts host body))
    (bindMatchTail orc stmts)

-- the arm body as statements: a bare block, or a monadic block heralded the SAME
-- way as the host (`host`: the enclosing block's herald), contributes its
-- own statements flattened into the outer block; anything else — including a
-- `defer` block inside a `do` block or vice versa, whose statements bind through
-- a different interface family (#824) — becomes a final expr-statement.
bodyToStmts : Herald -> Expr -> List DoStmt
bodyToStmts host e = match unwrapLoc e
  EDo d stmts => whenSameHerald host (heraldOf d) stmts e
  EBlock stmts => stmts
  _ => [DoExpr e]

whenSameHerald : Herald -> Herald -> List DoStmt -> Expr -> List DoStmt
whenSameHerald HeraldDo HeraldDo stmts _ = stmts
whenSameHerald HeraldDefer HeraldDefer stmts _ = stmts
whenSameHerald _ _ _ e = [DoExpr e]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "Visitor" true) (mem "mkVisitorRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorIsSingle" false) (mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "ruleNameBindThenDestructure" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KDo") (EVar "KBlock"))) (EApp (EVar "bindThenDestructureAt") (EApp (EVar "factOracle") (EVar "facts"))))))
(DTypeSig false "bindThenDestructureAt" (TyFun (TyCon "Oracle") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "bindThenDestructureAt" ((PVar "orc") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "blockStmts") (EVar "e")) (arm (PCon "Some" (PVar "stmts")) () (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EApp (EApp (EVar "bindDestructureFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "v")))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "blockStmts" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "blockStmts" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EVar "Some") (EVar "stmts")))
(DFunDef false "blockStmts" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "Some") (EVar "stmts")))
(DFunDef false "blockStmts" (PWild) (EVar "None"))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EApp (EVar "bindThenDestructureRewrite") (EVar "orc")))) (EVar "d")))
(DTypeSig false "bindThenDestructureRewrite" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "bindThenDestructureRewrite" ((PVar "orc") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "map") (ELam ((PVar "collapsed")) (EApp (EApp (EVar "EDo") (EVar "d")) (EVar "collapsed")))) (EApp (EApp (EApp (EVar "collapseTail") (EVar "orc")) (EApp (EVar "heraldOf") (EVar "d"))) (EVar "stmts"))))
(DFunDef false "bindThenDestructureRewrite" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "map") (ELam ((PVar "collapsed")) (EApp (EVar "EBlock") (EVar "collapsed")))) (EApp (EApp (EApp (EVar "collapseTail") (EVar "orc")) (EVar "HeraldDo")) (EVar "stmts"))))
(DFunDef false "bindThenDestructureRewrite" (PWild PWild) (EVar "None"))
(DData Private "Herald" () ((variant "HeraldDo" (ConPos)) (variant "HeraldDefer" (ConPos))) ())
(DTypeSig false "heraldOf" (TyFun (TyCon "Bool") (TyCon "Herald")))
(DFunDef false "heraldOf" ((PCon "True")) (EVar "HeraldDefer"))
(DFunDef false "heraldOf" ((PCon "False")) (EVar "HeraldDo"))
(DTypeSig false "collapseTail" (TyFun (TyCon "Oracle") (TyFun (TyCon "Herald") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "collapseTail" ((PVar "orc") (PVar "host") (PVar "stmts")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EApp (EVar "bodyToStmts") (EVar "host")) (EVar "body")))))) (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Herald") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bodyToStmts" ((PVar "host") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "d") (PVar "stmts")) () (EApp (EApp (EApp (EApp (EVar "whenSameHerald") (EVar "host")) (EApp (EVar "heraldOf") (EVar "d"))) (EVar "stmts")) (EVar "e"))) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "whenSameHerald" (TyFun (TyCon "Herald") (TyFun (TyCon "Herald") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "whenSameHerald" ((PCon "HeraldDo") (PCon "HeraldDo") (PVar "stmts") PWild) (EVar "stmts"))
(DFunDef false "whenSameHerald" ((PCon "HeraldDefer") (PCon "HeraldDefer") (PVar "stmts") PWild) (EVar "stmts"))
(DFunDef false "whenSameHerald" (PWild PWild PWild (PVar "e")) (EListLit (EApp (EVar "DoExpr") (EVar "e"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "Visitor" true) (mem "mkVisitorRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorIsSingle" false) (mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "ruleNameBindThenDestructure" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KDo") (EVar "KBlock"))) (EApp (EVar "bindThenDestructureAt") (EApp (EVar "factOracle") (EVar "facts"))))))
(DTypeSig false "bindThenDestructureAt" (TyFun (TyCon "Oracle") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "bindThenDestructureAt" ((PVar "orc") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "blockStmts") (EVar "e")) (arm (PCon "Some" (PVar "stmts")) () (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EApp (EApp (EVar "bindDestructureFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "v")))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "blockStmts" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "blockStmts" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EVar "Some") (EVar "stmts")))
(DFunDef false "blockStmts" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "Some") (EVar "stmts")))
(DFunDef false "blockStmts" (PWild) (EVar "None"))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EApp (EVar "bindThenDestructureRewrite") (EVar "orc")))) (EVar "d")))
(DTypeSig false "bindThenDestructureRewrite" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "bindThenDestructureRewrite" ((PVar "orc") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "collapsed")) (EApp (EApp (EVar "EDo") (EVar "d")) (EVar "collapsed")))) (EApp (EApp (EApp (EVar "collapseTail") (EVar "orc")) (EApp (EVar "heraldOf") (EVar "d"))) (EVar "stmts"))))
(DFunDef false "bindThenDestructureRewrite" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "collapsed")) (EApp (EVar "EBlock") (EVar "collapsed")))) (EApp (EApp (EApp (EVar "collapseTail") (EVar "orc")) (EVar "HeraldDo")) (EVar "stmts"))))
(DFunDef false "bindThenDestructureRewrite" (PWild PWild) (EVar "None"))
(DData Private "Herald" () ((variant "HeraldDo" (ConPos)) (variant "HeraldDefer" (ConPos))) ())
(DTypeSig false "heraldOf" (TyFun (TyCon "Bool") (TyCon "Herald")))
(DFunDef false "heraldOf" ((PCon "True")) (EVar "HeraldDefer"))
(DFunDef false "heraldOf" ((PCon "False")) (EVar "HeraldDo"))
(DTypeSig false "collapseTail" (TyFun (TyCon "Oracle") (TyFun (TyCon "Herald") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "collapseTail" ((PVar "orc") (PVar "host") (PVar "stmts")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EApp (EVar "bodyToStmts") (EVar "host")) (EVar "body")))))) (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Herald") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bodyToStmts" ((PVar "host") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "d") (PVar "stmts")) () (EApp (EApp (EApp (EApp (EVar "whenSameHerald") (EVar "host")) (EApp (EVar "heraldOf") (EVar "d"))) (EVar "stmts")) (EVar "e"))) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "whenSameHerald" (TyFun (TyCon "Herald") (TyFun (TyCon "Herald") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "whenSameHerald" ((PCon "HeraldDo") (PCon "HeraldDo") (PVar "stmts") PWild) (EVar "stmts"))
(DFunDef false "whenSameHerald" ((PCon "HeraldDefer") (PCon "HeraldDefer") (PVar "stmts") PWild) (EVar "stmts"))
(DFunDef false "whenSameHerald" (PWild PWild PWild (PVar "e")) (EListLit (EApp (EVar "DoExpr") (EVar "e"))))
