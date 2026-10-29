# META
source_lines=542
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_registry.mdk — THE REGISTRY: `allRules`, the cross-file
-- registry, and rule-name selection.  Adding a rule = write one
-- `List Decl -> List Finding` function and append one `Rule { … }` entry here.

import frontend.ast.{Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..), Diag(..), DiagId(..)}
import support.util.{contains, anyList, filterList, isEmptyL, isSome}
import hash_map.{has}
import regex.{RegexError(..), compile, mustCompile}
import tools.lint_core.{CrossFileRule(..), Rule(..)}
import tools.lint_shared.{
  ruleNameAndThenPureMap,
  ruleNameBindChainToDo,
  ruleNameBindThenDestructure,
  ruleNameBoolSimplify,
  ruleNameClauseMap,
  ruleNameCloneType,
  ruleNameComplementPredicate,
  ruleNameConcatToInterp,
  ruleNameDeadCode,
  ruleNameDerivable,
  ruleNameDestructureInParam,
  ruleNameDirectiveReason,
  ruleNameDoubleReverse,
  ruleNameDuplicateBody,
  ruleNameIfMaxMin,
  ruleNameLambdaSection,
  ruleNameMatchParam,
  ruleNameMatchToMap,
  ruleNameMissingSignature,
  ruleNameNotEq,
  ruleNameOrElseStaircase,
  ruleNamePreferAssignOp,
  ruleNamePromissoryReader,
  ruleNameRegexLiteral,
  ruleNameRemParity,
  ruleNameSelfShadowExtern,
  ruleNameStdlibReimpl,
  ruleNameTestBoolLiteralEqual,
  ruleNameTestEqualInTrue,
  ruleNameTestPreludeShadow,
  ruleNameWhenUnless,
}
import tools.lint_rules_staging.{
  andThenPureMapFix,
  bindThenDestructureFix,
  boolSimplifyFix,
  complementPredicateFix,
  concatToInterpFix,
  destructureInParamFix,
  doubleReverseFix,
  duplicateBodySameFileRule,
  ifMaxMinFix,
  lambdaSectionFix,
  matchParamFix,
  matchToMapFix,
  notEqFix,
  preferAssignFix,
  remParityFix,
  ruleAndThenPureMap,
  ruleBindChainToDo,
  ruleBindThenDestructure,
  ruleBoolSimplify,
  ruleClauseMap,
  ruleCloneType,
  ruleComplementPredicate,
  ruleConcatToInterp,
  ruleDeadCode,
  ruleDerivable,
  ruleDestructureInParam,
  ruleDirectiveReason,
  ruleDoubleReverse,
  ruleDuplicateBody,
  ruleForPreferAssign,
  ruleIfMaxMin,
  ruleLambdaSection,
  ruleMatchOnParam,
  ruleMatchToMap,
  ruleMissingSignature,
  ruleNotEq,
  ruleOrElseStaircase,
  rulePromissoryReader,
  ruleRegexLiteral,
  ruleRemParity,
  ruleSelfShadowExtern,
  ruleStdlibReimpl,
  ruleTestBoolLiteralEqual,
  ruleTestEqualInTrue,
  ruleTestPreludeShadow,
  ruleWhenUnless,
  testBoolLiteralEqualFix,
  testEqualInTrueFix,
  whenUnlessFix,
}

-- ── the registry ─────────────────────────────────────────────────────────────
-- Each Rule is its own top-level binding (rather than an inline element of the
-- `allRules` list literal) so the LLVM emitter's record-field scanner — which
-- traverses binding bodies but not into list-literal elements — registers the
-- `Rule` field layout.  Adding a rule = write its `check` fn + one `Rule` binding
-- + append it to `allRules`.
matchParamRule : Rule
matchParamRule = Rule {
  name = ruleNameMatchParam,
  descr =
    "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)",
  severity = SevWarning,
  enabled = True,
  check = ruleMatchOnParam,
  fix = Some matchParamFix,
}

derivableRule : Rule
derivableRule = Rule {
  name = ruleNameDerivable,
  descr = "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)",
  severity = SevWarning,
  enabled = True,
  check = ruleDerivable,
  fix = None,
}

stdlibReimplRule : Rule
stdlibReimplRule = Rule {
  name = ruleNameStdlibReimpl,
  descr =
    "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)",
  severity = SevWarning,
  enabled = True,
  check = ruleStdlibReimpl,
  fix = None,
}

