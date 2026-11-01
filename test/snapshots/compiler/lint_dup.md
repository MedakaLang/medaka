# META
source_lines=393
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_dup.mdk — the duplicate-body occurrence engine: per-clause
-- facts, occurrence grouping and the cross-file join.  The runner (`lint_walk`),
-- the `lint` facade and the cross-file rule all use it, so it sits below them.

import frontend.ast.{Loc(..), Pat(..), FieldAssign(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, allList, filterList, reverseL, joinWith}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}
import ir.sexp.{exprSexp, patSexp}
import tools.lint_core.{DupClause(..), Finding(..)}
import tools.lint_shared.{
  isCtorName, ruleNameDuplicateBody, sortUniqS, unwrapLoc
}

-- minimum body complexity (count of AST nodes) to be eligible.  Calibrated so the
-- real stdlib/compiler libraries stay quiet absent genuine duplication.
dupComplexityThreshold : Int
dupComplexityThreshold = 10

-- structural identity key: param-pattern shapes ++ ELoc-stripped body sexp.
structuralKey : List Pat -> Expr -> String
structuralKey pats body =
  "\{joinWith "|" (map patSexp pats)} => \{exprSexp body}"

-- complexity proxy: every `node`/`slist` in the sexp dump emits a '(', so counting
-- '(' counts AST nodes without a second traversal.
bodyComplexity : Expr -> Int
bodyComplexity body =
  let cs = stringToChars (exprSexp body)
  countOpenParens cs (arrayLength cs) 0 0

countOpenParens : Array Char -> Int -> Int -> Int -> Int
countOpenParens cs n i acc
  | i >= n = acc
  | arrayGetUnsafe i cs == '(' = countOpenParens cs n (i + 1) (acc + 1)
  | otherwise = countOpenParens cs n (i + 1) acc

