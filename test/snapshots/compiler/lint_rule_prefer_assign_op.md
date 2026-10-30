# META
source_lines=223
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
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts,
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  bindingOf,
  exprRuleEditVisitors,
  isEVarNamed,
  nodeSpan,
  noExcl,
  replaceFix,
  ruleNamePreferAssignOp,
  tightSpan,
  unwrapLoc,
  usesPreludeName,
}

export
rule : Rule
rule =
  mkVisitorRule
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
      needs = [NeedsScopes],
    }
    ruleForPreferAssign
    None

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
-- NOTE the interaction with the two sides, which is deliberate: `rewriteExprBU`
-- rebuilds children BEFORE applying this at the block, so by the time a block is
-- visited its `let _ = setRef r v` has ALREADY become `let _ = r := v` and this
-- collapses it — one pass does both halves.  The findings side
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
  List Visitor
ruleForPreferAssign _ _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    preferAssignOf
    (preferAssignFix facts)
    preferAssignFinding

-- The message is shape-directed: a `setRef` hit renders its `:=` replacement (the
-- helpful "prefer …" form the sibling rules use), while a block-collapse hit does
-- NOT render the rewritten node — that node is the WHOLE block, and printing it
-- would bury the one-line point in a wall of unrelated statements.
preferAssignFinding : Option Loc -> Expr -> Option Fix -> Finding
preferAssignFinding loc rewritten fix = Finding {
  rule = ruleNamePreferAssignOp,
  message = preferAssignMessage rewritten,
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

preferAssignMessage : Expr -> String
preferAssignMessage (EBlock _) =
  "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`"
preferAssignMessage rewritten =
  "`setRef r v` predates the `:=` write operator. Rewrite as '"
    ++ exprToString rewritten
    ++ "'"

-- A `setRef` rewrite reads the prelude's `setRef`, so it is withheld where the
-- file binds that name: the call it matched would then be the file's own.  The
-- collapse reads no name (`:=` is grammar).
preferAssignFix : FileFacts -> Ctx -> Expr -> Expr -> Option Fix
preferAssignFix _ _ (EBlock stmts) _ = collapseFix stmts
preferAssignFix facts ctx e rewritten = setRefFix facts ctx e rewritten

setRefFix : FileFacts -> Ctx -> Expr -> Expr -> Option Fix
setRefFix facts ctx (e@(EApp fn _)) rewritten = match unwrapLoc fn
  EApp hd _ =>
    if usesPreludeName facts hd then
      replaceFix
        "use the `:=` write operator"
        (nodeSpan ctx e)
        (bindingOf rewritten)
        ctx
        (exprToString rewritten)
    else
      None
  _ => None
setRefFix _ _ _ _ = None

-- One edit per `let _ = <write>` statement, deleting the text from the `let`
-- keyword to the write.  The statement's `Loc` is the `let` keyword's span; a
-- zero-width `Loc` marks a synthesized statement, which gets no edit.
collapseFix : List DoStmt -> Option Fix
collapseFix stmts =
  let edits = flatMap collapseEdit stmts
  if isEmpty edits then
    None
  else
    Some Fix {
      fixApplicability = Safe,
      fixEdits = edits,
      fixMessage = "drop the `let _ =`",
    }

collapseEdit : DoStmt -> List FixEdit
collapseEdit (DoLet _ _ PWild rhs (Loc f sl sc el ec))
  | (sl /= el || sc /= ec) && isAssignWrite (unwrapLoc rhs) = match rhsStart rhs
    Some (Loc _ rl rc _ _) => [FixEdit (Loc f sl sc rl rc) ""]
    None => []
collapseEdit _ = []

-- The write's start is its left operand's: the `ELoc` over an assignment starts
-- at the `:=` token, so the operands are read instead.  `None` (no edit) when
-- the left operand is a node whose own tokens no `ELoc` covers.
rhsStart : Expr -> Option Loc
rhsStart e = tightSpan (unwrapLoc e)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "unminted" false) (mem "Pat" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNamePreferAssignOp" false) (mem "tightSpan" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleForPreferAssign")) (EVar "None")))
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
(DTypeSig false "ruleForPreferAssign" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleForPreferAssign" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "preferAssignOf")) (EApp (EVar "preferAssignFix") (EVar "facts"))) (EVar "preferAssignFinding")))
(DTypeSig false "preferAssignFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "preferAssignFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreferAssignOp")) (fa "message" (EApp (EVar "preferAssignMessage") (EVar "rewritten"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "preferAssignMessage" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "preferAssignMessage" ((PCon "EBlock" PWild)) (ELit (LString "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`")))
(DFunDef false "preferAssignMessage" ((PVar "rewritten")) (EBinOp "++" (EBinOp "++" (ELit (LString "`setRef r v` predates the `:=` write operator. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'"))))
(DTypeSig false "preferAssignFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "preferAssignFix" (PWild PWild (PCon "EBlock" (PVar "stmts")) PWild) (EApp (EVar "collapseFix") (EVar "stmts")))
(DFunDef false "preferAssignFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EApp (EApp (EApp (EApp (EVar "setRefFix") (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten")))
(DTypeSig false "setRefFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "setRefFix" ((PVar "facts") (PVar "ctx") (PAs "e" (PCon "EApp" (PVar "fn") PWild)) (PVar "rewritten")) (EMatch (EApp (EVar "unwrapLoc") (EVar "fn")) (arm (PCon "EApp" (PVar "hd") PWild) () (EIf (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the `:=` write operator"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "setRefFix" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "collapseFix" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Fix"))))
(DFunDef false "collapseFix" ((PVar "stmts")) (EBlock (DoLet false false (PVar "edits") (EApp (EApp (EVar "flatMap") (EVar "collapseEdit")) (EVar "stmts"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "edits")) (EVar "None") (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EVar "edits")) (fa "fixMessage" (ELit (LString "drop the `let _ =`"))))))))))
(DTypeSig false "collapseEdit" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "FixEdit"))))
(DFunDef false "collapseEdit" ((PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "/=" (EVar "sl") (EVar "el")) (EBinOp "/=" (EVar "sc") (EVar "ec"))) (EApp (EVar "isAssignWrite") (EApp (EVar "unwrapLoc") (EVar "rhs")))) (EMatch (EApp (EVar "rhsStart") (EVar "rhs")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild)) () (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "collapseEdit" (PWild) (EListLit))
(DTypeSig false "rhsStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "rhsStart" ((PVar "e")) (EApp (EVar "tightSpan") (EApp (EVar "unwrapLoc") (EVar "e"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "unminted" false) (mem "Pat" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNamePreferAssignOp" false) (mem "tightSpan" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleForPreferAssign")) (EVar "None")))
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
(DTypeSig false "ruleForPreferAssign" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleForPreferAssign" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "preferAssignOf")) (EApp (EVar "preferAssignFix") (EVar "facts"))) (EVar "preferAssignFinding")))
(DTypeSig false "preferAssignFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "preferAssignFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreferAssignOp")) (fa "message" (EApp (EVar "preferAssignMessage") (EVar "rewritten"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "preferAssignMessage" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "preferAssignMessage" ((PCon "EBlock" PWild)) (ELit (LString "`let _ = … := …` binds a write to a wildcard. A `:=` write is a statement — drop the `let _ =`")))
(DFunDef false "preferAssignMessage" ((PVar "rewritten")) (EBinOp "++" (EBinOp "++" (ELit (LString "`setRef r v` predates the `:=` write operator. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'"))))
(DTypeSig false "preferAssignFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "preferAssignFix" (PWild PWild (PCon "EBlock" (PVar "stmts")) PWild) (EApp (EVar "collapseFix") (EVar "stmts")))
(DFunDef false "preferAssignFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EApp (EApp (EApp (EApp (EVar "setRefFix") (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten")))
(DTypeSig false "setRefFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "setRefFix" ((PVar "facts") (PVar "ctx") (PAs "e" (PCon "EApp" (PVar "fn") PWild)) (PVar "rewritten")) (EMatch (EApp (EVar "unwrapLoc") (EVar "fn")) (arm (PCon "EApp" (PVar "hd") PWild) () (EIf (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the `:=` write operator"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "setRefFix" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "collapseFix" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Fix"))))
(DFunDef false "collapseFix" ((PVar "stmts")) (EBlock (DoLet false false (PVar "edits") (EApp (EApp (EDictApp "flatMap") (EVar "collapseEdit")) (EVar "stmts"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "edits")) (EVar "None") (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EVar "edits")) (fa "fixMessage" (ELit (LString "drop the `let _ =`"))))))))))
(DTypeSig false "collapseEdit" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "FixEdit"))))
(DFunDef false "collapseEdit" ((PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "/=" (EVar "sl") (EVar "el")) (EBinOp "/=" (EVar "sc") (EVar "ec"))) (EApp (EVar "isAssignWrite") (EApp (EVar "unwrapLoc") (EVar "rhs")))) (EMatch (EApp (EVar "rhsStart") (EVar "rhs")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild)) () (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "collapseEdit" (PWild) (EListLit))
(DTypeSig false "rhsStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "rhsStart" ((PVar "e")) (EApp (EVar "tightSpan") (EApp (EVar "unwrapLoc") (EVar "e"))))
