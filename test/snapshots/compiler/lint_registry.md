# META
source_lines=160
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_registry.mdk — THE REGISTRY: `allRules`, the cross-file
-- registry, and rule-name selection.  Adding a rule = write a `lint_rule_<name>`
-- module exporting `rule`, import it here `as Alias` and append `Alias.rule,` to
-- `allRules`.

import support.util.{contains, anyList, filterList, isEmptyL}
import tools.lint_core.{CrossFileRule(..), Ratchet(..), Rule(..), RuleMeta(..)}
import tools.lint_rule_internal_match_on_param as MatchOnParam
import tools.lint_rule_stdlib_reimpl as StdlibReimpl
import tools.lint_rule_not_eq as NotEq
import tools.lint_rule_double_reverse as DoubleReverse
import tools.lint_rule_self_shadow_extern as SelfShadowExtern
import tools.lint_rule_internal_test_prelude_shadow as TestPreludeShadow
import tools.lint_rule_andthen_pure_map as AndThenPureMap
import tools.lint_rule_missing_signature as MissingSignature
import tools.lint_rule_match_to_map as MatchToMap
import tools.lint_rule_orelse_staircase as OrElseStaircase
import tools.lint_rule_clause_map as ClauseMap
import tools.lint_rule_internal_test_bool_literal_equal as TestBoolLiteralEqual
import tools.lint_rule_destructure_in_param as DestructureInParam
import tools.lint_rule_when_unless as WhenUnless
import tools.lint_rule_concat_to_interp as ConcatToInterp
import tools.lint_rule_internal_promissory_reader as PromissoryReader
import tools.lint_rule_clone_type as CloneType
import tools.lint_rule_hand_rolled_derivable as HandRolledDerivable
import tools.lint_rule_bind_then_destructure as BindThenDestructure
import tools.lint_rule_bind_chain_to_do as BindChainToDo
import tools.lint_rule_duplicate_body as DuplicateBody
import tools.lint_rule_duplicate_body_same_file as DuplicateBodySameFile
import tools.lint_rule_internal_directive_reason as DirectiveReason
import tools.lint_rule_dead_code as DeadCode
import tools.lint_rule_prefer_assign_op as PreferAssignOp
import tools.lint_rule_complement_predicate as ComplementPredicate
import tools.lint_rule_rem_parity as RemParity
import tools.lint_rule_lambda_section as LambdaSection
import tools.lint_rule_if_max_min as IfMaxMin
import tools.lint_rule_bool_simplify as BoolSimplify
import tools.lint_rule_regex_literal as RegexLiteral
import tools.lint_rule_internal_test_equal_in_true as TestEqualInTrue

-- ── the registry ─────────────────────────────────────────────────────────────
-- The list position is the output order of findings.  Each entry is the `rule`
-- binding of one `lint_rule_*` module.
export
allRules : List Rule
allRules = [
  MatchOnParam.rule,
  HandRolledDerivable.rule,
  StdlibReimpl.rule,
  BindThenDestructure.rule,
  LambdaSection.rule,
  IfMaxMin.rule,
  AndThenPureMap.rule,
  DestructureInParam.rule,
  MissingSignature.rule,
  NotEq.rule,
  BoolSimplify.rule,
  RemParity.rule,
  DoubleReverse.rule,
  WhenUnless.rule,
  ComplementPredicate.rule,
  MatchToMap.rule,
  BindChainToDo.rule,
  DeadCode.rule,
  ConcatToInterp.rule,
  SelfShadowExtern.rule,
  PreferAssignOp.rule,
  PromissoryReader.rule,
  OrElseStaircase.rule,
  CloneType.rule,
  ClauseMap.rule,
  DuplicateBodySameFile.rule,
  DirectiveReason.rule,
  RegexLiteral.rule,
  TestBoolLiteralEqual.rule,
  TestEqualInTrue.rule,
  TestPreludeShadow.rule,
]

-- ── the cross-file registry ───────────────────────────────────────────────────
-- Adding a cross-file rule = a `lint_rule_*` module exporting `rule : CrossFileRule`
-- plus an `Alias.rule,` entry in `allCrossFileRules`.
export
allCrossFileRules : List CrossFileRule
allCrossFileRules = [DuplicateBody.rule]

