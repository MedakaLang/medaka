# META
source_lines=176
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-duplicate-body (same-file arm): two top-level functions in one file with structurally identical bodies.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, filterList, reverseL, joinWith}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}
import tools.lint_core.{
  Category(..),
  DupClause(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex(..),
  mkRule,
  factDupClauses,
}
import tools.lint_shared.{ruleNameDuplicateBody, sortUniqS}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameDuplicateBody,
      summary =
        "top-level function body is structurally identical to another top-level function in the SAME file (copy-paste; consolidate) — the in-file counterpart of the cross-file rule of the same name",
      doc =
        "Two top-level functions in the same file with structurally identical bodies (location-stripped, above a complexity floor) are copy-paste. Consolidate them. The cross-file arm of the same rule compares across files.\n\nBefore:\n  f x = big x\n  g y = big y   -- same body shape\nAfter:\n  one function, called twice",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDuplicateBodySameFile
    None

-- Same-file eligibility uses a HIGHER complexity floor than the cross-file
-- rule.  This is not tuning-to-the-corpus: it is a structural consequence of
-- how the two comparisons scale.  Cross-file compares bodies across a small
-- number of DISTINCT files, so a coincidental small-body match is rare — the
-- collision space is O(files).  Same-file compares every top-level body in ONE
-- file against every OTHER body in that same file, so the collision space is
-- O(bindings²) — and a file the size of `typecheck.mdk` has thousands of small
-- one-line helpers (`ppTyAtom (TyFun a b) = "(" ++ ppTy (TyFun a b) ++ ")"`-
-- shaped wrappers, single-arm forwarding accessors) whose bodies coincide by
-- sheer combinatorics, not because anyone copy-pasted anything.  The genuine
-- hazard this rule exists to catch (#602's `parseBracketBlock`/`indentedBody`)
-- is a multi-statement `do`-block, comfortably above this floor.
dupSameFileComplexityThreshold : Int
dupSameFileComplexityThreshold = 20

-- ── per-file rule: duplicate-body, SAME FILE (#602) ─────────────────────────────
-- `ruleDuplicateBody` above is cross-file-only by construction (its `check`
-- takes every target file at once and requires ≥2 DISTINCT files per group) —
-- so two byte-identical top-level bodies in the SAME file (e.g. parser.mdk's
-- `parseBracketBlock`/`indentedBody`) were structurally invisible to it.  This
-- is the in-file counterpart: same structural key (`structuralKey`), its own
-- higher floor (`dupSameFileComplexityThreshold` + not-pure-data), but
-- grouped within ONE file's own decls instead of across the whole project.
-- Registered under the SAME rule name (`ruleNameDuplicateBody`) so
-- `--disable`/`--only`/`-- lint-disable-*` address both halves with one name.
--
-- It keys one CLAUSE at a time, so the multi-clause aggregation the cross-file
-- half gained above does not apply here: a multi-clause same-file duplicate is
-- still invisible, and a function whose clauses all match another's is reported
-- once PER CLAUSE rather than once.  Both are left as they are deliberately —
-- the same-file collision space is O(bindings²) (see the floor note above), so
-- widening this half needs an over-fire budget of its own.
sameFileOccOfClause : DupClause -> List (String, Int, String)
sameFileOccOfClause c =
  if c.dcCost >= dupSameFileComplexityThreshold && not c.dcPure then
    [(c.dcName, c.dcLine, c.dcKey)]
  else
    []

ruleDuplicateBodySameFile : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleDuplicateBodySameFile _ _ facts _ _ =
  let occs = flatMap sameFileOccOfClause (factDupClauses facts)
  let groups = sameFileGroupByKey occs
  let live =
    filterList
      (k => listLen (findWithDefault [] k groups) >= 2)
      (sameFileDistinctKeys occs)
  flatMap
    (k => emitSameFileGroup (reverseL (findWithDefault [] k groups)))
    (sortUniqS live)

sameFileGroupByKey : List (String, Int, String) ->
  HashMap String (List (String, Int, String))
sameFileGroupByKey occs =
  let m = new ()
  let _ = sameFileGroupGo m occs
  m

sameFileGroupGo : HashMap String (List (String, Int, String)) ->
  List (String, Int, String) ->
  Unit
sameFileGroupGo _ [] = ()
sameFileGroupGo m (o :: rest) =
  let _ =
    setInPlace
      (sameFileOccKey o)
      (o :: findWithDefault [] (sameFileOccKey o) m)
      m
  sameFileGroupGo m rest

sameFileDistinctKeys : List (String, Int, String) -> List String
sameFileDistinctKeys occs =
  let seen = new ()
  sameFileDistinctGo seen occs

sameFileDistinctGo : HashMap String Unit ->
  List (String, Int, String) ->
  List String
sameFileDistinctGo _ [] = []
sameFileDistinctGo seen (o :: rest)
  | has (sameFileOccKey o) seen = sameFileDistinctGo seen rest
  | otherwise =
    let _ = setInPlace (sameFileOccKey o) () seen
    sameFileOccKey o :: sameFileDistinctGo seen rest

sameFileOccName : (String, Int, String) -> String
sameFileOccName (n, _, _) = n

sameFileOccLine : (String, Int, String) -> Int
sameFileOccLine (_, l, _) = l

sameFileOccKey : (String, Int, String) -> String
sameFileOccKey (_, _, k) = k

-- emit findings for one same-file structural-key group (≥2 occurrences,
-- guaranteed by the `live` pre-filter above; the ≥2 check is re-asserted here
-- too, for the same "must not depend on the caller having filtered" reason
-- `emitDupGroup` states above).
emitSameFileGroup : List (String, Int, String) -> List Finding
emitSameFileGroup grp =
  if listLen grp < 2 then
    []
  else
    map (sameFileFinding grp) (sortSameFileOccs grp)

sameFileFinding : List (String, Int, String) -> (String, Int, String) -> Finding
sameFileFinding grp occ =
  let others = filterList (o => sameFileOccName o /= sameFileOccName occ) grp
  Finding {
    rule = ruleNameDuplicateBody,
    message =
      "function '\{sameFileOccName occ}' has a body structurally identical to '\{joinWith "', '" (map sameFileOccName others)}' in this same file — consolidate into one function",
    severity = SevWarning,
    loc = Some (Loc "" (sameFileOccLine occ) 1 (sameFileOccLine occ) 1),
    fix = None,
  }

sortSameFileOccs : List (String, Int, String) -> List (String, Int, String)
sortSameFileOccs [] = []
sortSameFileOccs (x :: xs) = sameFileInsert x (sortSameFileOccs xs)

sameFileInsert : (String, Int, String) ->
  List (String, Int, String) ->
  List (String, Int, String)
sameFileInsert x [] = [x]
sameFileInsert x (y :: ys)
  | sameFileOccLine x <= sameFileOccLine y = x :: y :: ys
  | otherwise = y :: sameFileInsert x ys
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "DupClause" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factDupClauses" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false) (mem "sortUniqS" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to another top-level function in the SAME file (copy-paste; consolidate) — the in-file counterpart of the cross-file rule of the same name"))) (fa "doc" (ELit (LString "Two top-level functions in the same file with structurally identical bodies (location-stripped, above a complexity floor) are copy-paste. Consolidate them. The cross-file arm of the same rule compares across files.\n\nBefore:\n  f x = big x\n  g y = big y   -- same body shape\nAfter:\n  one function, called twice"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBodySameFile")) (EVar "None")))
(DTypeSig false "dupSameFileComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupSameFileComplexityThreshold" () (ELit (LInt 20)))
(DTypeSig false "sameFileOccOfClause" (TyFun (TyCon "DupClause") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))))
(DFunDef false "sameFileOccOfClause" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupSameFileComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EListLit (ETuple (EFieldAccess (EVar "c") "dcName") (EFieldAccess (EVar "c") "dcLine") (EFieldAccess (EVar "c") "dcKey"))) (EListLit)))
(DTypeSig false "ruleDuplicateBodySameFile" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDuplicateBodySameFile" (PWild PWild (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "occs") (EApp (EApp (EVar "flatMap") (EVar "sameFileOccOfClause")) (EApp (EVar "factDupClauses") (EVar "facts")))) (DoLet false false (PVar "groups") (EApp (EVar "sameFileGroupByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))) (ELit (LInt 2))))) (EApp (EVar "sameFileDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitSameFileGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live"))))))
(DTypeSig false "sameFileGroupByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "sameFileGroupByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "sameFileGroupGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "sameFileGroupGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "sameFileGroupGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "sameFileGroupGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "sameFileOccKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "sameFileOccKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "sameFileGroupGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "sameFileDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sameFileDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "sameFileDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sameFileDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "sameFileDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "sameFileOccKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "sameFileOccKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "sameFileOccKey") (EVar "o")) (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sameFileOccName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "sameFileOccName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "sameFileOccLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "Int")))
(DFunDef false "sameFileOccLine" ((PTuple PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "sameFileOccKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "sameFileOccKey" ((PTuple PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitSameFileGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitSameFileGroup" ((PVar "grp")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EVar "map") (EApp (EVar "sameFileFinding") (EVar "grp"))) (EApp (EVar "sortSameFileOccs") (EVar "grp")))))
(DTypeSig false "sameFileFinding" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "sameFileFinding" ((PVar "grp") (PVar "occ")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "/=" (EApp (EVar "sameFileOccName") (EVar "o")) (EApp (EVar "sameFileOccName") (EVar "occ"))))) (EVar "grp"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EApp (EVar "sameFileOccName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to '"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "', '"))) (EApp (EApp (EVar "map") (EVar "sameFileOccName")) (EVar "others"))))) (ELit (LString "' in this same file — consolidate into one function")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EApp (EVar "sameFileOccLine") (EVar "occ"))) (ELit (LInt 1))) (EApp (EVar "sameFileOccLine") (EVar "occ"))) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))))
(DTypeSig false "sortSameFileOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))))
(DFunDef false "sortSameFileOccs" ((PList)) (EListLit))
(DFunDef false "sortSameFileOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "sameFileInsert") (EVar "x")) (EApp (EVar "sortSameFileOccs") (EVar "xs"))))
(DTypeSig false "sameFileInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "sameFileInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sameFileInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "sameFileOccLine") (EVar "x")) (EApp (EVar "sameFileOccLine") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sameFileInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "DupClause" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factDupClauses" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false) (mem "sortUniqS" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to another top-level function in the SAME file (copy-paste; consolidate) — the in-file counterpart of the cross-file rule of the same name"))) (fa "doc" (ELit (LString "Two top-level functions in the same file with structurally identical bodies (location-stripped, above a complexity floor) are copy-paste. Consolidate them. The cross-file arm of the same rule compares across files.\n\nBefore:\n  f x = big x\n  g y = big y   -- same body shape\nAfter:\n  one function, called twice"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBodySameFile")) (EVar "None")))
(DTypeSig false "dupSameFileComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupSameFileComplexityThreshold" () (ELit (LInt 20)))
(DTypeSig false "sameFileOccOfClause" (TyFun (TyCon "DupClause") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))))
(DFunDef false "sameFileOccOfClause" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupSameFileComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EListLit (ETuple (EFieldAccess (EVar "c") "dcName") (EFieldAccess (EVar "c") "dcLine") (EFieldAccess (EVar "c") "dcKey"))) (EListLit)))
(DTypeSig false "ruleDuplicateBodySameFile" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDuplicateBodySameFile" (PWild PWild (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "occs") (EApp (EApp (EDictApp "flatMap") (EVar "sameFileOccOfClause")) (EApp (EVar "factDupClauses") (EVar "facts")))) (DoLet false false (PVar "groups") (EApp (EVar "sameFileGroupByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))) (ELit (LInt 2))))) (EApp (EVar "sameFileDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitSameFileGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live"))))))
(DTypeSig false "sameFileGroupByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "sameFileGroupByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "sameFileGroupGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "sameFileGroupGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "sameFileGroupGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "sameFileGroupGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "sameFileOccKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "sameFileOccKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "sameFileGroupGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "sameFileDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sameFileDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "sameFileDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sameFileDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "sameFileDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "sameFileOccKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "sameFileOccKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "sameFileOccKey") (EVar "o")) (EApp (EApp (EVar "sameFileDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sameFileOccName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "sameFileOccName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "sameFileOccLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "Int")))
(DFunDef false "sameFileOccLine" ((PTuple PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "sameFileOccKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "String")))
(DFunDef false "sameFileOccKey" ((PTuple PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitSameFileGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitSameFileGroup" ((PVar "grp")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EMethodRef "map") (EApp (EVar "sameFileFinding") (EVar "grp"))) (EApp (EVar "sortSameFileOccs") (EVar "grp")))))
(DTypeSig false "sameFileFinding" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "sameFileFinding" ((PVar "grp") (PVar "occ")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "/=" (EApp (EVar "sameFileOccName") (EVar "o")) (EApp (EVar "sameFileOccName") (EVar "occ"))))) (EVar "grp"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EApp (EVar "sameFileOccName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to '"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "', '"))) (EApp (EApp (EMethodRef "map") (EVar "sameFileOccName")) (EVar "others"))))) (ELit (LString "' in this same file — consolidate into one function")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EApp (EVar "sameFileOccLine") (EVar "occ"))) (ELit (LInt 1))) (EApp (EVar "sameFileOccLine") (EVar "occ"))) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))))
(DTypeSig false "sortSameFileOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")))))
(DFunDef false "sortSameFileOccs" ((PList)) (EListLit))
(DFunDef false "sortSameFileOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "sameFileInsert") (EVar "x")) (EApp (EVar "sortSameFileOccs") (EVar "xs"))))
(DTypeSig false "sameFileInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "sameFileInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sameFileInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "sameFileOccLine") (EVar "x")) (EApp (EVar "sameFileOccLine") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sameFileInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