bindThenDestructureRule : Rule
bindThenDestructureRule = Rule {
  name = ruleNameBindThenDestructure,
  descr =
    "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind",
  severity = SevWarning,
  enabled = True,
  check = ruleBindThenDestructure,
  fix = Some bindThenDestructureFix,
}

lambdaSectionRule : Rule
lambdaSectionRule = Rule {
  name = ruleNameLambdaSection,
  descr =
    "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")",
  severity = SevWarning,
  enabled = True,
  check = ruleLambdaSection,
  fix = Some lambdaSectionFix,
}

ifMaxMinRule : Rule
ifMaxMinRule = Rule {
  name = ruleNameIfMaxMin,
  descr =
    "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`",
  severity = SevWarning,
  enabled = True,
  check = ruleIfMaxMin,
  fix = Some ifMaxMinFix,
}

andThenPureMapRule : Rule
andThenPureMapRule = Rule {
  name = ruleNameAndThenPureMap,
  descr =
    "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)",
  severity = SevWarning,
  enabled = True,
  check = ruleAndThenPureMap,
  fix = Some andThenPureMapFix,
}

destructureInParamRule : Rule
destructureInParamRule = Rule {
  name = ruleNameDestructureInParam,
  descr =
    "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position",
  severity = SevWarning,
  enabled = True,
  check = ruleDestructureInParam,
  fix = Some destructureInParamFix,
}

missingSignatureRule : Rule
missingSignatureRule = Rule {
  name = ruleNameMissingSignature,
  descr =
    "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)",
  severity = SevWarning,
  enabled = True,
  check = ruleMissingSignature,
  fix = None,
}

notEqRule : Rule
notEqRule = Rule {
  name = ruleNameNotEq,
  descr =
    "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`",
  severity = SevWarning,
  enabled = True,
  check = ruleNotEq,
  fix = Some notEqFix,
}

boolSimplifyRule : Rule
boolSimplifyRule = Rule {
  name = ruleNameBoolSimplify,
  descr =
    "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify",
  severity = SevWarning,
  enabled = True,
  check = ruleBoolSimplify,
  fix = Some boolSimplifyFix,
}

remParityRule : Rule
remParityRule = Rule {
  name = ruleNameRemParity,
  descr =
    "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`",
  severity = SevWarning,
  enabled = True,
  check = ruleRemParity,
  fix = Some remParityFix,
}

doubleReverseRule : Rule
doubleReverseRule = Rule {
  name = ruleNameDoubleReverse,
  descr = "`reverse (reverse x)` is `x`. Drop the double reversal",
  severity = SevWarning,
  enabled = True,
  check = ruleDoubleReverse,
  fix = Some doubleReverseFix,
}

whenUnlessRule : Rule
whenUnlessRule = Rule {
  name = ruleNameWhenUnless,
  descr =
    "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`",
  severity = SevWarning,
  enabled = True,
  check = ruleWhenUnless,
  fix = Some whenUnlessFix,
}

complementPredicateRule : Rule
complementPredicateRule = Rule {
  name = ruleNameComplementPredicate,
  descr =
    "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly",
  severity = SevWarning,
  enabled = True,
  check = ruleComplementPredicate,
  fix = Some complementPredicateFix,
}

matchToMapRule : Rule
matchToMapRule = Rule {
  name = ruleNameMatchToMap,
  descr =
    "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')",
  severity = SevWarning,
  enabled = True,
  check = ruleMatchToMap,
  fix = Some matchToMapFix,
}

bindChainToDoRule : Rule
bindChainToDoRule = Rule {
  name = ruleNameBindChainToDo,
  descr =
    "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleBindChainToDo,
  fix = None,
}

deadCodeRule : Rule
deadCodeRule = Rule {
  name = ruleNameDeadCode,
  descr =
    "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)",
  severity = SevWarning,
  enabled = True,
  check = ruleDeadCode,
  fix = None,
}

concatToInterpRule : Rule
concatToInterpRule = Rule {
  name = ruleNameConcatToInterp,
  descr =
    "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')",
  severity = SevWarning,
  enabled = True,
  check = ruleConcatToInterp,
  fix = Some concatToInterpFix,
}

