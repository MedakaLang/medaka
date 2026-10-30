# META
source_lines=223
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-concat-to-interp: a `++` chain mixing string literals and expressions. Prefer string interpolation.

-- ── rule: concat-to-interp ────────────────────────────────────────────────────
-- An `++` spine that mixes string LITERALS and expressions is string concat that
-- reads better as an interpolated string: `"  " ++ r ++ " = " ++ v` → `"  \{r} = \{v}"`.
--
-- SOUNDNESS.  `\{e}` auto-stringifies its hole; for a String-typed operand `\{s}`
-- renders `s` VERBATIM (identity, no quotes).  In a `++` chain that contains a
-- string LITERAL, `++` forces every operand to `String`, so mapping each
-- non-literal operand `e` → `\{e}` verbatim (preserving any `debug`/`show`
-- wrapper inside the hole) is exactly equivalent.  The printer escapes an
-- `InterpStr` part with the SAME `escSOne` it uses for a plain string literal, so
-- the literal text round-trips byte-for-byte.  Hence the self-compile fixpoint
-- stays byte-identical (interp desugars to the same concat).
--
-- FIRING CONDITION: the `++` spine has ≥1 string-literal operand (confirms String
-- concat, not list `++`) AND ≥2 non-literal operands (≥2 holes — the clear wins;
-- single-hole `"prefix: " ++ x` chains are left alone).  A chain whose literal
-- text already contains a `\{` sequence is SKIPPED (would collide with the
-- interpolation syntax).
--
-- `++` is left-associative, so a chain nests leftward and a sub-chain
-- would fire again under the shared bottom-up driver; this rule therefore uses a
-- bespoke TOP-DOWN rewrite that fires once at the maximal chain and descends only
-- into hole operands (`rewriteConcatExpr`).

