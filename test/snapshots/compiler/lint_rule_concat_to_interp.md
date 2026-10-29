# META
source_lines=221
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

import frontend.ast.{
  Loc(..), Lit(..), ImplMethod(..), InterpPart(..), Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, anyList, isNonEmptyL}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
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
  childExprs,
  declLocList,
  implMethodsBodyKey,
  mapChildExprs,
  ruleNameConcatToInterp,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
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
      needs = [],
    }
    ruleConcatToInterp
    (Some concatToInterpFix)

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

-- one rewritten node per maximal chain; when a chain fires, still look for nested
-- chains inside its hole operands (NOT its consumed `++` spine).
collectConcatHits : Expr -> List Expr
collectConcatHits e = match concatChainOf e
  Some e2 => e2 :: flatMap collectConcatHits (concatOperands e)
  None => flatMap collectConcatHits (childExprs e)

ruleConcatToInterp : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleConcatToInterp _ _ _ pos prog =
  flatMap concatToInterpDeclL (declLocList pos prog)

concatToInterpDeclL : (Decl, Option Loc) -> List Finding
concatToInterpDeclL (d, loc) =
  map (concatToInterpFinding loc) (declConcatHits d)

declConcatHits : Decl -> List Expr
declConcatHits (DFunDef _ _ _ body _ _) = collectConcatHits body
declConcatHits (DImpl { methods, ... }) = flatMap implMethodConcatHits methods
declConcatHits (DAttrib _ d) = declConcatHits d
declConcatHits _ = []

implMethodConcatHits : ImplMethod -> List Expr
implMethodConcatHits (ImplMethod _ _ body) = collectConcatHits body

concatToInterpFinding : Option Loc -> Expr -> Finding
concatToInterpFinding loc rewritten = Finding {
  rule = ruleNameConcatToInterp,
  message =
    "`++` chain of string literals and expressions. Rewrite as an interpolated string '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
}

concatToInterpFix : Oracle -> Decl -> Option (List Decl)
concatToInterpFix _ (DFunDef vis name pats body site bid) =
  let body2 = rewriteConcatExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2 site bid]
concatToInterpFix orc (DAttrib a d) = match concatToInterpFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
concatToInterpFix _ (d@(DImpl { implOrigin = _, methods })) =
  let methods2 = map fixImplMethodConcat methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    -- #1110: record UPDATE — re-synthesising would reset the acquired identity.
    Some [DImpl { d | methods = methods2 }]
concatToInterpFix _ _ = None

fixImplMethodConcat : ImplMethod -> ImplMethod
fixImplMethodConcat (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteConcatExpr body)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "mapChildExprs" false) (mem "ruleNameConcatToInterp" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleConcatToInterp")) (EApp (EVar "Some") (EVar "concatToInterpFix"))))
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
(DTypeSig false "collectConcatHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectConcatHits" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EBinOp "::" (EVar "e2") (EApp (EApp (EVar "flatMap") (EVar "collectConcatHits")) (EApp (EVar "concatOperands") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "flatMap") (EVar "collectConcatHits")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleConcatToInterp" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "concatToInterpDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "concatToInterpDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "concatToInterpDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "concatToInterpFinding") (EVar "loc"))) (EApp (EVar "declConcatHits") (EVar "d"))))
(DTypeSig false "declConcatHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declConcatHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectConcatHits") (EVar "body")))
(DFunDef false "declConcatHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodConcatHits")) (EVar "methods")))
(DFunDef false "declConcatHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declConcatHits") (EVar "d")))
(DFunDef false "declConcatHits" (PWild) (EListLit))
(DTypeSig false "implMethodConcatHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodConcatHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "concatToInterpFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteConcatExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "concatToInterpFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "concatToInterpFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "concatToInterpFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodConcat")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "concatToInterpFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodConcat" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodConcat" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteConcatExpr") (EVar "body"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "mapChildExprs" false) (mem "ruleNameConcatToInterp" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleConcatToInterp")) (EApp (EVar "Some") (EVar "concatToInterpFix"))))
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
(DTypeSig false "collectConcatHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectConcatHits" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EBinOp "::" (EVar "e2") (EApp (EApp (EDictApp "flatMap") (EVar "collectConcatHits")) (EApp (EVar "concatOperands") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EDictApp "flatMap") (EVar "collectConcatHits")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleConcatToInterp" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "concatToInterpDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "concatToInterpDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "concatToInterpDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "concatToInterpFinding") (EVar "loc"))) (EApp (EVar "declConcatHits") (EVar "d"))))
(DTypeSig false "declConcatHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declConcatHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectConcatHits") (EVar "body")))
(DFunDef false "declConcatHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodConcatHits")) (EVar "methods")))
(DFunDef false "declConcatHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declConcatHits") (EVar "d")))
(DFunDef false "declConcatHits" (PWild) (EListLit))
(DTypeSig false "implMethodConcatHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodConcatHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "concatToInterpFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteConcatExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "concatToInterpFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "concatToInterpFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "concatToInterpFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodConcat")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "concatToInterpFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodConcat" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodConcat" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteConcatExpr") (EVar "body"))))
