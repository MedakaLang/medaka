# META
source_lines=802
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
import tools.lint_core.{
  Category(..),
  CrossFileRule(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule(..),
  RuleMeta(..),
  Scope(..),
  mkCrossFileRule,
  mkRule,
}
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
matchParamRule =
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

derivableRule : Rule
derivableRule =
  mkRule
    RuleMeta {
      name = ruleNameDerivable,
      summary =
        "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)",
      doc =
        "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDerivable
    None

stdlibReimplRule : Rule
stdlibReimplRule =
  mkRule
    RuleMeta {
      name = ruleNameStdlibReimpl,
      summary =
        "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)",
      doc =
        "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsStdlibIndex],
    }
    ruleStdlibReimpl
    None

bindThenDestructureRule : Rule
bindThenDestructureRule =
  mkRule
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

lambdaSectionRule : Rule
lambdaSectionRule =
  mkRule
    RuleMeta {
      name = ruleNameLambdaSection,
      summary =
        "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")",
      doc =
        "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleLambdaSection
    (Some lambdaSectionFix)

ifMaxMinRule : Rule
ifMaxMinRule =
  mkRule
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
      fixability = Fixable,
      needs = [],
    }
    ruleIfMaxMin
    (Some ifMaxMinFix)

andThenPureMapRule : Rule
andThenPureMapRule =
  mkRule
    RuleMeta {
      name = ruleNameAndThenPureMap,
      summary =
        "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)",
      doc =
        "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleAndThenPureMap
    (Some andThenPureMapFix)

destructureInParamRule : Rule
destructureInParamRule =
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

missingSignatureRule : Rule
missingSignatureRule =
  mkRule
    RuleMeta {
      name = ruleNameMissingSignature,
      summary =
        "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)",
      doc =
        "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleMissingSignature
    None

notEqRule : Rule
notEqRule =
  mkRule
    RuleMeta {
      name = ruleNameNotEq,
      summary =
        "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`",
      doc =
        "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleNotEq
    (Some notEqFix)

boolSimplifyRule : Rule
boolSimplifyRule =
  mkRule
    RuleMeta {
      name = ruleNameBoolSimplify,
      summary =
        "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify",
      doc =
        "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleBoolSimplify
    (Some boolSimplifyFix)

remParityRule : Rule
remParityRule =
  mkRule
    RuleMeta {
      name = ruleNameRemParity,
      summary =
        "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`",
      doc =
        "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleRemParity
    (Some remParityFix)

doubleReverseRule : Rule
doubleReverseRule =
  mkRule
    RuleMeta {
      name = ruleNameDoubleReverse,
      summary = "`reverse (reverse x)` is `x`. Drop the double reversal",
      doc =
        "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleDoubleReverse
    (Some doubleReverseFix)

whenUnlessRule : Rule
whenUnlessRule =
  mkRule
    RuleMeta {
      name = ruleNameWhenUnless,
      summary =
        "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`",
      doc =
        "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleWhenUnless
    (Some whenUnlessFix)

complementPredicateRule : Rule
complementPredicateRule =
  mkRule
    RuleMeta {
      name = ruleNameComplementPredicate,
      summary =
        "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly",
      doc =
        "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleComplementPredicate
    (Some complementPredicateFix)

matchToMapRule : Rule
matchToMapRule =
  mkRule
    RuleMeta {
      name = ruleNameMatchToMap,
      summary =
        "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')",
      doc =
        "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleMatchToMap
    (Some matchToMapFix)

bindChainToDoRule : Rule
bindChainToDoRule =
  mkRule
    RuleMeta {
      name = ruleNameBindChainToDo,
      summary =
        "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)",
      doc =
        "Three or more nested `match` arms that each pass a `Result` or `Option` failure straight through form a pyramid. A `do` block flattens it. The rule only suggests; it has no fixer.\n\nBefore:\n  match a\n    Ok x => match b x\n      Ok y => match c y\n        Ok z => Ok z\n        Err e => Err e\n      Err e => Err e\n    Err e => Err e\nAfter:\n  do\n    x <- a\n    y <- b x\n    c y",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleBindChainToDo
    None

deadCodeRule : Rule
deadCodeRule =
  mkRule
    RuleMeta {
      name = ruleNameDeadCode,
      summary =
        "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)",
      doc =
        "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)",
      category = Suspicious,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDeadCode
    None

concatToInterpRule : Rule
concatToInterpRule =
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

selfShadowExternRule : Rule
selfShadowExternRule =
  mkRule
    RuleMeta {
      name = ruleNameSelfShadowExtern,
      summary =
        "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)",
      doc =
        "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name",
      category = Correctness,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleSelfShadowExtern
    None

preferAssignOpRule : Rule
preferAssignOpRule =
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

promissoryReaderRule : Rule
promissoryReaderRule =
  mkRule
    RuleMeta {
      name = ruleNamePromissoryReader,
      summary =
        "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)",
      doc =
        "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    rulePromissoryReader
    None

orElseStaircaseRule : Rule
orElseStaircaseRule =
  mkRule
    RuleMeta {
      name = ruleNameOrElseStaircase,
      summary =
        "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)",
      doc =
        "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Express it with `orElse` or `findMap`. Suggest-only.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElse (probeA x) (orElse (probeB x) (probeC x))",
      category = Complexity,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleOrElseStaircase
    None

cloneTypeRule : Rule
cloneTypeRule =
  mkRule
    RuleMeta {
      name = ruleNameCloneType,
      summary =
        "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)",
      doc =
        "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleCloneType
    None

clauseMapRule : Rule
clauseMapRule =
  mkRule
    RuleMeta {
      name = ruleNameClauseMap,
      summary =
        "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)",
      doc =
        "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleClauseMap
    None

directiveReasonRule : Rule
directiveReasonRule =
  mkRule
    RuleMeta {
      name = ruleNameDirectiveReason,
      summary =
        "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)",
      doc =
        "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDirectiveReason
    None

regexLiteralRule : Rule
regexLiteralRule =
  mkRule
    RuleMeta {
      name = ruleNameRegexLiteral,
      summary =
        "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern",
      doc =
        "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\"",
      category = Correctness,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleRegexLiteral
    None

testBoolLiteralEqualRule : Rule
testBoolLiteralEqualRule =
  mkRule
    RuleMeta {
      name = ruleNameTestBoolLiteralEqual,
      summary =
        "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`",
      doc =
        "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. Findings are reported but `--fix` does not apply: the rewrite matched verbs by bare name and could change a program's meaning (#3837).\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleTestBoolLiteralEqual
    (Some testBoolLiteralEqualFix)

testEqualInTrueRule : Rule
testEqualInTrueRule =
  mkRule
    RuleMeta {
      name = ruleNameTestEqualInTrue,
      summary =
        "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure",
      doc =
        "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. Findings are reported but `--fix` does not apply (#3837).\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleTestEqualInTrue
    (Some testEqualInTrueFix)

testPreludeShadowRule : Rule
testPreludeShadowRule =
  mkRule
    RuleMeta {
      name = ruleNameTestPreludeShadow,
      summary =
        "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)",
      doc =
        "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper",
      category = Suspicious,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleTestPreludeShadow
    None

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
duplicateBodyRule =
  mkCrossFileRule
    RuleMeta {
      name = ruleNameDuplicateBody,
      summary =
        "top-level function body is structurally identical to one in another file (copy-paste; consolidate)",
      doc =
        "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDuplicateBody

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
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "CrossFileRule" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkCrossFileRule" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameAndThenPureMap" false) (mem "ruleNameBindChainToDo" false) (mem "ruleNameBindThenDestructure" false) (mem "ruleNameBoolSimplify" false) (mem "ruleNameClauseMap" false) (mem "ruleNameCloneType" false) (mem "ruleNameComplementPredicate" false) (mem "ruleNameConcatToInterp" false) (mem "ruleNameDeadCode" false) (mem "ruleNameDerivable" false) (mem "ruleNameDestructureInParam" false) (mem "ruleNameDirectiveReason" false) (mem "ruleNameDoubleReverse" false) (mem "ruleNameDuplicateBody" false) (mem "ruleNameIfMaxMin" false) (mem "ruleNameLambdaSection" false) (mem "ruleNameMatchParam" false) (mem "ruleNameMatchToMap" false) (mem "ruleNameMissingSignature" false) (mem "ruleNameNotEq" false) (mem "ruleNameOrElseStaircase" false) (mem "ruleNamePreferAssignOp" false) (mem "ruleNamePromissoryReader" false) (mem "ruleNameRegexLiteral" false) (mem "ruleNameRemParity" false) (mem "ruleNameSelfShadowExtern" false) (mem "ruleNameStdlibReimpl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "ruleNameTestEqualInTrue" false) (mem "ruleNameTestPreludeShadow" false) (mem "ruleNameWhenUnless" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "andThenPureMapFix" false) (mem "bindThenDestructureFix" false) (mem "boolSimplifyFix" false) (mem "complementPredicateFix" false) (mem "concatToInterpFix" false) (mem "destructureInParamFix" false) (mem "doubleReverseFix" false) (mem "duplicateBodySameFileRule" false) (mem "ifMaxMinFix" false) (mem "lambdaSectionFix" false) (mem "matchParamFix" false) (mem "matchToMapFix" false) (mem "notEqFix" false) (mem "preferAssignFix" false) (mem "remParityFix" false) (mem "ruleAndThenPureMap" false) (mem "ruleBindChainToDo" false) (mem "ruleBindThenDestructure" false) (mem "ruleBoolSimplify" false) (mem "ruleClauseMap" false) (mem "ruleCloneType" false) (mem "ruleComplementPredicate" false) (mem "ruleConcatToInterp" false) (mem "ruleDeadCode" false) (mem "ruleDerivable" false) (mem "ruleDestructureInParam" false) (mem "ruleDirectiveReason" false) (mem "ruleDoubleReverse" false) (mem "ruleDuplicateBody" false) (mem "ruleForPreferAssign" false) (mem "ruleIfMaxMin" false) (mem "ruleLambdaSection" false) (mem "ruleMatchOnParam" false) (mem "ruleMatchToMap" false) (mem "ruleMissingSignature" false) (mem "ruleNotEq" false) (mem "ruleOrElseStaircase" false) (mem "rulePromissoryReader" false) (mem "ruleRegexLiteral" false) (mem "ruleRemParity" false) (mem "ruleSelfShadowExtern" false) (mem "ruleStdlibReimpl" false) (mem "ruleTestBoolLiteralEqual" false) (mem "ruleTestEqualInTrue" false) (mem "ruleTestPreludeShadow" false) (mem "ruleWhenUnless" false) (mem "testBoolLiteralEqualFix" false) (mem "testEqualInTrueFix" false) (mem "whenUnlessFix" false))))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchParam")) (fa "summary" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "doc" (ELit (LString "A function whose whole body is a `match` on one of its own parameters is clearer as several clauses: the patterns move into the parameter position and the extra indentation level goes away. This enforces STYLE section 8, a repository taste ruling.\n\nBefore:\n  len xs = match xs\n    [] => 0\n    _ :: t => 1 + len t\nAfter:\n  len [] = 0\n  len (_ :: t) = 1 + len t"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchOnParam")) (EApp (EVar "Some") (EVar "matchParamFix"))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDerivable")) (fa "summary" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "doc" (ELit (LString "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDerivable")) (EVar "None")))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "summary" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "doc" (ELit (LString "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsStdlibIndex")))))) (EVar "ruleStdlibReimpl")) (EVar "None")))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleAndThenPureMap")) (EApp (EVar "Some") (EVar "andThenPureMapFix"))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "summary" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "doc" (ELit (LString "A function body that is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple, record, single-constructor) can destructure in the parameter position.\n\nBefore:\n  f p = match p\n    (a, b) => a + b\nAfter:\n  f (a, b) = a + b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDestructureInParam")) (EApp (EVar "Some") (EVar "destructureInParamFix"))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleMissingSignature")) (EVar "None")))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleNotEq")) (EApp (EVar "Some") (EVar "notEqFix"))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "summary" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "doc" (ELit (LString "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBoolSimplify")) (EApp (EVar "Some") (EVar "boolSimplifyFix"))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleRemParity")) (EApp (EVar "Some") (EVar "remParityFix"))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDoubleReverse")) (EApp (EVar "Some") (EVar "doubleReverseFix"))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleWhenUnless")) (EApp (EVar "Some") (EVar "whenUnlessFix"))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "summary" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "doc" (ELit (LString "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleComplementPredicate")) (EApp (EVar "Some") (EVar "complementPredicateFix"))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchToMap")) (EApp (EVar "Some") (EVar "matchToMapFix"))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "summary" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "doc" (ELit (LString "Three or more nested `match` arms that each pass a `Result` or `Option` failure straight through form a pyramid. A `do` block flattens it. The rule only suggests; it has no fixer.\n\nBefore:\n  match a\n    Ok x => match b x\n      Ok y => match c y\n        Ok z => Ok z\n        Err e => Err e\n      Err e => Err e\n    Err e => Err e\nAfter:\n  do\n    x <- a\n    y <- b x\n    c y"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleBindChainToDo")) (EVar "None")))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDeadCode")) (fa "summary" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "doc" (ELit (LString "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDeadCode")) (EVar "None")))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleConcatToInterp")) (EApp (EVar "Some") (EVar "concatToInterpFix"))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "summary" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "doc" (ELit (LString "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name"))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleSelfShadowExtern")) (EVar "None")))
(DTypeSig false "preferAssignOpRule" (TyCon "Rule"))
(DFunDef false "preferAssignOpRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleForPreferAssign")) (EApp (EVar "Some") (EVar "preferAssignFix"))))
(DTypeSig false "promissoryReaderRule" (TyCon "Rule"))
(DFunDef false "promissoryReaderRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "summary" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "doc" (ELit (LString "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePromissoryReader")) (EVar "None")))
(DTypeSig false "orElseStaircaseRule" (TyCon "Rule"))
(DFunDef false "orElseStaircaseRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "summary" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)"))) (fa "doc" (ELit (LString "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Express it with `orElse` or `findMap`. Suggest-only.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElse (probeA x) (orElse (probeB x) (probeC x))"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleOrElseStaircase")) (EVar "None")))
(DTypeSig false "cloneTypeRule" (TyCon "Rule"))
(DFunDef false "cloneTypeRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCloneType")) (fa "summary" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "doc" (ELit (LString "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleCloneType")) (EVar "None")))
(DTypeSig false "clauseMapRule" (TyCon "Rule"))
(DFunDef false "clauseMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameClauseMap")) (fa "summary" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "doc" (ELit (LString "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleClauseMap")) (EVar "None")))
(DTypeSig false "directiveReasonRule" (TyCon "Rule"))
(DFunDef false "directiveReasonRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "summary" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "doc" (ELit (LString "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDirectiveReason")) (EVar "None")))
(DTypeSig false "regexLiteralRule" (TyCon "Rule"))
(DFunDef false "regexLiteralRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "summary" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "doc" (ELit (LString "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\""))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleRegexLiteral")) (EVar "None")))
(DTypeSig false "testBoolLiteralEqualRule" (TyCon "Rule"))
(DFunDef false "testBoolLiteralEqualRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "summary" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "doc" (ELit (LString "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. Findings are reported but `--fix` does not apply: the rewrite matched verbs by bare name and could change a program's meaning (#3837).\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestBoolLiteralEqual")) (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))
(DTypeSig false "testEqualInTrueRule" (TyCon "Rule"))
(DFunDef false "testEqualInTrueRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "summary" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "doc" (ELit (LString "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. Findings are reported but `--fix` does not apply (#3837).\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestEqualInTrue")) (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))
(DTypeSig false "testPreludeShadowRule" (TyCon "Rule"))
(DFunDef false "testPreludeShadowRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "summary" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestPreludeShadow")) (EVar "None")))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule") (EVar "preferAssignOpRule") (EVar "promissoryReaderRule") (EVar "orElseStaircaseRule") (EVar "cloneTypeRule") (EVar "clauseMapRule") (EVar "duplicateBodySameFileRule") (EVar "directiveReasonRule") (EVar "regexLiteralRule") (EVar "testBoolLiteralEqualRule") (EVar "testEqualInTrueRule") (EVar "testPreludeShadowRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (EApp (EApp (EVar "mkCrossFileRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBody")))
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
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "CrossFileRule" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkCrossFileRule" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameAndThenPureMap" false) (mem "ruleNameBindChainToDo" false) (mem "ruleNameBindThenDestructure" false) (mem "ruleNameBoolSimplify" false) (mem "ruleNameClauseMap" false) (mem "ruleNameCloneType" false) (mem "ruleNameComplementPredicate" false) (mem "ruleNameConcatToInterp" false) (mem "ruleNameDeadCode" false) (mem "ruleNameDerivable" false) (mem "ruleNameDestructureInParam" false) (mem "ruleNameDirectiveReason" false) (mem "ruleNameDoubleReverse" false) (mem "ruleNameDuplicateBody" false) (mem "ruleNameIfMaxMin" false) (mem "ruleNameLambdaSection" false) (mem "ruleNameMatchParam" false) (mem "ruleNameMatchToMap" false) (mem "ruleNameMissingSignature" false) (mem "ruleNameNotEq" false) (mem "ruleNameOrElseStaircase" false) (mem "ruleNamePreferAssignOp" false) (mem "ruleNamePromissoryReader" false) (mem "ruleNameRegexLiteral" false) (mem "ruleNameRemParity" false) (mem "ruleNameSelfShadowExtern" false) (mem "ruleNameStdlibReimpl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "ruleNameTestEqualInTrue" false) (mem "ruleNameTestPreludeShadow" false) (mem "ruleNameWhenUnless" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "andThenPureMapFix" false) (mem "bindThenDestructureFix" false) (mem "boolSimplifyFix" false) (mem "complementPredicateFix" false) (mem "concatToInterpFix" false) (mem "destructureInParamFix" false) (mem "doubleReverseFix" false) (mem "duplicateBodySameFileRule" false) (mem "ifMaxMinFix" false) (mem "lambdaSectionFix" false) (mem "matchParamFix" false) (mem "matchToMapFix" false) (mem "notEqFix" false) (mem "preferAssignFix" false) (mem "remParityFix" false) (mem "ruleAndThenPureMap" false) (mem "ruleBindChainToDo" false) (mem "ruleBindThenDestructure" false) (mem "ruleBoolSimplify" false) (mem "ruleClauseMap" false) (mem "ruleCloneType" false) (mem "ruleComplementPredicate" false) (mem "ruleConcatToInterp" false) (mem "ruleDeadCode" false) (mem "ruleDerivable" false) (mem "ruleDestructureInParam" false) (mem "ruleDirectiveReason" false) (mem "ruleDoubleReverse" false) (mem "ruleDuplicateBody" false) (mem "ruleForPreferAssign" false) (mem "ruleIfMaxMin" false) (mem "ruleLambdaSection" false) (mem "ruleMatchOnParam" false) (mem "ruleMatchToMap" false) (mem "ruleMissingSignature" false) (mem "ruleNotEq" false) (mem "ruleOrElseStaircase" false) (mem "rulePromissoryReader" false) (mem "ruleRegexLiteral" false) (mem "ruleRemParity" false) (mem "ruleSelfShadowExtern" false) (mem "ruleStdlibReimpl" false) (mem "ruleTestBoolLiteralEqual" false) (mem "ruleTestEqualInTrue" false) (mem "ruleTestPreludeShadow" false) (mem "ruleWhenUnless" false) (mem "testBoolLiteralEqualFix" false) (mem "testEqualInTrueFix" false) (mem "whenUnlessFix" false))))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchParam")) (fa "summary" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "doc" (ELit (LString "A function whose whole body is a `match` on one of its own parameters is clearer as several clauses: the patterns move into the parameter position and the extra indentation level goes away. This enforces STYLE section 8, a repository taste ruling.\n\nBefore:\n  len xs = match xs\n    [] => 0\n    _ :: t => 1 + len t\nAfter:\n  len [] = 0\n  len (_ :: t) = 1 + len t"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchOnParam")) (EApp (EVar "Some") (EVar "matchParamFix"))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDerivable")) (fa "summary" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "doc" (ELit (LString "A hand-written `Eq`, `Ord` or `Debug` impl that does exactly what `deriving` would generate is code that can drift from the type. Derive it instead.\n\nBefore:\n  impl Eq Color\n    Red == Red = True\n    ...\nAfter:\n  data Color = Red | Green deriving (Eq)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDerivable")) (EVar "None")))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "summary" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "doc" (ELit (LString "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsStdlibIndex")))))) (EVar "ruleStdlibReimpl")) (EVar "None")))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleAndThenPureMap")) (EApp (EVar "Some") (EVar "andThenPureMapFix"))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "summary" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "doc" (ELit (LString "A function body that is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple, record, single-constructor) can destructure in the parameter position.\n\nBefore:\n  f p = match p\n    (a, b) => a + b\nAfter:\n  f (a, b) = a + b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDestructureInParam")) (EApp (EVar "Some") (EVar "destructureInParamFix"))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleMissingSignature")) (EVar "None")))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleNotEq")) (EApp (EVar "Some") (EVar "notEqFix"))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "summary" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "doc" (ELit (LString "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBoolSimplify")) (EApp (EVar "Some") (EVar "boolSimplifyFix"))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleRemParity")) (EApp (EVar "Some") (EVar "remParityFix"))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDoubleReverse")) (EApp (EVar "Some") (EVar "doubleReverseFix"))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleWhenUnless")) (EApp (EVar "Some") (EVar "whenUnlessFix"))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "summary" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "doc" (ELit (LString "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleComplementPredicate")) (EApp (EVar "Some") (EVar "complementPredicateFix"))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchToMap")) (EApp (EVar "Some") (EVar "matchToMapFix"))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "summary" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "doc" (ELit (LString "Three or more nested `match` arms that each pass a `Result` or `Option` failure straight through form a pyramid. A `do` block flattens it. The rule only suggests; it has no fixer.\n\nBefore:\n  match a\n    Ok x => match b x\n      Ok y => match c y\n        Ok z => Ok z\n        Err e => Err e\n      Err e => Err e\n    Err e => Err e\nAfter:\n  do\n    x <- a\n    y <- b x\n    c y"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleBindChainToDo")) (EVar "None")))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDeadCode")) (fa "summary" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "doc" (ELit (LString "A private top-level binding that nothing reachable from the file's exports, `main` or doctests uses is dead code (Haskell -Wunused-top-binds). Delete it or export it.\n\nBefore:\n  helper x = x + 1   -- never called\nAfter:\n  (binding removed)"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDeadCode")) (EVar "None")))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "summary" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "doc" (ELit (LString "A `++` chain mixing string literals with expressions reads better as string interpolation.\n\nBefore:\n  \"n = \" ++ show n ++ \"!\"\nAfter:\n  \"n = \\{show n}!\""))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleConcatToInterp")) (EApp (EVar "Some") (EVar "concatToInterpFix"))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "summary" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "doc" (ELit (LString "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name"))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleSelfShadowExtern")) (EVar "None")))
(DTypeSig false "preferAssignOpRule" (TyCon "Rule"))
(DFunDef false "preferAssignOpRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreferAssignOp")) (fa "summary" (ELit (LString "`setRef r v` (predates the `:=` write operator), or a `:=` write bound to a wildcard `let _ =`. Prefer `r := v` as a statement"))) (fa "doc" (ELit (LString "`setRef r v` predates the `:=` write operator, and a `:=` write bound to a wildcard `let _ =` is a statement in disguise.\n\nBefore:\n  setRef counter 1\nAfter:\n  counter := 1"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleForPreferAssign")) (EApp (EVar "Some") (EVar "preferAssignFix"))))
(DTypeSig false "promissoryReaderRule" (TyCon "Rule"))
(DFunDef false "promissoryReaderRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "summary" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "doc" (ELit (LString "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePromissoryReader")) (EVar "None")))
(DTypeSig false "orElseStaircaseRule" (TyCon "Rule"))
(DFunDef false "orElseStaircaseRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "summary" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Rewrite with `orElse`/`findMap` (suggest-only)"))) (fa "doc" (ELit (LString "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Express it with `orElse` or `findMap`. Suggest-only.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElse (probeA x) (orElse (probeB x) (probeC x))"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleOrElseStaircase")) (EVar "None")))
(DTypeSig false "cloneTypeRule" (TyCon "Rule"))
(DFunDef false "cloneTypeRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCloneType")) (fa "summary" (ELit (LString "two-constructor `data` with `Option`'s or `Result`'s constructor arities and no `impl` in the declaring file. Prefer the stdlib type (suggest-only)"))) (fa "doc" (ELit (LString "A two-constructor `data` with the arities of `Option` or `Result` and no `impl` in its file duplicates the stdlib type and loses its instances. Suggest-only.\n\nBefore:\n  data Maybe2 a = Nope | Yep a\nAfter:\n  use `Option a`"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleCloneType")) (EVar "None")))
(DTypeSig false "clauseMapRule" (TyCon "Rule"))
(DFunDef false "clauseMapRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameClauseMap")) (fa "summary" (ELit (LString "two-clause `[]`/`(x :: xs)` recursion that conses a per-element transform onto the recursive call — a hand-written `map` (suggest-only)"))) (fa "doc" (ELit (LString "A two-clause `[]` / `(x :: xs)` recursion that conses a per-element transform onto the recursive call is a hand-written `map`. Suggest-only.\n\nBefore:\n  go [] = []\n  go (x :: xs) = f x :: go xs\nAfter:\n  map f"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleClauseMap")) (EVar "None")))
(DTypeSig false "directiveReasonRule" (TyCon "Rule"))
(DFunDef false "directiveReasonRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "summary" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "doc" (ELit (LString "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDirectiveReason")) (EVar "None")))
(DTypeSig false "regexLiteralRule" (TyCon "Rule"))
(DFunDef false "regexLiteralRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "summary" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "doc" (ELit (LString "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\""))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleRegexLiteral")) (EVar "None")))
(DTypeSig false "testBoolLiteralEqualRule" (TyCon "Rule"))
(DFunDef false "testBoolLiteralEqualRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "summary" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "doc" (ELit (LString "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. Findings are reported but `--fix` does not apply: the rewrite matched verbs by bare name and could change a program's meaning (#3837).\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestBoolLiteralEqual")) (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))
(DTypeSig false "testEqualInTrueRule" (TyCon "Rule"))
(DFunDef false "testEqualInTrueRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "summary" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "doc" (ELit (LString "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. Findings are reported but `--fix` does not apply (#3837).\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestEqualInTrue")) (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))
(DTypeSig false "testPreludeShadowRule" (TyCon "Rule"))
(DFunDef false "testPreludeShadowRule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "summary" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestPreludeShadow")) (EVar "None")))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule") (EVar "preferAssignOpRule") (EVar "promissoryReaderRule") (EVar "orElseStaircaseRule") (EVar "cloneTypeRule") (EVar "clauseMapRule") (EVar "duplicateBodySameFileRule") (EVar "directiveReasonRule") (EVar "regexLiteralRule") (EVar "testBoolLiteralEqualRule") (EVar "testEqualInTrueRule") (EVar "testPreludeShadowRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (EApp (EApp (EVar "mkCrossFileRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBody")))
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
