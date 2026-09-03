# META
source_lines=278
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_baseline.mdk — the per-(file, rule) finding-count baseline
-- behind `medaka lint --baseline` / `--write-baseline` (#2619).
--
-- WHY.  `.githooks/pre-commit`'s `GATED_LINT_RULES` is a MAX RATCHET: a rule may
-- only be gated once the whole tree is at zero findings for it.  A rule whose
-- tree count is nonzero and not this sprint's to drain (`rule-stdlib-reimpl`)
-- therefore had no enforcement at all — it warned, and nothing stopped the count
-- from growing.  A baseline is the intermediate: the CURRENT per-file count is
-- pinned, a file may go down freely, and going UP is an error.
--
-- ── THE INVARIANT (hold every change in this file to it) ─────────────────────
--   AN UNANSWERABLE QUESTION IS AN ERROR, NEVER A PASS.
-- A missing baseline file, malformed TOML, a duplicate row, a negative count,
-- and — the one that matters most — a file that HAS findings for a rule but no
-- row for that (file, rule) all resolve to a violation.  There is no "assume
-- zero" and no "assume clean" branch and there must never be one: a baseline
-- that silently passes when it cannot answer is worth less than no baseline,
-- because it reports green.
--
-- ── KEYS ────────────────────────────────────────────────────────────────────
-- A row's `file` is the lint TARGET path as `medaka lint` was given it, made
-- relative to the process's working directory.  Both consumers (the pre-commit
-- hook and test/diff_compiler_lint_baseline.sh) run at the repo root, so the
-- rows read as ordinary repo-relative paths.  Run from elsewhere, a key stops
-- matching and the run fails closed with the key it looked for — the loud half
-- of the invariant above, not a wrong answer.

import driver.diagnostics.{Diag(..), Severity(..)}
import tools.lint.{Finding(..), applyFindingDeny}
import support.util.{
  contains, listLen, filterList, joinNl, startsWith, sortUniqS, isSome
}
import list.{sortOn}
import toml.{Toml, parse, getString, getInt, tableCount, tableEntry}

-- ── the data ────────────────────────────────────────────────────────────────

-- One `[[entry]]` of the baseline file: "file F is allowed COUNT findings of
-- rule R, and no more".
public export data BaselineRow = BaselineRow {
  file : String,
  rule : String,
  count : Int,
}

public export data LintBaseline = LintBaseline (List BaselineRow)

-- ── reading ─────────────────────────────────────────────────────────────────

-- Read and parse a baseline file.  `Err` on anything that leaves the baseline
-- unable to answer — including the file not existing, which is the case a
-- careless implementation would treat as "no rows, so nothing exceeds".
export
readLintBaseline : String -> <IO> Result String LintBaseline
readLintBaseline path = match readFile path
  Err msg => Err "cannot read lint baseline '\{path}': \{msg}"
  Ok src => parseLintBaseline path src

export
parseLintBaseline : String -> String -> Result String LintBaseline
parseLintBaseline origin src = match parse src
  Err e => Err "\{origin}: not valid TOML: \{e}"
  Ok doc =>
    map LintBaseline (baselineRowsGo doc origin 0 (tableCount "entry" doc) [])

baselineRowsGo : Toml ->
  String ->
  Int ->
  Int ->
  List BaselineRow ->
  Result String (List BaselineRow)
baselineRowsGo doc origin i n acc =
  if i >= n then
    Ok acc
  else match baselineRowAt doc origin i
    Err e => Err e
    Ok r =>
      if baselineHasKey acc r.file r.rule then
        Err "\{origin}: duplicate row for '\{r.file}' / \{r.rule}"
      else
        baselineRowsGo doc origin (i + 1) n (acc ++ [r])

baselineRowAt : Toml -> String -> Int -> Result String BaselineRow
baselineRowAt doc origin i = match tableEntry "entry" i doc
  None => Err "\{origin}: [[entry]] #\{intToString i} is out of range"
  Some e => match (getString "file" e, getString "rule" e, getInt "count" e)
    (Some f, Some r, Some c) =>
      if c < 0 then
        Err "\{origin}: [[entry]] #\{intToString i} has a negative count"
      else
        Ok BaselineRow { file = f, rule = r, count = c }
    _ => Err "\{origin}: [[entry]] #\{intToString i} needs file, rule and count"

baselineHasKey : List BaselineRow -> String -> String -> Bool
baselineHasKey rows file rule = isSome (baselineAllowedGo rows file rule)