-- ── over-fire narrowing (#893): "pure data" bodies never fire ──────────────────
-- A body built ENTIRELY out of literals, variable references, tuples/lists/
-- records/maps/sets of those, and data-CONSTRUCTOR application (an `EApp` whose
-- ultimate head is an upper-case `EVar` — Medaka's ctor-naming convention) is
-- DATA, not logic: it calls no function, branches on nothing.  Two files that
-- coincidentally wire up parallel fixture literals with the same shape (e.g. a
-- `specs : List (String, String, Option Int, List (List Cell))` table built from
-- differently-named-but-identically-shaped rows) are not a copy-paste hazard —
-- there is no *behavior* to diverge, only data, and the fields plainly differ
-- file-to-file even when the structural skeleton matches.  A body containing
-- ANY call to a lower-case function (a real combinator, a `println`, string
-- interpolation invoking a formatter, …) or any control flow (`if`/`match`/
-- `do`) is NOT pure data and remains fully eligible — that is where actual
-- logic can silently diverge, which is the defect this rule exists to catch.
isPureDataExpr : Expr -> Bool
isPureDataExpr e =
  let e2 = unwrapLoc e
  match e2
    ELit _ => True
    ENumLit _ _ _ => True
    EWideLit _ _ _ _ => True
    EVar _ => True
    ETuple es => allList isPureDataExpr es
    EListLit es => allList isPureDataExpr es
    EArrayLit es => allList isPureDataExpr es
    ERecordCreate _ fields => allList isPureDataField fields
    EMapLit _ kvs => allList isPureDataKv kvs
    ESetLit _ es => allList isPureDataExpr es
    EAnnot inner _ => isPureDataExpr inner
    EUnOp _ inner _ => isPureDataExpr inner
    EApp _ _ if appHeadIsCtor e2 => allList isPureDataExpr (appArgs e2)
    _ => False

isPureDataField : FieldAssign -> Bool
isPureDataField (FieldAssign _ e) = isPureDataExpr e

isPureDataKv : (Expr, Expr) -> Bool
isPureDataKv (k, v) = isPureDataExpr k && isPureDataExpr v

-- the ultimate callee of an `EApp` spine is an upper-case `EVar` (a data ctor,
-- by Medaka's naming convention — see `isCtorName`), not an ordinary function.
appHeadIsCtor : Expr -> Bool
appHeadIsCtor e = match unwrapLoc e
  EVar name => isCtorName name
  EApp f _ => appHeadIsCtor f
  _ => False

-- an `EApp` spine's arguments, left-to-right (innermost-first application
-- unwound into a flat list).
appArgs : Expr -> List Expr
appArgs e = reverseL (appArgsRev e)

appArgsRev : Expr -> List Expr
appArgsRev e = match unwrapLoc e
  EApp f a => a :: appArgsRev f
  _ => []

-- THE join: occurrences (from every file) → findings.  Split out of
-- `ruleDuplicateBody` for #395's `--cache`, which reaches the same join from
-- occurrences it deserialized rather than from freshly-parsed decls.  Both
-- callers run THIS function, so a cached run's cross-file findings are computed
-- by the identical code an uncached one runs.
--
-- This split is the whole correctness story of the lint cache.  A cache MUST
-- store the per-file INPUTS to this join (the rule's `DupOccs` summary) and re-run it every
-- time — never the findings it returns.  A finding here names file A *because
-- of* file B, so a cached A-finding survives an edit to B that should have
-- retracted it: the finding silently lingers (or, symmetrically, never
-- appears).  Re-running the join is cheap — it measures LINEAR at occs≈10k, as
-- `emitDupGroup`'s scan short-circuits at char 0 on distinct keys — so there is
-- no efficiency argument for caching its output either.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh exists to fail loudly if someone ever tries.
--
-- PERFORMANCE, and a debunking that was itself half-wrong.  This join used to
-- read:
--
--     let keys = sortUniqS (map occKey occs)
--     flatMap (emitDupGroup occs) keys        -- emitDupGroup filters ALL occs
--
-- i.e. for each of ~10k distinct keys, a `filterList` over all ~10k occurrences:
-- 100M string comparisons, QUADRATIC in occurrence count.  #395's spike graded
-- that shape "measured LINEAR at occs=8000" — but what it actually established
-- is that each comparison is O(1) rather than O(key length), because distinct
-- sexp keys mismatch at char 0.  The comparisons are cheap; there are n² of
-- them.  MEASURED here at N vs 2N with a warm cache (which removes the parse and
-- leaves the join exposed): 0.115 s → 0.416 s, a 3.6x growth for 2x the input —
-- quadratic, not the 2.0x of linear.  It cost 0.6 s of a 0.97 s warm run.
--
-- It hid for the same two reasons this repo keeps rediscovering: it was dwarfed
-- by the parse it sat behind (so it never showed up cold), and a pure `List`
-- scan ALLOCATES NOTHING, so `diff_compiler_perf_scaling` — which grades
-- allocation growth, deliberately, because GC bytes are machine-independent —
-- is blind to it (issue #110's class).
--
-- Now: bucket the occurrences by key ONCE (linear), then emit only from the
-- groups that can actually fire.  A group needs ≥2 occurrences across ≥2 files,
-- which in a clean tree is a handful out of ~10k — so the `sortUniqS` that
-- orders the output for determinism now sorts that handful rather than every
-- key.  Same findings, same order.
export
dupJoin : List (String, Int, String, String) -> List Finding
dupJoin occs =
  let groups = groupOccsByKey occs
  let live =
    filterList
      (k => dupGroupFires (findWithDefault [] k groups))
      (dupDistinctKeys occs)
  dedupeFindings
    (flatMap
      (k => emitDupGroup (reverseL (findWithDefault [] k groups)))
      (sortUniqS live))

-- Both occurrence grains can key the SAME duplicate pair: a multi-clause
-- function whose every clause matches another's fires once per matching clause
-- and once in aggregate, and the aggregate anchors at the first individually
-- eligible clause — the very line the clause grain reports.  The two findings
-- are then word-for-word identical, and a reader gains nothing from reading the
-- sentence twice.
--
-- Repeats are dropped HERE rather than prevented at the occurrence level because
-- only the rendered finding can tell whether two grains say the same thing: the
-- grains carry different keys, so they group over different partner-file sets,
-- and a clause grain that spans strictly more files than the aggregate says
-- something the aggregate does not.  First finding wins, so the `sortUniqS`-
-- ordered output above keeps its order.
dedupeFindings : List Finding -> List Finding
dedupeFindings fs =
  let seen = new ()
  dedupeFindingsGo seen fs

dedupeFindingsGo : HashMap String Unit -> List Finding -> List Finding
dedupeFindingsGo _ [] = []
dedupeFindingsGo seen (f :: rest)
  | has (findingDedupeKey f) seen = dedupeFindingsGo seen rest
  | otherwise =
    setInPlace (findingDedupeKey f) () seen
    f :: dedupeFindingsGo seen rest

findingDedupeKey : Finding -> String
findingDedupeKey f = "\{f.rule}\n\{dupLocKey f.loc}\n\{f.message}"

dupLocKey : Option Loc -> String
dupLocKey (Some (Loc file line col _ _)) = "\{file}:\{line}:\{col}"
dupLocKey None = "-"

-- key → its occurrences, in one linear pass.  Each bucket accumulates REVERSED
-- (prepend is O(1)); `dupJoin` reverses on the way out so the occurrence order
-- reaching `emitDupGroup` matches the old filter-in-input-order behaviour.
-- (`sortDupOccs` sorts them anyway — this only keeps the pre-sort list identical
-- so the two implementations are diffable.)
groupOccsByKey : List (String, Int, String, String) ->
  HashMap String (List (String, Int, String, String))
groupOccsByKey occs =
  let m = new ()
  groupOccsGo m occs
  m

groupOccsGo : HashMap String (List (String, Int, String, String)) ->
  List (String, Int, String, String) ->
  Unit
groupOccsGo _ [] = ()
groupOccsGo m (o :: rest) =
  setInPlace (occKey o) (o :: findWithDefault [] (occKey o) m) m
  groupOccsGo m rest

-- Distinct keys in first-appearance order.  `keys` on the HashMap would do this
-- too, but its order is bucket order — a function of the hash, so it would make
-- the output depend on table internals.  This is deterministic by construction,
-- and `dupJoin` sorts the survivors regardless.  (A `HashMap String Unit` as the
-- seen-set, rather than a HashSet, only because hash_set's `new`/`has` would
-- collide with hash_map's under this module's flat import list.)
dupDistinctKeys : List (String, Int, String, String) -> List String
dupDistinctKeys occs =
  let seen = new ()
  dupDistinctGo seen occs

dupDistinctGo : HashMap String Unit ->
  List (String, Int, String, String) ->
  List String
dupDistinctGo _ [] = []
dupDistinctGo seen (o :: rest)
  | has (occKey o) seen = dupDistinctGo seen rest
  | otherwise =
    setInPlace (occKey o) () seen
    occKey o :: dupDistinctGo seen rest

-- Can this key's group emit at all?  ≥2 occurrences spanning ≥2 distinct files.
-- Cheap pre-filter so the sort and `emitDupGroup` only ever see live groups.
dupGroupFires : List (String, Int, String, String) -> Bool
dupGroupFires grp =
  listLen grp >= 2 && listLen (sortUniqS (map occFile grp)) >= 2

-- one occurrence per eligible top-level CLAUSE, plus one per eligible
-- multi-clause FUNCTION: (file, line, name, key)
export
dupOccsOfClauses : String ->
  List DupClause ->
  List (String, Int, String, String)
dupOccsOfClauses path clauses =
  flatMap (dupOccsOfGroup path) (dupClauseGroups clauses)

export
dupClauseOfDecl : (Decl, Option Loc) -> List DupClause
dupClauseOfDecl (d, loc) = match d
  DFunDef _ name pats body _ _ => [
    DupClause {
      dcName = name,
      dcLine = locLineOf loc,
      dcKey = structuralKey pats body,
      dcCost = bodyComplexity body,
      dcPure = isPureDataExpr body,
    },
  ]
  DAttrib _ inner => dupClauseOfDecl (inner, loc)
  _ => []

-- Clauses of one function are adjacent in the decl list, so consecutive runs of
-- a name group them.  Grouping by name across the whole file instead would fuse
-- two unrelated definitions if a file ever held one name twice.
dupClauseGroups : List DupClause -> List (List DupClause)
dupClauseGroups [] = []
dupClauseGroups (c :: rest) =
  let (same, others) = dupSpanName c.dcName rest
  (c :: same) :: dupClauseGroups others

dupSpanName : String -> List DupClause -> (List DupClause, List DupClause)
dupSpanName _ [] = ([], [])
dupSpanName nm (c :: rest)
  | c.dcName == nm =
    let (same, others) = dupSpanName nm rest
    (c :: same, others)
  | otherwise = ([], c :: rest)

dupOccsOfGroup : String -> List DupClause -> List (String, Int, String, String)
dupOccsOfGroup path cs = dupClauseOccs path cs ++ dupAggregateOcc path cs

-- Clause grain: each clause that clears the floor on its own, keyed and reported
-- at its own line.  This is the original (pre-#2651) occurrence set.
dupClauseOccs : String -> List DupClause -> List (String, Int, String, String)
dupClauseOccs _ [] = []
dupClauseOccs path (c :: cs)
  | c.dcCost >= dupComplexityThreshold && not c.dcPure =
    (path, c.dcLine, c.dcName, c.dcKey) :: dupClauseOccs path cs
  | otherwise = dupClauseOccs path cs

-- Function grain.  The group is eligible when the COMBINED body clears the floor
-- and at least one clause is real logic: a function all of whose clauses are
-- pure data is data, which is #893's narrowing applied at function grain instead
-- of clause grain.  A one-clause group has nothing to aggregate — its function
-- grain is byte-for-byte its clause grain — so it yields nothing here.
dupAggregateOcc : String -> List DupClause -> List (String, Int, String, String)
dupAggregateOcc _ [] = []
dupAggregateOcc _ [_] = []
dupAggregateOcc path (c :: cs)
  | dupGroupCost (c :: cs) >= dupComplexityThreshold
    && not (allList dcPureOf (c :: cs)) = [
    (
      path,
      dupAnchorLine (c :: cs) c.dcLine,
      c.dcName,
      joinWith "\n" (map dcKeyOf (c :: cs)),
    ),
  ]
  | otherwise = []

-- WHERE the finding points, and this is load-bearing rather than cosmetic.
-- A suppression directive is matched against the reported line, so moving an
-- anchor silently un-suppresses a duplicate someone has already adjudicated —
-- and this tree carries over a hundred such directives.  So the anchor is the
-- first clause that clears the floor on its own, which is exactly the clause the
-- per-clause rule reports and therefore exactly the clause every existing
-- directive was placed above.  Aggregation then only ADDS findings; it moves
-- none.  A function that fires only in aggregate has no such clause and no
-- directive to preserve, so it anchors at its first clause, where a reader looks
-- to find the function.
dupAnchorLine : List DupClause -> Int -> Int
dupAnchorLine [] fallback = fallback
dupAnchorLine (c :: cs) fallback
  | c.dcCost >= dupComplexityThreshold && not c.dcPure = c.dcLine
  | otherwise = dupAnchorLine cs fallback

dcKeyOf : DupClause -> String
dcKeyOf c = c.dcKey

dcPureOf : DupClause -> Bool
dcPureOf c = c.dcPure

dupGroupCost : List DupClause -> Int
dupGroupCost [] = 0
dupGroupCost (c :: cs) = c.dcCost + dupGroupCost cs

locLineOf : Option Loc -> Int
locLineOf (Some (Loc _ l _ _ _)) = l
locLineOf None = 1

occFile : (String, Int, String, String) -> String
occFile (f, _, _, _) = f

occLine : (String, Int, String, String) -> Int
occLine (_, l, _, _) = l

occName : (String, Int, String, String) -> String
occName (_, _, n, _) = n

occKey : (String, Int, String, String) -> String
occKey (_, _, _, k) = k

-- emit findings for one structural-key group, but only when it spans ≥2 files.
-- Takes the group itself; `dupJoin` bucketed the occurrences by key and already
-- dropped the groups that cannot fire (see `dupGroupFires`).  The ≥2-file check
-- stays here regardless — this function's contract is "≥2 files or nothing", and
-- it must not depend on its caller having filtered.
emitDupGroup : List (String, Int, String, String) -> List Finding
emitDupGroup grp =
  let distinctFiles = sortUniqS (map occFile grp)
  if listLen distinctFiles < 2 then
    []
  else
    map (dupFinding distinctFiles) (sortDupOccs grp)

dupFinding : List String -> (String, Int, String, String) -> Finding
dupFinding distinctFiles occ =
  let file = occFile occ
  let line = occLine occ
  let others = filterList (/= file) distinctFiles
  Finding {
    rule = ruleNameDuplicateBody,
    message =
      "function '\{occName occ}' has a body structurally identical to a definition in \{joinWith ", " others} — consolidate into a shared module",
    severity = SevWarning,
    loc = Some (Loc file line 1 line 1),
    fix = None,
  }

-- insertion sort occurrences by (file, line) for deterministic output.
sortDupOccs : List (String, Int, String, String) ->
  List (String, Int, String, String)
sortDupOccs [] = []
sortDupOccs (x :: xs) = dupInsert x (sortDupOccs xs)

dupInsert : (String, Int, String, String) ->
  List (String, Int, String, String) ->
  List (String, Int, String, String)
dupInsert x [] = [x]
dupInsert x (y :: ys)
  | dupOccLe x y = x :: y :: ys
  | otherwise = y :: dupInsert x ys

dupOccLe : (String, Int, String, String) ->
  (String, Int, String, String) ->
  Bool
dupOccLe a b = match stringCompare (occFile a) (occFile b)
  Lt => True
  Gt => False
  Eq => occLine a <= occLine b
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "FieldAssign" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "allList" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DupClause" true) (mem "Finding" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "isCtorName" false) (mem "ruleNameDuplicateBody" false) (mem "sortUniqS" false) (mem "unwrapLoc" false))))
(DTypeSig false "dupComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupComplexityThreshold" () (ELit (LInt 10)))
(DTypeSig false "structuralKey" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "String"))))
(DFunDef false "structuralKey" ((PVar "pats") (PVar "body")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "exprSexp") (EVar "body")))) (ELit (LString ""))))
(DTypeSig false "bodyComplexity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "bodyComplexity" ((PVar "body")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EApp (EVar "exprSexp") (EVar "body")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "countOpenParens" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countOpenParens" ((PVar "cs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "("))) (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isPureDataExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureDataExpr" ((PVar "e")) (EBlock (DoLet false false (PVar "e2") (EApp (EVar "unwrapLoc") (EVar "e"))) (DoExpr (EMatch (EVar "e2") (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "ETuple" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EListLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EArrayLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "ERecordCreate" PWild (PVar "fields")) () (EApp (EApp (EVar "allList") (EVar "isPureDataField")) (EVar "fields"))) (arm (PCon "EMapLit" PWild (PVar "kvs")) () (EApp (EApp (EVar "allList") (EVar "isPureDataKv")) (EVar "kvs"))) (arm (PCon "ESetLit" PWild (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EAnnot" (PVar "inner") PWild) () (EApp (EVar "isPureDataExpr") (EVar "inner"))) (arm (PCon "EUnOp" PWild (PVar "inner") PWild) () (EApp (EVar "isPureDataExpr") (EVar "inner"))) (arm (PCon "EApp" PWild PWild) ((GBool (EApp (EVar "appHeadIsCtor") (EVar "e2")))) (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EApp (EVar "appArgs") (EVar "e2")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "isPureDataField" (TyFun (TyCon "FieldAssign") (TyCon "Bool")))
(DFunDef false "isPureDataField" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "isPureDataExpr") (EVar "e")))
(DTypeSig false "isPureDataKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "isPureDataKv" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "&&" (EApp (EVar "isPureDataExpr") (EVar "k")) (EApp (EVar "isPureDataExpr") (EVar "v"))))
(DTypeSig false "appHeadIsCtor" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHeadIsCtor" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "name")) () (EApp (EVar "isCtorName") (EVar "name"))) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHeadIsCtor") (EVar "f"))) (arm PWild () (EVar "False"))))
(DTypeSig false "appArgs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appArgs" ((PVar "e")) (EApp (EVar "reverseL") (EApp (EVar "appArgsRev") (EVar "e"))))
(DTypeSig false "appArgsRev" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appArgsRev" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EBinOp "::" (EVar "a") (EApp (EVar "appArgsRev") (EVar "f")))) (arm PWild () (EListLit))))
(DTypeSig true "dupJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dupJoin" ((PVar "occs")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "groupOccsByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "dupGroupFires") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))))) (EApp (EVar "dupDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EVar "dedupeFindings") (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitDupGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live")))))))
(DTypeSig false "dedupeFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dedupeFindings" ((PVar "fs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "fs")))))
(DTypeSig false "dedupeFindingsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "dedupeFindingsGo" (PWild (PList)) (EListLit))
(DFunDef false "dedupeFindingsGo" ((PVar "seen") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "findingDedupeKey") (EVar "f"))) (EVar "seen")) (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "findingDedupeKey") (EVar "f"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EVar "f") (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findingDedupeKey" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingDedupeKey" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "dupLocKey") (EFieldAccess (EVar "f") "loc")))) (ELit (LString "\n"))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DTypeSig false "dupLocKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "dupLocKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "line"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "col"))) (ELit (LString ""))))
(DFunDef false "dupLocKey" ((PCon "None")) (ELit (LString "-")))
(DTypeSig false "groupOccsByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "groupOccsByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupOccsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "groupOccsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "groupOccsGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "occKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "occKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "dupDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dupDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "dupDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "dupDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "occKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "occKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "occKey") (EVar "o")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupGroupFires" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "dupGroupFires" ((PVar "grp")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "occFile")) (EVar "grp")))) (ELit (LInt 2)))))
(DTypeSig true "dupOccsOfClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccsOfClauses" ((PVar "path") (PVar "clauses")) (EApp (EApp (EVar "flatMap") (EApp (EVar "dupOccsOfGroup") (EVar "path"))) (EApp (EVar "dupClauseGroups") (EVar "clauses"))))
(DTypeSig true "dupClauseOfDecl" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "dupClauseOfDecl" ((PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EListLit (ERecordCreate "DupClause" ((fa "dcName" (EVar "name")) (fa "dcLine" (EApp (EVar "locLineOf") (EVar "loc"))) (fa "dcKey" (EApp (EApp (EVar "structuralKey") (EVar "pats")) (EVar "body"))) (fa "dcCost" (EApp (EVar "bodyComplexity") (EVar "body"))) (fa "dcPure" (EApp (EVar "isPureDataExpr") (EVar "body"))))))) (arm (PCon "DAttrib" PWild (PVar "inner")) () (EApp (EVar "dupClauseOfDecl") (ETuple (EVar "inner") (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "dupClauseGroups" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "DupClause")))))
(DFunDef false "dupClauseGroups" ((PList)) (EListLit))
(DFunDef false "dupClauseGroups" ((PCons (PVar "c") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "same") (PVar "others")) (EApp (EApp (EVar "dupSpanName") (EFieldAccess (EVar "c") "dcName")) (EVar "rest"))) (DoExpr (EBinOp "::" (EBinOp "::" (EVar "c") (EVar "same")) (EApp (EVar "dupClauseGroups") (EVar "others"))))))
(DTypeSig false "dupSpanName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyTuple (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyCon "DupClause"))))))
(DFunDef false "dupSpanName" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "dupSpanName" ((PVar "nm") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "dcName") (EVar "nm")) (EBlock (DoLet false false (PTuple (PVar "same") (PVar "others")) (EApp (EApp (EVar "dupSpanName") (EVar "nm")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "same")) (EVar "others")))) (EIf (EVar "otherwise") (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccsOfGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccsOfGroup" ((PVar "path") (PVar "cs")) (EBinOp "++" (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs")) (EApp (EApp (EVar "dupAggregateOcc") (EVar "path")) (EVar "cs"))))
(DTypeSig false "dupClauseOccs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupClauseOccs" (PWild (PList)) (EListLit))
(DFunDef false "dupClauseOccs" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EBinOp "::" (ETuple (EVar "path") (EFieldAccess (EVar "c") "dcLine") (EFieldAccess (EVar "c") "dcName") (EFieldAccess (EVar "c") "dcKey")) (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupAggregateOcc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupAggregateOcc" (PWild (PList)) (EListLit))
(DFunDef false "dupAggregateOcc" (PWild (PList PWild)) (EListLit))
(DFunDef false "dupAggregateOcc" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dupGroupCost") (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EVar "dcPureOf")) (EBinOp "::" (EVar "c") (EVar "cs"))))) (EListLit (ETuple (EVar "path") (EApp (EApp (EVar "dupAnchorLine") (EBinOp "::" (EVar "c") (EVar "cs"))) (EFieldAccess (EVar "c") "dcLine")) (EFieldAccess (EVar "c") "dcName") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EVar "dcKeyOf")) (EBinOp "::" (EVar "c") (EVar "cs")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupAnchorLine" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "dupAnchorLine" ((PList) (PVar "fallback")) (EVar "fallback"))
(DFunDef false "dupAnchorLine" ((PCons (PVar "c") (PVar "cs")) (PVar "fallback")) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EFieldAccess (EVar "c") "dcLine") (EIf (EVar "otherwise") (EApp (EApp (EVar "dupAnchorLine") (EVar "cs")) (EVar "fallback")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dcKeyOf" (TyFun (TyCon "DupClause") (TyCon "String")))
(DFunDef false "dcKeyOf" ((PVar "c")) (EFieldAccess (EVar "c") "dcKey"))
(DTypeSig false "dcPureOf" (TyFun (TyCon "DupClause") (TyCon "Bool")))
(DFunDef false "dcPureOf" ((PVar "c")) (EFieldAccess (EVar "c") "dcPure"))
(DTypeSig false "dupGroupCost" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyCon "Int")))
(DFunDef false "dupGroupCost" ((PList)) (ELit (LInt 0)))
(DFunDef false "dupGroupCost" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "+" (EFieldAccess (EVar "c") "dcCost") (EApp (EVar "dupGroupCost") (EVar "cs"))))
(DTypeSig false "locLineOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))
(DFunDef false "locLineOf" ((PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) (EVar "l"))
(DFunDef false "locLineOf" ((PCon "None")) (ELit (LInt 1)))
(DTypeSig false "occFile" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occFile" ((PTuple (PVar "f") PWild PWild PWild)) (EVar "f"))
(DTypeSig false "occLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Int")))
(DFunDef false "occLine" ((PTuple PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig false "occName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occName" ((PTuple PWild PWild (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "occKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occKey" ((PTuple PWild PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitDupGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitDupGroup" ((PVar "grp")) (EBlock (DoLet false false (PVar "distinctFiles") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "occFile")) (EVar "grp")))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "distinctFiles")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EVar "map") (EApp (EVar "dupFinding") (EVar "distinctFiles"))) (EApp (EVar "sortDupOccs") (EVar "grp")))))))
(DTypeSig false "dupFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "dupFinding" ((PVar "distinctFiles") (PVar "occ")) (EBlock (DoLet false false (PVar "file") (EApp (EVar "occFile") (EVar "occ"))) (DoLet false false (PVar "line") (EApp (EVar "occLine") (EVar "occ"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "file")))) (EVar "distinctFiles"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EApp (EVar "occName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to a definition in "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (ELit (LString " — consolidate into a shared module")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))))
(DTypeSig false "sortDupOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "sortDupOccs" ((PList)) (EListLit))
(DFunDef false "sortDupOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "dupInsert") (EVar "x")) (EApp (EVar "sortDupOccs") (EVar "xs"))))
(DTypeSig false "dupInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "dupInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "dupOccLe") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "dupInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccLe" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "dupOccLe" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "occFile") (EVar "a"))) (EApp (EVar "occFile") (EVar "b"))) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "<=" (EApp (EVar "occLine") (EVar "a")) (EApp (EVar "occLine") (EVar "b"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "FieldAssign" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "allList" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DupClause" true) (mem "Finding" true))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "isCtorName" false) (mem "ruleNameDuplicateBody" false) (mem "sortUniqS" false) (mem "unwrapLoc" false))))
(DTypeSig false "dupComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupComplexityThreshold" () (ELit (LInt 10)))
(DTypeSig false "structuralKey" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "String"))))
(DFunDef false "structuralKey" ((PVar "pats") (PVar "body")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "exprSexp") (EVar "body")))) (ELit (LString ""))))
(DTypeSig false "bodyComplexity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "bodyComplexity" ((PVar "body")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EApp (EVar "exprSexp") (EVar "body")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "countOpenParens" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countOpenParens" ((PVar "cs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "("))) (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isPureDataExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureDataExpr" ((PVar "e")) (EBlock (DoLet false false (PVar "e2") (EApp (EVar "unwrapLoc") (EVar "e"))) (DoExpr (EMatch (EVar "e2") (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "ETuple" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EListLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EArrayLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "ERecordCreate" PWild (PVar "fields")) () (EApp (EApp (EVar "allList") (EVar "isPureDataField")) (EVar "fields"))) (arm (PCon "EMapLit" PWild (PVar "kvs")) () (EApp (EApp (EVar "allList") (EVar "isPureDataKv")) (EVar "kvs"))) (arm (PCon "ESetLit" PWild (PVar "es")) () (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EVar "es"))) (arm (PCon "EAnnot" (PVar "inner") PWild) () (EApp (EVar "isPureDataExpr") (EVar "inner"))) (arm (PCon "EUnOp" PWild (PVar "inner") PWild) () (EApp (EVar "isPureDataExpr") (EVar "inner"))) (arm (PCon "EApp" PWild PWild) ((GBool (EApp (EVar "appHeadIsCtor") (EVar "e2")))) (EApp (EApp (EVar "allList") (EVar "isPureDataExpr")) (EApp (EVar "appArgs") (EVar "e2")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "isPureDataField" (TyFun (TyCon "FieldAssign") (TyCon "Bool")))
(DFunDef false "isPureDataField" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "isPureDataExpr") (EVar "e")))
(DTypeSig false "isPureDataKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "isPureDataKv" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "&&" (EApp (EVar "isPureDataExpr") (EVar "k")) (EApp (EVar "isPureDataExpr") (EVar "v"))))
(DTypeSig false "appHeadIsCtor" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHeadIsCtor" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "name")) () (EApp (EVar "isCtorName") (EVar "name"))) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHeadIsCtor") (EVar "f"))) (arm PWild () (EVar "False"))))
(DTypeSig false "appArgs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appArgs" ((PVar "e")) (EApp (EVar "reverseL") (EApp (EVar "appArgsRev") (EVar "e"))))
(DTypeSig false "appArgsRev" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appArgsRev" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EBinOp "::" (EVar "a") (EApp (EVar "appArgsRev") (EVar "f")))) (arm PWild () (EListLit))))
(DTypeSig true "dupJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dupJoin" ((PVar "occs")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "groupOccsByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "dupGroupFires") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))))) (EApp (EVar "dupDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EVar "dedupeFindings") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitDupGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live")))))))
(DTypeSig false "dedupeFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dedupeFindings" ((PVar "fs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "fs")))))
(DTypeSig false "dedupeFindingsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "dedupeFindingsGo" (PWild (PList)) (EListLit))
(DFunDef false "dedupeFindingsGo" ((PVar "seen") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "findingDedupeKey") (EVar "f"))) (EVar "seen")) (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "findingDedupeKey") (EVar "f"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EVar "f") (EApp (EApp (EVar "dedupeFindingsGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findingDedupeKey" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingDedupeKey" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "dupLocKey") (EFieldAccess (EVar "f") "loc")))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DTypeSig false "dupLocKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "dupLocKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "line"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "col"))) (ELit (LString ""))))
(DFunDef false "dupLocKey" ((PCon "None")) (ELit (LString "-")))
(DTypeSig false "groupOccsByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "groupOccsByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupOccsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "groupOccsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "groupOccsGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "occKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "occKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "dupDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dupDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "dupDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "dupDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "occKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "occKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "occKey") (EVar "o")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupGroupFires" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "dupGroupFires" ((PVar "grp")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "occFile")) (EVar "grp")))) (ELit (LInt 2)))))
(DTypeSig true "dupOccsOfClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccsOfClauses" ((PVar "path") (PVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "dupOccsOfGroup") (EVar "path"))) (EApp (EVar "dupClauseGroups") (EVar "clauses"))))
(DTypeSig true "dupClauseOfDecl" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "dupClauseOfDecl" ((PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EListLit (ERecordCreate "DupClause" ((fa "dcName" (EVar "name")) (fa "dcLine" (EApp (EVar "locLineOf") (EVar "loc"))) (fa "dcKey" (EApp (EApp (EVar "structuralKey") (EVar "pats")) (EVar "body"))) (fa "dcCost" (EApp (EVar "bodyComplexity") (EVar "body"))) (fa "dcPure" (EApp (EVar "isPureDataExpr") (EVar "body"))))))) (arm (PCon "DAttrib" PWild (PVar "inner")) () (EApp (EVar "dupClauseOfDecl") (ETuple (EVar "inner") (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "dupClauseGroups" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "DupClause")))))
(DFunDef false "dupClauseGroups" ((PList)) (EListLit))
(DFunDef false "dupClauseGroups" ((PCons (PVar "c") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "same") (PVar "others")) (EApp (EApp (EVar "dupSpanName") (EFieldAccess (EVar "c") "dcName")) (EVar "rest"))) (DoExpr (EBinOp "::" (EBinOp "::" (EVar "c") (EVar "same")) (EApp (EVar "dupClauseGroups") (EVar "others"))))))
(DTypeSig false "dupSpanName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyTuple (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyCon "DupClause"))))))
(DFunDef false "dupSpanName" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "dupSpanName" ((PVar "nm") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "dcName") (EVar "nm")) (EBlock (DoLet false false (PTuple (PVar "same") (PVar "others")) (EApp (EApp (EVar "dupSpanName") (EVar "nm")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "same")) (EVar "others")))) (EIf (EVar "otherwise") (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccsOfGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccsOfGroup" ((PVar "path") (PVar "cs")) (EBinOp "++" (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs")) (EApp (EApp (EVar "dupAggregateOcc") (EVar "path")) (EVar "cs"))))
(DTypeSig false "dupClauseOccs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupClauseOccs" (PWild (PList)) (EListLit))
(DFunDef false "dupClauseOccs" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EBinOp "::" (ETuple (EVar "path") (EFieldAccess (EVar "c") "dcLine") (EFieldAccess (EVar "c") "dcName") (EFieldAccess (EVar "c") "dcKey")) (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "dupClauseOccs") (EVar "path")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupAggregateOcc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupAggregateOcc" (PWild (PList)) (EListLit))
(DFunDef false "dupAggregateOcc" (PWild (PList PWild)) (EListLit))
(DFunDef false "dupAggregateOcc" ((PVar "path") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dupGroupCost") (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EVar "dcPureOf")) (EBinOp "::" (EVar "c") (EVar "cs"))))) (EListLit (ETuple (EVar "path") (EApp (EApp (EVar "dupAnchorLine") (EBinOp "::" (EVar "c") (EVar "cs"))) (EFieldAccess (EVar "c") "dcLine")) (EFieldAccess (EVar "c") "dcName") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EVar "dcKeyOf")) (EBinOp "::" (EVar "c") (EVar "cs")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupAnchorLine" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "dupAnchorLine" ((PList) (PVar "fallback")) (EVar "fallback"))
(DFunDef false "dupAnchorLine" ((PCons (PVar "c") (PVar "cs")) (PVar "fallback")) (EIf (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "c") "dcCost") (EVar "dupComplexityThreshold")) (EApp (EVar "not") (EFieldAccess (EVar "c") "dcPure"))) (EFieldAccess (EVar "c") "dcLine") (EIf (EVar "otherwise") (EApp (EApp (EVar "dupAnchorLine") (EVar "cs")) (EVar "fallback")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dcKeyOf" (TyFun (TyCon "DupClause") (TyCon "String")))
(DFunDef false "dcKeyOf" ((PVar "c")) (EFieldAccess (EVar "c") "dcKey"))
(DTypeSig false "dcPureOf" (TyFun (TyCon "DupClause") (TyCon "Bool")))
(DFunDef false "dcPureOf" ((PVar "c")) (EFieldAccess (EVar "c") "dcPure"))
(DTypeSig false "dupGroupCost" (TyFun (TyApp (TyCon "List") (TyCon "DupClause")) (TyCon "Int")))
(DFunDef false "dupGroupCost" ((PList)) (ELit (LInt 0)))
(DFunDef false "dupGroupCost" ((PCons (PVar "c") (PVar "cs"))) (EBinOp "+" (EFieldAccess (EVar "c") "dcCost") (EApp (EVar "dupGroupCost") (EVar "cs"))))
(DTypeSig false "locLineOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))
(DFunDef false "locLineOf" ((PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) (EVar "l"))
(DFunDef false "locLineOf" ((PCon "None")) (ELit (LInt 1)))
(DTypeSig false "occFile" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occFile" ((PTuple (PVar "f") PWild PWild PWild)) (EVar "f"))
(DTypeSig false "occLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Int")))
(DFunDef false "occLine" ((PTuple PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig false "occName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occName" ((PTuple PWild PWild (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "occKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occKey" ((PTuple PWild PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitDupGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitDupGroup" ((PVar "grp")) (EBlock (DoLet false false (PVar "distinctFiles") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "occFile")) (EVar "grp")))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "distinctFiles")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupFinding") (EVar "distinctFiles"))) (EApp (EVar "sortDupOccs") (EVar "grp")))))))
(DTypeSig false "dupFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "dupFinding" ((PVar "distinctFiles") (PVar "occ")) (EBlock (DoLet false false (PVar "file") (EApp (EVar "occFile") (EVar "occ"))) (DoLet false false (PVar "line") (EApp (EVar "occLine") (EVar "occ"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "file")))) (EVar "distinctFiles"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EApp (EVar "occName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to a definition in "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (ELit (LString " — consolidate into a shared module")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))))
(DTypeSig false "sortDupOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "sortDupOccs" ((PList)) (EListLit))
(DFunDef false "sortDupOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "dupInsert") (EVar "x")) (EApp (EVar "sortDupOccs") (EVar "xs"))))
(DTypeSig false "dupInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "dupInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "dupOccLe") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "dupInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccLe" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "dupOccLe" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "occFile") (EVar "a"))) (EApp (EVar "occFile") (EVar "b"))) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "<=" (EApp (EVar "occLine") (EVar "a")) (EApp (EVar "occLine") (EVar "b"))))))