selfShadowExternRule : Rule
selfShadowExternRule = Rule {
  name = ruleNameSelfShadowExtern,
  descr =
    "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)",
  severity = SevWarning,
  enabled = True,
  check = ruleSelfShadowExtern,
  fix = None,
}

preferAssignOpRule : Rule
preferAssignOpRule = Rule {
  name = ruleNamePreferAssignOp,
  descr =
    "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement",
  severity = SevWarning,
  enabled = True,
  check = ruleForPreferAssign,
  fix = Some preferAssignFix,
}

promissoryReaderRule : Rule
promissoryReaderRule = Rule {
  name = ruleNamePromissoryReader,
  descr =
    "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)",
  severity = SevWarning,
  enabled = True,
  check = rulePromissoryReader,
  fix = None,
}

orElseStaircaseRule : Rule
orElseStaircaseRule = Rule {
  name = ruleNameOrElseStaircase,
  descr =
    "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleOrElseStaircase,
  fix = None,
}

cloneTypeRule : Rule
cloneTypeRule = Rule {
  name = ruleNameCloneType,
  descr =
    "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleCloneType,
  fix = None,
}

clauseMapRule : Rule
clauseMapRule = Rule {
  name = ruleNameClauseMap,
  descr =
    "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleClauseMap,
  fix = None,
}

directiveReasonRule : Rule
directiveReasonRule = Rule {
  name = ruleNameDirectiveReason,
  descr =
    "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)",
  severity = SevWarning,
  enabled = True,
  check = ruleDirectiveReason,
  fix = None,
}

regexLiteralRule : Rule
regexLiteralRule = Rule {
  name = ruleNameRegexLiteral,
  descr =
    "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern",
  severity = SevWarning,
  enabled = True,
  check = ruleRegexLiteral,
  fix = None,
}

testBoolLiteralEqualRule : Rule
testBoolLiteralEqualRule = Rule {
  name = ruleNameTestBoolLiteralEqual,
  descr =
    "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`",
  severity = SevWarning,
  enabled = True,
  check = ruleTestBoolLiteralEqual,
  fix = Some testBoolLiteralEqualFix,
}

testEqualInTrueRule : Rule
testEqualInTrueRule = Rule {
  name = ruleNameTestEqualInTrue,
  descr =
    "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure",
  severity = SevWarning,
  enabled = True,
  check = ruleTestEqualInTrue,
  fix = Some testEqualInTrueFix,
}

testPreludeShadowRule : Rule
testPreludeShadowRule = Rule {
  name = ruleNameTestPreludeShadow,
  descr =
    "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleTestPreludeShadow,
  fix = None,
}

export
allRules : List Rule
allRules = [
  matchParamRule,
  derivableRule,
  stdlibReimplRule,
  bindThenDestructureRule,
  lambdaSectionRule,
  ifMaxMinRule,
  andThenPureMapRule,
  destructureInParamRule,
  missingSignatureRule,
  notEqRule,
  boolSimplifyRule,
  remParityRule,
  doubleReverseRule,
  whenUnlessRule,
  complementPredicateRule,
  matchToMapRule,
  bindChainToDoRule,
  deadCodeRule,
  concatToInterpRule,
  selfShadowExternRule,
  preferAssignOpRule,
  promissoryReaderRule,
  orElseStaircaseRule,
  cloneTypeRule,
  clauseMapRule,
  duplicateBodySameFileRule,
  directiveReasonRule,
  regexLiteralRule,
  testBoolLiteralEqualRule,
  testEqualInTrueRule,
  testPreludeShadowRule,
]

-- ── the cross-file registry ───────────────────────────────────────────────────
-- Each CrossFileRule is its own top-level binding.  Adding a cross-file rule =
-- write its `check` fn + one binding here + append it to `allCrossFileRules`.
duplicateBodyRule : CrossFileRule
duplicateBodyRule = CrossFileRule {
  name = ruleNameDuplicateBody,
  descr =
    "top-level function body is structurally identical to one in another file (copy-paste; consolidate)",
  severity = SevWarning,
  enabled = True,
  check = ruleDuplicateBody,
}

export
allCrossFileRules : List CrossFileRule
allCrossFileRules = [duplicateBodyRule]

