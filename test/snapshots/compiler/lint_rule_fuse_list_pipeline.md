# META
source_lines=179
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-fuse-list-pipeline: a list traversal the stdlib has a single name for. Write the one name.

import driver.diagnostics.{Severity(..)}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  mkVisitorRule,
}
import tools.lint_hints.{
  Hint,
  HintCond(..),
  HintRow(..),
  compileHints,
  hintVisitors,
}
import tools.lint_shared.{ruleNameFuseListPipeline}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameFuseListPipeline,
      summary =
        "a traversal with a single stdlib name: `somes (map f xs)`, `length (filter p xs)`, `length xs == 0`, `xs == []`",
      doc =
        "Several traversals build an intermediate list, or count a whole list to learn whether it is empty, where one stdlib name does the work in one pass.\n\nBefore:\n  length (filter p xs)\n  length xs == 0\n  xs == []\nAfter:\n  count p xs\n  isEmpty xs\n  isEmpty xs",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    (idx path facts pos decls =>
      hintVisitors
        ruleNameFuseListPipeline
        SevWarning
        hints
        idx
        path
        facts
        pos
        decls)
    None

-- ── rule: fuse-list-pipeline ──────────────────────────────────────────────────
-- Each row has one receiver type the pattern can match without types: the
-- `[]` of `xs == []` and the `somes` of `somes (map f xs)` pin a `List`, and
-- `length`, `isEmpty`, `filter` and `count` are the prelude's `Foldable` and
-- `Filterable` methods, so a qualified `B.length` never matches.  `Safe` rows
-- keep the value, the effects and their order.  `isEmpty (filter p xs)` is
-- `Unsafe`: `filter` applies `p` to every element and `any` stops at the first
-- hit, so a `p` that performs an effect or panics on a later element differs.
-- `xs == []` is `Unsafe` for typing: `isEmpty` is `Foldable`-polymorphic, so an
-- unsigned binding that the `List` comparison pinned becomes more general, and
-- a caller that relied on the pin can turn ambiguous.
-- `head (reverse xs)` is `Suggest` because `last` lives in `list` and the fix
-- would not add its import.  Fusing two `map`s is `Suggest` because it
-- interleaves the effects of `f` and `g`.  The names a rewrite writes
-- (`count`, `isEmpty`, `not`, ...) are guarded like the names it reads.
export
hintRows : List HintRow
hintRows = [
  HintRow {
    rowText = "somes (map f a) ==> filterMap f a",
    rowMessage = "`somes` over `map` builds an intermediate list",
    rowFix = "use filterMap",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "length (filter p a) ==> count p a",
    rowMessage = "`length` over `filter` builds an intermediate list",
    rowFix = "use count",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "isEmpty (filter p a) ==> not (any p a)",
    rowMessage = "`isEmpty` over `filter` builds an intermediate list",
    rowFix = "use any",
    rowApplicability = Unsafe,
    rowConds = [],
  },
  HintRow {
    rowText = "length a == 0 ==> isEmpty a",
    rowMessage = "emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "0 == length a ==> isEmpty a",
    rowMessage = "emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "length a /= 0 ==> not (isEmpty a)",
    rowMessage = "non-emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "0 /= length a ==> not (isEmpty a)",
    rowMessage = "non-emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "length a > 0 ==> not (isEmpty a)",
    rowMessage = "non-emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "0 < length a ==> not (isEmpty a)",
    rowMessage = "non-emptiness by counting the whole list",
    rowFix = "use isEmpty",
    rowApplicability = Safe,
    rowConds = [],
  },
  HintRow {
    rowText = "a == [] ==> isEmpty a",
    rowMessage = "emptiness by comparison with `[]`",
    rowFix = "use isEmpty",
    rowApplicability = Unsafe,
    rowConds = [],
  },
  HintRow {
    rowText = "[] == a ==> isEmpty a",
    rowMessage = "emptiness by comparison with `[]`",
    rowFix = "use isEmpty",
    rowApplicability = Unsafe,
    rowConds = [],
  },
  HintRow {
    rowText = "a /= [] ==> not (isEmpty a)",
    rowMessage = "non-emptiness by comparison with `[]`",
    rowFix = "use isEmpty",
    rowApplicability = Unsafe,
    rowConds = [],
  },
  HintRow {
    rowText = "[] /= a ==> not (isEmpty a)",
    rowMessage = "non-emptiness by comparison with `[]`",
    rowFix = "use isEmpty",
    rowApplicability = Unsafe,
    rowConds = [],
  },
  HintRow {
    rowText = "head (reverse a) ==> last a",
    rowMessage = "`head` over `reverse` reverses the whole list",
    rowFix = "use last (from list)",
    rowApplicability = Suggest,
    rowConds = [],
  },
  HintRow {
    rowText = "map f (map g a) ==> map (g >> f) a",
    rowMessage = "two `map` passes build an intermediate list",
    rowFix = "fuse into one map",
    rowApplicability = Suggest,
    rowConds = [],
  },
]

