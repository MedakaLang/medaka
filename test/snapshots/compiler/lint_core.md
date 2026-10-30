# META
source_lines=484
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_core.mdk — the lint framework's data types: `Finding`,
-- suppression `Directive`s, the per-file `FileFacts` cell set, the `Rule` and
-- `CrossFileRule` records, the visitor `Ctx` and `Visitor` a walking rule
-- registers, and the `StdlibIndex` value with its pure accessors.
-- Leaf of the lint module family: it imports no rule, registry or runner module.

import frontend.ast.{Loc(..), Ty(..), Decl(..), Expr, Pat}
import frontend.ast_walk.{ExprKind}
import tools.lint_scope.{FileScopes}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..), Diag(..)}
import driver.diagnostic_value as DV
import support.util.{listLen, filterList, lookupAssoc, anyList}
import hash_map.{HashMap, new, size, findWithDefault}
import tools.printer.{ppTy}
import frontend.exhaust.{Oracle}
import frontend.lexer.{Comment}

-- One lint hit: which rule produced it, the human message, its severity (the
-- CLI may promote this via `lintProgram`), and an optional source span.
public export data Finding = Finding {
  rule : String,
  message : String,
  severity : Severity,
  loc : Option Loc,
  fix : Option Fix,
}

-- How far a fix may be trusted.  `Safe` is applied by `--fix`, `Unsafe` only
-- by `--fix --unsafe-fixes`, `Suggest` is shown and never applied.
public export data Applicability = Safe | Unsafe | Suggest deriving (Eq)

-- One source edit: the text between the start and end of `feSpan` becomes
-- `feText`.  Columns are codepoint offsets within the line, as in every `Loc`.
public export data FixEdit = FixEdit { feSpan : Loc, feText : String }

-- A finding's rewrite as span edits.  The edits of one fix are applied
-- together or not at all.
public export data Fix = Fix {
  fixApplicability : Applicability,
  fixEdits : List FixEdit,
  fixMessage : String,
}

-- The applicability's lowercase name, as `--json` and `--list-rules` print it.
export
applicabilityText : Applicability -> String
applicabilityText Safe = "safe"
applicabilityText Unsafe = "unsafe"
applicabilityText Suggest = "suggest"

-- The `Diag` form of a fix, for `--json`.
export
fixToDiagFix : Fix -> DV.Fix
fixToDiagFix fx =
  DV.FixEdits
    (applicabilityText fx.fixApplicability)
    (map (e => (e.feSpan, e.feText)) fx.fixEdits)

-- A write-once cell holding a derived value, forced on first demand.  Rules run
-- under a pure `check`, and the cell is private to one file's `FileFacts`, so
-- two rules asking for the same derived value share one computation without any
-- table keyed by source text.
export data Memo a = Memo (Ref (Option a)) (Unit -> a)

export
memoNew : (Unit -> a) -> Memo a
memoNew f = Memo (Ref None) f

memoGet : Memo a -> a
memoGet (Memo cell f) = match !cell
  Some v => v
  None =>
    let v = f ()
    cell := Some v
    v

-- What every rule may ask of the one file being linted, each derived at most
-- once per file and only if some active rule asks: the source text, its comment
-- side channel, the constructor `Oracle`, and the per-clause duplicate-body keys
-- shared by the same-file rule and the cross-file occurrence list, and the scope
-- model (`tools/lint_scope.mdk`), built only for a rule whose metadata says
-- `NeedsScopes`.
public export data FileFacts = FileFacts {
  ffSrc : String,
  ffComments : Memo (List Comment),
  ffOracle : Memo Oracle,
  ffDupClauses : Memo (List DupClause),
  ffScopes : Memo FileScopes,
}

export
factComments : FileFacts -> List Comment
factComments ff = memoGet ff.ffComments

export
factOracle : FileFacts -> Oracle
factOracle ff = memoGet ff.ffOracle

export
factDupClauses : FileFacts -> List DupClause
factDupClauses ff = memoGet ff.ffDupClauses

export
factScopes : FileFacts -> FileScopes
factScopes ff = memoGet ff.ffScopes

-- What kind of defect a rule reports, for the rules page and `--list-rules`.
public export data Category =
  | Correctness
  | Suspicious
  | Perf
  | Complexity
  | Style

-- Whether a rule is meaningful in any Medaka program (`Universal`) or enforces
-- this repository's own conventions or compiler-private code (`Internal`).
public export data Scope = Universal | Internal deriving (Eq)

-- How the repository enforces a rule: zero findings (`Gated`) or a per-file
-- count that may only fall (`Baselined`).
public export data Ratchet = Gated | Baselined deriving (Eq)

-- The most a rule's fixes may be trusted: `Fixable` is `Safe`, and a rule
-- whose fixes `--fix` leaves alone is `FixableUnsafe` or `SuggestOnly`.
-- `Fixable` also marks the rules that carry a whole-declaration fixer.
public export data Fixability =
  | Fixable
  | FixableUnsafe
  | SuggestOnly
  | NotFixable

-- The applicability ceiling of a fixability, `None` for a rule with no fix.
export
maxApplicability : Fixability -> Option Applicability
maxApplicability Fixable = Some Safe
maxApplicability FixableUnsafe = Some Unsafe
maxApplicability SuggestOnly = Some Suggest
maxApplicability NotFixable = None

-- The lower of two trusts: a fix is applied no further than its rule's ceiling.
export
clampApplicability : Applicability -> Applicability -> Applicability
clampApplicability Suggest _ = Suggest
clampApplicability _ Suggest = Suggest
clampApplicability Unsafe _ = Unsafe
clampApplicability _ Unsafe = Unsafe
clampApplicability Safe Safe = Safe

-- An input a rule's `check` reads beyond the file itself; the runner builds
-- only what some active rule needs.
public export data Need = NeedsStdlibIndex | NeedsWildIndex | NeedsScopes