-- Every registered rule name, per-file and cross-file, as plain Strings.
-- CLI-CONFORMANCE.md §5f: `medaka lint --only=nosuchrule` would otherwise be
-- accepted silently — a typo'd rule name filters EVERY finding away and the run
-- exits 0 looking clean.  The CLI validates `--only=`/`--disable=`/`--deny=` against
-- this list, so the CLI receives only these Strings.
-- Deduped, and in registry order: `rule-duplicate-body` is registered TWICE
-- (a same-file `Rule` and the cross-file `CrossFileRule` under one name), and
-- printing it twice in the known set reads as a bug in the list.
export
allRuleNames : List String
allRuleNames =
  let perFile = map ruleNameOf allRules
  perFile
    ++ filterList
      (n => not (contains n perFile))
      (map crossRuleNameOf allCrossFileRules)

ruleNameOf : Rule -> String
ruleNameOf r = r.name

crossRuleNameOf : CrossFileRule -> String
crossRuleNameOf r = r.name

-- ── runner ───────────────────────────────────────────────────────────────────

-- The registry narrowed to the rules `--only`/`--disable` leave active, for runs
-- whose findings are filtered in this same process.  Findings are still filtered
-- by name afterwards; this only stops the excluded rules from computing.
export
selectRules : List String -> List String -> List Rule
selectRules only disable = filterList (ruleSelected only disable) allRules

ruleSelected : List String -> List String -> Rule -> Bool
ruleSelected only disable r =
  (isEmptyL only || contains r.name only) && not (contains r.name disable)

-- Does `--only`/`--disable` leave the cross-file duplicate-body rule active?
export
crossFileSelected : List String -> List String -> Bool
crossFileSelected only disable =
  anyList (crossRuleActive only disable) allCrossFileRules

export
crossRuleActive : List String -> List String -> CrossFileRule -> Bool
crossRuleActive only disable r =
  r.enabled
    && (isEmptyL only || contains r.name only)
    && not (contains r.name disable)

