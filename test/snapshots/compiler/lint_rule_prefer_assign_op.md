# META
source_lines=163
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-prefer-assign-op: `setRef r v`, or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement.

import frontend.ast.{
  Loc(..),
  unminted,
  Pat(..),
  DoStmt(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts,
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
  detApply,
  exprRuleFindings,
  exprRuleFix,
  isEVarNamed,
  noExcl,
  ruleNamePreferAssignOp,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNamePreferAssignOp,
      summary =
        "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement",
      doc =
        "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleForPreferAssign
    (Some preferAssignFix)

-- Two spellings of one smell, both left over from before the `:=` operator landed
-- (P0-5, `31f4ea80` — the sugar arrived but its ~740 existing call sites were
-- never migrated):
--
--   setRef r v        →  r := v
--   let _ = r := v    →  r := v      (a write IS a statement; it needs no binding)
--
-- The two halves have DIFFERENT equivalence arguments — do not collapse them into
-- one claim:
--
--   * `setRef r v` → `r := v` is IR-identical BY CONSTRUCTION.  `:=` is pure
--     surface sugar that `rewriteSugar` (`frontend/desugar.mdk`) lowers straight
--     back to `setRef r v` before typecheck runs, so the Core IR is unchanged —
--     verified by diffing `core_ir_dump_main` across the rewrite.
--
--   * `let _ = w` → `w` genuinely CHANGES the Core IR: `CSLet false PWild w`
--     becomes `CSExpr w`.  It is still semantics-preserving, but by argument
--     rather than by identity:
--       - NON-TAIL, the two `emitBlock` arms in `backend/llvm_emit.mdk` are
--         literally the same two lines (`let _ = emitExpr …` then recurse), so
--         emission is unchanged.
--       - TAIL, a block yields its last statement's value, and a trailing `CSLet`
--         yields Unit.  This is why the collapse is guarded to a `:=` RHS
--         SPECIFICALLY: `setRef : Ref a -> a -> Unit`, so the write yields Unit
--         either way.  The guard is load-bearing for tail position, NOT defensive
--         narrowing — widening this rule to `let _ = <any expr>` would change a
--         block's result type wherever that expr is not Unit.
--
-- (Tail position additionally sidesteps #1741 — a trailing `let` currently cannot
-- be BUILT at all, `E-PANIC: empty block`. That is a bug this rule happens to route
-- around, not a reason this rule is correct.)
--
-- Fires ONLY on a SATURATED two-argument `setRef`.  A bare `setRef` passed as a
-- value, or a partially-applied `setRef r`, has NO `:=` spelling — the operator is
-- grammar, not a function — and both shapes are real in this tree, so narrowing to
-- the saturated form is load-bearing, not defensive.
preferAssignOf : Expr -> Option Expr
preferAssignOf (EApp fn v) = setRefWriteOf (unwrapLoc fn) v
preferAssignOf (EBlock stmts) = collapsedBlockOf stmts
preferAssignOf _ = None

-- the saturated `setRef r v` spine (head already loc-unwrapped by the caller).
setRefWriteOf : Expr -> Expr -> Option Expr
setRefWriteOf (EApp hd r) v =
  if isEVarNamed "setRef" hd then Some (EBinOp ":=" r v unminted) else None
setRefWriteOf _ _ = None

-- `let _ = <write>` → a bare `<write>` statement, for every statement in a block.
-- Returns `None` when nothing moved, so the generic drivers' change-detection and
-- the fixer's "did this decl change" test both stay honest.
--
-- NOTE the interaction with the two drivers, which is deliberate: `rewriteExprBU`
-- rebuilds children BEFORE applying this at the block, so by the time a block is
-- visited its `let _ = setRef r v` has ALREADY become `let _ = r := v` and this
-- collapses it — one pass does both halves.  `collectRewrites` (the findings side)
-- instead matches the RAW node, so those sites report only the `setRef` finding and
-- are not double-counted; a block reports a collapse finding only when the source
-- ALREADY wrote `let _ = r := v` by hand.
collapsedBlockOf : List DoStmt -> Option Expr
collapsedBlockOf stmts =
  let stmts2 = map collapseWildWrite stmts
  if exprSexp (EBlock stmts2) == exprSexp (EBlock stmts) then
    None
  else
    Some (EBlock stmts2)

collapseWildWrite : DoStmt -> DoStmt
collapseWildWrite (s@(DoLet _ _ PWild e _)) =
  if isAssignWrite (unwrapLoc e) then DoExpr e else s
collapseWildWrite s = s

isAssignWrite : Expr -> Bool
isAssignWrite (EBinOp ":=" _ _ _) = True
isAssignWrite _ = False

ruleForPreferAssign : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleForPreferAssign _ _ _ pos prog =
  exprRuleFindings noExcl preferAssignOf preferAssignFinding pos prog

-- The message is shape-directed: a `setRef` hit renders its `:=` replacement (the
-- helpful "prefer …" form the sibling rules use), while a block-collapse hit does
-- NOT render the rewritten node — that node is the WHOLE block, and printing it
-- would bury the one-line point in a wall of unrelated statements.
preferAssignFinding : Option Loc -> Expr -> Finding
preferAssignFinding loc rewritten = Finding {
  rule = ruleNamePreferAssignOp,
  message = preferAssignMessage rewritten,
  severity = SevWarning,
  loc = loc,
}

preferAssignMessage : Expr -> String
preferAssignMessage (EBlock _) =
  "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`"
preferAssignMessage rewritten =
  "`setRef r v` predates the `:=` write operator. Rewrite as '"
    ++ exprToString rewritten
    ++ "'"

preferAssignFix : Oracle -> Decl -> Option (List Decl)
preferAssignFix _ d = exprRuleFix noExcl (detApply preferAssignOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "unminted" false) (mem "Pat" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNamePreferAssignOp" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleForPreferAssign")) (EApp (EVar "Some") (EVar "preferAssignFix"))))
(DTypeSig false "preferAssignOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "preferAssignOf" ((PCon "EApp" (PVar "fn") (PVar "v"))) (EApp (EApp (EVar "setRefWriteOf") (EApp (EVar "unwrapLoc") (EVar "fn"))) (EVar "v")))
(DFunDef false "preferAssignOf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "collapsedBlockOf") (EVar "stmts")))
(DFunDef false "preferAssignOf" (PWild) (EVar "None"))
(DTypeSig false "setRefWriteOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "setRefWriteOf" ((PCon "EApp" (PVar "hd") (PVar "r")) (PVar "v")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "setRef"))) (EVar "hd")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "r")) (EVar "v")) (EVar "unminted"))) (EVar "None")))
(DFunDef false "setRefWriteOf" (PWild PWild) (EVar "None"))
(DTypeSig false "collapsedBlockOf" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "collapsedBlockOf" ((PVar "stmts")) (EBlock (DoLet false false (PVar "stmts2") (EApp (EApp (EVar "map") (EVar "collapseWildWrite")) (EVar "stmts"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EApp (EVar "EBlock") (EVar "stmts2"))) (EApp (EVar "exprSexp") (EApp (EVar "EBlock") (EVar "stmts")))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "EBlock") (EVar "stmts2")))))))
(DTypeSig false "collapseWildWrite" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "collapseWildWrite" ((PAs "s" (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "e") PWild))) (EIf (EApp (EVar "isAssignWrite") (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EVar "DoExpr") (EVar "e")) (EVar "s")))
(DFunDef false "collapseWildWrite" ((PVar "s")) (EVar "s"))
(DTypeSig false "isAssignWrite" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAssignWrite" ((PCon "EBinOp" (PLit (LString ":=")) PWild PWild PWild)) (EVar "True"))
(DFunDef false "isAssignWrite" (PWild) (EVar "False"))
(DTypeSig false "ruleForPreferAssign" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleForPreferAssign" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "preferAssignOf")) (EVar "preferAssignFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "preferAssignFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "preferAssignFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreferAssignOp")) (fa "message" (EApp (EVar "preferAssignMessage") (EVar "rewritten"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "preferAssignMessage" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "preferAssignMessage" ((PCon "EBlock" PWild)) (ELit (LString "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`")))
(DFunDef false "preferAssignMessage" ((PVar "rewritten")) (EBinOp "++" (EBinOp "++" (ELit (LString "`setRef r v` predates the `:=` write operator. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'"))))
(DTypeSig false "preferAssignFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "preferAssignFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "preferAssignOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "unminted" false) (mem "Pat" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNamePreferAssignOp" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleForPreferAssign")) (EApp (EVar "Some") (EVar "preferAssignFix"))))
(DTypeSig false "preferAssignOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "preferAssignOf" ((PCon "EApp" (PVar "fn") (PVar "v"))) (EApp (EApp (EVar "setRefWriteOf") (EApp (EVar "unwrapLoc") (EVar "fn"))) (EVar "v")))
(DFunDef false "preferAssignOf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "collapsedBlockOf") (EVar "stmts")))
(DFunDef false "preferAssignOf" (PWild) (EVar "None"))
(DTypeSig false "setRefWriteOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "setRefWriteOf" ((PCon "EApp" (PVar "hd") (PVar "r")) (PVar "v")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "setRef"))) (EVar "hd")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "r")) (EVar "v")) (EVar "unminted"))) (EVar "None")))
(DFunDef false "setRefWriteOf" (PWild PWild) (EVar "None"))
(DTypeSig false "collapsedBlockOf" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "collapsedBlockOf" ((PVar "stmts")) (EBlock (DoLet false false (PVar "stmts2") (EApp (EApp (EMethodRef "map") (EVar "collapseWildWrite")) (EVar "stmts"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EApp (EVar "EBlock") (EVar "stmts2"))) (EApp (EVar "exprSexp") (EApp (EVar "EBlock") (EVar "stmts")))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "EBlock") (EVar "stmts2")))))))
(DTypeSig false "collapseWildWrite" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "collapseWildWrite" ((PAs "s" (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "e") PWild))) (EIf (EApp (EVar "isAssignWrite") (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EVar "DoExpr") (EVar "e")) (EVar "s")))
(DFunDef false "collapseWildWrite" ((PVar "s")) (EVar "s"))
(DTypeSig false "isAssignWrite" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAssignWrite" ((PCon "EBinOp" (PLit (LString ":=")) PWild PWild PWild)) (EVar "True"))
(DFunDef false "isAssignWrite" (PWild) (EVar "False"))
(DTypeSig false "ruleForPreferAssign" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleForPreferAssign" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "preferAssignOf")) (EVar "preferAssignFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "preferAssignFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "preferAssignFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreferAssignOp")) (fa "message" (EApp (EVar "preferAssignMessage") (EVar "rewritten"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "preferAssignMessage" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "preferAssignMessage" ((PCon "EBlock" PWild)) (ELit (LString "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`")))
(DFunDef false "preferAssignMessage" ((PVar "rewritten")) (EBinOp "++" (EBinOp "++" (ELit (LString "`setRef r v` predates the `:=` write operator. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'"))))
(DTypeSig false "preferAssignFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "preferAssignFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "preferAssignOf"))) (EVar "d")))