import frontend.ast.{Loc(..), Lit(..), InterpPart(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, anyList, isNonEmptyL}
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
  bindingOf,
  rebinds,
  declHeadHits,
  mapChildExprs,
  replaceFix,
  ruleNameConcatToInterp,
  tightSpan,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameConcatToInterp,
      summary =
        "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')",
      doc =
        "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\"",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    ruleConcatToInterp
    None

-- flatten a `++` spine into its operands, left-to-right (each still ELoc-wrapped).
concatOperands : Expr -> List Expr
concatOperands e = match unwrapLoc e
  EBinOp "++" l r _ => concatOperands l ++ [r]
  _ => [e]

-- an operand that is a string literal (possibly under ELoc); the decoded value.
strLitValueOf : Expr -> Option String
strLitValueOf e = match unwrapLoc e
  ELit (LString s) => Some s
  _ => None

isStrLitOperand : Expr -> Bool
isStrLitOperand e = match strLitValueOf e
  Some _ => True
  None => False

-- decoded literal value contains the 2-char sequence `\{` (would open an interp
-- hole) — such a literal is unsafe to inline into an interpolated string.
hasBackslashBrace : String -> Bool
hasBackslashBrace s =
  let cs = stringToChars s
  backslashBraceGo cs (arrayLength cs) 0

backslashBraceGo : Array Char -> Int -> Int -> Bool
backslashBraceGo cs n i
  | i + 1 >= n = False
  | arrayGetUnsafe i cs == '\\' && arrayGetUnsafe (i + 1) cs == '{' = True
  | otherwise = backslashBraceGo cs n (i + 1)

-- the chain qualifies: ≥1 literal, ≥2 non-literals, no literal already holds `\{`.
concatChainQualifies : List Expr -> Bool
concatChainQualifies ops =
  let lits = filterExprs isStrLitOperand ops
  let holes = filterExprs (e => not (isStrLitOperand e)) ops
  isNonEmptyL lits
    && listLen holes >= 2
    && not (anyList litHasBackslashBrace lits)

litHasBackslashBrace : Expr -> Bool
litHasBackslashBrace e = match strLitValueOf e
  Some s => hasBackslashBrace s
  None => False

filterExprs : (Expr -> Bool) -> List Expr -> List Expr
filterExprs p es = filter p es

-- build the interpolated-string parts, merging adjacent literal text.  A literal
-- operand contributes its decoded text; a non-literal operand `e` becomes the hole
-- `\{e}` with `e` recursively rewritten (so a nested chain inside a hole is fixed).
buildInterpParts : List Expr -> List InterpPart
buildInterpParts ops = mergeInterpStr (map operandToInterp ops)

operandToInterp : Expr -> InterpPart
operandToInterp e = match strLitValueOf e
  Some s => InterpStr s
  None => InterpExpr (rewriteConcatExpr e)

-- coalesce consecutive `InterpStr` parts into one (cosmetic + matches how the
-- lexer would re-tokenise the emitted string).
mergeInterpStr : List InterpPart -> List InterpPart
mergeInterpStr [] = []
mergeInterpStr ((InterpStr a) :: (InterpStr b) :: rest) =
  mergeInterpStr (InterpStr (a ++ b) :: rest)
mergeInterpStr (p :: rest) = p :: mergeInterpStr rest

-- fire on the RAW node only when it is a qualifying `++` chain top; return the
-- interpolated-string node.
concatChainOf : Expr -> Option Expr
concatChainOf (EBinOp "++" l r rf) =
  let ops = concatOperands (EBinOp "++" l r rf)
  if concatChainQualifies ops then
    Some (EStringInterp (buildInterpParts ops))
  else
    None
concatChainOf _ = None

-- top-down rewrite: fire once at the maximal chain, else descend into children.
rewriteConcatExpr : Expr -> Expr
rewriteConcatExpr e = match concatChainOf e
  Some e2 => e2
  None => mapChildExprs rewriteConcatExpr e

-- One rewritten node per maximal chain, with the chain's span: the search continues
-- into the hole operands, not the consumed `++` spine.
concatChainPick : Expr -> Option ((Expr, Option Loc), List Expr)
concatChainPick e =
  map (e2 => ((e2, tightSpan e), concatOperands e)) (concatChainOf e)

ruleConcatToInterp : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleConcatToInterp idx _ facts _ _ = [OnDecl (concatToInterpAt idx facts)]

concatToInterpAt : StdlibIndex -> FileFacts -> Ctx -> Decl -> List Finding
concatToInterpAt idx facts ctx d =
  map (concatToInterpHit idx facts ctx) (declHeadHits concatChainPick d)

concatToInterpHit : StdlibIndex ->
  FileFacts ->
  Ctx ->
  (Expr, Option Loc) ->
  Finding
concatToInterpHit idx facts ctx (rewritten, span) =
  concatToInterpFinding
    ctx.ctxSpan
    rewritten
    (concatToInterpFix idx facts ctx span rewritten)

concatToInterpFinding : Option Loc -> Expr -> Option Fix -> Finding
concatToInterpFinding loc rewritten fix = Finding {
  rule = ruleNameConcatToInterp,
  message =
    "`++` chain of string literals and expressions. Rewrite as an interpolated string '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The fix replaces the chain's span with the interpolated string.  An interpolation
-- hole desugars to a call of `display`, so the fix is withheld where the file binds
-- `display`: that binding would capture the new call.
concatToInterpFix : StdlibIndex ->
  FileFacts ->
  Ctx ->
  Option Loc ->
  Expr ->
  Option Fix
concatToInterpFix idx facts ctx span rewritten =
  if rebinds idx facts ctx "display" then
    None
  else
    replaceFix
      Safe
      "interpolate the string"
      span
      (bindingOf rewritten)
      ctx
      (exprToString rewritten)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "InterpPart" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "rebinds" false) (mem "declHeadHits" false) (mem "mapChildExprs" false) (mem "replaceFix" false) (mem "ruleNameConcatToInterp" false) (mem "tightSpan" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleConcatToInterp")) (EVar "None")))
(DTypeSig false "concatOperands" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "concatOperands" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") PWild) () (EBinOp "++" (EApp (EVar "concatOperands") (EVar "l")) (EListLit (EVar "r")))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "strLitValueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "strLitValueOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig false "isStrLitOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isStrLitOperand" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hasBackslashBrace" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasBackslashBrace" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "backslashBraceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "backslashBraceGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "{")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatChainQualifies" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "concatChainQualifies" ((PVar "ops")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterExprs") (EVar "isStrLitOperand")) (EVar "ops"))) (DoLet false false (PVar "holes") (EApp (EApp (EVar "filterExprs") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isStrLitOperand") (EVar "e"))))) (EVar "ops"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "lits")) (EBinOp ">=" (EApp (EVar "listLen") (EVar "holes")) (ELit (LInt 2)))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "litHasBackslashBrace")) (EVar "lits")))))))
(DTypeSig false "litHasBackslashBrace" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "litHasBackslashBrace" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "hasBackslashBrace") (EVar "s"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "filterExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "filterExprs" ((PVar "p") (PVar "es")) (EApp (EApp (EVar "filter") (EVar "p")) (EVar "es")))
(DTypeSig false "buildInterpParts" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "buildInterpParts" ((PVar "ops")) (EApp (EVar "mergeInterpStr") (EApp (EApp (EVar "map") (EVar "operandToInterp")) (EVar "ops"))))
(DTypeSig false "operandToInterp" (TyFun (TyCon "Expr") (TyCon "InterpPart")))
(DFunDef false "operandToInterp" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "InterpStr") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "InterpExpr") (EApp (EVar "rewriteConcatExpr") (EVar "e"))))))
(DTypeSig false "mergeInterpStr" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "mergeInterpStr" ((PList)) (EListLit))
(DFunDef false "mergeInterpStr" ((PCons (PCon "InterpStr" (PVar "a")) (PCons (PCon "InterpStr" (PVar "b")) (PVar "rest")))) (EApp (EVar "mergeInterpStr") (EBinOp "::" (EApp (EVar "InterpStr") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "rest"))))
(DFunDef false "mergeInterpStr" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "mergeInterpStr") (EVar "rest"))))
(DTypeSig false "concatChainOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "concatChainOf" ((PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") (PVar "rf"))) (EBlock (DoLet false false (PVar "ops") (EApp (EVar "concatOperands") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "l")) (EVar "r")) (EVar "rf")))) (DoExpr (EIf (EApp (EVar "concatChainQualifies") (EVar "ops")) (EApp (EVar "Some") (EApp (EVar "EStringInterp") (EApp (EVar "buildInterpParts") (EVar "ops")))) (EVar "None")))))
(DFunDef false "concatChainOf" (PWild) (EVar "None"))
(DTypeSig false "rewriteConcatExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteConcatExpr" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EApp (EApp (EVar "mapChildExprs") (EVar "rewriteConcatExpr")) (EVar "e")))))
(DTypeSig false "concatChainPick" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "concatChainPick" ((PVar "e")) (EApp (EApp (EVar "map") (ELam ((PVar "e2")) (ETuple (ETuple (EVar "e2") (EApp (EVar "tightSpan") (EVar "e"))) (EApp (EVar "concatOperands") (EVar "e"))))) (EApp (EVar "concatChainOf") (EVar "e"))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleConcatToInterp" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "concatToInterpAt") (EVar "idx")) (EVar "facts")))))
(DTypeSig false "concatToInterpAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "concatToInterpAt" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "concatToInterpHit") (EVar "idx")) (EVar "facts")) (EVar "ctx"))) (EApp (EApp (EVar "declHeadHits") (EVar "concatChainPick")) (EVar "d"))))
(DTypeSig false "concatToInterpHit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyTuple (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding"))))))
(DFunDef false "concatToInterpHit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PTuple (PVar "rewritten") (PVar "span"))) (EApp (EApp (EApp (EVar "concatToInterpFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "concatToInterpFix") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "span")) (EVar "rewritten"))))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "concatToInterpFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "span") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "display"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Safe")) (ELit (LString "interpolate the string"))) (EVar "span")) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "InterpPart" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "rebinds" false) (mem "declHeadHits" false) (mem "mapChildExprs" false) (mem "replaceFix" false) (mem "ruleNameConcatToInterp" false) (mem "tightSpan" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleConcatToInterp")) (EVar "None")))
(DTypeSig false "concatOperands" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "concatOperands" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") PWild) () (EBinOp "++" (EApp (EVar "concatOperands") (EVar "l")) (EListLit (EVar "r")))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "strLitValueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "strLitValueOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig false "isStrLitOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isStrLitOperand" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hasBackslashBrace" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasBackslashBrace" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "backslashBraceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "backslashBraceGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "{")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatChainQualifies" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "concatChainQualifies" ((PVar "ops")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterExprs") (EVar "isStrLitOperand")) (EVar "ops"))) (DoLet false false (PVar "holes") (EApp (EApp (EVar "filterExprs") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isStrLitOperand") (EVar "e"))))) (EVar "ops"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "lits")) (EBinOp ">=" (EApp (EVar "listLen") (EVar "holes")) (ELit (LInt 2)))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "litHasBackslashBrace")) (EVar "lits")))))))
(DTypeSig false "litHasBackslashBrace" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "litHasBackslashBrace" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "hasBackslashBrace") (EVar "s"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "filterExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "filterExprs" ((PVar "p") (PVar "es")) (EApp (EApp (EMethodRef "filter") (EVar "p")) (EVar "es")))
(DTypeSig false "buildInterpParts" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "buildInterpParts" ((PVar "ops")) (EApp (EVar "mergeInterpStr") (EApp (EApp (EMethodRef "map") (EVar "operandToInterp")) (EVar "ops"))))
(DTypeSig false "operandToInterp" (TyFun (TyCon "Expr") (TyCon "InterpPart")))
(DFunDef false "operandToInterp" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "InterpStr") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "InterpExpr") (EApp (EVar "rewriteConcatExpr") (EVar "e"))))))
(DTypeSig false "mergeInterpStr" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "mergeInterpStr" ((PList)) (EListLit))
(DFunDef false "mergeInterpStr" ((PCons (PCon "InterpStr" (PVar "a")) (PCons (PCon "InterpStr" (PVar "b")) (PVar "rest")))) (EApp (EVar "mergeInterpStr") (EBinOp "::" (EApp (EVar "InterpStr") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "rest"))))
(DFunDef false "mergeInterpStr" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "mergeInterpStr") (EVar "rest"))))
(DTypeSig false "concatChainOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "concatChainOf" ((PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") (PVar "rf"))) (EBlock (DoLet false false (PVar "ops") (EApp (EVar "concatOperands") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "l")) (EVar "r")) (EVar "rf")))) (DoExpr (EIf (EApp (EVar "concatChainQualifies") (EVar "ops")) (EApp (EVar "Some") (EApp (EVar "EStringInterp") (EApp (EVar "buildInterpParts") (EVar "ops")))) (EVar "None")))))
(DFunDef false "concatChainOf" (PWild) (EVar "None"))
(DTypeSig false "rewriteConcatExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteConcatExpr" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EApp (EApp (EVar "mapChildExprs") (EVar "rewriteConcatExpr")) (EVar "e")))))
(DTypeSig false "concatChainPick" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "concatChainPick" ((PVar "e")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e2")) (ETuple (ETuple (EVar "e2") (EApp (EVar "tightSpan") (EVar "e"))) (EApp (EVar "concatOperands") (EVar "e"))))) (EApp (EVar "concatChainOf") (EVar "e"))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleConcatToInterp" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "concatToInterpAt") (EVar "idx")) (EVar "facts")))))
(DTypeSig false "concatToInterpAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "concatToInterpAt" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "d")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "concatToInterpHit") (EVar "idx")) (EVar "facts")) (EVar "ctx"))) (EApp (EApp (EVar "declHeadHits") (EVar "concatChainPick")) (EVar "d"))))
(DTypeSig false "concatToInterpHit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyTuple (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding"))))))
(DFunDef false "concatToInterpHit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PTuple (PVar "rewritten") (PVar "span"))) (EApp (EApp (EApp (EVar "concatToInterpFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "concatToInterpFix") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "span")) (EVar "rewritten"))))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "concatToInterpFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "span") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "display"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Safe")) (ELit (LString "interpolate the string"))) (EVar "span")) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