-- Everything the CLI, the rules page and the runner know about a rule besides
-- its `check`.  `doc` states what the rule flags, why, and a before -> after
-- example; `summary` is its first line.
public export data RuleMeta = RuleMeta {
  name : String,
  summary : String,
  doc : String,
  category : Category,
  scope : Scope,
  ratchet : Ratchet,
  defaultSeverity : Severity,
  fixability : Fixability,
  needs : List Need,
}

export
ruleMetaName : RuleMeta -> String
ruleMetaName m = m.name

export
needsStdlibIndex : RuleMeta -> Bool
needsStdlibIndex m = anyList isStdlibIndexNeed m.needs

export
needsScopes : RuleMeta -> Bool
needsScopes m = anyList isScopesNeed m.needs

isStdlibIndexNeed : Need -> Bool
isStdlibIndexNeed NeedsStdlibIndex = True
isStdlibIndexNeed NeedsWildIndex = False
isStdlibIndexNeed NeedsScopes = False

-- A rule whose name guards read the index only to resolve an `import m.*`.
export
needsWildIndex : RuleMeta -> Bool
needsWildIndex m = anyList isWildIndexNeed m.needs

isWildIndexNeed : Need -> Bool
isWildIndexNeed NeedsWildIndex = True
isWildIndexNeed NeedsStdlibIndex = False
isWildIndexNeed NeedsScopes = False

isScopesNeed : Need -> Bool
isScopesNeed NeedsScopes = True
isScopesNeed NeedsStdlibIndex = False
isScopesNeed NeedsWildIndex = False

-- Where a visited node sits.  `ctxDeclName` and `ctxParams` name the body's
-- owner (a clause's function, an `impl` or interface-default method, a
-- let-group binding, a test's or prop's description) and its parameter
-- patterns, so a call to the enclosing function is recognisable; a test or prop
-- has none.  `ctxInTest` is True inside a `test` or `prop` body.  `ctxParent`
-- is the kind of the nearest enclosing expression other than an `ELoc`, `None`
-- at a body's root and for a declaration.  `ctxSpan` is the span of the
-- nearest enclosing `ELoc`, else the declaration's start line.  `ctxOwn` is the
-- span of the outermost of the `ELoc`s that directly wrap the node, which takes
-- in the brackets of a parenthesised node; `None` for a node no `ELoc` wraps (an
-- application or operator expression the parser leaves bare).  `ctxDeclLoc` is
-- always the declaration's start line, where an inline suppression sits.
public export data Ctx = Ctx {
  ctxDeclName : String,
  ctxParams : List Pat,
  ctxInTest : Bool,
  ctxParent : Option ExprKind,
  ctxSpan : Option Loc,
  ctxOwn : Option Loc,
  ctxDeclLoc : Option Loc,
}

-- One callback a walking rule registers: on every expression node whose kind is
-- listed (an `ELoc` is never visited; its span becomes the `Ctx` span beneath
-- it), on every expression node whatever its kind (`OnAnyExpr`, for a rule
-- whose detector inspects raw nodes of any shape), or on every top-level
-- declaration, in source order.
public export data Visitor =
  | OnExpr (List ExprKind) (Ctx -> Expr -> List Finding)
  | OnAnyExpr (Ctx -> Expr -> List Finding)
  | OnDecl (Ctx -> Decl -> List Finding)

-- How a rule inspects a file.  `WholeFile` is the whole pass for the rule: the
-- STDLIB INDEX (`StdlibIndex`, below — every exported stdlib name with its
-- declared signature, so a rule can ask what the stdlib actually provides
-- instead of consulting a curated list; it is a plain value, so the pass stays
-- PURE even though building the index needs `<IO>`) + the target file PATH (so
-- a rule may scope itself, e.g. skip stdlib-owned files) + Positions (for
-- per-decl source locations) + raw decls → hits.  `Visits` takes the same
-- inputs once per file and returns the rule's visitors, which the runner's one
-- walk over the file drives; any per-file state the visitors need is computed
-- there.  The two constructors are two kinds of pass, not failure and success.
-- lint-disable-next-line rule-clone-type
public export data RuleCheck =
  | WholeFile (StdlibIndex -> String -> FileFacts -> Positions -> List Decl -> List Finding)
  | Visits (StdlibIndex -> String -> FileFacts -> Positions -> List Decl -> List Visitor)

-- A registered rule.  `check` says how it inspects a file.  `fix`, when
-- `Some f`, is a per-decl autofixer: given the syntactic constructor `Oracle`
-- (built once from the whole target file's decls — used by the irrefutability
-- logic to recognise single-constructor patterns) and a single decl, it returns
-- `Some replacementDecls` if the rule can safely rewrite that decl, else
-- `None`.  `None` = the rule is not auto-fixable.
-- `name`/`descr`/`severity`/`enabled`/`fix` are derived from `meta` by `mkRule`;
-- `enabled`/`severity` are the defaults the CLI may override before running.
public export data Rule = Rule {
  meta : RuleMeta,
  name : String,
  descr : String,
  severity : Severity,
  enabled : Bool,
  check : RuleCheck,
  fix : Option (Oracle -> Decl -> Option (List Decl)),
}

-- A registered CROSS-FILE rule.  Unlike `Rule` (one file at a time), `check`
-- sees EVERY target file's `(path, Positions, decls)` triple at once, so it can
-- relate definitions across files (e.g. duplicate bodies).  Findings stamp the
-- file path into their `loc`.  Adding a cross-file rule = one `check` fn + one
-- binding + one `allCrossFileRules` entry.
public export data CrossFileRule = CrossFileRule {
  meta : RuleMeta,
  name : String,
  descr : String,
  severity : Severity,
  enabled : Bool,
  check : List (String, Positions, List Decl) -> List Finding,
}

-- The constructors of a `Rule`: the record's plain fields are read off the
-- metadata so the two cannot disagree.  A rule whose `fixability` is
-- `NotFixable` carries no fixer whatever `fix` says.
export
mkRule : RuleMeta ->
  (StdlibIndex -> String -> FileFacts -> Positions -> List Decl -> List Finding) ->
  Option (Oracle -> Decl -> Option (List Decl)) ->
  Rule