-- ── the key ─────────────────────────────────────────────────────────────────

-- The baseline key for a lint target, given the canonical working directory:
-- the target with that directory's prefix (or a leading `./`) removed.  A path
-- that is neither is left alone — it will simply not match a row, which the
-- caller reports as a missing row.
export
baselineKeyOf : String -> String -> String
baselineKeyOf cwd target
  | startsWith "\{cwd}/" target =
    stringSlice (stringLength cwd + 1) (stringLength target) target
  | startsWith "./" target = stringSlice 2 (stringLength target) target
  | otherwise = target

-- ── comparing ───────────────────────────────────────────────────────────────

-- The allowance for one (file, rule), or `None` when the baseline has no row.
export
baselineAllowed : LintBaseline -> String -> String -> Option Int
baselineAllowed (LintBaseline rows) file rule = baselineAllowedGo rows file rule

baselineAllowedGo : List BaselineRow -> String -> String -> Option Int
baselineAllowedGo [] _ _ = None
baselineAllowedGo (r :: rest) file rule
  | r.file == file && r.rule == rule = Some r.count
  | otherwise = baselineAllowedGo rest file rule

-- One entry per DISTINCT rule name in `names`, with how many times it occurs,
-- rule-sorted.  `names` is one entry per finding, so the count is the finding
-- count for that rule in that file.
export
ruleCounts : List String -> List (String, Int)
ruleCounts names = map (r => (r, occurrencesOf r names)) (sortUniqS names)

occurrencesOf : String -> List String -> Int
occurrencesOf r names = listLen (filterList (== r) names)

-- Every rule whose count for `file` is not covered by the baseline: `(rule,
-- actual, allowance)`, with `None` as the allowance when there is no row at all.
export
baselineViolations : LintBaseline ->
  String ->
  List String ->
  List (String, Int, Option Int)
baselineViolations base file names =
  filterList
    baselineViolated
    (map (rc => baselineCheckOne base file rc) (ruleCounts names))

baselineCheckOne : LintBaseline ->
  String ->
  (String, Int) ->
  (String, Int, Option Int)
baselineCheckOne base file (rule, n) = (rule, n, baselineAllowed base file rule)

baselineViolated : (String, Int, Option Int) -> Bool
baselineViolated (_, _, None) = True
baselineViolated (_, n, Some allowed) = n > allowed

export
baselineViolationLine : String -> (String, Int, Option Int) -> String
baselineViolationLine file (rule, n, None) =
  "\{file}: \{rule}: \{intToString n} finding(s) but no baseline row"
baselineViolationLine file (rule, n, Some allowed) =
  "\{file}: \{rule}: \{intToString n} finding(s) exceed the baseline of \{intToString allowed}"

-- The rules a file busted, as a plain name list — the input both promotion
-- surfaces below reduce to.
export
baselineBustedRules : LintBaseline -> String -> List String -> List String
baselineBustedRules base file names =
  map (v => bustedRuleOf v) (baselineViolations base file names)

bustedRuleOf : (String, Int, Option Int) -> String
bustedRuleOf (rule, _, _) = rule

-- ── promotion ───────────────────────────────────────────────────────────────
--
-- Promotion is `--deny`'s, conditioned on the count rather than on blanket rule
-- membership: once a file busts its row for a rule, EVERY finding of that rule
-- in that file becomes a `SevError`, so the exit code follows from the ordinary
-- `isFindingError` / `diagIsError` fold and no caller needs a second channel.
-- Findings, for the text report path:
export
applyBaselineToFindings : LintBaseline -> String -> List Finding -> List Finding
applyBaselineToFindings base file findings =
  applyFindingDeny
    (baselineBustedRules base file (map findingRuleOf findings))
    findings

-- Diags, for `--json` — `findingToDiag` puts the rule name in `code`, so the
-- same decision applies to the serialized form without re-deriving it.
-- The `baselineViolations` of a file's serialized diagnostics, so a `--json`
-- caller need not reach for the `code` accessor itself.
export
baselineDiagViolations : LintBaseline ->
  String ->
  List Diag ->
  List (String, Int, Option Int)
baselineDiagViolations base file diags =
  baselineViolations base file (map diagCodeOf diags)

export
applyBaselineToDiags : LintBaseline -> String -> List Diag -> List Diag
applyBaselineToDiags base file diags =
  promoteDiags (baselineBustedRules base file (map diagCodeOf diags)) diags