-- Metadata a cross-file rule may not carry.  A `Baselined` ratchet is enforced by
-- a per-file count row, and a cross-file finding has no file row to count
-- against, so such a rule would be enforced by nothing.  (`Internal` scope is
-- fine: the runner filters the tier's findings by the file they land in.)
export
crossFileMetaProblems : List CrossFileRule -> List String
crossFileMetaProblems rules = flatMap crossFileRuleProblems rules

crossFileRuleProblems : CrossFileRule -> List String
crossFileRuleProblems r = match r.meta.ratchet
  Baselined => [
    "cross-file rule `\{r.name}` is Baselined; only a per-file rule can be (no count row exists for a cross-file finding), so it would be enforced by nothing",
  ]
  Gated => []

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
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true))))
(DUse false (UseAlias ("tools" "lint_rule_internal_match_on_param") "MatchOnParam"))
(DUse false (UseAlias ("tools" "lint_rule_stdlib_reimpl") "StdlibReimpl"))
(DUse false (UseAlias ("tools" "lint_rule_not_eq") "NotEq"))
(DUse false (UseAlias ("tools" "lint_rule_double_reverse") "DoubleReverse"))
(DUse false (UseAlias ("tools" "lint_rule_self_shadow_extern") "SelfShadowExtern"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_prelude_shadow") "TestPreludeShadow"))
(DUse false (UseAlias ("tools" "lint_rule_andthen_pure_map") "AndThenPureMap"))
(DUse false (UseAlias ("tools" "lint_rule_missing_signature") "MissingSignature"))
(DUse false (UseAlias ("tools" "lint_rule_match_to_map") "MatchToMap"))
(DUse false (UseAlias ("tools" "lint_rule_orelse_staircase") "OrElseStaircase"))
(DUse false (UseAlias ("tools" "lint_rule_clause_map") "ClauseMap"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_bool_literal_equal") "TestBoolLiteralEqual"))
(DUse false (UseAlias ("tools" "lint_rule_destructure_in_param") "DestructureInParam"))
(DUse false (UseAlias ("tools" "lint_rule_when_unless") "WhenUnless"))
(DUse false (UseAlias ("tools" "lint_rule_concat_to_interp") "ConcatToInterp"))
(DUse false (UseAlias ("tools" "lint_rule_internal_promissory_reader") "PromissoryReader"))
(DUse false (UseAlias ("tools" "lint_rule_clone_type") "CloneType"))
(DUse false (UseAlias ("tools" "lint_rule_hand_rolled_derivable") "HandRolledDerivable"))
(DUse false (UseAlias ("tools" "lint_rule_bind_then_destructure") "BindThenDestructure"))
(DUse false (UseAlias ("tools" "lint_rule_bind_chain_to_do") "BindChainToDo"))
(DUse false (UseAlias ("tools" "lint_rule_duplicate_body") "DuplicateBody"))
(DUse false (UseAlias ("tools" "lint_rule_duplicate_body_same_file") "DuplicateBodySameFile"))
(DUse false (UseAlias ("tools" "lint_rule_internal_directive_reason") "DirectiveReason"))
(DUse false (UseAlias ("tools" "lint_rule_dead_code") "DeadCode"))
(DUse false (UseAlias ("tools" "lint_rule_prefer_assign_op") "PreferAssignOp"))
(DUse false (UseAlias ("tools" "lint_rule_complement_predicate") "ComplementPredicate"))
(DUse false (UseAlias ("tools" "lint_rule_rem_parity") "RemParity"))
(DUse false (UseAlias ("tools" "lint_rule_lambda_section") "LambdaSection"))
(DUse false (UseAlias ("tools" "lint_rule_if_max_min") "IfMaxMin"))
(DUse false (UseAlias ("tools" "lint_rule_bool_simplify") "BoolSimplify"))
(DUse false (UseAlias ("tools" "lint_rule_regex_literal") "RegexLiteral"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_equal_in_true") "TestEqualInTrue"))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "MatchOnParam.rule") (EVar "HandRolledDerivable.rule") (EVar "StdlibReimpl.rule") (EVar "BindThenDestructure.rule") (EVar "LambdaSection.rule") (EVar "IfMaxMin.rule") (EVar "AndThenPureMap.rule") (EVar "DestructureInParam.rule") (EVar "MissingSignature.rule") (EVar "NotEq.rule") (EVar "BoolSimplify.rule") (EVar "RemParity.rule") (EVar "DoubleReverse.rule") (EVar "WhenUnless.rule") (EVar "ComplementPredicate.rule") (EVar "MatchToMap.rule") (EVar "BindChainToDo.rule") (EVar "DeadCode.rule") (EVar "ConcatToInterp.rule") (EVar "SelfShadowExtern.rule") (EVar "PreferAssignOp.rule") (EVar "PromissoryReader.rule") (EVar "OrElseStaircase.rule") (EVar "CloneType.rule") (EVar "ClauseMap.rule") (EVar "DuplicateBodySameFile.rule") (EVar "DirectiveReason.rule") (EVar "RegexLiteral.rule") (EVar "TestBoolLiteralEqual.rule") (EVar "TestEqualInTrue.rule") (EVar "TestPreludeShadow.rule")))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "DuplicateBody.rule")))
(DTypeSig true "crossFileMetaProblems" (TyFun (TyApp (TyCon "List") (TyCon "CrossFileRule")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "crossFileMetaProblems" ((PVar "rules")) (EApp (EApp (EVar "flatMap") (EVar "crossFileRuleProblems")) (EVar "rules")))
(DTypeSig false "crossFileRuleProblems" (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "crossFileRuleProblems" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "ratchet") (arm (PCon "Baselined") () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "cross-file rule `")) (EApp (EVar "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "` is Baselined; only a per-file rule can be (no count row exists for a cross-file finding), so it would be enforced by nothing"))))) (arm (PCon "Gated") () (EListLit))))
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
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true))))
(DUse false (UseAlias ("tools" "lint_rule_internal_match_on_param") "MatchOnParam"))
(DUse false (UseAlias ("tools" "lint_rule_stdlib_reimpl") "StdlibReimpl"))
(DUse false (UseAlias ("tools" "lint_rule_not_eq") "NotEq"))
(DUse false (UseAlias ("tools" "lint_rule_double_reverse") "DoubleReverse"))
(DUse false (UseAlias ("tools" "lint_rule_self_shadow_extern") "SelfShadowExtern"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_prelude_shadow") "TestPreludeShadow"))
(DUse false (UseAlias ("tools" "lint_rule_andthen_pure_map") "AndThenPureMap"))
(DUse false (UseAlias ("tools" "lint_rule_missing_signature") "MissingSignature"))
(DUse false (UseAlias ("tools" "lint_rule_match_to_map") "MatchToMap"))
(DUse false (UseAlias ("tools" "lint_rule_orelse_staircase") "OrElseStaircase"))
(DUse false (UseAlias ("tools" "lint_rule_clause_map") "ClauseMap"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_bool_literal_equal") "TestBoolLiteralEqual"))
(DUse false (UseAlias ("tools" "lint_rule_destructure_in_param") "DestructureInParam"))
(DUse false (UseAlias ("tools" "lint_rule_when_unless") "WhenUnless"))
(DUse false (UseAlias ("tools" "lint_rule_concat_to_interp") "ConcatToInterp"))
(DUse false (UseAlias ("tools" "lint_rule_internal_promissory_reader") "PromissoryReader"))
(DUse false (UseAlias ("tools" "lint_rule_clone_type") "CloneType"))
(DUse false (UseAlias ("tools" "lint_rule_hand_rolled_derivable") "HandRolledDerivable"))
(DUse false (UseAlias ("tools" "lint_rule_bind_then_destructure") "BindThenDestructure"))
(DUse false (UseAlias ("tools" "lint_rule_bind_chain_to_do") "BindChainToDo"))
(DUse false (UseAlias ("tools" "lint_rule_duplicate_body") "DuplicateBody"))
(DUse false (UseAlias ("tools" "lint_rule_duplicate_body_same_file") "DuplicateBodySameFile"))
(DUse false (UseAlias ("tools" "lint_rule_internal_directive_reason") "DirectiveReason"))
(DUse false (UseAlias ("tools" "lint_rule_dead_code") "DeadCode"))
(DUse false (UseAlias ("tools" "lint_rule_prefer_assign_op") "PreferAssignOp"))
(DUse false (UseAlias ("tools" "lint_rule_complement_predicate") "ComplementPredicate"))
(DUse false (UseAlias ("tools" "lint_rule_rem_parity") "RemParity"))
(DUse false (UseAlias ("tools" "lint_rule_lambda_section") "LambdaSection"))
(DUse false (UseAlias ("tools" "lint_rule_if_max_min") "IfMaxMin"))
(DUse false (UseAlias ("tools" "lint_rule_bool_simplify") "BoolSimplify"))
(DUse false (UseAlias ("tools" "lint_rule_regex_literal") "RegexLiteral"))
(DUse false (UseAlias ("tools" "lint_rule_internal_test_equal_in_true") "TestEqualInTrue"))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "MatchOnParam.rule") (EVar "HandRolledDerivable.rule") (EVar "StdlibReimpl.rule") (EVar "BindThenDestructure.rule") (EVar "LambdaSection.rule") (EVar "IfMaxMin.rule") (EVar "AndThenPureMap.rule") (EVar "DestructureInParam.rule") (EVar "MissingSignature.rule") (EVar "NotEq.rule") (EVar "BoolSimplify.rule") (EVar "RemParity.rule") (EVar "DoubleReverse.rule") (EVar "WhenUnless.rule") (EVar "ComplementPredicate.rule") (EVar "MatchToMap.rule") (EVar "BindChainToDo.rule") (EVar "DeadCode.rule") (EVar "ConcatToInterp.rule") (EVar "SelfShadowExtern.rule") (EVar "PreferAssignOp.rule") (EVar "PromissoryReader.rule") (EVar "OrElseStaircase.rule") (EVar "CloneType.rule") (EVar "ClauseMap.rule") (EVar "DuplicateBodySameFile.rule") (EVar "DirectiveReason.rule") (EVar "RegexLiteral.rule") (EVar "TestBoolLiteralEqual.rule") (EVar "TestEqualInTrue.rule") (EVar "TestPreludeShadow.rule")))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "DuplicateBody.rule")))
(DTypeSig true "crossFileMetaProblems" (TyFun (TyApp (TyCon "List") (TyCon "CrossFileRule")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "crossFileMetaProblems" ((PVar "rules")) (EApp (EApp (EDictApp "flatMap") (EVar "crossFileRuleProblems")) (EVar "rules")))
(DTypeSig false "crossFileRuleProblems" (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "crossFileRuleProblems" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "ratchet") (arm (PCon "Baselined") () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "cross-file rule `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "name"))) (ELit (LString "` is Baselined; only a per-file rule can be (no count row exists for a cross-file finding), so it would be enforced by nothing"))))) (arm (PCon "Gated") () (EListLit))))
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
