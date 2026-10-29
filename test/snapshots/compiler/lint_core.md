# META
source_lines=251
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_core.mdk — the lint framework's data types: `Finding`,
-- suppression `Directive`s, the per-file `FileFacts` cell set, the `Rule` and
-- `CrossFileRule` records, and the `StdlibIndex` value with its pure accessors.
-- Leaf of the lint module family: it imports no rule, registry or runner module.

import frontend.ast.{Loc(..), Ty(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..), Diag(..), DiagId(..)}
import support.util.{listLen, filterList, lookupAssoc}
import hash_map.{HashMap, new, size, findWithDefault}
import tools.printer.{ppTy}
import regex.{RegexError(..)}
import frontend.exhaust.{Oracle}
import frontend.lexer.{Comment}

-- One lint hit: which rule produced it, the human message, its severity (the
-- CLI may promote this via `lintProgram`), and an optional source span.
public export data Finding = Finding {
  rule : String,
  message : String,
  severity : Severity,
  loc : Option Loc,
}

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
-- shared by the same-file rule and the cross-file occurrence list.
public export data FileFacts = FileFacts {
  ffSrc : String,
  ffComments : Memo (List Comment),
  ffOracle : Memo Oracle,
  ffDupClauses : Memo (List DupClause),
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

-- A registered rule.  `check` is the whole pass for that rule: the STDLIB INDEX
-- (`StdlibIndex`, below — every exported stdlib name with its declared
-- signature, so a rule can ask what the stdlib actually provides instead of
-- consulting a curated list; it is a plain value, so `check` stays PURE even
-- though building the index needs `<IO>`) + the target file
-- PATH (so a rule may scope itself, e.g. skip stdlib-owned files) + Positions
-- (for per-decl source locations) + raw decls → hits.  `fix`, when `Some f`, is a
-- per-decl autofixer: given the syntactic constructor
-- `Oracle` (built once from the whole target file's decls — used by the
-- irrefutability logic to recognise single-constructor patterns) and a single
-- decl, it returns `Some replacementDecls` if the rule can safely rewrite that
-- decl, else `None`.  `None` = the rule is not auto-fixable.
-- `enabled`/`severity` are the defaults the CLI may override before running.
public export data Rule = Rule {
  name : String,
  descr : String,
  severity : Severity,
  enabled : Bool,
  check : StdlibIndex -> String -> FileFacts -> Positions -> List Decl -> List Finding,
  fix : Option (Oracle -> Decl -> Option (List Decl)),
}

-- A registered CROSS-FILE rule.  Unlike `Rule` (one file at a time), `check`
-- sees EVERY target file's `(path, Positions, decls)` triple at once, so it can
-- relate definitions across files (e.g. duplicate bodies).  Findings stamp the
-- file path into their `loc`.  Adding a cross-file rule = one `check` fn + one
-- binding + one `allCrossFileRules` entry.
public export data CrossFileRule = CrossFileRule {
  name : String,
  descr : String,
  severity : Severity,
  enabled : Bool,
  check : List (String, Positions, List Decl) -> List Finding,
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
-- 🚨 A STDLIB NAME IS NOT UNIQUE, so the index maps a name to a LIST of
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
-- ⚠️ `Rule.check` is PURE and reading the stdlib needs `<IO>`, so the index is
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
  StdlibIndex (HashMap String (List (String, Ty))) (List String)

-- The degraded index.  Also what a caller passes when it deliberately wants no
-- stdlib knowledge: `medaka_cli.mdk`'s `runLintCmd` and `mcp.mdk`'s
-- `runLintTool` both pass this when `stdlibIndexNeeded` says the active
-- `--only`/`--disable` set never reads it.  `runLintCmd` additionally forces
-- the real index whenever `--cache` is active, regardless of
-- `stdlibIndexNeeded`'s answer — a cache entry outlives this process's flag
-- choices, so it must never be populated from a degraded index.
export
emptyStdlibIndex : StdlibIndex
emptyStdlibIndex = StdlibIndex (new ()) []

-- How many distinct exported NAMES the index carries (not declarations — a name
-- declared in two modules counts once).  0 means degraded, or an empty stdlib;
-- it is the number an entry point prints to say what it actually got.
export
stdlibIndexSize : StdlibIndex -> Int
stdlibIndexSize (StdlibIndex m _) = size m

-- Every stdlib module declaring `name`, with the type each one declares, in
-- stdlib-file order.  `[]` = not a stdlib export (or the index is degraded);
-- more than one element = the name is ambiguous and the CALLER must decide.
export
stdlibEntriesOf : StdlibIndex -> String -> List (String, Ty)
stdlibEntriesOf (StdlibIndex m _) name = findWithDefault [] name m

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
stdlibIndexNames (StdlibIndex _ names) = names

-- The names declared by MORE THAN ONE stdlib module, sorted.  Exported because
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "size" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Abstract "Memo" ("a") ((variant "Memo" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyCon "Unit") (TyVar "a"))))) ())
(DTypeSig true "memoNew" (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyApp (TyCon "Memo") (TyVar "a"))))
(DFunDef false "memoNew" ((PVar "f")) (EApp (EApp (EVar "Memo") (EApp (EVar "Ref") (EVar "None"))) (EVar "f")))
(DTypeSig false "memoGet" (TyFun (TyApp (TyCon "Memo") (TyVar "a")) (TyVar "a")))
(DFunDef false "memoGet" ((PCon "Memo" (PVar "cell") (PVar "f"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (DoExpr (EVar "v"))))))
(DData Public "FileFacts" () ((variant "FileFacts" (ConNamed (field "ffSrc" (TyCon "String")) (field "ffComments" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "Comment")))) (field "ffOracle" (TyApp (TyCon "Memo") (TyCon "Oracle"))) (field "ffDupClauses" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "DupClause"))))))) ())
(DTypeSig true "factComments" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "factComments" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffComments")))
(DTypeSig true "factOracle" (TyFun (TyCon "FileFacts") (TyCon "Oracle")))
(DFunDef false "factOracle" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffOracle")))
(DTypeSig true "factDupClauses" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "factDupClauses" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffDupClauses")))
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Public "StdlibIndex" () ((variant "StdlibIndex" (ConPos (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "emptyStdlibIndex" (TyCon "StdlibIndex"))
(DFunDef false "emptyStdlibIndex" () (EApp (EApp (EVar "StdlibIndex") (EApp (EVar "new") (ELit LUnit))) (EListLit)))
(DTypeSig true "stdlibIndexSize" (TyFun (TyCon "StdlibIndex") (TyCon "Int")))
(DFunDef false "stdlibIndexSize" ((PCon "StdlibIndex" (PVar "m") PWild)) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "stdlibEntriesOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stdlibEntriesOf" ((PCon "StdlibIndex" (PVar "m") PWild) (PVar "name")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")))
(DTypeSig true "stdlibSigIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "stdlibSigIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "lookupAssoc") (EVar "modName")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "name"))))
(DTypeSig true "stdlibSigTextIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stdlibSigTextIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "map") (EVar "ppTy")) (EApp (EApp (EApp (EVar "stdlibSigIn") (EVar "idx")) (EVar "modName")) (EVar "name"))))
(DTypeSig true "stdlibIndexNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibIndexNames" ((PCon "StdlibIndex" PWild (PVar "names"))) (EVar "names"))
(DTypeSig true "stdlibAmbiguousNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibAmbiguousNames" ((PVar "idx")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "n"))) (ELit (LInt 1))))) (EApp (EVar "stdlibIndexNames") (EVar "idx"))))
(DData Public "StdlibIndexError" () ((variant "StdlibIndexError" (ConNamed (field "path" (TyCon "String")) (field "source" (TyCon "String")) (field "diagnostic" (TyCon "Diag"))))) ())
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "DupClause" () ((variant "DupClause" (ConNamed (field "dcName" (TyCon "String")) (field "dcLine" (TyCon "Int")) (field "dcKey" (TyCon "String")) (field "dcCost" (TyCon "Int")) (field "dcPure" (TyCon "Bool"))))) ())
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "size" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Abstract "Memo" ("a") ((variant "Memo" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyVar "a"))) (TyFun (TyCon "Unit") (TyVar "a"))))) ())
(DTypeSig true "memoNew" (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyApp (TyCon "Memo") (TyVar "a"))))
(DFunDef false "memoNew" ((PVar "f")) (EApp (EApp (EVar "Memo") (EApp (EVar "Ref") (EVar "None"))) (EVar "f")))
(DTypeSig false "memoGet" (TyFun (TyApp (TyCon "Memo") (TyVar "a")) (TyVar "a")))
(DFunDef false "memoGet" ((PCon "Memo" (PVar "cell") (PVar "f"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (DoExpr (EVar "v"))))))
(DData Public "FileFacts" () ((variant "FileFacts" (ConNamed (field "ffSrc" (TyCon "String")) (field "ffComments" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "Comment")))) (field "ffOracle" (TyApp (TyCon "Memo") (TyCon "Oracle"))) (field "ffDupClauses" (TyApp (TyCon "Memo") (TyApp (TyCon "List") (TyCon "DupClause"))))))) ())
(DTypeSig true "factComments" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "factComments" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffComments")))
(DTypeSig true "factOracle" (TyFun (TyCon "FileFacts") (TyCon "Oracle")))
(DFunDef false "factOracle" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffOracle")))
(DTypeSig true "factDupClauses" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "DupClause"))))
(DFunDef false "factDupClauses" ((PVar "ff")) (EApp (EVar "memoGet") (EFieldAccess (EVar "ff") "ffDupClauses")))
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Public "StdlibIndex" () ((variant "StdlibIndex" (ConPos (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "emptyStdlibIndex" (TyCon "StdlibIndex"))
(DFunDef false "emptyStdlibIndex" () (EApp (EApp (EVar "StdlibIndex") (EApp (EVar "new") (ELit LUnit))) (EListLit)))
(DTypeSig true "stdlibIndexSize" (TyFun (TyCon "StdlibIndex") (TyCon "Int")))
(DFunDef false "stdlibIndexSize" ((PCon "StdlibIndex" (PVar "m") PWild)) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "stdlibEntriesOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stdlibEntriesOf" ((PCon "StdlibIndex" (PVar "m") PWild) (PVar "name")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")))
(DTypeSig true "stdlibSigIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "stdlibSigIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EVar "lookupAssoc") (EVar "modName")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "name"))))
(DTypeSig true "stdlibSigTextIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stdlibSigTextIn" ((PVar "idx") (PVar "modName") (PVar "name")) (EApp (EApp (EMethodRef "map") (EVar "ppTy")) (EApp (EApp (EApp (EVar "stdlibSigIn") (EVar "idx")) (EVar "modName")) (EVar "name"))))
(DTypeSig true "stdlibIndexNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibIndexNames" ((PCon "StdlibIndex" PWild (PVar "names"))) (EVar "names"))
(DTypeSig true "stdlibAmbiguousNames" (TyFun (TyCon "StdlibIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibAmbiguousNames" ((PVar "idx")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "n"))) (ELit (LInt 1))))) (EApp (EVar "stdlibIndexNames") (EVar "idx"))))
(DData Public "StdlibIndexError" () ((variant "StdlibIndexError" (ConNamed (field "path" (TyCon "String")) (field "source" (TyCon "String")) (field "diagnostic" (TyCon "Diag"))))) ())
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "DupClause" () ((variant "DupClause" (ConNamed (field "dcName" (TyCon "String")) (field "dcLine" (TyCon "Int")) (field "dcKey" (TyCon "String")) (field "dcCost" (TyCon "Int")) (field "dcPure" (TyCon "Bool"))))) ())