-- Both promotion surfaces reduce their input to a plain rule-name list; these
-- two projections are where `Finding` and `Diag` say the same thing.  Named
-- rather than inlined as `f => f.rule`, which is ambiguous between `Finding` and
-- `BaselineRow` at the use site.
export
findingRuleOf : Finding -> String
findingRuleOf f = f.rule

export
diagCodeOf : Diag -> String
diagCodeOf (Diag _ code _ _ _ _) = code

promoteDiags : List String -> List Diag -> List Diag
promoteDiags [] diags = diags
promoteDiags names diags = map (d => promoteDiag names d) diags

promoteDiag : List String -> Diag -> Diag
promoteDiag names (Diag sev code msg loc help fix)
  | contains code names = Diag SevError code msg loc help fix
  | otherwise = Diag sev code msg loc help fix

-- ── writing ─────────────────────────────────────────────────────────────────

-- Render a whole baseline file from a real run's per-file rule occurrences
-- (`(key, one name per finding)`).  Rows are sorted by `file` then `rule` and
-- zero-count files are omitted, so a regeneration that changed nothing produces
-- a byte-identical file — the property that lets `--write-baseline` be the ONLY
-- sanctioned way to move a count.
export
renderLintBaseline : List (String, List String) -> String
renderLintBaseline perFile = stringConcat [
  baselineFileHeader,
  joinNl
    (map renderBaselineRow (sortOn baselineRowKey (baselineRowsOf perFile))),
  "\n",
]

export
baselineRowsOf : List (String, List String) -> List BaselineRow
baselineRowsOf [] = []
baselineRowsOf ((file, names) :: rest) =
  map (rc => baselineRowOf file rc) (ruleCounts names) ++ baselineRowsOf rest

baselineRowOf : String -> (String, Int) -> BaselineRow
baselineRowOf file (rule, n) =
  BaselineRow { file = file, rule = rule, count = n }

baselineRowKey : BaselineRow -> String
baselineRowKey r = "\{r.file}\n\{r.rule}"

renderBaselineRow : BaselineRow -> String
renderBaselineRow r =
  "[[entry]]\nfile = \"\{r.file}\"\nrule = \"\{r.rule}\"\ncount = \{intToString r.count}\n"