-- ── cross-file rule: duplicate-body (copy-paste detector) ──────────────────────
-- Flags a top-level `DFunDef` whose ELoc-stripped body (+ param-pattern shape) is
-- structurally identical to a top-level function in a DIFFERENT file.  The
-- structural key reuses `ir.sexp.exprSexp` — the location-stripped AST serializer
-- the parse/sexp gates already rely on — so two copy-pasted bodies render to the
-- same string.  HIGH-SIGNAL: only bodies at/above `dupComplexityThreshold` AST
-- nodes are eligible, so trivial bodies (`main = …`, `f x = x`, one-field
-- accessors) never fire.  Same-file duplicates are out of scope (≥2 distinct
-- files required).  Deterministic: keys processed in sorted order, occurrences
-- sorted by (file, line).
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false))))
(DUse false (UseGroup ("hash_map") ((mem "has" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true) (mem "compile" false) (mem "mustCompile" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "Rule" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameAndThenPureMap" false) (mem "ruleNameBindChainToDo" false) (mem "ruleNameBindThenDestructure" false) (mem "ruleNameBoolSimplify" false) (mem "ruleNameClauseMap" false) (mem "ruleNameCloneType" false) (mem "ruleNameComplementPredicate" false) (mem "ruleNameConcatToInterp" false) (mem "ruleNameDeadCode" false) (mem "ruleNameDerivable" false) (mem "ruleNameDestructureInParam" false) (mem "ruleNameDirectiveReason" false) (mem "ruleNameDoubleReverse" false) (mem "ruleNameDuplicateBody" false) (mem "ruleNameIfMaxMin" false) (mem "ruleNameLambdaSection" false) (mem "ruleNameMatchParam" false) (mem "ruleNameMatchToMap" false) (mem "ruleNameMissingSignature" false) (mem "ruleNameNotEq" false) (mem "ruleNameOrElseStaircase" false) (mem "ruleNamePreferAssignOp" false) (mem "ruleNamePromissoryReader" false) (mem "ruleNameRegexLiteral" false) (mem "ruleNameRemParity" false) (mem "ruleNameSelfShadowExtern" false) (mem "ruleNameStdlibReimpl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "ruleNameTestEqualInTrue" false) (mem "ruleNameTestPreludeShadow" false) (mem "ruleNameWhenUnless" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "andThenPureMapFix" false) (mem "bindThenDestructureFix" false) (mem "boolSimplifyFix" false) (mem "complementPredicateFix" false) (mem "concatToInterpFix" false) (mem "destructureInParamFix" false) (mem "doubleReverseFix" false) (mem "duplicateBodySameFileRule" false) (mem "ifMaxMinFix" false) (mem "lambdaSectionFix" false) (mem "matchParamFix" false) (mem "matchToMapFix" false) (mem "notEqFix" false) (mem "preferAssignFix" false) (mem "remParityFix" false) (mem "ruleAndThenPureMap" false) (mem "ruleBindChainToDo" false) (mem "ruleBindThenDestructure" false) (mem "ruleBoolSimplify" false) (mem "ruleClauseMap" false) (mem "ruleCloneType" false) (mem "ruleComplementPredicate" false) (mem "ruleConcatToInterp" false) (mem "ruleDeadCode" false) (mem "ruleDerivable" false) (mem "ruleDestructureInParam" false) (mem "ruleDirectiveReason" false) (mem "ruleDoubleReverse" false) (mem "ruleDuplicateBody" false) (mem "ruleForPreferAssign" false) (mem "ruleIfMaxMin" false) (mem "ruleLambdaSection" false) (mem "ruleMatchOnParam" false) (mem "ruleMatchToMap" false) (mem "ruleMissingSignature" false) (mem "ruleNotEq" false) (mem "ruleOrElseStaircase" false) (mem "rulePromissoryReader" false) (mem "ruleRegexLiteral" false) (mem "ruleRemParity" false) (mem "ruleSelfShadowExtern" false) (mem "ruleStdlibReimpl" false) (mem "ruleTestBoolLiteralEqual" false) (mem "ruleTestEqualInTrue" false) (mem "ruleTestPreludeShadow" false) (mem "ruleWhenUnless" false) (mem "testBoolLiteralEqualFix" false) (mem "testEqualInTrueFix" false) (mem "whenUnlessFix" false))))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchParam")) (fa "descr" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchOnParam")) (fa "fix" (EApp (EVar "Some") (EVar "matchParamFix"))))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDerivable")) (fa "descr" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDerivable")) (fa "fix" (EVar "None")))))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "descr" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleStdlibReimpl")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "descr" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindThenDestructure")) (fa "fix" (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "descr" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleLambdaSection")) (fa "fix" (EApp (EVar "Some") (EVar "lambdaSectionFix"))))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "descr" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleIfMaxMin")) (fa "fix" (EApp (EVar "Some") (EVar "ifMaxMinFix"))))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "descr" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleAndThenPureMap")) (fa "fix" (EApp (EVar "Some") (EVar "andThenPureMapFix"))))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "descr" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDestructureInParam")) (fa "fix" (EApp (EVar "Some") (EVar "destructureInParamFix"))))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "descr" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMissingSignature")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameNotEq")) (fa "descr" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleNotEq")) (fa "fix" (EApp (EVar "Some") (EVar "notEqFix"))))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "descr" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBoolSimplify")) (fa "fix" (EApp (EVar "Some") (EVar "boolSimplifyFix"))))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRemParity")) (fa "descr" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRemParity")) (fa "fix" (EApp (EVar "Some") (EVar "remParityFix"))))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "descr" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDoubleReverse")) (fa "fix" (EApp (EVar "Some") (EVar "doubleReverseFix"))))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "descr" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleWhenUnless")) (fa "fix" (EApp (EVar "Some") (EVar "whenUnlessFix"))))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "descr" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleComplementPredicate")) (fa "fix" (EApp (EVar "Some") (EVar "complementPredicateFix"))))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "descr" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchToMap")) (fa "fix" (EApp (EVar "Some") (EVar "matchToMapFix"))))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "descr" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindChainToDo")) (fa "fix" (EVar "None")))))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDeadCode")) (fa "descr" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDeadCode")) (fa "fix" (EVar "None")))))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "descr" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleConcatToInterp")) (fa "fix" (EApp (EVar "Some") (EVar "concatToInterpFix"))))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "descr" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleSelfShadowExtern")) (fa "fix" (EVar "None")))))
(DTypeSig false "preferAssignOpRule" (TyCon "Rule"))
(DFunDef false "preferAssignOpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "descr" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleForPreferAssign")) (fa "fix" (EApp (EVar "Some") (EVar "preferAssignFix"))))))
(DTypeSig false "promissoryReaderRule" (TyCon "Rule"))
(DFunDef false "promissoryReaderRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "descr" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "rulePromissoryReader")) (fa "fix" (EVar "None")))))
(DTypeSig false "orElseStaircaseRule" (TyCon "Rule"))
(DFunDef false "orElseStaircaseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "descr" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleOrElseStaircase")) (fa "fix" (EVar "None")))))
(DTypeSig false "cloneTypeRule" (TyCon "Rule"))
(DFunDef false "cloneTypeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameCloneType")) (fa "descr" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleCloneType")) (fa "fix" (EVar "None")))))
(DTypeSig false "clauseMapRule" (TyCon "Rule"))
(DFunDef false "clauseMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameClauseMap")) (fa "descr" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleClauseMap")) (fa "fix" (EVar "None")))))
(DTypeSig false "directiveReasonRule" (TyCon "Rule"))
(DFunDef false "directiveReasonRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "descr" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDirectiveReason")) (fa "fix" (EVar "None")))))
(DTypeSig false "regexLiteralRule" (TyCon "Rule"))
(DFunDef false "regexLiteralRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "descr" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRegexLiteral")) (fa "fix" (EVar "None")))))
(DTypeSig false "testBoolLiteralEqualRule" (TyCon "Rule"))
(DFunDef false "testBoolLiteralEqualRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "descr" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestBoolLiteralEqual")) (fa "fix" (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))))
(DTypeSig false "testEqualInTrueRule" (TyCon "Rule"))
(DFunDef false "testEqualInTrueRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "descr" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestEqualInTrue")) (fa "fix" (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))))
(DTypeSig false "testPreludeShadowRule" (TyCon "Rule"))
(DFunDef false "testPreludeShadowRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "descr" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestPreludeShadow")) (fa "fix" (EVar "None")))))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule") (EVar "preferAssignOpRule") (EVar "promissoryReaderRule") (EVar "orElseStaircaseRule") (EVar "cloneTypeRule") (EVar "clauseMapRule") (EVar "duplicateBodySameFileRule") (EVar "directiveReasonRule") (EVar "regexLiteralRule") (EVar "testBoolLiteralEqualRule") (EVar "testEqualInTrueRule") (EVar "testPreludeShadowRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (ERecordCreate "CrossFileRule" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "descr" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDuplicateBody")))))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "duplicateBodyRule")))
(DTypeSig true "allRuleNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "allRuleNames" () (EBlock (DoLet false false (PVar "perFile") (EApp (EApp (EVar "map") (EVar "ruleNameOf")) (EVar "allRules"))) (DoExpr (EBinOp "++" (EVar "perFile") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "perFile"))))) (EApp (EApp (EVar "map") (EVar "crossRuleNameOf")) (EVar "allCrossFileRules")))))))
(DTypeSig false "ruleNameOf" (TyFun (TyCon "Rule") (TyCon "String")))
(DFunDef false "ruleNameOf" ((PVar "r")) (EFieldAccess (EVar "r") "name"))
(DTypeSig false "crossRuleNameOf" (TyFun (TyCon "CrossFileRule") (TyCon "String")))
(DFunDef false "crossRuleNameOf" ((PVar "r")) (EFieldAccess (EVar "r") "name"))
(DTypeSig true "selectRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Rule")))))
(DFunDef false "selectRules" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleSelected") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig false "ruleSelected" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleSelected" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "crossFileSelected" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "crossFileSelected" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable"))) (EVar "allCrossFileRules")))
(DTypeSig true "crossRuleActive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CrossFileRule") (TyCon "Bool")))))
(DFunDef false "crossRuleActive" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false))))
(DUse false (UseGroup ("hash_map") ((mem "has" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true) (mem "compile" false) (mem "mustCompile" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "Rule" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameAndThenPureMap" false) (mem "ruleNameBindChainToDo" false) (mem "ruleNameBindThenDestructure" false) (mem "ruleNameBoolSimplify" false) (mem "ruleNameClauseMap" false) (mem "ruleNameCloneType" false) (mem "ruleNameComplementPredicate" false) (mem "ruleNameConcatToInterp" false) (mem "ruleNameDeadCode" false) (mem "ruleNameDerivable" false) (mem "ruleNameDestructureInParam" false) (mem "ruleNameDirectiveReason" false) (mem "ruleNameDoubleReverse" false) (mem "ruleNameDuplicateBody" false) (mem "ruleNameIfMaxMin" false) (mem "ruleNameLambdaSection" false) (mem "ruleNameMatchParam" false) (mem "ruleNameMatchToMap" false) (mem "ruleNameMissingSignature" false) (mem "ruleNameNotEq" false) (mem "ruleNameOrElseStaircase" false) (mem "ruleNamePreferAssignOp" false) (mem "ruleNamePromissoryReader" false) (mem "ruleNameRegexLiteral" false) (mem "ruleNameRemParity" false) (mem "ruleNameSelfShadowExtern" false) (mem "ruleNameStdlibReimpl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "ruleNameTestEqualInTrue" false) (mem "ruleNameTestPreludeShadow" false) (mem "ruleNameWhenUnless" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "andThenPureMapFix" false) (mem "bindThenDestructureFix" false) (mem "boolSimplifyFix" false) (mem "complementPredicateFix" false) (mem "concatToInterpFix" false) (mem "destructureInParamFix" false) (mem "doubleReverseFix" false) (mem "duplicateBodySameFileRule" false) (mem "ifMaxMinFix" false) (mem "lambdaSectionFix" false) (mem "matchParamFix" false) (mem "matchToMapFix" false) (mem "notEqFix" false) (mem "preferAssignFix" false) (mem "remParityFix" false) (mem "ruleAndThenPureMap" false) (mem "ruleBindChainToDo" false) (mem "ruleBindThenDestructure" false) (mem "ruleBoolSimplify" false) (mem "ruleClauseMap" false) (mem "ruleCloneType" false) (mem "ruleComplementPredicate" false) (mem "ruleConcatToInterp" false) (mem "ruleDeadCode" false) (mem "ruleDerivable" false) (mem "ruleDestructureInParam" false) (mem "ruleDirectiveReason" false) (mem "ruleDoubleReverse" false) (mem "ruleDuplicateBody" false) (mem "ruleForPreferAssign" false) (mem "ruleIfMaxMin" false) (mem "ruleLambdaSection" false) (mem "ruleMatchOnParam" false) (mem "ruleMatchToMap" false) (mem "ruleMissingSignature" false) (mem "ruleNotEq" false) (mem "ruleOrElseStaircase" false) (mem "rulePromissoryReader" false) (mem "ruleRegexLiteral" false) (mem "ruleRemParity" false) (mem "ruleSelfShadowExtern" false) (mem "ruleStdlibReimpl" false) (mem "ruleTestBoolLiteralEqual" false) (mem "ruleTestEqualInTrue" false) (mem "ruleTestPreludeShadow" false) (mem "ruleWhenUnless" false) (mem "testBoolLiteralEqualFix" false) (mem "testEqualInTrueFix" false) (mem "whenUnlessFix" false))))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchParam")) (fa "descr" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchOnParam")) (fa "fix" (EApp (EVar "Some") (EVar "matchParamFix"))))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDerivable")) (fa "descr" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDerivable")) (fa "fix" (EVar "None")))))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "descr" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleStdlibReimpl")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "descr" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindThenDestructure")) (fa "fix" (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "descr" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleLambdaSection")) (fa "fix" (EApp (EVar "Some") (EVar "lambdaSectionFix"))))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "descr" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleIfMaxMin")) (fa "fix" (EApp (EVar "Some") (EVar "ifMaxMinFix"))))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "descr" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleAndThenPureMap")) (fa "fix" (EApp (EVar "Some") (EVar "andThenPureMapFix"))))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "descr" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDestructureInParam")) (fa "fix" (EApp (EVar "Some") (EVar "destructureInParamFix"))))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "descr" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMissingSignature")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameNotEq")) (fa "descr" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleNotEq")) (fa "fix" (EApp (EVar "Some") (EVar "notEqFix"))))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "descr" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBoolSimplify")) (fa "fix" (EApp (EVar "Some") (EVar "boolSimplifyFix"))))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRemParity")) (fa "descr" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRemParity")) (fa "fix" (EApp (EVar "Some") (EVar "remParityFix"))))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "descr" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDoubleReverse")) (fa "fix" (EApp (EVar "Some") (EVar "doubleReverseFix"))))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "descr" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleWhenUnless")) (fa "fix" (EApp (EVar "Some") (EVar "whenUnlessFix"))))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "descr" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleComplementPredicate")) (fa "fix" (EApp (EVar "Some") (EVar "complementPredicateFix"))))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "descr" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchToMap")) (fa "fix" (EApp (EVar "Some") (EVar "matchToMapFix"))))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "descr" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindChainToDo")) (fa "fix" (EVar "None")))))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDeadCode")) (fa "descr" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDeadCode")) (fa "fix" (EVar "None")))))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "descr" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleConcatToInterp")) (fa "fix" (EApp (EVar "Some") (EVar "concatToInterpFix"))))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "descr" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleSelfShadowExtern")) (fa "fix" (EVar "None")))))
(DTypeSig false "preferAssignOpRule" (TyCon "Rule"))
(DFunDef false "preferAssignOpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "descr" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleForPreferAssign")) (fa "fix" (EApp (EVar "Some") (EVar "preferAssignFix"))))))
(DTypeSig false "promissoryReaderRule" (TyCon "Rule"))
(DFunDef false "promissoryReaderRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "descr" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "rulePromissoryReader")) (fa "fix" (EVar "None")))))
(DTypeSig false "orElseStaircaseRule" (TyCon "Rule"))
(DFunDef false "orElseStaircaseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "descr" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleOrElseStaircase")) (fa "fix" (EVar "None")))))
(DTypeSig false "cloneTypeRule" (TyCon "Rule"))
(DFunDef false "cloneTypeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameCloneType")) (fa "descr" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleCloneType")) (fa "fix" (EVar "None")))))
(DTypeSig false "clauseMapRule" (TyCon "Rule"))
(DFunDef false "clauseMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameClauseMap")) (fa "descr" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleClauseMap")) (fa "fix" (EVar "None")))))
(DTypeSig false "directiveReasonRule" (TyCon "Rule"))
(DFunDef false "directiveReasonRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "descr" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDirectiveReason")) (fa "fix" (EVar "None")))))
(DTypeSig false "regexLiteralRule" (TyCon "Rule"))
(DFunDef false "regexLiteralRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "descr" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRegexLiteral")) (fa "fix" (EVar "None")))))
(DTypeSig false "testBoolLiteralEqualRule" (TyCon "Rule"))
(DFunDef false "testBoolLiteralEqualRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "descr" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestBoolLiteralEqual")) (fa "fix" (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))))
(DTypeSig false "testEqualInTrueRule" (TyCon "Rule"))
(DFunDef false "testEqualInTrueRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "descr" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestEqualInTrue")) (fa "fix" (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))))
(DTypeSig false "testPreludeShadowRule" (TyCon "Rule"))
(DFunDef false "testPreludeShadowRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "descr" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleTestPreludeShadow")) (fa "fix" (EVar "None")))))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule") (EVar "preferAssignOpRule") (EVar "promissoryReaderRule") (EVar "orElseStaircaseRule") (EVar "cloneTypeRule") (EVar "clauseMapRule") (EVar "duplicateBodySameFileRule") (EVar "directiveReasonRule") (EVar "regexLiteralRule") (EVar "testBoolLiteralEqualRule") (EVar "testEqualInTrueRule") (EVar "testPreludeShadowRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (ERecordCreate "CrossFileRule" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "descr" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDuplicateBody")))))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "duplicateBodyRule")))
(DTypeSig true "allRuleNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "allRuleNames" () (EBlock (DoLet false false (PVar "perFile") (EApp (EApp (EMethodRef "map") (EVar "ruleNameOf")) (EVar "allRules"))) (DoExpr (EBinOp "++" (EVar "perFile") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "perFile"))))) (EApp (EApp (EMethodRef "map") (EVar "crossRuleNameOf")) (EVar "allCrossFileRules")))))))
(DTypeSig false "ruleNameOf" (TyFun (TyCon "Rule") (TyCon "String")))
(DFunDef false "ruleNameOf" ((PVar "r")) (EFieldAccess (EVar "r") "name"))
(DTypeSig false "crossRuleNameOf" (TyFun (TyCon "CrossFileRule") (TyCon "String")))
(DFunDef false "crossRuleNameOf" ((PVar "r")) (EFieldAccess (EVar "r") "name"))
(DTypeSig true "selectRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Rule")))))
(DFunDef false "selectRules" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleSelected") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig false "ruleSelected" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleSelected" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "crossFileSelected" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "crossFileSelected" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable"))) (EVar "allCrossFileRules")))
(DTypeSig true "crossRuleActive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CrossFileRule") (TyCon "Bool")))))
(DFunDef false "crossRuleActive" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