hints : List Hint
hints = compileHints hintRows
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameFuseListPipeline" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameFuseListPipeline")) (fa "summary" (ELit (LString "a traversal with a single stdlib name: `somes (map f xs)`, `length (filter p xs)`, `length xs == 0`, `xs == []`"))) (fa "doc" (ELit (LString "Several traversals build an intermediate list, or count a whole list to learn whether it is empty, where one stdlib name does the work in one pass.\n\nBefore:\n  length (filter p xs)\n  length xs == 0\n  xs == []\nAfter:\n  count p xs\n  isEmpty xs\n  isEmpty xs"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameFuseListPipeline")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "somes (map f a) ==> filterMap f a"))) (fa "rowMessage" (ELit (LString "`somes` over `map` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use filterMap"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length (filter p a) ==> count p a"))) (fa "rowMessage" (ELit (LString "`length` over `filter` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use count"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "isEmpty (filter p a) ==> not (any p a)"))) (fa "rowMessage" (ELit (LString "`isEmpty` over `filter` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use any"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a == 0 ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 == length a ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a /= 0 ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 /= length a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a > 0 ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 < length a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "a == [] ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "[] == a ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "a /= [] ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "[] /= a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "head (reverse a) ==> last a"))) (fa "rowMessage" (ELit (LString "`head` over `reverse` reverses the whole list"))) (fa "rowFix" (ELit (LString "use last (from list)"))) (fa "rowApplicability" (EVar "Suggest")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "map f (map g a) ==> map (g >> f) a"))) (fa "rowMessage" (ELit (LString "two `map` passes build an intermediate list"))) (fa "rowFix" (ELit (LString "fuse into one map"))) (fa "rowApplicability" (EVar "Suggest")) (fa "rowConds" (EListLit))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameFuseListPipeline" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameFuseListPipeline")) (fa "summary" (ELit (LString "a traversal with a single stdlib name: `somes (map f xs)`, `length (filter p xs)`, `length xs == 0`, `xs == []`"))) (fa "doc" (ELit (LString "Several traversals build an intermediate list, or count a whole list to learn whether it is empty, where one stdlib name does the work in one pass.\n\nBefore:\n  length (filter p xs)\n  length xs == 0\n  xs == []\nAfter:\n  count p xs\n  isEmpty xs\n  isEmpty xs"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameFuseListPipeline")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "somes (map f a) ==> filterMap f a"))) (fa "rowMessage" (ELit (LString "`somes` over `map` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use filterMap"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length (filter p a) ==> count p a"))) (fa "rowMessage" (ELit (LString "`length` over `filter` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use count"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "isEmpty (filter p a) ==> not (any p a)"))) (fa "rowMessage" (ELit (LString "`isEmpty` over `filter` builds an intermediate list"))) (fa "rowFix" (ELit (LString "use any"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a == 0 ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 == length a ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a /= 0 ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 /= length a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "length a > 0 ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "0 < length a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by counting the whole list"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "a == [] ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "[] == a ==> isEmpty a"))) (fa "rowMessage" (ELit (LString "emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "a /= [] ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "[] /= a ==> not (isEmpty a)"))) (fa "rowMessage" (ELit (LString "non-emptiness by comparison with `[]`"))) (fa "rowFix" (ELit (LString "use isEmpty"))) (fa "rowApplicability" (EVar "Unsafe")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "head (reverse a) ==> last a"))) (fa "rowMessage" (ELit (LString "`head` over `reverse` reverses the whole list"))) (fa "rowFix" (ELit (LString "use last (from list)"))) (fa "rowApplicability" (EVar "Suggest")) (fa "rowConds" (EListLit)))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "map f (map g a) ==> map (g >> f) a"))) (fa "rowMessage" (ELit (LString "two `map` passes build an intermediate list"))) (fa "rowFix" (ELit (LString "fuse into one map"))) (fa "rowApplicability" (EVar "Suggest")) (fa "rowConds" (EListLit))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