mkRule m check fix = ruleOf m (WholeFile check) fix

export
mkVisitorRule : RuleMeta ->
  (StdlibIndex -> String -> FileFacts -> Positions -> List Decl -> List Visitor) ->
  Option (Oracle -> Decl -> Option (List Decl)) ->
  Rule
mkVisitorRule m visits fix = ruleOf m (Visits visits) fix

ruleOf : RuleMeta ->
  RuleCheck ->
  Option (Oracle -> Decl -> Option (List Decl)) ->
  Rule
ruleOf m check fix = Rule {
  meta = m,
  name = m.name,
  descr = m.summary,
  severity = m.defaultSeverity,
  enabled = True,
  check = check,
  fix = match m.fixability
    Fixable => fix
    FixableUnsafe => None
    SuggestOnly => None
    NotFixable => None,
}

export
mkCrossFileRule : RuleMeta ->
  (List (String, Positions, List Decl) -> List Finding) ->
  CrossFileRule
mkCrossFileRule m check = CrossFileRule {
  meta = m,
  name = m.name,
  descr = m.summary,
  severity = m.defaultSeverity,
  enabled = True,
  check = check,
}

-- ── the stdlib reference index ────────────────────────────────────────────────
-- A name → DECLARED-SIGNATURE map for every exported stdlib binding, built by
-- PARSING `<MEDAKA_ROOT>/stdlib/*.mdk` and reading each exported `DTypeSig`.
-- It is the reference a style rule consults instead of a hand-curated name
-- list: the stdlib is the source of truth, so the index cannot drift from it.
--
-- Signatures come from the SOURCE, never from the typechecker's `ppScheme`:
-- lint runs on the RAW pre-desugar AST with no type environment at all (there
-- is no inferred scheme to read), and what a hand-rolled user binding has to be
-- compared against is what the stdlib author WROTE.
--
-- A stdlib name is not unique, so the index maps a name to a LIST of
-- (module, type), never to one type.  Measured on this tree: 55 of the 396
-- exported names are declared in more than one stdlib module, and `reverse` is
-- declared in THREE — `array.reverse : Array a -> Array a`,
-- `list.reverse : List a -> List a`, `string.reverse : String -> String`.
-- A flat `HashMap String Ty` silently keeps whichever file `listDir` yielded
-- last: `reverse` then reads back as `String -> String`, and every List-shaped
-- question about it gets a String-shaped answer with no error anywhere.  That
-- is the bare-name-keyed-table failure mode AGENTS.md's [T-GLOBAL-TABLE] names,
-- and it is invisible to any check that only asks whether a name is PRESENT —
-- this index was written flat first and the flat version passed exactly that
-- test while answering `reverse` wrong.  Consumers must therefore say WHICH
-- module they mean (`stdlibSigIn`) or handle every candidate
-- (`stdlibEntriesOf`); there is deliberately no "the signature of X" accessor,
-- because for 55 names there is no such thing.  `stdlibAmbiguousNames` is that
-- set, derived — never a list written down here.
--
-- A rule's `check` is PURE and reading the stdlib needs `<IO>`, so the index is
-- never built inside a rule.  Each IO entry point builds it ONCE and passes it
-- down through `lintProgram` as `check`'s first argument.
--
-- DEGRADATION.  Every failure mode — `MEDAKA_ROOT` unset and the exe-relative
-- fallback wrong, no `stdlib/` directory, an unreadable or unparseable member —
-- yields an EMPTY index (or one missing that member), never a crash and never a
-- wrong entry.  Same self-disabling shape `lintCacheCtx` uses for
-- `crossFileCacheSound` (`driver/medaka_cli.mdk`): a degraded run costs findings
-- it could have made, never findings it should not have made.
--
-- POSITIONAL, not a named-field record, and read ONLY through the helpers
-- below.
public export data StdlibIndex =
  StdlibIndex (HashMap String (List (String, Ty))) (List String) (List String)

-- The degraded index.  Also what a caller passes when it deliberately wants no
-- stdlib knowledge: `medaka_cli.mdk`'s `runLintCmd` and `mcp.mdk`'s
-- `runLintTool` both pass this when `stdlibIndexNeeded` says the active
-- `--only`/`--disable` set never reads it.  `runLintCmd` additionally forces
-- the real index whenever `--cache` is active, regardless of
-- `stdlibIndexNeeded`'s answer — a cache entry outlives this process's flag
-- choices, so it must never be populated from a degraded index.
export
emptyStdlibIndex : StdlibIndex
emptyStdlibIndex = StdlibIndex (new ()) [] []

-- How many distinct exported NAMES the index carries (not declarations — a name
-- declared in two modules counts once).  0 means degraded, or an empty stdlib;
-- it is the number an entry point prints to say what it actually got.
export
stdlibIndexSize : StdlibIndex -> Int
stdlibIndexSize (StdlibIndex m _ _) = size m

-- Every stdlib module declaring `name`, with the type each one declares, in
-- stdlib-file order.  `[]` = not a stdlib export (or the index is degraded);
-- more than one element = the name is ambiguous and the CALLER must decide.
export
stdlibEntriesOf : StdlibIndex -> String -> List (String, Ty)
stdlibEntriesOf (StdlibIndex m _ _) name = findWithDefault [] name m

-- The type `<module>.<name>` declares, e.g. `stdlibSigIn idx "list" "reverse"`
-- = `List a -> List a`.  The unambiguous accessor: it names the module, so it
-- cannot be answered by a same-named binding somewhere else in the stdlib.
export
stdlibSigIn : StdlibIndex -> String -> String -> Option Ty
stdlibSigIn idx modName name = lookupAssoc modName (stdlibEntriesOf idx name)

-- …rendered.  `printer.ppTy` is the precedence type printer, so `list.reverse`
-- reads back as exactly the `List a -> List a` its source declares.
export
stdlibSigTextIn : StdlibIndex -> String -> String -> Option String
stdlibSigTextIn idx modName name = map ppTy (stdlibSigIn idx modName name)