baselineFileHeader : String
baselineFileHeader = stringConcat [
  "# lint finding-count baseline — GENERATED, never hand-edited (#2619).\n",
  "#\n",
  "# One [[entry]] per (file, rule) with at least one finding: the number of\n",
  "# findings that file is currently ALLOWED for that rule.  A file may drop\n",
  "# below its count freely; exceeding it is an error, and so is having\n",
  "# findings for a rule with no row here at all.\n",
  "#\n",
  "# Enforced by .githooks/pre-commit (BASELINED_LINT_RULES, per staged file)\n",
  "# and by test/diff_compiler_lint_baseline.sh (whole tree, so --no-verify\n",
  "# cannot smuggle an increase past the hook).\n",
  "#\n",
  "# Regenerate from the repo root, never by hand:\n",
  "#\n",
  "#   sh test/diff_compiler_lint_baseline.sh --write\n",
  "#\n",
  "# Paths are relative to the directory `medaka lint` runs in (the repo root\n",
  "# for both consumers above).\n",
  "\n",
]
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" true) (mem "applyFindingDeny" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "filterList" false) (mem "joinNl" false) (mem "startsWith" false) (mem "sortUniqS" false) (mem "isSome" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getInt" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DData Public "BaselineRow" () ((variant "BaselineRow" (ConNamed (field "file" (TyCon "String")) (field "rule" (TyCon "String")) (field "count" (TyCon "Int"))))) ())
(DData Public "LintBaseline" () ((variant "LintBaseline" (ConPos (TyApp (TyCon "List") (TyCon "BaselineRow"))))) ())
(DTypeSig true "readLintBaseline" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LintBaseline")))))
(DFunDef false "readLintBaseline" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read lint baseline '")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "': "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "parseLintBaseline") (EVar "path")) (EVar "src")))))
(DTypeSig true "parseLintBaseline" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LintBaseline")))))
(DFunDef false "parseLintBaseline" ((PVar "origin") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString ": not valid TOML: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "map") (EVar "LintBaseline")) (EApp (EApp (EApp (EApp (EApp (EVar "baselineRowsGo") (EVar "doc")) (EVar "origin")) (ELit (LInt 0))) (EApp (EApp (EVar "tableCount") (ELit (LString "entry"))) (EVar "doc"))) (EListLit))))))
(DTypeSig false "baselineRowsGo" (TyFun (TyCon "Toml") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "BaselineRow")))))))))
(DFunDef false "baselineRowsGo" ((PVar "doc") (PVar "origin") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EApp (EApp (EVar "baselineRowAt") (EVar "doc")) (EVar "origin")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "r")) () (EIf (EApp (EApp (EApp (EVar "baselineHasKey") (EVar "acc")) (EFieldAccess (EVar "r") "file")) (EFieldAccess (EVar "r") "rule")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString ": duplicate row for '"))) (EApp (EVar "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "' / "))) (EApp (EVar "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EVar "baselineRowsGo") (EVar "doc")) (EVar "origin")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EListLit (EVar "r")))))))))
(DTypeSig false "baselineRowAt" (TyFun (TyCon "Toml") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BaselineRow"))))))
(DFunDef false "baselineRowAt" ((PVar "doc") (PVar "origin") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "entry"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is out of range"))))) (arm (PCon "Some" (PVar "e")) () (EMatch (ETuple (EApp (EApp (EVar "getString") (ELit (LString "file"))) (EVar "e")) (EApp (EApp (EVar "getString") (ELit (LString "rule"))) (EVar "e")) (EApp (EApp (EVar "getInt") (ELit (LString "count"))) (EVar "e"))) (arm (PTuple (PCon "Some" (PVar "f")) (PCon "Some" (PVar "r")) (PCon "Some" (PVar "c"))) () (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " has a negative count")))) (EApp (EVar "Ok") (ERecordCreate "BaselineRow" ((fa "file" (EVar "f")) (fa "rule" (EVar "r")) (fa "count" (EVar "c"))))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " needs file, rule and count")))))))))
(DTypeSig false "baselineHasKey" (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "baselineHasKey" ((PVar "rows") (PVar "file") (PVar "rule")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rows")) (EVar "file")) (EVar "rule"))))
(DTypeSig true "baselineKeyOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "baselineKeyOf" ((PVar "cwd") (PVar "target")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "cwd"))) (ELit (LString "/")))) (EVar "target")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EApp (EVar "stringLength") (EVar "cwd")) (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "target"))) (EVar "target")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "target")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "target"))) (EVar "target")) (EIf (EVar "otherwise") (EVar "target") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "baselineAllowed" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "baselineAllowed" ((PCon "LintBaseline" (PVar "rows")) (PVar "file") (PVar "rule")) (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rows")) (EVar "file")) (EVar "rule")))
(DTypeSig false "baselineAllowedGo" (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "baselineAllowedGo" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "baselineAllowedGo" ((PCons (PVar "r") (PVar "rest")) (PVar "file") (PVar "rule")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "file") (EVar "file")) (EBinOp "==" (EFieldAccess (EVar "r") "rule") (EVar "rule"))) (EApp (EVar "Some") (EFieldAccess (EVar "r") "count")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rest")) (EVar "file")) (EVar "rule")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ruleCounts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ruleCounts" ((PVar "names")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EVar "r") (EApp (EApp (EVar "occurrencesOf") (EVar "r")) (EVar "names"))))) (EApp (EVar "sortUniqS") (EVar "names"))))
(DTypeSig false "occurrencesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "occurrencesOf" ((PVar "r") (PVar "names")) (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "r")))) (EVar "names"))))
(DTypeSig true "baselineViolations" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "baselineViolations" ((PVar "base") (PVar "file") (PVar "names")) (EApp (EApp (EVar "filterList") (EVar "baselineViolated")) (EApp (EApp (EVar "map") (ELam ((PVar "rc")) (EApp (EApp (EApp (EVar "baselineCheckOne") (EVar "base")) (EVar "file")) (EVar "rc")))) (EApp (EVar "ruleCounts") (EVar "names")))))
(DTypeSig false "baselineCheckOne" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "baselineCheckOne" ((PVar "base") (PVar "file") (PTuple (PVar "rule") (PVar "n"))) (ETuple (EVar "rule") (EVar "n") (EApp (EApp (EApp (EVar "baselineAllowed") (EVar "base")) (EVar "file")) (EVar "rule"))))
(DTypeSig false "baselineViolated" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "baselineViolated" ((PTuple PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "baselineViolated" ((PTuple PWild (PVar "n") (PCon "Some" (PVar "allowed")))) (EBinOp ">" (EVar "n") (EVar "allowed")))
(DTypeSig true "baselineViolationLine" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "String"))))
(DFunDef false "baselineViolationLine" ((PVar "file") (PTuple (PVar "rule") (PVar "n") (PCon "None"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "rule"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) but no baseline row"))))
(DFunDef false "baselineViolationLine" ((PVar "file") (PTuple (PVar "rule") (PVar "n") (PCon "Some" (PVar "allowed")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "rule"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) exceed the baseline of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "allowed")))) (ELit (LString ""))))
(DTypeSig true "baselineBustedRules" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "baselineBustedRules" ((PVar "base") (PVar "file") (PVar "names")) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EVar "bustedRuleOf") (EVar "v")))) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "file")) (EVar "names"))))
(DTypeSig false "bustedRuleOf" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "bustedRuleOf" ((PTuple (PVar "rule") PWild PWild)) (EVar "rule"))
(DTypeSig true "applyBaselineToFindings" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "applyBaselineToFindings" ((PVar "base") (PVar "file") (PVar "findings")) (EApp (EApp (EVar "applyFindingDeny") (EApp (EApp (EApp (EVar "baselineBustedRules") (EVar "base")) (EVar "file")) (EApp (EApp (EVar "map") (EVar "findingRuleOf")) (EVar "findings")))) (EVar "findings")))
(DTypeSig true "baselineDiagViolations" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "baselineDiagViolations" ((PVar "base") (PVar "file") (PVar "diags")) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "file")) (EApp (EApp (EVar "map") (EVar "diagCodeOf")) (EVar "diags"))))
(DTypeSig true "applyBaselineToDiags" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "applyBaselineToDiags" ((PVar "base") (PVar "file") (PVar "diags")) (EApp (EApp (EVar "promoteDiags") (EApp (EApp (EApp (EVar "baselineBustedRules") (EVar "base")) (EVar "file")) (EApp (EApp (EVar "map") (EVar "diagCodeOf")) (EVar "diags")))) (EVar "diags")))
(DTypeSig true "findingRuleOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingRuleOf" ((PVar "f")) (EFieldAccess (EVar "f") "rule"))
(DTypeSig true "diagCodeOf" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagCodeOf" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "promoteDiags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "promoteDiags" ((PList) (PVar "diags")) (EVar "diags"))
(DFunDef false "promoteDiags" ((PVar "names") (PVar "diags")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EVar "promoteDiag") (EVar "names")) (EVar "d")))) (EVar "diags")))
(DTypeSig false "promoteDiag" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Diag") (TyCon "Diag"))))
(DFunDef false "promoteDiag" ((PVar "names") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EIf (EApp (EApp (EVar "contains") (EVar "code")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderLintBaseline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderLintBaseline" ((PVar "perFile")) (EApp (EVar "stringConcat") (EListLit (EVar "baselineFileHeader") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "renderBaselineRow")) (EApp (EApp (EVar "sortOn") (EVar "baselineRowKey")) (EApp (EVar "baselineRowsOf") (EVar "perFile"))))) (ELit (LString "\n")))))
(DTypeSig true "baselineRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "BaselineRow"))))
(DFunDef false "baselineRowsOf" ((PList)) (EListLit))
(DFunDef false "baselineRowsOf" ((PCons (PTuple (PVar "file") (PVar "names")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "rc")) (EApp (EApp (EVar "baselineRowOf") (EVar "file")) (EVar "rc")))) (EApp (EVar "ruleCounts") (EVar "names"))) (EApp (EVar "baselineRowsOf") (EVar "rest"))))
(DTypeSig false "baselineRowOf" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "BaselineRow"))))
(DFunDef false "baselineRowOf" ((PVar "file") (PTuple (PVar "rule") (PVar "n"))) (ERecordCreate "BaselineRow" ((fa "file" (EVar "file")) (fa "rule" (EVar "rule")) (fa "count" (EVar "n")))))
(DTypeSig false "baselineRowKey" (TyFun (TyCon "BaselineRow") (TyCon "String")))
(DFunDef false "baselineRowKey" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "\n"))) (EApp (EVar "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString ""))))
(DTypeSig false "renderBaselineRow" (TyFun (TyCon "BaselineRow") (TyCon "String")))
(DFunDef false "renderBaselineRow" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[[entry]]\nfile = \"")) (EApp (EVar "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "\"\nrule = \""))) (EApp (EVar "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString "\"\ncount = "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "count")))) (ELit (LString "\n"))))
(DTypeSig false "baselineFileHeader" (TyCon "String"))
(DFunDef false "baselineFileHeader" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "# lint finding-count baseline — GENERATED, never hand-edited (#2619).\n")) (ELit (LString "#\n")) (ELit (LString "# One [[entry]] per (file, rule) with at least one finding: the number of\n")) (ELit (LString "# findings that file is currently ALLOWED for that rule.  A file may drop\n")) (ELit (LString "# below its count freely; exceeding it is an error, and so is having\n")) (ELit (LString "# findings for a rule with no row here at all.\n")) (ELit (LString "#\n")) (ELit (LString "# Enforced by .githooks/pre-commit (BASELINED_LINT_RULES, per staged file)\n")) (ELit (LString "# and by test/diff_compiler_lint_baseline.sh (whole tree, so --no-verify\n")) (ELit (LString "# cannot smuggle an increase past the hook).\n")) (ELit (LString "#\n")) (ELit (LString "# Regenerate from the repo root, never by hand:\n")) (ELit (LString "#\n")) (ELit (LString "#   sh test/diff_compiler_lint_baseline.sh --write\n")) (ELit (LString "#\n")) (ELit (LString "# Paths are relative to the directory `medaka lint` runs in (the repo root\n")) (ELit (LString "# for both consumers above).\n")) (ELit (LString "\n")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint") ((mem "Finding" true) (mem "applyFindingDeny" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "filterList" false) (mem "joinNl" false) (mem "startsWith" false) (mem "sortUniqS" false) (mem "isSome" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getInt" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DData Public "BaselineRow" () ((variant "BaselineRow" (ConNamed (field "file" (TyCon "String")) (field "rule" (TyCon "String")) (field "count" (TyCon "Int"))))) ())
(DData Public "LintBaseline" () ((variant "LintBaseline" (ConPos (TyApp (TyCon "List") (TyCon "BaselineRow"))))) ())
(DTypeSig true "readLintBaseline" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LintBaseline")))))
(DFunDef false "readLintBaseline" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read lint baseline '")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "': "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "parseLintBaseline") (EVar "path")) (EVar "src")))))
(DTypeSig true "parseLintBaseline" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LintBaseline")))))
(DFunDef false "parseLintBaseline" ((PVar "origin") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString ": not valid TOML: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EMethodRef "map") (EVar "LintBaseline")) (EApp (EApp (EApp (EApp (EApp (EVar "baselineRowsGo") (EVar "doc")) (EVar "origin")) (ELit (LInt 0))) (EApp (EApp (EVar "tableCount") (ELit (LString "entry"))) (EVar "doc"))) (EListLit))))))
(DTypeSig false "baselineRowsGo" (TyFun (TyCon "Toml") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "BaselineRow")))))))))
(DFunDef false "baselineRowsGo" ((PVar "doc") (PVar "origin") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EApp (EApp (EVar "baselineRowAt") (EVar "doc")) (EVar "origin")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "r")) () (EIf (EApp (EApp (EApp (EVar "baselineHasKey") (EVar "acc")) (EFieldAccess (EVar "r") "file")) (EFieldAccess (EVar "r") "rule")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString ": duplicate row for '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "' / "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EVar "baselineRowsGo") (EVar "doc")) (EVar "origin")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EListLit (EVar "r")))))))))
(DTypeSig false "baselineRowAt" (TyFun (TyCon "Toml") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BaselineRow"))))))
(DFunDef false "baselineRowAt" ((PVar "doc") (PVar "origin") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "entry"))) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is out of range"))))) (arm (PCon "Some" (PVar "e")) () (EMatch (ETuple (EApp (EApp (EVar "getString") (ELit (LString "file"))) (EVar "e")) (EApp (EApp (EVar "getString") (ELit (LString "rule"))) (EVar "e")) (EApp (EApp (EVar "getInt") (ELit (LString "count"))) (EVar "e"))) (arm (PTuple (PCon "Some" (PVar "f")) (PCon "Some" (PVar "r")) (PCon "Some" (PVar "c"))) () (EIf (EBinOp "<" (EVar "c") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " has a negative count")))) (EApp (EVar "Ok") (ERecordCreate "BaselineRow" ((fa "file" (EVar "f")) (fa "rule" (EVar "r")) (fa "count" (EVar "c"))))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString ": [[entry]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " needs file, rule and count")))))))))
(DTypeSig false "baselineHasKey" (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "baselineHasKey" ((PVar "rows") (PVar "file") (PVar "rule")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rows")) (EVar "file")) (EVar "rule"))))
(DTypeSig true "baselineKeyOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "baselineKeyOf" ((PVar "cwd") (PVar "target")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "cwd"))) (ELit (LString "/")))) (EVar "target")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EApp (EVar "stringLength") (EVar "cwd")) (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "target"))) (EVar "target")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "target")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "target"))) (EVar "target")) (EIf (EVar "otherwise") (EVar "target") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "baselineAllowed" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "baselineAllowed" ((PCon "LintBaseline" (PVar "rows")) (PVar "file") (PVar "rule")) (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rows")) (EVar "file")) (EVar "rule")))
(DTypeSig false "baselineAllowedGo" (TyFun (TyApp (TyCon "List") (TyCon "BaselineRow")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "baselineAllowedGo" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "baselineAllowedGo" ((PCons (PVar "r") (PVar "rest")) (PVar "file") (PVar "rule")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "file") (EVar "file")) (EBinOp "==" (EFieldAccess (EVar "r") "rule") (EVar "rule"))) (EApp (EVar "Some") (EFieldAccess (EVar "r") "count")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "baselineAllowedGo") (EVar "rest")) (EVar "file")) (EVar "rule")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ruleCounts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ruleCounts" ((PVar "names")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EVar "r") (EApp (EApp (EVar "occurrencesOf") (EVar "r")) (EVar "names"))))) (EApp (EVar "sortUniqS") (EVar "names"))))
(DTypeSig false "occurrencesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "occurrencesOf" ((PVar "r") (PVar "names")) (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "r")))) (EVar "names"))))
(DTypeSig true "baselineViolations" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "baselineViolations" ((PVar "base") (PVar "file") (PVar "names")) (EApp (EApp (EVar "filterList") (EVar "baselineViolated")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "rc")) (EApp (EApp (EApp (EVar "baselineCheckOne") (EVar "base")) (EVar "file")) (EVar "rc")))) (EApp (EVar "ruleCounts") (EVar "names")))))
(DTypeSig false "baselineCheckOne" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "baselineCheckOne" ((PVar "base") (PVar "file") (PTuple (PVar "rule") (PVar "n"))) (ETuple (EVar "rule") (EVar "n") (EApp (EApp (EApp (EVar "baselineAllowed") (EVar "base")) (EVar "file")) (EVar "rule"))))
(DTypeSig false "baselineViolated" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "baselineViolated" ((PTuple PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "baselineViolated" ((PTuple PWild (PVar "n") (PCon "Some" (PVar "allowed")))) (EBinOp ">" (EVar "n") (EVar "allowed")))
(DTypeSig true "baselineViolationLine" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "String"))))
(DFunDef false "baselineViolationLine" ((PVar "file") (PTuple (PVar "rule") (PVar "n") (PCon "None"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "rule"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) but no baseline row"))))
(DFunDef false "baselineViolationLine" ((PVar "file") (PTuple (PVar "rule") (PVar "n") (PCon "Some" (PVar "allowed")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "rule"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) exceed the baseline of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "allowed")))) (ELit (LString ""))))
(DTypeSig true "baselineBustedRules" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "baselineBustedRules" ((PVar "base") (PVar "file") (PVar "names")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EVar "bustedRuleOf") (EVar "v")))) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "file")) (EVar "names"))))
(DTypeSig false "bustedRuleOf" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))) (TyCon "String")))
(DFunDef false "bustedRuleOf" ((PTuple (PVar "rule") PWild PWild)) (EVar "rule"))
(DTypeSig true "applyBaselineToFindings" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "applyBaselineToFindings" ((PVar "base") (PVar "file") (PVar "findings")) (EApp (EApp (EVar "applyFindingDeny") (EApp (EApp (EApp (EVar "baselineBustedRules") (EVar "base")) (EVar "file")) (EApp (EApp (EMethodRef "map") (EVar "findingRuleOf")) (EVar "findings")))) (EVar "findings")))
(DTypeSig true "baselineDiagViolations" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "baselineDiagViolations" ((PVar "base") (PVar "file") (PVar "diags")) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "file")) (EApp (EApp (EMethodRef "map") (EVar "diagCodeOf")) (EVar "diags"))))
(DTypeSig true "applyBaselineToDiags" (TyFun (TyCon "LintBaseline") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "applyBaselineToDiags" ((PVar "base") (PVar "file") (PVar "diags")) (EApp (EApp (EVar "promoteDiags") (EApp (EApp (EApp (EVar "baselineBustedRules") (EVar "base")) (EVar "file")) (EApp (EApp (EMethodRef "map") (EVar "diagCodeOf")) (EVar "diags")))) (EVar "diags")))
(DTypeSig true "findingRuleOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingRuleOf" ((PVar "f")) (EFieldAccess (EVar "f") "rule"))
(DTypeSig true "diagCodeOf" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagCodeOf" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "promoteDiags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "promoteDiags" ((PList) (PVar "diags")) (EVar "diags"))
(DFunDef false "promoteDiags" ((PVar "names") (PVar "diags")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EVar "promoteDiag") (EVar "names")) (EVar "d")))) (EVar "diags")))
(DTypeSig false "promoteDiag" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Diag") (TyCon "Diag"))))
(DFunDef false "promoteDiag" ((PVar "names") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EIf (EApp (EApp (EVar "contains") (EVar "code")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderLintBaseline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "String")))
(DFunDef false "renderLintBaseline" ((PVar "perFile")) (EApp (EVar "stringConcat") (EListLit (EVar "baselineFileHeader") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "renderBaselineRow")) (EApp (EApp (EVar "sortOn") (EVar "baselineRowKey")) (EApp (EVar "baselineRowsOf") (EVar "perFile"))))) (ELit (LString "\n")))))
(DTypeSig true "baselineRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "BaselineRow"))))
(DFunDef false "baselineRowsOf" ((PList)) (EListLit))
(DFunDef false "baselineRowsOf" ((PCons (PTuple (PVar "file") (PVar "names")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "rc")) (EApp (EApp (EVar "baselineRowOf") (EVar "file")) (EVar "rc")))) (EApp (EVar "ruleCounts") (EVar "names"))) (EApp (EVar "baselineRowsOf") (EVar "rest"))))
(DTypeSig false "baselineRowOf" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "BaselineRow"))))
(DFunDef false "baselineRowOf" ((PVar "file") (PTuple (PVar "rule") (PVar "n"))) (ERecordCreate "BaselineRow" ((fa "file" (EVar "file")) (fa "rule" (EVar "rule")) (fa "count" (EVar "n")))))
(DTypeSig false "baselineRowKey" (TyFun (TyCon "BaselineRow") (TyCon "String")))
(DFunDef false "baselineRowKey" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString ""))))
(DTypeSig false "renderBaselineRow" (TyFun (TyCon "BaselineRow") (TyCon "String")))
(DFunDef false "renderBaselineRow" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[[entry]]\nfile = \"")) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "file"))) (ELit (LString "\"\nrule = \""))) (EApp (EMethodRef "display") (EFieldAccess (EVar "r") "rule"))) (ELit (LString "\"\ncount = "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "count")))) (ELit (LString "\n"))))
(DTypeSig false "baselineFileHeader" (TyCon "String"))
(DFunDef false "baselineFileHeader" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "# lint finding-count baseline — GENERATED, never hand-edited (#2619).\n")) (ELit (LString "#\n")) (ELit (LString "# One [[entry]] per (file, rule) with at least one finding: the number of\n")) (ELit (LString "# findings that file is currently ALLOWED for that rule.  A file may drop\n")) (ELit (LString "# below its count freely; exceeding it is an error, and so is having\n")) (ELit (LString "# findings for a rule with no row here at all.\n")) (ELit (LString "#\n")) (ELit (LString "# Enforced by .githooks/pre-commit (BASELINED_LINT_RULES, per staged file)\n")) (ELit (LString "# and by test/diff_compiler_lint_baseline.sh (whole tree, so --no-verify\n")) (ELit (LString "# cannot smuggle an increase past the hook).\n")) (ELit (LString "#\n")) (ELit (LString "# Regenerate from the repo root, never by hand:\n")) (ELit (LString "#\n")) (ELit (LString "#   sh test/diff_compiler_lint_baseline.sh --write\n")) (ELit (LString "#\n")) (ELit (LString "# Paths are relative to the directory `medaka lint` runs in (the repo root\n")) (ELit (LString "# for both consumers above).\n")) (ELit (LString "\n")))))
