# META
source_lines=195
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-if-max-min: an `if` that selects the larger or smaller of two operands. Prefer `max`/`min`.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import ir.sexp.{exprSexp}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  mkVisitorRule,
}
import tools.lint_shared.{
  rebinds,
  declLocList,
  replaceNodeFix,
  ruleNameIfMaxMin,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameIfMaxMin,
      summary =
        "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`",
      doc =
        "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = FixableUnsafe,
      needs = [NeedsScopes, NeedsStdlibIndex],
    }
    ruleIfMaxMin
    None

-- ── rule: if-max-min (an `if` selecting the larger/smaller of two operands) ────
-- `if a > b then a else b` (and the >=/</<=/reversed-branch variants) select the
-- SAME two operands as the comparison — rewritable to the canonical `max`/`min`
-- prelude methods (always in-scope `Ord` methods).
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * the condition must be a comparison `EBinOp` with op in {>, >=, <, <=} —
--     symbolic ops only (backtick `EInfix` comparisons are a DIFFERENT node and
--     are not handled).
--   * `then`/`else` must each be STRUCTURALLY EQUAL (via `ir.sexp.exprSexp`,
--     which already strips source locations — the same comparator
--     `rule-duplicate-body` uses) to one of the two comparison operands, and
--     together must cover BOTH operands (one branch keys to `a`, the other to
--     `b`) — so `if x < 0 then 0 else x` (0 is not an operand) and
--     `if a > b then a else c` (c isn't b) both skip.
--   * if the two operands are themselves structurally identical, skip (the
--     rewrite is a no-op / degenerate — nothing to gain, and it hides which
--     operand the rule "picked").
-- The check walks the WHOLE decl expression tree (an `if` can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible `if` to a `max`/`min` application.

-- true for the four symbolic comparison operators this rule handles.
ifMaxMinCompareOp : String -> Bool
ifMaxMinCompareOp op = op == ">" || op == ">=" || op == "<" || op == "<="

-- which prelude fn the idiom collapses to when `then` keys to the LEFT operand
-- and `else` keys to the RIGHT operand (the "normal" orientation).
ifMaxMinFnNormal : String -> String
ifMaxMinFnNormal op
  | op == ">" || op == ">=" = "max"
  | otherwise = "min"

-- ...and when the branches are REVERSED (`then` keys to the right operand).
ifMaxMinFnReversed : String -> String
ifMaxMinFnReversed op
  | op == ">" || op == ">=" = "min"
  | otherwise = "max"

-- a bare literal operand (`ELit`/`ENumLit`) disqualifies the idiom — a
-- clamp-to-constant shape like `if x < 0 then 0 else x` (max x 0) reads as a
-- deliberate clamp, not the "same two operands" max/min idiom this rule
-- targets, so it is conservatively left alone.
isLiteralExpr : Expr -> Bool
isLiteralExpr e = match unwrapLoc e
  ELit _ => True
  ENumLit _ _ _ => True
  EWideLit _ _ _ _ => True
  _ => False

-- does `EIf cond t el` match the idiom?  Returns the prelude fn name plus the
-- comparison's left/right operands (always emitted left-then-right, regardless
-- of which branch order matched) — or `None` if not eligible.
ifMaxMinOf : Expr -> Expr -> Expr -> Option (String, Expr, Expr)
ifMaxMinOf cond t el = match unwrapLoc cond
  EBinOp op a b _ if ifMaxMinCompareOp op =>
    let aK = exprSexp a
    let bK = exprSexp b
    let tK = exprSexp t
    let eK = exprSexp el
    if aK == bK || isLiteralExpr a || isLiteralExpr b then
      None
    else if tK == aK && eK == bK then
      Some (ifMaxMinFnNormal op, a, b)
    else if tK == bK && eK == aK then
      Some (ifMaxMinFnReversed op, a, b)
    else
      None
  _ => None

-- ── check ─────────────────────────────────────────────────────────────────────
-- Only `EIf` nodes can match, so only those are visited.
ruleIfMaxMin : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleIfMaxMin idx _ facts pos decls =
  [OnExpr [KIf] (ifMaxMinAt idx (ordImplLocs pos decls) facts)]

ifMaxMinAt : StdlibIndex -> List Loc -> FileFacts -> Ctx -> Expr -> List Finding
ifMaxMinAt idx ordLocs facts ctx (e@(EIf cond t el)) =
  match ifMaxMinOf cond t el
    Some hit => [
      ifMaxMinFinding
        ctx.ctxDeclLoc
        hit
        (ifMaxMinFix idx ordLocs facts ctx e hit),
    ]
    None => []
ifMaxMinAt _ _ _ _ _ = []

ifMaxMinFinding : Option Loc -> (String, Expr, Expr) -> Option Fix -> Finding
ifMaxMinFinding loc (fn, a, b) fix = Finding {
  rule = ruleNameIfMaxMin,
  message =
    "if-then-else selects the \{if fn == "max" then "larger" else "smaller"} of the same two operands. Rewrite as '\{exprToString (EApp (EApp (EVar fn) a) b)}'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- The fix replaces the `if` with a `max`/`min` call.  It is withheld in two places,
-- and the finding is reported either way:
--   * inside an `impl Ord`: the call resolves to the `Ord` method being defined,
--     so `min a b = if a <= b then a else b` would become `min a b = min a b`;
--   * where the file binds the called name, since the call is then not the prelude's.
-- A `lint-disable-next-line` over the site drops the finding, so its fix with it.
ifMaxMinFix : StdlibIndex ->
  List Loc ->
  FileFacts ->
  Ctx ->
  Expr ->
  (String, Expr, Expr) ->
  Option Fix
ifMaxMinFix idx ordLocs facts ctx e (fn, a, b) =
  if inOrdImpl ctx.ctxDeclLoc ordLocs || rebinds idx facts ctx fn then
    None
  else
    let call = EApp (EApp (EVar fn) a) b
    replaceNodeFix Unsafe ("select with " ++ fn) ctx e call

-- The declaration locations of the `impl Ord` blocks.  The walk gives every body
-- of an impl the impl's own location as its `ctxDeclLoc`.
ordImplLocs : Positions -> List Decl -> List Loc
ordImplLocs pos decls = flatMap ordImplLoc (declLocList pos decls)

ordImplLoc : (Decl, Option Loc) -> List Loc
ordImplLoc (d, loc) = match (isOrdImpl d, loc)
  (True, Some l) => [l]
  _ => []

isOrdImpl : Decl -> Bool
isOrdImpl (DImpl { iface = i }) = i == "Ord"
isOrdImpl (DAttrib _ d) = isOrdImpl d
isOrdImpl _ = False

inOrdImpl : Option Loc -> List Loc -> Bool
inOrdImpl (Some l) ls = elem l ls
inOrdImpl None _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "rebinds" false) (mem "declLocList" false) (mem "replaceNodeFix" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleIfMaxMin")) (EVar "None")))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleIfMaxMin" ((PVar "idx") PWild (PVar "facts") (PVar "pos") (PVar "decls")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KIf"))) (EApp (EApp (EApp (EVar "ifMaxMinAt") (EVar "idx")) (EApp (EApp (EVar "ordImplLocs") (EVar "pos")) (EVar "decls"))) (EVar "facts")))))
(DTypeSig false "ifMaxMinAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ifMaxMinAt" ((PVar "idx") (PVar "ordLocs") (PVar "facts") (PVar "ctx") (PAs "e" (PCon "EIf" (PVar "cond") (PVar "t") (PVar "el")))) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PVar "hit")) () (EListLit (EApp (EApp (EApp (EVar "ifMaxMinFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "hit")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifMaxMinFix") (EVar "idx")) (EVar "ordLocs")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "hit"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "ifMaxMinAt" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b")) (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Fix")))))))))
(DFunDef false "ifMaxMinFix" ((PVar "idx") (PVar "ordLocs") (PVar "facts") (PVar "ctx") (PVar "e") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (EIf (EBinOp "||" (EApp (EApp (EVar "inOrdImpl") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "ordLocs")) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "fn"))) (EVar "None") (EBlock (DoLet false false (PVar "call") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Unsafe")) (EBinOp "++" (ELit (LString "select with ")) (EVar "fn"))) (EVar "ctx")) (EVar "e")) (EVar "call"))))))
(DTypeSig false "ordImplLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Loc")))))
(DFunDef false "ordImplLocs" ((PVar "pos") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "ordImplLoc")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "decls"))))
(DTypeSig false "ordImplLoc" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Loc"))))
(DFunDef false "ordImplLoc" ((PTuple (PVar "d") (PVar "loc"))) (EMatch (ETuple (EApp (EVar "isOrdImpl") (EVar "d")) (EVar "loc")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "l"))) () (EListLit (EVar "l"))) (arm PWild () (EListLit))))
(DTypeSig false "isOrdImpl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isOrdImpl" ((PRec "DImpl" ((rf "iface" (PVar "i"))) false)) (EBinOp "==" (EVar "i") (ELit (LString "Ord"))))
(DFunDef false "isOrdImpl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isOrdImpl") (EVar "d")))
(DFunDef false "isOrdImpl" (PWild) (EVar "False"))
(DTypeSig false "inOrdImpl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "inOrdImpl" ((PCon "Some" (PVar "l")) (PVar "ls")) (EApp (EApp (EVar "elem") (EVar "l")) (EVar "ls")))
(DFunDef false "inOrdImpl" ((PCon "None") PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "rebinds" false) (mem "declLocList" false) (mem "replaceNodeFix" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleIfMaxMin")) (EVar "None")))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleIfMaxMin" ((PVar "idx") PWild (PVar "facts") (PVar "pos") (PVar "decls")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KIf"))) (EApp (EApp (EApp (EVar "ifMaxMinAt") (EVar "idx")) (EApp (EApp (EVar "ordImplLocs") (EVar "pos")) (EVar "decls"))) (EVar "facts")))))
(DTypeSig false "ifMaxMinAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ifMaxMinAt" ((PVar "idx") (PVar "ordLocs") (PVar "facts") (PVar "ctx") (PAs "e" (PCon "EIf" (PVar "cond") (PVar "t") (PVar "el")))) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PVar "hit")) () (EListLit (EApp (EApp (EApp (EVar "ifMaxMinFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "hit")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifMaxMinFix") (EVar "idx")) (EVar "ordLocs")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "hit"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "ifMaxMinAt" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b")) (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Fix")))))))))
(DFunDef false "ifMaxMinFix" ((PVar "idx") (PVar "ordLocs") (PVar "facts") (PVar "ctx") (PVar "e") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (EIf (EBinOp "||" (EApp (EApp (EVar "inOrdImpl") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "ordLocs")) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "fn"))) (EVar "None") (EBlock (DoLet false false (PVar "call") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Unsafe")) (EBinOp "++" (ELit (LString "select with ")) (EVar "fn"))) (EVar "ctx")) (EVar "e")) (EVar "call"))))))
(DTypeSig false "ordImplLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Loc")))))
(DFunDef false "ordImplLocs" ((PVar "pos") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "ordImplLoc")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "decls"))))
(DTypeSig false "ordImplLoc" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Loc"))))
(DFunDef false "ordImplLoc" ((PTuple (PVar "d") (PVar "loc"))) (EMatch (ETuple (EApp (EVar "isOrdImpl") (EVar "d")) (EVar "loc")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "l"))) () (EListLit (EVar "l"))) (arm PWild () (EListLit))))
(DTypeSig false "isOrdImpl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isOrdImpl" ((PRec "DImpl" ((rf "iface" (PVar "i"))) false)) (EBinOp "==" (EVar "i") (ELit (LString "Ord"))))
(DFunDef false "isOrdImpl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isOrdImpl") (EVar "d")))
(DFunDef false "isOrdImpl" (PWild) (EVar "False"))
(DTypeSig false "inOrdImpl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "inOrdImpl" ((PCon "Some" (PVar "l")) (PVar "ls")) (EApp (EApp (EDictApp "elem") (EVar "l")) (EVar "ls")))
(DFunDef false "inOrdImpl" ((PCon "None") PWild) (EVar "False"))