-- Every name the index knows, sorted.  `rule-stdlib-reimpl` generates its
-- candidate names from THIS rather than from a curated 15-name list, so the
-- rule cannot drift from the
-- stdlib the way a hand-written list does (#2248 Miss 2).
export
stdlibIndexNames : StdlibIndex -> List String
stdlibIndexNames (StdlibIndex _ names _) = names

-- Whether the index read `modName` (a dotted path, `crypto.hmac`) at all.  A
-- module it did not read exports nothing the index can vouch for.
export
stdlibKnowsModule : StdlibIndex -> String -> Bool
stdlibKnowsModule (StdlibIndex _ _ mods) modName = elem modName mods

-- The names declared by more than one stdlib module, sorted.  Exported because
-- it is the set every consumer has to have an answer for — a rule that treats a
-- stdlib name as having one signature is wrong for exactly these.
export
stdlibAmbiguousNames : StdlibIndex -> List String
stdlibAmbiguousNames idx =
  filterList (n => listLen (stdlibEntriesOf idx n) > 1) (stdlibIndexNames idx)

-- THE one IO entry point.  Call it ONCE per process and thread the result: it
-- parses the whole stdlib, which is cheap once and wasteful per file. Callers
-- gate this behind `stdlibIndexNeeded` first — when no active rule reads the
-- index, `emptyStdlibIndex` costs nothing and every rule's `check` behaves
-- identically (see `emptyStdlibIndex`'s own doc).
public export data StdlibIndexError = StdlibIndexError {
  path : String,
  source : String,
  diagnostic : Diag,
}

-- `public export` (not bare `data`) because a Directive is one of the four
-- things `medaka lint --cache` persists per file (#395): the cache round-trips
-- these values through JSON, so tools/lint_cache.mdk needs the constructors.
-- lint-disable-next-line rule-clone-type
public export data DirScope = DScopeLine Int | DScopeFile

-- one parsed directive: which source lines it covers + which rule ids it names
-- (empty list = all rules).
public export data Directive = Directive DirScope (List String)

-- ── the per-clause floor blind spot (#2651) ────────────────────────────────────
-- A function written as several pattern clauses is several `DFunDef`s sharing
-- one name.  Judging the complexity floor on ONE clause's body meant a function
-- whose clauses are individually small never reached it, however faithfully the
-- whole set of them duplicated another file's — so a multi-clause recursion, the
-- commonest shape in this codebase, was the shape the rule could not see.
-- Clauses are therefore collected first and the floor ALSO applied to the
-- FUNCTION: complexities summed (`bodyComplexity` counts '(' in the sexp dump,
-- so the units are additive and nothing is re-serialized) and clause keys
-- concatenated in declaration order, so a function matches only when every
-- clause matches, in the same order.
--
-- The function grain does not subsume the clause grain, and emitting only the
-- former silently dropped every PARTIAL match: one clause of a multi-clause
-- function duplicating a whole single-clause function elsewhere, or two
-- multi-clause functions sharing some clauses but not all, produce unequal
-- aggregate keys however exactly the shared clauses coincide.  Both grains are
-- therefore emitted, each judged against the floor on its own terms.  A
-- single-clause function's two grains are the same occurrence, so the aggregate
-- is emitted only for a group of two or more clauses.
--
-- The occurrence TUPLE is unchanged, which is what keeps the `--cache` path in
-- lockstep for free: `fileDupOccs` is what a cached run persists per file, and
-- the aggregation happens strictly inside it, so `runCrossFileRulesFromOccs`
-- runs the identical join over the identical shape.
public export data DupClause = DupClause {
  dcName : String,
  dcLine : Int,
  dcKey : String,
  dcCost : Int,
  dcPure : Bool,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true) (mem "Expr" false) (mem "Pat" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true))))
(DUse false (UseAlias ("driver" "diagnostic_value") "DV"))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "anyList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "size" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "fix" (TyApp (TyCon "Option") (TyCon "Fix")))))) ())
(DData Public "Applicability" () ((variant "Safe" (ConPos)) (variant "Unsafe" (ConPos)) (variant "Suggest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Applicability")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Safe") (PCon "Safe")) () (EVar "True")) (arm (PTuple (PCon "Unsafe") (PCon "Unsafe")) () (EVar "True")) (arm (PTuple (PCon "Suggest") (PCon "Suggest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "FixEdit" () ((variant "FixEdit" (ConNamed (field "feSpan" (TyCon "Loc")) (field "feText" (TyCon "String"))))) ())
(DData Public "Fix" () ((variant "Fix" (ConNamed (field "fixApplicability" (TyCon "Applicability")) (field "fixEdits" (TyApp (TyCon "List") (TyCon "FixEdit"))) (field "fixMessage" (TyCon "String"))))) ())
(DTypeSig true "applicabilityText" (TyFun (TyCon "Applicability") (TyCon "String")))
(DFunDef false "applicabilityText" ((PCon "Safe")) (ELit (LString "safe")))
(DFunDef false "applicabilityText" ((PCon "Unsafe")) (ELit (LString "unsafe")))
(DFunDef false "applicabilityText" ((PCon "Suggest")) (ELit (LString "suggest")))
(DTypeSig true "fixToDiagFix" (TyFun (TyCon "Fix") (TyCon "DV.Fix")))
(DFunDef false "fixToDiagFix" ((PVar "fx")) (EApp (EApp (EVar "DV.FixEdits") (EApp (EVar "applicabilityText") (EFieldAccess (EVar "fx") "fixApplicability"))) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "feSpan") (EFieldAccess (EVar "e") "feText")))) (EFieldAccess (EVar "fx") "fixEdits"))))
(DData Abstract "Memo" ("a") ((variant "Memo" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyCon "Unit") (TyVar "a"))))) ())
(DTypeSig true "memoNew" (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyApp (TyCon "Memo") (TyVar "a"))))
(DFunDef false "memoNew" ((PVar "f")) (EApp (EApp (EVar "Memo") (EApp (EVar "Ref") (EVar "None"))) (EVar "f")))
(DTypeSig false "memoGet" (TyFun (TyApp (TyCon "Memo") (TyVar "a")) (TyVar "a")))
(DFunDef false "memoGet" ((PCon "Memo" (PVar "cell") (PVar "f"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (DoExpr (EVar "v"))))))
(DData Public "FileFacts" () ((variant "FileFacts" (ConNamed (field "ffSrc" (TyCon "String")) (field "ffComments" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "Comment")))) (field "ffOracle" (TyApp (TyCon "Memo") (TyCon "Oracle"))) (field "ffDupClauses" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "DupClause")))) (field "ffScopes" (TyApp (TyCon "Memo") (TyCon "FileScopes")))))) ())
(DTypeSig true "factComments" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "factComments" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffComments")))
(DTypeSig true "factOracle" (TyFun (TyCon "FileFacts") (TyCon "Oracle")))
(DFunDef false "factOracle" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffOracle")))
(DTypeSig true "factDupClauses" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "factDupClauses" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffDupClauses")))
(DTypeSig true "factScopes" (TyFun (TyCon "FileFacts") (TyCon "FileScopes")))
(DFunDef false "factScopes" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffScopes")))
(DData Public "Category" () ((variant "Correctness" (ConPos)) (variant "Suspicious" (ConPos)) (variant "Perf" (ConPos)) (variant "Complexity" (ConPos)) (variant "Style" (ConPos))) ())
(DData Public "Scope" () ((variant "Universal" (ConPos)) (variant "Internal" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Scope")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Universal") (PCon "Universal")) () (EVar "True")) (arm (PTuple (PCon "Internal") (PCon "Internal")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Ratchet" () ((variant "Gated" (ConPos)) (variant "Baselined" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Ratchet")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Gated") (PCon "Gated")) () (EVar "True")) (arm (PTuple (PCon "Baselined") (PCon "Baselined")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Fixability" () ((variant "Fixable" (ConPos)) (variant "FixableUnsafe" (ConPos)) (variant "SuggestOnly" (ConPos)) (variant "NotFixable" (ConPos))) ())
(DTypeSig true "maxApplicability" (TyFun (TyCon "Fixability") (TyApp (TyCon "Option") (TyCon "Applicability"))))
(DFunDef false "maxApplicability" ((PCon "Fixable")) (EApp (EVar "Some") (EVar "Safe")))
(DFunDef false "maxApplicability" ((PCon "FixableUnsafe")) (EApp (EVar "Some") (EVar "Unsafe")))
(DFunDef false "maxApplicability" ((PCon "SuggestOnly")) (EApp (EVar "Some") (EVar "Suggest")))
(DFunDef false "maxApplicability" ((PCon "NotFixable")) (EVar "None"))
(DTypeSig true "clampApplicability" (TyFun (TyCon "Applicability") (TyFun (TyCon "Applicability") (TyCon "Applicability"))))
(DFunDef false "clampApplicability" ((PCon "Suggest") PWild) (EVar "Suggest"))
(DFunDef false "clampApplicability" (PWild (PCon "Suggest")) (EVar "Suggest"))
(DFunDef false "clampApplicability" ((PCon "Unsafe") PWild) (EVar "Unsafe"))
(DFunDef false "clampApplicability" (PWild (PCon "Unsafe")) (EVar "Unsafe"))
(DFunDef false "clampApplicability" ((PCon "Safe") (PCon "Safe")) (EVar "Safe"))
(DData Public "Need" () ((variant "NeedsStdlibIndex" (ConPos)) (variant "NeedsWildIndex" (ConPos)) (variant "NeedsScopes" (ConPos))) ())
(DData Public "RuleMeta" () ((variant "RuleMeta" (ConNamed (field "name" (TyCon "String")) (field "summary" (TyCon "String")) (field "doc" (TyCon "String")) (field "category" (TyCon "Category")) (field "scope" (TyCon "Scope")) (field "ratchet" (TyCon "Ratchet")) (field "defaultSeverity" (TyCon "Severity")) (field "fixability" (TyCon "Fixability")) (field "needs" (TyApp (TyCon "List") (TyCon "Need")))))) ())
(DTypeSig true "ruleMetaName" (TyFun (TyCon "RuleMeta") (TyCon "String")))
(DFunDef false "ruleMetaName" ((PVar "m")) (EFieldAccess (EVar "m") "name"))
(DTypeSig true "needsStdlibIndex" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsStdlibIndex" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isStdlibIndexNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig true "needsScopes" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsScopes" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isScopesNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig false "isStdlibIndexNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsStdlibIndex")) (EVar "True"))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsWildIndex")) (EVar "False"))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsScopes")) (EVar "False"))
(DTypeSig true "needsWildIndex" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsWildIndex" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isWildIndexNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig false "isWildIndexNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsWildIndex")) (EVar "True"))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsStdlibIndex")) (EVar "False"))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsScopes")) (EVar "False"))
(DTypeSig false "isScopesNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isScopesNeed" ((PCon "NeedsScopes")) (EVar "True"))
(DFunDef false "isScopesNeed" ((PCon "NeedsStdlibIndex")) (EVar "False"))
(DFunDef false "isScopesNeed" ((PCon "NeedsWildIndex")) (EVar "False"))
(DData Public "Ctx" () ((variant "Ctx" (ConNamed (field "ctxDeclName" (TyCon "String")) (field "ctxParams" (TyApp (TyCon "List") (TyCon "Pat"))) (field "ctxInTest" (TyCon "Bool")) (field "ctxParent" (TyApp (TyCon "Option") (TyCon "ExprKind"))) (field "ctxSpan" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "ctxOwn" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "ctxDeclLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Visitor" () ((variant "OnExpr" (ConPos (TyApp (TyCon "List") (TyCon "ExprKind")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))) (variant "OnAnyExpr" (ConPos (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))) (variant "OnDecl" (ConPos (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Public "RuleCheck" () ((variant "WholeFile" (ConPos (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))) (variant "Visits" (ConPos (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor")))))))))) ())
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "meta" (TyCon "RuleMeta")) (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyCon "RuleCheck")) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "meta" (TyCon "RuleMeta")) (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DTypeSig true "mkRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))) (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "mkRule" ((PVar "m") (PVar "check") (PVar "fix")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "m")) (EApp (EVar "WholeFile") (EVar "check"))) (EVar "fix")))
(DTypeSig true "mkVisitorRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))) (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "mkVisitorRule" ((PVar "m") (PVar "visits") (PVar "fix")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "m")) (EApp (EVar "Visits") (EVar "visits"))) (EVar "fix")))
(DTypeSig false "ruleOf" (TyFun (TyCon "RuleMeta") (TyFun (TyCon "RuleCheck") (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "ruleOf" ((PVar "m") (PVar "check") (PVar "fix")) (ERecordCreate "Rule" ((fa "meta" (EVar "m")) (fa "name" (EFieldAccess (EVar "m") "name")) (fa "descr" (EFieldAccess (EVar "m") "summary")) (fa "severity" (EFieldAccess (EVar "m") "defaultSeverity")) (fa "enabled" (EVar "True")) (fa "check" (EVar "check")) (fa "fix" (EMatch (EFieldAccess (EVar "m") "fixability") (arm (PCon "Fixable") () (EVar "fix")) (arm (PCon "FixableUnsafe") () (EVar "None")) (arm (PCon "SuggestOnly") () (EVar "None")) (arm (PCon "NotFixable") () (EVar "None")))))))
(DTypeSig true "mkCrossFileRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))) (TyCon "CrossFileRule"))))
(DFunDef false "mkCrossFileRule" ((PVar "m") (PVar "check")) (ERecordCreate "CrossFileRule" ((fa "meta" (EVar "m")) (fa "name" (EFieldAccess (EVar "m") "name")) (fa "descr" (EFieldAccess (EVar "m") "summary")) (fa "severity" (EFieldAccess (EVar "m") "defaultSeverity")) (fa "enabled" (EVar "True")) (fa "check" (EVar "check")))))
(DData Public "StdlibIndex" () ((variant "StdlibIndex" (ConPos (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "emptyStdlibIndex" (TyCon "StdlibIndex"))
(DFunDef false "emptyStdlibIndex" () (EApp (EApp (EApp (EVar "StdlibIndex") (EApp (EVar "new") (ELit LUnit))) (EListLit)) (EListLit)))
(DTypeSig true "stdlibIndexSize" (TyFun (TyCon "StdlibIndex") (TyCon "Int")))
(DFunDef false "stdlibIndexSize" ((PCon "StdlibIndex" (PVar "m") PWild PWild)) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "stdlibEntriesOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stdlibEntriesOf" ((PCon "StdlibIndex" (PVar "m") PWild PWild) (PVar "name")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")))
(DTypeSig true "stdlibSigIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "stdlibSigIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "lookupAssoc") (EVar "modName")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "name"))))
(DTypeSig true "stdlibSigTextIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stdlibSigTextIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "map") (EVar "ppTy")) (EApp (EApp (EApp (EVar "stdlibSigIn") (EVar "idx")) (EVar "modName")) (EVar "name"))))
(DTypeSig true "stdlibIndexNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibIndexNames" ((PCon "StdlibIndex" PWild (PVar "names") PWild)) (EVar "names"))
(DTypeSig true "stdlibKnowsModule" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "stdlibKnowsModule" ((PCon "StdlibIndex" PWild PWild (PVar "mods")) (PVar "modName")) (EApp (EApp (EVar "elem") (EVar "modName")) (EVar "mods")))
(DTypeSig true "stdlibAmbiguousNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibAmbiguousNames" ((PVar "idx")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "n"))) (ELit (LInt 1))))) (EApp (EVar "stdlibIndexNames") (EVar "idx"))))
(DData Public "StdlibIndexError" () ((variant "StdlibIndexError" (ConNamed (field "path" (TyCon "String")) (field "source" (TyCon "String")) (field "diagnostic" (TyCon "Diag"))))) ())
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "DupClause" () ((variant "DupClause" (ConNamed (field "dcName" (TyCon "String")) (field "dcLine" (TyCon "Int")) (field "dcKey" (TyCon "String")) (field "dcCost" (TyCon "Int")) (field "dcPure" (TyCon "Bool"))))) ())
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true) (mem "Expr" false) (mem "Pat" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true))))
(DUse false (UseAlias ("driver" "diagnostic_value") "DV"))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "lookupAssoc" false) (mem "anyList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "size" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "fix" (TyApp (TyCon "Option") (TyCon "Fix")))))) ())
(DData Public "Applicability" () ((variant "Safe" (ConPos)) (variant "Unsafe" (ConPos)) (variant "Suggest" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Applicability")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Safe") (PCon "Safe")) () (EVar "True")) (arm (PTuple (PCon "Unsafe") (PCon "Unsafe")) () (EVar "True")) (arm (PTuple (PCon "Suggest") (PCon "Suggest")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "FixEdit" () ((variant "FixEdit" (ConNamed (field "feSpan" (TyCon "Loc")) (field "feText" (TyCon "String"))))) ())
(DData Public "Fix" () ((variant "Fix" (ConNamed (field "fixApplicability" (TyCon "Applicability")) (field "fixEdits" (TyApp (TyCon "List") (TyCon "FixEdit"))) (field "fixMessage" (TyCon "String"))))) ())
(DTypeSig true "applicabilityText" (TyFun (TyCon "Applicability") (TyCon "String")))
(DFunDef false "applicabilityText" ((PCon "Safe")) (ELit (LString "safe")))
(DFunDef false "applicabilityText" ((PCon "Unsafe")) (ELit (LString "unsafe")))
(DFunDef false "applicabilityText" ((PCon "Suggest")) (ELit (LString "suggest")))
(DTypeSig true "fixToDiagFix" (TyFun (TyCon "Fix") (TyCon "DV.Fix")))
(DFunDef false "fixToDiagFix" ((PVar "fx")) (EApp (EApp (EVar "DV.FixEdits") (EApp (EVar "applicabilityText") (EFieldAccess (EVar "fx") "fixApplicability"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "feSpan") (EFieldAccess (EVar "e") "feText")))) (EFieldAccess (EVar "fx") "fixEdits"))))
(DData Abstract "Memo" ("a") ((variant "Memo" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyCon "Unit") (TyVar "a"))))) ())
(DTypeSig true "memoNew" (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyApp (TyCon "Memo") (TyVar "a"))))
(DFunDef false "memoNew" ((PVar "f")) (EApp (EApp (EVar "Memo") (EApp (EVar "Ref") (EVar "None"))) (EVar "f")))
(DTypeSig false "memoGet" (TyFun (TyApp (TyCon "Memo") (TyVar "a")) (TyVar "a")))
(DFunDef false "memoGet" ((PCon "Memo" (PVar "cell") (PVar "f"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (DoExpr (EVar "v"))))))
(DData Public "FileFacts" () ((variant "FileFacts" (ConNamed (field "ffSrc" (TyCon "String")) (field "ffComments" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "Comment")))) (field "ffOracle" (TyApp (TyCon "Memo") (TyCon "Oracle"))) (field "ffDupClauses" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "DupClause")))) (field "ffScopes" (TyApp (TyCon "Memo") (TyCon "FileScopes")))))) ())
(DTypeSig true "factComments" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "factComments" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffComments")))
(DTypeSig true "factOracle" (TyFun (TyCon "FileFacts") (TyCon "Oracle")))
(DFunDef false "factOracle" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffOracle")))
(DTypeSig true "factDupClauses" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "factDupClauses" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffDupClauses")))
(DTypeSig true "factScopes" (TyFun (TyCon "FileFacts") (TyCon "FileScopes")))
(DFunDef false "factScopes" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffScopes")))
(DData Public "Category" () ((variant "Correctness" (ConPos)) (variant "Suspicious" (ConPos)) (variant "Perf" (ConPos)) (variant "Complexity" (ConPos)) (variant "Style" (ConPos))) ())
(DData Public "Scope" () ((variant "Universal" (ConPos)) (variant "Internal" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Scope")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Universal") (PCon "Universal")) () (EVar "True")) (arm (PTuple (PCon "Internal") (PCon "Internal")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Ratchet" () ((variant "Gated" (ConPos)) (variant "Baselined" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Ratchet")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Gated") (PCon "Gated")) () (EVar "True")) (arm (PTuple (PCon "Baselined") (PCon "Baselined")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Fixability" () ((variant "Fixable" (ConPos)) (variant "FixableUnsafe" (ConPos)) (variant "SuggestOnly" (ConPos)) (variant "NotFixable" (ConPos))) ())
(DTypeSig true "maxApplicability" (TyFun (TyCon "Fixability") (TyApp (TyCon "Option") (TyCon "Applicability"))))
(DFunDef false "maxApplicability" ((PCon "Fixable")) (EApp (EVar "Some") (EVar "Safe")))
(DFunDef false "maxApplicability" ((PCon "FixableUnsafe")) (EApp (EVar "Some") (EVar "Unsafe")))
(DFunDef false "maxApplicability" ((PCon "SuggestOnly")) (EApp (EVar "Some") (EVar "Suggest")))
(DFunDef false "maxApplicability" ((PCon "NotFixable")) (EVar "None"))
(DTypeSig true "clampApplicability" (TyFun (TyCon "Applicability") (TyFun (TyCon "Applicability") (TyCon "Applicability"))))
(DFunDef false "clampApplicability" ((PCon "Suggest") PWild) (EVar "Suggest"))
(DFunDef false "clampApplicability" (PWild (PCon "Suggest")) (EVar "Suggest"))
(DFunDef false "clampApplicability" ((PCon "Unsafe") PWild) (EVar "Unsafe"))
(DFunDef false "clampApplicability" (PWild (PCon "Unsafe")) (EVar "Unsafe"))
(DFunDef false "clampApplicability" ((PCon "Safe") (PCon "Safe")) (EVar "Safe"))
(DData Public "Need" () ((variant "NeedsStdlibIndex" (ConPos)) (variant "NeedsWildIndex" (ConPos)) (variant "NeedsScopes" (ConPos))) ())
(DData Public "RuleMeta" () ((variant "RuleMeta" (ConNamed (field "name" (TyCon "String")) (field "summary" (TyCon "String")) (field "doc" (TyCon "String")) (field "category" (TyCon "Category")) (field "scope" (TyCon "Scope")) (field "ratchet" (TyCon "Ratchet")) (field "defaultSeverity" (TyCon "Severity")) (field "fixability" (TyCon "Fixability")) (field "needs" (TyApp (TyCon "List") (TyCon "Need")))))) ())
(DTypeSig true "ruleMetaName" (TyFun (TyCon "RuleMeta") (TyCon "String")))
(DFunDef false "ruleMetaName" ((PVar "m")) (EFieldAccess (EVar "m") "name"))
(DTypeSig true "needsStdlibIndex" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsStdlibIndex" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isStdlibIndexNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig true "needsScopes" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsScopes" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isScopesNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig false "isStdlibIndexNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsStdlibIndex")) (EVar "True"))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsWildIndex")) (EVar "False"))
(DFunDef false "isStdlibIndexNeed" ((PCon "NeedsScopes")) (EVar "False"))
(DTypeSig true "needsWildIndex" (TyFun (TyCon "RuleMeta") (TyCon "Bool")))
(DFunDef false "needsWildIndex" ((PVar "m")) (EApp (EApp (EVar "anyList") (EVar "isWildIndexNeed")) (EFieldAccess (EVar "m") "needs")))
(DTypeSig false "isWildIndexNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsWildIndex")) (EVar "True"))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsStdlibIndex")) (EVar "False"))
(DFunDef false "isWildIndexNeed" ((PCon "NeedsScopes")) (EVar "False"))
(DTypeSig false "isScopesNeed" (TyFun (TyCon "Need") (TyCon "Bool")))
(DFunDef false "isScopesNeed" ((PCon "NeedsScopes")) (EVar "True"))
(DFunDef false "isScopesNeed" ((PCon "NeedsStdlibIndex")) (EVar "False"))
(DFunDef false "isScopesNeed" ((PCon "NeedsWildIndex")) (EVar "False"))
(DData Public "Ctx" () ((variant "Ctx" (ConNamed (field "ctxDeclName" (TyCon "String")) (field "ctxParams" (TyApp (TyCon "List") (TyCon "Pat"))) (field "ctxInTest" (TyCon "Bool")) (field "ctxParent" (TyApp (TyCon "Option") (TyCon "ExprKind"))) (field "ctxSpan" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "ctxOwn" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "ctxDeclLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Visitor" () ((variant "OnExpr" (ConPos (TyApp (TyCon "List") (TyCon "ExprKind")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))) (variant "OnAnyExpr" (ConPos (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))) (variant "OnDecl" (ConPos (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Public "RuleCheck" () ((variant "WholeFile" (ConPos (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))) (variant "Visits" (ConPos (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor")))))))))) ())
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "meta" (TyCon "RuleMeta")) (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyCon "RuleCheck")) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "meta" (TyCon "RuleMeta")) (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DTypeSig true "mkRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))) (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "mkRule" ((PVar "m") (PVar "check") (PVar "fix")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "m")) (EApp (EVar "WholeFile") (EVar "check"))) (EVar "fix")))
(DTypeSig true "mkVisitorRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))) (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "mkVisitorRule" ((PVar "m") (PVar "visits") (PVar "fix")) (EApp (EApp (EApp (EVar "ruleOf") (EVar "m")) (EApp (EVar "Visits") (EVar "visits"))) (EVar "fix")))
(DTypeSig false "ruleOf" (TyFun (TyCon "RuleMeta") (TyFun (TyCon "RuleCheck") (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyCon "Rule")))))
(DFunDef false "ruleOf" ((PVar "m") (PVar "check") (PVar "fix")) (ERecordCreate "Rule" ((fa "meta" (EVar "m")) (fa "name" (EFieldAccess (EVar "m") "name")) (fa "descr" (EFieldAccess (EVar "m") "summary")) (fa "severity" (EFieldAccess (EVar "m") "defaultSeverity")) (fa "enabled" (EVar "True")) (fa "check" (EVar "check")) (fa "fix" (EMatch (EFieldAccess (EVar "m") "fixability") (arm (PCon "Fixable") () (EVar "fix")) (arm (PCon "FixableUnsafe") () (EVar "None")) (arm (PCon "SuggestOnly") () (EVar "None")) (arm (PCon "NotFixable") () (EVar "None")))))))
(DTypeSig true "mkCrossFileRule" (TyFun (TyCon "RuleMeta") (TyFun (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))) (TyCon "CrossFileRule"))))
(DFunDef false "mkCrossFileRule" ((PVar "m") (PVar "check")) (ERecordCreate "CrossFileRule" ((fa "meta" (EVar "m")) (fa "name" (EFieldAccess (EVar "m") "name")) (fa "descr" (EFieldAccess (EVar "m") "summary")) (fa "severity" (EFieldAccess (EVar "m") "defaultSeverity")) (fa "enabled" (EVar "True")) (fa "check" (EVar "check")))))
(DData Public "StdlibIndex" () ((variant "StdlibIndex" (ConPos (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "emptyStdlibIndex" (TyCon "StdlibIndex"))
(DFunDef false "emptyStdlibIndex" () (EApp (EApp (EApp (EVar "StdlibIndex") (EApp (EVar "new") (ELit LUnit))) (EListLit)) (EListLit)))
(DTypeSig true "stdlibIndexSize" (TyFun (TyCon "StdlibIndex") (TyCon "Int")))
(DFunDef false "stdlibIndexSize" ((PCon "StdlibIndex" (PVar "m") PWild PWild)) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "stdlibEntriesOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stdlibEntriesOf" ((PCon "StdlibIndex" (PVar "m") PWild PWild) (PVar "name")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")))
(DTypeSig true "stdlibSigIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "stdlibSigIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "lookupAssoc") (EVar "modName")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "name"))))
(DTypeSig true "stdlibSigTextIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stdlibSigTextIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EMethodRef "map") (EVar "ppTy")) (EApp (EApp (EApp (EVar "stdlibSigIn") (EVar "idx")) (EVar "modName")) (EVar "name"))))
(DTypeSig true "stdlibIndexNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibIndexNames" ((PCon "StdlibIndex" PWild (PVar "names") PWild)) (EVar "names"))
(DTypeSig true "stdlibKnowsModule" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "stdlibKnowsModule" ((PCon "StdlibIndex" PWild PWild (PVar "mods")) (PVar "modName")) (EApp (EApp (EDictApp "elem") (EVar "modName")) (EVar "mods")))
(DTypeSig true "stdlibAmbiguousNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibAmbiguousNames" ((PVar "idx")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "n"))) (ELit (LInt 1))))) (EApp (EVar "stdlibIndexNames") (EVar "idx"))))
(DData Public "StdlibIndexError" () ((variant "StdlibIndexError" (ConNamed (field "path" (TyCon "String")) (field "source" (TyCon "String")) (field "diagnostic" (TyCon "Diag"))))) ())
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "DupClause" () ((variant "DupClause" (ConNamed (field "dcName" (TyCon "String")) (field "dcLine" (TyCon "Int")) (field "dcKey" (TyCon "String")) (field "dcCost" (TyCon "Int")) (field "dcPure" (TyCon "Bool"))))) ())
