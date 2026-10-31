# META
source_lines=1751
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_walk.mdk — the lint runner: `lintProgram*` and the one
-- visitor walk per file (`runVisitors`), per-file facts, the autofix driver,
-- finding filters, inline suppressions, the project-rule runner and the
-- index builders.  The CLI filters and severity-overrides the registry's
-- rules and hands them in, so this module knows nothing about flags.

import frontend.ast.{
  letBindName,
  Loc(..),
  Ty(..),
  UsePath(..),
  UseMember(..),
  useMemberLocal,
  IfaceMethod(..),
  Decl(..),
  Expr(..),
  ExternDecl(..),
  Pat,
}
import frontend.ast_walk.{
  BodyOwner(..),
  DeclBody(..),
  ExprKind(..),
  childExprs,
  declBodies,
  exprKind,
}
import frontend.parser.{
  Positions(..),
  DeclPos,
  positionsDecls,
  declPosLine,
  declPosEndLine,
  parseWithPositions,
  parseResultPairs,
  parseWithPositionsOptPairs,
  prescanErrorPairs,
  ParseError,
}
import driver.loader.{
  entrySearchRoots,
  fileOfModuleId,
  findProjectRootOrSelf,
  moduleIdOfPath,
}
import support.cli_targets.{collectMdkFiles}
import tools.lint_cache.{ruleSetStamp}
import tools.lint_index.{
  IndexRow,
  ProjectIndex,
  combineDigests,
  emptyProjectIndex,
  fileRows,
  stdlibShardDir,
  projectShardDir,
}
import driver.diagnostics.{
  Severity(..),
  Diag(..),
  DiagId(..),
  ppSeverity,
  readFileSafe,
  parseErrDiag,
}
import support.util.{
  contains,
  listLen,
  anyList,
  allList,
  filterList,
  joinNl,
  isEmptyL,
  isNonEmptyL,
  reverseL,
  splitNl,
  splitOnChar,
  joinWith,
  startsWith,
  endsWith,
  dedup,
  stringTrim,
  isSome,
  lookupAssoc,
}
import hash_map.{HashMap, new, get, setInPlace, has, keys, findWithDefault}
import list.{take, drop, indexed, nub}
import string.{indexOf, lines}
import array.{fromList}
import tools.printer.{declToString}
import support.path.{dirOf, stripMdk}
import frontend.marker.{declRefs}
import frontend.exhaust.{Oracle, buildOracle}
import support.stage_count.{stageBump}
import frontend.lexer.{
  Comment,
  collectComments,
  tokenizeWithOffsetPairs,
  commentLine,
  commentText,
}
import tools.lint_core.{
  Ctx(..),
  DirScope(..),
  Directive(..),
  FileFacts(..),
  Finding(..),
  Fix(..),
  Fixability(..),
  ProjectRule(..),
  Rule(..),
  RuleCheck(..),
  RuleMeta,
  StdlibIndex(..),
  Summary,
  StdlibIndexError(..),
  Visitor(..),
  factComments,
  fixToDiagFix,
  factDupClauses,
  factScopes,
  clampApplicability,
  emptyStdlibIndex,
  maxApplicability,
  memoNew,
  mkStdlibIndex,
  projectIndexOf,
  stdlibIndexFingerprint,
  stdlibLocalModAsked,
  withStdlibLocalMods,
  needsProjectIndex,
  needsScopes,
  needsStdlibIndex,
  needsWildIndex,
  readsIndex,
}
import tools.lint_scope.{
  Binder(..),
  BinderKind(..),
  FileScopes,
  Use(..),
  bindersNamed,
  bindersNamedIn,
  buildScopes,
  usesNamedIn,
  wildImports,
}
import tools.lint_shared.{
  collectDirectives,
  declLocList,
  sortUniqS,
  zipDeclPos,
}
import tools.lint_fix.{demoteOverComments}
import tools.lint_dup.{dupClauseOfDecl}
import tools.lint_registry.{
  allProjectRules, allRules, projectRuleActive, selectRules
}

export
mkFileFacts : String -> List Decl -> Positions -> FileFacts
mkFileFacts src prog pos = FileFacts {
  ffSrc = src,
  ffComments = memoNew (_ => collectComments src),
  ffOracle = memoNew (_ => buildOracle prog),
  ffDupClauses = memoNew (_ => flatMap dupClauseOfDecl (declLocList pos prog)),
  ffScopes = memoNew (_ => buildScopes prog),
  ffLines = memoNew (_ => fromList (lines src)),
  ffLocalMods = [],
}

-- The dotted names of the program's `import m.*` modules that resolve to a file
-- of the project: `<root>/<m as a path>.mdk` under the file's own directory or
-- the manifest root, the loader's rule.  Such a module shadows a stdlib module
-- of the same name, so its exports are unknown to the stdlib index.
export
projectWildMods : String -> List Decl -> <IO> List String
projectWildMods path prog = match wildModsOf prog
  [] => []
  wild => localModsIn (entrySearchRoots (dirOf path)) wild

-- The dotted names of the program's `import m.*` modules, once each.
export
wildModsOf : List Decl -> List String
wildModsOf prog = dedup (map (joinWith ".") (flatMap wildPathsOf prog))

-- For each of `mods`, whether it is a file of the project as seen from the file
-- at `path`.
export
localModStates : String -> List String -> <IO> List (String, Bool)
localModStates _ [] = []
localModStates path mods =
  let roots = entrySearchRoots (dirOf path)
  map (m => (m, hasModuleFile roots m)) mods

localModsIn : List String -> List String -> <IO> List String
localModsIn _ [] = []
localModsIn roots (m :: rest) =
  let others = localModsIn roots rest
  if hasModuleFile roots m then m :: others else others

hasModuleFile : List String -> String -> <IO> Bool
hasModuleFile [] _ = False
hasModuleFile (r :: rs) m =
  fileExists (fileOfModuleId r m) || hasModuleFile rs m

wildPathsOf : Decl -> List (List String)
wildPathsOf (DUse _ (UseWild p) _) = [p]
wildPathsOf _ = []

-- `facts` knowing which wildcard imports are the project's own modules.
export
withLocalMods : List String -> FileFacts -> FileFacts
withLocalMods mods ff = { ff | ffLocalMods = mods }

-- `mkFileFacts` for a file on disk, reading which wildcard imports are the
-- project's own modules.
export
mkFileFactsAt : String -> String -> List Decl -> Positions -> <IO> FileFacts
mkFileFactsAt path src prog pos =
  withLocalMods (projectWildMods path prog) (mkFileFacts src prog pos)

-- `mkFileFactsAt` for a file whose rules are handed `idx`: the filesystem says
-- which wildcard imports are the project's modules, and the index is asked
-- about each one, so a recording index logs the answer, absent as well as
-- present.  Returns the index the file's rules must be handed.
export
mkFileFactsIn : StdlibIndex ->
  String ->
  String ->
  List Decl ->
  Positions ->
  <IO> (StdlibIndex, FileFacts)
mkFileFactsIn idx path src prog pos =
  let wild = wildModsOf prog
  let idxHere = withStdlibLocalMods (localModStates path wild) idx
  let local = filterList (stdlibLocalModAsked idxHere) wild
  (idxHere, withLocalMods local (mkFileFacts src prog pos))

-- The file's inline-suppression directives, off the shared comment channel.
export
factDirectives : FileFacts -> List Directive
factDirectives ff = collectDirectives (factComments ff)

-- Run the enabled rules over a program, collecting every finding.  `pos` carries
-- per-decl source spans so each rule can stamp its finding with the decl's real
-- location.  Each rule's findings are re-stamped with the rule's (possibly
-- CLI-overridden) severity so a `--deny` promotion propagates without the rule
-- knowing about flags.
-- `idx` is the stdlib reference index, built ONCE by the IO caller (see
-- `buildStdlibIndexResult`) and handed to every rule; a caller with no stdlib to read
-- passes `emptyStdlibIndex` and the rules simply learn nothing from it.
export
lintProgram : StdlibIndex ->
  List Rule ->
  String ->
  String ->
  Positions ->
  List Decl ->
  List Finding
lintProgram idx rules path src pos prog =
  lintProgramFacts idx rules path (mkFileFacts src prog pos) pos prog

-- `lintProgram` over facts the caller already holds, so the caller's own
-- comment/directive/key needs share the rules' derivations.  Findings come out
-- rule by rule in `rules` order; every visitor rule's findings come from one
-- shared walk of the file.
export
lintProgramFacts : StdlibIndex ->
  List Rule ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
lintProgramFacts idx rules path facts pos prog =
  map snd (lintProgramRanked idx (ranked 0 rules) path facts pos prog)

-- A rule's rank is its place in the roster the cache is keyed on, so findings
-- computed in two runs (index-free rules in one, index-reading rules in a later
-- one) merge back into the order a single run would have produced.
export
ranked : Int -> List Rule -> List (Int, Rule)
ranked _ [] = []
ranked i (r :: rest) = (i, r) :: ranked (i + 1) rest

-- `lintProgramFacts` over rules that carry their rank; each finding comes back
-- with the rank of the rule that made it.
export
lintProgramRanked : StdlibIndex ->
  List (Int, Rule) ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List (Int, Finding)
lintProgramRanked idx rules path facts pos prog =
  let enabled = filterList rankedEnabled rules
  let visitorSets =
    flatMap (rf => ruleVisitors idx path facts pos prog (snd rf)) enabled
  let walked =
    if isEmptyL visitorSets then
      []
    else
      runVisitors visitorSets (declLocList pos prog)
  ruleFindings idx path facts pos prog enabled walked

rankedEnabled : (Int, Rule) -> Bool
rankedEnabled (_, r) = r.enabled

ruleVisitors : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  Rule ->
  List (List Visitor)
ruleVisitors idx path facts pos prog r = match r.check
  WholeFile _ => []
  Visits visits => [visits (indexFor r idx) path facts pos prog]

-- THE index access: the index a rule is handed.  The real one only if the rule
-- declares that it reads it; an undeclared read then finds nothing on every
-- run, instead of finding the index on some runs and a stale answer under
-- `--cache`.  Every rule reaches the index through here, which is what lets a
-- cache key be derived from what was handed out.
indexFor : Rule -> StdlibIndex -> StdlibIndex
indexFor r idx = if readsIndex r.meta then idx else emptyStdlibIndex

-- `walked` holds one finding list per visitor rule, in `rules` order.
ruleFindings : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List (Int, Rule) ->
  List (List Finding) ->
  List (Int, Finding)
ruleFindings _ _ _ _ _ [] _ = []
ruleFindings idx path facts pos prog ((rank, r) :: rs) walked = match r.check
  WholeFile check =>
    map
        (f => (rank, restampFinding r f))
        (check (indexFor r idx) path facts pos prog)
      ++ ruleFindings idx path facts pos prog rs walked
  Visits _ => match walked
    hits :: rest =>
      map (f => (rank, restampFinding r f)) hits
        ++ ruleFindings idx path facts pos prog rs rest
    [] => ruleFindings idx path facts pos prog rs []

-- ── the visitor walk ──────────────────────────────────────────────────────────
-- One pass over a file's declarations (each paired with its start location)
-- for every visitor set at once: each `OnDecl` sees every top-level
-- declaration, and each `OnExpr` sees every expression node of the listed kinds
-- in every body `declBodies` names, pre-order.  Returns one finding list per
-- visitor set, in the order given.  No body is walked when no set has an
-- `OnExpr`.
export
runVisitors : List (List Visitor) ->
  List (Decl, Option Loc) ->
  List (List Finding)
runVisitors sets decls =
  let tagged = indexed sets
  let exprHooks = flatMap (hooksOf exprHookOf) tagged
  let declHooks = flatMap (hooksOf declHookOf) tagged
  let hits = reverseL (walkDecls exprHooks declHooks [] decls)
  map (t => findingsTagged (fst t) hits) tagged

data ExprHook =
  ExprHook Int (Option (List ExprKind)) (Ctx -> Expr -> List Finding)

data DeclHook = DeclHook Int (Ctx -> Decl -> List Finding)

-- What every node of one body shares: its owner's name and parameters, and
-- whether it is a test or prop body.
data BodyScope = BodyScope String (List Pat) BodyKind (Option Loc)

data BodyKind = PlainBody | TestBody

-- The hooks of one visitor set, each tagged with the set's index.
hooksOf : (Int -> Visitor -> List h) -> (Int, List Visitor) -> List h
hooksOf hookOf (i, vs) = flatMap (hookOf i) vs

exprHookOf : Int -> Visitor -> List ExprHook
exprHookOf i (OnExpr kinds cb) = [ExprHook i (Some kinds) cb]
exprHookOf i (OnAnyExpr cb) = [ExprHook i None cb]
exprHookOf _ (OnDecl _) = []

declHookOf : Int -> Visitor -> List DeclHook
declHookOf _ (OnExpr _ _) = []
declHookOf _ (OnAnyExpr _) = []
declHookOf i (OnDecl cb) = [DeclHook i cb]

findingsTagged : Int -> List (Int, Finding) -> List Finding
findingsTagged i hits = map snd (filterList (h => fst h == i) hits)

-- `acc` holds the hits so far, newest first.  The walk recurses on its lists
-- directly rather than through `fold`, whose dispatch and per-node closures
-- were a measured share of lint's cost.
walkDecls : List ExprHook ->
  List DeclHook ->
  List (Int, Finding) ->
  List (Decl, Option Loc) ->
  List (Int, Finding)
walkDecls _ _ acc [] = acc
walkDecls exprHooks declHooks acc ((d, loc) :: rest) =
  let bodies = declBodies d
  let acc2 = match declHooks
    [] => acc
    _ =>
      runDeclHooks
        (scopeCtx (declScope bodies loc) KLoc loc None)
        d
        acc
        declHooks
  let acc3 = match exprHooks
    [] => acc2
    _ => walkBodies exprHooks loc acc2 bodies
  walkDecls exprHooks declHooks acc3 rest

-- A declaration's own `Ctx` reads its first body's owner, so a function clause
-- carries its name and parameters and a test or prop is in a test.
declScope : List DeclBody -> Option Loc -> BodyScope
declScope [] loc = BodyScope "" [] PlainBody loc
declScope ((DeclBody owner _) :: _) loc = ownerScope owner loc

ownerScope : BodyOwner -> Option Loc -> BodyScope
ownerScope (OwnerClause name ps) loc = BodyScope name ps PlainBody loc
ownerScope (OwnerImplMethod _ m ps) loc = BodyScope m ps PlainBody loc
ownerScope (OwnerIfaceDefault _ m ps) loc = BodyScope m ps PlainBody loc
ownerScope (OwnerTest name) loc = BodyScope name [] TestBody loc
ownerScope (OwnerProp name _) loc = BodyScope name [] TestBody loc
ownerScope (OwnerLetGroup name ps) loc = BodyScope name ps PlainBody loc

-- The walk carries the parent kind unwrapped, with `KLoc` standing for "no
-- parent": an `ELoc` is never a parent, and the `Option` is built only when a
-- callback fires.
scopeCtx : BodyScope -> ExprKind -> Option Loc -> Option Loc -> Ctx
scopeCtx (BodyScope name ps kind declLoc) parent span own = Ctx {
  ctxDeclName = name,
  ctxParams = ps,
  ctxInTest = isTestBody kind,
  ctxParent = if parent == KLoc then None else Some parent,
  ctxSpan = span,
  ctxOwn = own,
  ctxDeclLoc = declLoc,
}

isTestBody : BodyKind -> Bool
isTestBody TestBody = True
isTestBody PlainBody = False

runDeclHooks : Ctx ->
  Decl ->
  List (Int, Finding) ->
  List DeclHook ->
  List (Int, Finding)
runDeclHooks _ _ acc [] = acc
runDeclHooks ctx d acc ((DeclHook i cb) :: rest) =
  runDeclHooks ctx d (pushTagged i (cb ctx d) acc) rest

pushTagged : Int -> List Finding -> List (Int, Finding) -> List (Int, Finding)
pushTagged _ [] acc = acc
pushTagged i (f :: fs) acc = pushTagged i fs ((i, f) :: acc)

walkBodies : List ExprHook ->
  Option Loc ->
  List (Int, Finding) ->
  List DeclBody ->
  List (Int, Finding)
walkBodies _ _ acc [] = acc
walkBodies hooks loc acc ((DeclBody owner body) :: rest) =
  walkBodies
    hooks
    loc
    (walkExpr hooks (ownerScope owner loc) KLoc loc acc body)
    rest

-- An `ELoc` is transparent: its span becomes the span beneath it and its
-- parent is the parent of what it wraps.  The outermost `ELoc` of a run of
-- them is the node's own extent (`ctxOwn`); a node no `ELoc` wraps has none.
walkExpr : List ExprHook ->
  BodyScope ->
  ExprKind ->
  Option Loc ->
  List (Int, Finding) ->
  Expr ->
  List (Int, Finding)
walkExpr hooks scope parent _ acc (ELoc l inner) =
  walkWrapped hooks scope parent l l acc inner
walkExpr hooks scope parent span acc e =
  walkNode hooks scope parent span None acc e

walkWrapped : List ExprHook ->
  BodyScope ->
  ExprKind ->
  Loc ->
  Loc ->
  List (Int, Finding) ->
  Expr ->
  List (Int, Finding)
walkWrapped hooks scope parent outer _ acc (ELoc l inner) =
  walkWrapped hooks scope parent outer l acc inner
walkWrapped hooks scope parent outer innermost acc e =
  walkNode hooks scope parent (Some innermost) (Some outer) acc e

walkNode : List ExprHook ->
  BodyScope ->
  ExprKind ->
  Option Loc ->
  Option Loc ->
  List (Int, Finding) ->
  Expr ->
  List (Int, Finding)
walkNode hooks scope parent span own acc e =
  let k = exprKind e
  let acc2 = visitHooks (scopeCtx scope parent span own) k e acc hooks
  walkKids hooks scope k span acc2 (childExprs e)

walkKids : List ExprHook ->
  BodyScope ->
  ExprKind ->
  Option Loc ->
  List (Int, Finding) ->
  List Expr ->
  List (Int, Finding)
walkKids _ _ _ _ acc [] = acc
walkKids hooks scope parent span acc (c :: cs) =
  walkKids hooks scope parent span (walkExpr hooks scope parent span acc c) cs

visitHooks : Ctx ->
  ExprKind ->
  Expr ->
  List (Int, Finding) ->
  List ExprHook ->
  List (Int, Finding)
visitHooks _ _ _ acc [] = acc
visitHooks ctx k e acc ((ExprHook i kinds cb) :: rest)
  | hookWants k kinds = visitHooks ctx k e (pushTagged i (cb ctx e) acc) rest
  | otherwise = visitHooks ctx k e acc rest

hookWants : ExprKind -> Option (List ExprKind) -> Bool
hookWants _ None = True
hookWants k (Some kinds) = kindIn k kinds

-- A direct scan, not `elem`: this runs for every hook on every node, and the
-- `Foldable` dispatch of `elem` measured +193M Ir on `lint compiler/frontend`.
kindIn : ExprKind -> List ExprKind -> Bool
kindIn _ [] = False
kindIn k (x :: xs) = k == x || kindIn k xs

-- A rule's finding under the rule's own severity, its fix held to the rule's
-- applicability ceiling.
restampFinding : Rule -> Finding -> Finding
restampFinding r f = Finding {
  rule = f.rule,
  message = f.message,
  severity = r.severity,
  loc = f.loc,
  fix = map (clampFix r.meta.fixability) f.fix,
}

clampFix : Fixability -> Fix -> Fix
clampFix fixability fx = match maxApplicability fixability
  Some ceiling => Fix {
    fixApplicability = clampApplicability ceiling fx.fixApplicability,
    fixEdits = fx.fixEdits,
    fixMessage = fx.fixMessage,
  }
  None => fx

restampSeverity : Severity -> Finding -> Finding
restampSeverity sev f = Finding {
  rule = f.rule,
  message = f.message,
  severity = sev,
  loc = f.loc,
  fix = f.fix,
}

-- Whether some rule in the active `--only`/`--disable` set declares
-- `NeedsStdlibIndex` in its metadata.  Mirrors `ruleActiveFixable`'s only/disable
-- semantics (the `enabled`/fixer checks that helper also makes don't apply
-- here: the registry always enables these rules). A caller uses this to decide
-- whether `buildStdlibIndexResult` is worth its cost at all.
export
stdlibIndexNeeded : List String -> List String -> Bool
stdlibIndexNeeded only disable = anyList (ruleNeedsIndex only disable) allRules

-- Whether the index is worth building for linting `paths`: a rule that reads
-- it outright is active, or a rule whose guards read it only for wildcard
-- imports is active and some path has an `import m.*`.
export
stdlibIndexNeededFor : List String -> List String -> List String -> <IO> Bool
stdlibIndexNeededFor only disable paths =
  stdlibIndexNeeded only disable
    || wildIndexNeeded only disable && anyPathWild paths

-- Whether some active rule, per-file or project, declares `NeedsProjectIndex`.
export
projectIndexNeeded : List String -> List String -> Bool
projectIndexNeeded only disable =
  anyActive needsProjectIndex allRules only disable
    || anyProjectActive needsProjectIndex allProjectRules only disable

-- Whether some rule of `roster` that survives `--only`/`--disable` has the
-- need `declares` tests for.
anyActive : (RuleMeta -> Bool) ->
  List Rule ->
  List String ->
  List String ->
  Bool
anyActive declares roster only disable =
  anyList (activeWith declares only disable) roster

activeWith : (RuleMeta -> Bool) -> List String -> List String -> Rule -> Bool
activeWith declares only disable r =
  declares r.meta
    && (isEmptyL only || contains r.name only)
    && not (contains r.name disable)

-- The index one `medaka lint` run needs, built once and only from the needs of
-- the rules that survive `--only`/`--disable`, per-file and project rules
-- alike: empty when none reads it, the stdlib's rows when a stdlib reader is
-- active, the project's rows too when a project reader is.  `keepAll` builds
-- for the whole roster, which `--cache` needs because a shard outlives this
-- run's flags.  The project's rows are those of the project of each linted
-- path (`projectRootsOf`).
export
indexForRun : Bool ->
  List String ->
  List String ->
  List String ->
  <IO> Result StdlibIndexError StdlibIndex
indexForRun keepAll only disable paths =
  indexForRoster allRules "" keepAll only disable paths

-- `indexForRun` over a given roster, with the project's rows read from `root`
-- (empty: from the project of each of `paths`).
export
indexForRoster : List Rule ->
  String ->
  Bool ->
  List String ->
  List String ->
  List String ->
  <IO> Result StdlibIndexError StdlibIndex
indexForRoster roster root keepAll only disable paths =
  indexForRosterIn
    lintStdlibDir
    (stdlibShardDir ())
    roster
    root
    keepAll
    only
    disable
    paths

-- `indexForRoster` with the stdlib read from `sdir` and its row shards kept in
-- `shardDir` (empty: not cached), instead of from the environment.  A test
-- gives each run a stdlib copy of its own this way.
export
indexForRosterIn : String ->
  String ->
  List Rule ->
  String ->
  Bool ->
  List String ->
  List String ->
  List String ->
  <IO> Result StdlibIndexError StdlibIndex
indexForRosterIn sdir shardDir roster root keepAll only disable paths =
  indexForRostersIn
    sdir
    shardDir
    roster
    allProjectRules
    root
    keepAll
    only
    disable
    paths

-- `indexForRosterIn` over a given project-rule roster too: a project rule's
-- declared need builds the index as a per-file rule's does.
export
indexForRostersIn : String ->
  String ->
  List Rule ->
  List ProjectRule ->
  String ->
  Bool ->
  List String ->
  List String ->
  List String ->
  <IO> Result StdlibIndexError StdlibIndex
indexForRostersIn sdir shardDir roster projects root keepAll only disable paths =
  let only2 = if keepAll then [] else only
  let disable2 = if keepAll then [] else disable
  if anyActive needsProjectIndex roster only2 disable2
    || anyProjectActive needsProjectIndex projects only2 disable2 then
    buildProjectIndexResultRootsIn sdir shardDir (if root == "" then
      projectRootsOf paths
    else
      [root])
  else if anyActive needsStdlibIndex roster only2 disable2
    || anyProjectActive needsStdlibIndex projects only2 disable2
    || (anyActive needsWildIndex roster only2 disable2
        || anyProjectActive needsWildIndex projects only2 disable2)
      && anyPathWild paths then
    buildStdlibIndexResultIn sdir shardDir
  else
    Ok emptyStdlibIndex

-- Whether some project rule that survives `--only`/`--disable` has the need
-- `declares` tests for.
anyProjectActive : (RuleMeta -> Bool) ->
  List ProjectRule ->
  List String ->
  List String ->
  Bool
anyProjectActive declares projects only disable =
  anyList (projectActiveWith declares only disable) projects

projectActiveWith : (RuleMeta -> Bool) ->
  List String ->
  List String ->
  ProjectRule ->
  Bool
projectActiveWith declares only disable r =
  declares r.meta && projectRuleActive only disable r

-- The roots of the projects the linted `paths` belong to: the nearest
-- `medaka.toml` above each file, or the file's own directory when none is
-- above it, so a run never indexes the working directory it happens to start
-- in.
projectRootsOf : List String -> <IO> List String
projectRootsOf paths = nub (map projectRootOfPath paths)

projectRootOfPath : String -> <IO> String
projectRootOfPath path = findProjectRootOrSelf (dirOf (canonicalizePath path))

anyPathWild : List String -> <IO> Bool
anyPathWild [] = False
anyPathWild (p :: rest) =
  sourceHasWildImport (readFileSafe p) || anyPathWild rest

-- Whether a rule whose guards read the index for wildcard imports is active.
export
wildIndexNeeded : List String -> List String -> Bool
wildIndexNeeded only disable =
  anyList (ruleNeedsWildIndex only disable) allRules

ruleNeedsWildIndex : List String -> List String -> Rule -> Bool
ruleNeedsWildIndex only disable r =
  needsWildIndex r.meta
    && (isEmptyL only || contains r.name only)
    && not (contains r.name disable)

-- Whether some line of `src` looks like an `import m.*`; a superset of the
-- parsed wildcard imports, so a false positive costs only an index build.
export
sourceHasWildImport : String -> Bool
sourceHasWildImport src = anyList isWildImportLine (splitNl src)

isWildImportLine : String -> Bool
isWildImportLine l = startsWith "import " l && isSome (indexOf ".*" l)

ruleNeedsScopes : Rule -> Bool
ruleNeedsScopes r = needsScopes r.meta

ruleNeedsIndex : List String -> List String -> Rule -> Bool
ruleNeedsIndex only disable r =
  needsStdlibIndex r.meta
    && (isEmptyL only || contains r.name only)
    && not (contains r.name disable)

-- The stdlib's rows as an index, from the per-file row shards where they answer
-- for the file's current content and from a parse where they do not.  Every
-- failure to read the stdlib degrades to an empty or partial index (see
-- `StdlibIndex`); only a stdlib file that does not PARSE is an error.
export
buildStdlibIndexResult : <IO> Result StdlibIndexError StdlibIndex
buildStdlibIndexResult =
  buildStdlibIndexResultIn lintStdlibDir (stdlibShardDir ())

export
buildStdlibIndexResultIn : String ->
  String ->
  <IO> Result StdlibIndexError StdlibIndex
buildStdlibIndexResultIn sdir shardDir =
  map
    ((digests, rows) => mkStdlibIndex (combineDigests digests) "" rows [])
    (stdlibRowsResult sdir shardDir)

-- The stdlib's rows plus the rows of every `.mdk` file under `root`.
export
buildProjectIndexResult : String -> <IO> Result StdlibIndexError StdlibIndex
buildProjectIndexResult root =
  buildProjectIndexResultIn lintStdlibDir (stdlibShardDir ()) root

export
buildProjectIndexResultIn : String ->
  String ->
  String ->
  <IO> Result StdlibIndexError StdlibIndex
buildProjectIndexResultIn sdir shardDir root =
  buildProjectIndexResultRootsIn sdir shardDir [root]

-- The stdlib's rows plus the rows of every `.mdk` file under each of `roots`,
-- module ids relative to the root the file was found under.
export
buildProjectIndexResultRootsIn : String ->
  String ->
  List String ->
  <IO> Result StdlibIndexError StdlibIndex
buildProjectIndexResultRootsIn sdir shardDir roots =
  let (pdigests, prows) = projectRowsOfRoots roots
  map
    ((sdigests, srows) =>
      mkStdlibIndex
        (combineDigests sdigests)
        (combineDigests pdigests)
        srows
        prows)
    (stdlibRowsResult sdir shardDir)

-- The shard stamp: the build fingerprint, or the binary's own hash for a
-- binary that carries none (a shipped or `medaka build` binary).  Empty when
-- neither can be had, which turns the cache off for the run.
indexStamp : Unit -> <IO> String
indexStamp _ =
  let fp = buildFingerprint ()
  if fp == "" then ruleSetStamp () else fp

stdlibRowsResult : String ->
  String ->
  <IO> Result StdlibIndexError (List String, List IndexRow)
stdlibRowsResult sdir shardDir = match stdlibMemberPaths sdir
  None => Ok ([], [])
  Some rels =>
    let stamp = indexStamp ()
    let dir = if stamp == "" then "" else shardDir
    stdlibRowsGo dir stamp sdir rels

stdlibRowsGo : String ->
  String ->
  String ->
  List String ->
  <IO> Result StdlibIndexError (List String, List IndexRow)
stdlibRowsGo _ _ _ [] = Ok ([], [])
stdlibRowsGo dir stamp sdir (rel :: rest) =
  let path = "\{sdir}/\{rel}"
  let modId = joinWith "." (splitOnChar '/' (stripMdk rel))
  match fileRows True lintParseSource dir stamp modId path
    Err (src, e) => Err StdlibIndexError {
      path = path,
      source = src,
      diagnostic = parseErrDiag path e,
    }
    Ok (digest, rows) =>
      map
        ((ds, rs) => (digest :: ds, rows ++ rs))
        (stdlibRowsGo dir stamp sdir rest)

-- A project file that does not parse has no rows: the lint pass over that file
-- reports the parse error, and the index abstains on what it cannot read.
projectRowsOfRoots : List String -> <IO> (List String, List IndexRow)
projectRowsOfRoots roots =
  let perRoot = map projectRowsOf roots
  (flatMap fst perRoot, flatMap snd perRoot)

projectRowsOf : String -> <IO> (List String, List IndexRow)
projectRowsOf root =
  let stamp = indexStamp ()
  let dir = if stamp == "" then "" else projectShardDir root
  let files = map (projectFileRows dir stamp root) (collectMdkFiles root)
  (map fst files, flatMap snd files)

projectFileRows : String ->
  String ->
  String ->
  String ->
  <IO> (String, List IndexRow)
projectFileRows dir stamp root path =
  match (fileRows
    False
    lintParseSource
    dir
    stamp
    (moduleIdOfPath [root] path)
    path)
    Err _ => ("", [])
    Ok (digest, rows) => (digest, rows)

-- `<MEDAKA_ROOT>/stdlib`, resolved exactly as the CLI resolves it (`envOr
-- "MEDAKA_ROOT" defaultMedakaRoot`, `driver/build_cmd.mdk`) — an unset or empty
-- var falls back to the running executable's own directory, so a relocated
-- `medaka` still finds its stdlib.  Restated locally rather than imported so the
-- lint graph — and with it `entries/lint_main.mdk`, the gate oracle — does not
-- pull in `driver/build_cmd.mdk`.  Same reason `tools/lsp.mdk` keeps its own.
lintStdlibDir : <IO> String
lintStdlibDir = match getEnv "MEDAKA_ROOT"
  Some v => if v == "" then exeStdlibDir () else "\{v}/stdlib"
  None => exeStdlibDir ()

exeStdlibDir : Unit -> <IO> String
exeStdlibDir _ = "\{dirOf (executablePath ())}/stdlib"

-- ── what a cached finding that read the index depends on ──────────────────────
-- A shard holds two finding groups.  The index-free rules' findings are keyed by
-- the binary alone.  The index-reading rules' findings are also keyed by what
-- the file's rules asked of the index, each question with a digest of its
-- answer (`lint_index.recording`), so an edit to a declaration re-runs those
-- rules for the files that asked about it and for no other.  The fingerprint of
-- every row the run's index was built from (`indexKeyFor`) is stored beside the
-- answers: while it is unchanged no question is asked again, since no answer
-- can have moved.  A roster that reads no index has no such key, so an index
-- edit never invalidates its shards.

-- Whether some rule of `roster` reads the index.
export
rosterNeeds : List Rule -> Bool
rosterNeeds roster = anyList ruleReadsIndex roster

ruleReadsIndex : Rule -> Bool
ruleReadsIndex r = readsIndex r.meta

-- The roster's index-reading rules with their ranks.
export
rankedIndexRules : List Rule -> List (Int, Rule)
rankedIndexRules roster =
  filterList (rf => ruleReadsIndex (snd rf)) (ranked 0 roster)

-- A roster's findings, ranked, split into those of the index-free rules and
-- those of the index-reading rules.
export
splitByIndex : List Rule ->
  List (Int, Finding) ->
  (List (Int, Finding), List (Int, Finding))
splitByIndex roster found =
  let indexRanks = map fst (rankedIndexRules roster)
  (
    filterList (rf => not (elem (fst rf) indexRanks)) found,
    filterList (rf => elem (fst rf) indexRanks) found,
  )

-- The fingerprint an index-reading finding group is stored under for `roster`.
export
indexKeyFor : List Rule -> StdlibIndex -> String
indexKeyFor = indexKeyWith stdlibIndexFingerprint

-- `indexKeyFor` with the index fingerprint taken from `fingerprintOf`.  The
-- soundness tests pass a constant to show a stale hit without the fingerprint;
-- every production call goes through `indexKeyFor`.
export
indexKeyWith : (StdlibIndex -> String) -> List Rule -> StdlibIndex -> String
indexKeyWith fingerprintOf roster idx =
  if rosterNeeds roster then fingerprintOf idx else ""

export
lintParseSource : String -> Result ParseError (List Decl, Positions)
lintParseSource src =
  let (tokens, offsets) = tokenizeWithOffsetPairs src
  match prescanErrorPairs src tokens offsets
    Some e => Err e
    None =>
      let _ = stageBump "parse.positions"
      match parseWithPositionsOptPairs src tokens offsets
        Some parsed => Ok parsed
        None =>
          map
            (_ => parseWithPositions src)
            (parseResultPairs src tokens offsets)

-- The `.mdk` members under `dir` as `dir`-relative paths (`list.mdk`,
-- `crypto/hmac.mdk`), dot-entries dropped, sorted for determinism.  `None`
-- when `dir` itself will not list.
stdlibMemberPaths : String -> <IO> Option (List String)
stdlibMemberPaths dir = match listDir dir
  Err _ => None
  Ok entries => Some (sortUniqS (memberPathsGo dir "" entries))

memberPathsGo : String -> String -> List String -> <IO> List String
memberPathsGo _ _ [] = []
memberPathsGo dir prefix (n :: rest) =
  let here =
    if startsWith "." n then
      []
    else if endsWith ".mdk" n then
      ["\{prefix}\{n}"]
    else match listDir "\{dir}/\{prefix}\{n}"
      Err _ => []
      Ok sub => memberPathsGo dir "\{prefix}\{n}/" sub
  here ++ memberPathsGo dir prefix rest

-- The (rule, line) of every finding of `rules` that no inline directive
-- suppresses.  A decl fixer runs only where its rule has one of these on the
-- decl's lines: a directive says the shape is deliberate.
liveFindingLines : String ->
  FileFacts ->
  List Rule ->
  Positions ->
  List Decl ->
  List (String, Int)
liveFindingLines src facts rules pos prog =
  flatMap
    findingRuleLine
    (applySuppressions
      src
      (lintProgramFacts emptyStdlibIndex rules "" facts pos prog))

findingRuleLine : Finding -> List (String, Int)
findingRuleLine f = match f.loc
  Some (Loc _ line _ _ _) => [(f.rule, line)]
  None => []

-- Whether `r` has a live finding on the lines `[s, e]`.
ruleLiveIn : List (String, Int) -> (Int, Int) -> Rule -> Bool
ruleLiveIn live (s, e) r =
  anyList (p => fst p == r.name && s <= snd p && snd p <= e) live

-- ── autofix driver (Task A3) ───────────────────────────────────────────────────
-- The CLI calls this for `--fix`, passing only plain data (the
-- `--only`/`--disable` name lists, the source text, the parsed decls +
-- `Positions`) and getting plain data back.
--
-- Algorithm: for each decl, the first active fixable rule whose fixer applies
-- yields `Some replacementDecls`; we render those via the printer and record a
-- splice over the decl's own source line range (`DeclPos` start..end).  Splices
-- are applied bottom-up (descending start line) so earlier line numbers stay
-- valid.  Returns `(rewrittenSource, fixedCount)`; unchanged source if no fix.
export
applyFixes : List String ->
  List String ->
  String ->
  List Decl ->
  Positions ->
  (String, Int)
applyFixes only disable src prog pos =
  let rules = filterList (ruleActiveFixable only disable) allRules
  let orc = buildOracle prog
  let cmts = collectComments src
  let cmtLines = map commentLine cmts
  let declPos = zipDeclPos prog (positionsDecls pos)
  let allFacts = mkFileFacts src prog pos
  let facts = if anyList ruleNeedsScopes rules then Some allFacts else None
  let live = liveFindingLines src allFacts rules pos prog
  let tagged = collectSplices facts live cmtLines orc rules declPos
  let (kept, widen) = reconcileTestImport cmts declPos tagged
  (applySplices src (withWiden widen kept), listLen kept)

withWiden : Option (Int, Int, String) ->
  List (Int, Int, String) ->
  List (Int, Int, String)
withWiden None splices = splices
withWiden (Some sp) splices = insertSpliceAsc sp splices

-- The `stdlib/test.mdk` verbs a fixer can introduce.  Every other name a fixer
-- emits is prelude-global.
testVerbNames : List String
testVerbNames = ["expectEqual", "expectNotEqual", "expectTrue", "expectFalse"]

-- How many times a `test` verb is called.
data VerbCount = VerbCount { verbName : String, verbUses : Int }

-- The verbs a rewrite stops calling and the verbs it starts calling more.
data VerbDelta = VerbDelta { stopped : List String, started : List String }

-- How many times each `test` verb is called in a decl list, read off the AST
-- (never the rendered text, where a string literal could name a verb).
testVerbCounts : List Decl -> List VerbCount
testVerbCounts ds =
  let refs = flatMap declRefs ds
  map
    (v =>
      VerbCount { verbName = v, verbUses = listLen (filterList (== v) refs) })
    testVerbNames

-- The verbs a rewrite stops calling, and the verbs it starts calling more.  A
-- verb the declaration already mentions for another reason (a parameter named
-- `expectTrue`) is still introduced when the rewrite adds a call to it.
testVerbDelta : Decl -> List Decl -> VerbDelta
testVerbDelta d newDecls =
  let before = testVerbCounts [d]
  let after = testVerbCounts newDecls
  let moved = filterList (c => verbUsesIn c.verbName after /= c.verbUses) before
  VerbDelta {
    stopped =
      map
        verbOf
        (filterList (c => verbUsesIn c.verbName after < c.verbUses) moved),
    started =
      map
        verbOf
        (filterList (c => verbUsesIn c.verbName after > c.verbUses) moved),
  }

verbOf : VerbCount -> String
verbOf c = c.verbName

verbUsesIn : String -> List VerbCount -> Int
verbUsesIn v cs = match find (c => c.verbName == v) cs
  Some c => c.verbUses
  None => 0

-- A fix whose rewrite touches a `test` verb is applied only when every use of a
-- verb it matched, within the declaration, resolves to that verb's `import
-- test.{…}` member under its own name (or is unresolved while the file has
-- `import test.*`), and no binder that is not the same `test` verb captures a
-- verb it introduces: neither a file-level one nor a local one inside the
-- declaration.  Matching `expectEqual` by name alone would otherwise rewrite a
-- file's own `expectEqual` into a call to a verb that file never imported, and
-- introducing a name the file already binds would silently call that binding
-- instead.  A fix that touches a verb under a rule that declares no `NeedsScopes`
-- is refused: nothing says its verb is `test`'s.
testFixAllowed : Option FileFacts ->
  (Int, Int) ->
  List String ->
  List String ->
  Bool
testFixAllowed _ _ _ [] = True
testFixAllowed None _ _ _ = False
testFixAllowed (Some facts) (from, to) matched introduced =
  let fs = factScopes facts
  isNonEmptyL matched
    && allList (matchedIsTestVerb fs from to) matched
    && allList (introducedIsFree fs from to) introduced

matchedIsTestVerb : FileScopes -> Int -> Int -> String -> Bool
matchedIsTestVerb fs from to verb =
  let uses = usesNamedIn fs from to verb
  isNonEmptyL uses && allList (useIsTestVerb fs verb) uses

useIsTestVerb : FileScopes -> String -> Use -> Bool
useIsTestVerb fs verb u = match u.useBinder
  Some b => isTestMember verb b
  None => elem ["test"] (wildImports fs)

-- The binder is the `import test.{verb}` member, not an alias or another module's.
isTestMember : String -> Binder -> Bool
isTestMember verb b =
  b.binderKind == BImport && b.binderFrom == ["test"] && b.binderOrigin == verb

introducedIsFree : FileScopes -> Int -> Int -> String -> Bool
introducedIsFree fs from to verb =
  isEmptyL (bindersNamedIn fs from to verb)
    && isEmptyL (filterList unplacedBinder (bindersNamed fs verb))
    && allList (== ["test"]) (wildImports fs)
    && allList (isTestMember verb) (filterList fileLevel (bindersNamed fs verb))

-- A binder the parser built from an expression (lambda parameter, guard-bind,
-- do-bind) has no source line, so no declaration's line range can place it:
-- it counts as in scope everywhere.
unplacedBinder : Binder -> Bool
unplacedBinder b = match b.binderSpan
  Loc _ 0 _ _ _ => True
  _ => False

fileLevel : Binder -> Bool
fileLevel b = match b.binderKind
  BImport => True
  BTopLevel => True
  BLetGroup => True
  _ => False

-- A fix that introduces a call to a `test` verb must leave the file's
-- `import test.{…}` list naming it, or the next `check` fails with an unbound
-- variable.  Returns the splices to apply plus the (zero or one) splice that
-- widens the import.  A fix whose verb is missing from every `import test.{…}`
-- group is kept only when some group can be widened without losing a comment:
-- otherwise it is dropped and stays a finding.  `import test.*` already binds
-- the verbs, so that file is untouched here.  A bare or aliased `import test`,
-- or no import at all, never bound the matched verb, so `testFixAllowed` has
-- already dropped every fix in such a file.
reconcileTestImport : List Comment ->
  List (Decl, DeclPos) ->
  List ((Int, Int, String), List String) ->
  (List (Int, Int, String), Option (Int, Int, String))
reconcileTestImport cmts declPos tagged =
  let groups = testGroups declPos
  let listed = flatMap (g => map useMemberLocal (fst g)) groups
  let wild = anyList isTestWild (map fst declPos)
  if isEmptyL groups || wild then
    (map fst tagged, None)
  else
    let missingOf = verbs => filterList (v => not (contains v listed)) verbs
    let target = findWidenable cmts groups
    let kept =
      filterList (t => isEmptyL (missingOf (snd t)) || isSome target) tagged
    let missing = dedup (flatMap (t => missingOf (snd t)) kept)
    match target
      Some (pub, path, members, loc, dp, trailing) =>
        if isEmptyL missing then
          (map fst kept, None)
        else
          let widened =
            UseGroup
              path
              (members ++ map (v => UseMember v False loc None) missing)
          let txt = declToString (DUse pub widened loc) ++ trailing
          (map fst kept, Some (declPosLine dp, declPosEndLine dp, txt))
      None => (map fst kept, None)

isTestWild : Decl -> Bool
isTestWild (DUse _ (UseWild path) _) = path == ["test"]
isTestWild _ = False

testGroups : List (Decl, DeclPos) ->
  List (List UseMember, (Bool, List String, Loc, DeclPos))
testGroups [] = []
testGroups ((DUse pub (UseGroup path members) loc, dp) :: rest)
  | path == ["test"] = (members, (pub, path, loc, dp)) :: testGroups rest
testGroups (_ :: rest) = testGroups rest

-- The first `import test.{…}` group whose span holds no comment, or only a
-- `--` comment on its last line, which the rewritten import re-appends.
findWidenable : List Comment ->
  List (List UseMember, (Bool, List String, Loc, DeclPos)) ->
  Option (Bool, List String, List UseMember, Loc, DeclPos, String)
findWidenable _ [] = None
findWidenable cmts ((members, (pub, path, loc, dp)) :: rest) =
  match spanComments cmts (declPosLine dp) (declPosEndLine dp)
    [] => Some (pub, path, members, loc, dp, "")
    [c] =>
      if commentLine c == declPosEndLine dp
        && startsWith "--" (commentText c) then
        Some (pub, path, members, loc, dp, " " ++ commentText c)
      else
        findWidenable cmts rest
    _ => findWidenable cmts rest

spanComments : List Comment -> Int -> Int -> List Comment
spanComments cmts s e =
  filterList (c => s <= commentLine c && commentLine c <= e) cmts

insertSpliceAsc : (Int, Int, String) ->
  List (Int, Int, String) ->
  List (Int, Int, String)
insertSpliceAsc sp [] = [sp]
insertSpliceAsc (s, e, t) ((s2, e2, t2) :: rest)
  | s < s2 = (s, e, t) :: (s2, e2, t2) :: rest
  | otherwise = (s2, e2, t2) :: insertSpliceAsc (s, e, t) rest

-- a rule participates in `--fix` iff it is enabled, passes the --only/--disable
-- filters, AND carries a fixer.
ruleActiveFixable : List String -> List String -> Rule -> Bool
ruleActiveFixable only disable r =
  r.enabled
    && (isEmptyL only || contains r.name only)
    && not (contains r.name disable)
    && ruleHasFixer r

ruleHasFixer : Rule -> Bool
ruleHasFixer r = isSome r.fix

-- one (startLine, endLine, replacementText) per fixed decl, in source order.
--
-- COMMENT-LOSS SAFETY-NET (mirrors `medaka fmt`'s verbatim bail).  The printer
-- carries NO comments, so splicing printer output over a decl's `[startLine,
-- endLine]` span would silently DELETE any comment inside that span.  So before
-- emitting a splice we check `spanHasComment`: if the decl's span contains an
-- interior comment line we SKIP the fix (the rule still WARNS; the source is
-- left untouched).  A leading doc-comment ABOVE the decl is on a line
-- `< declPosLine` → outside the span → the fix is still allowed (no over-bail).
collectSplices : Option FileFacts ->
  List (String, Int) ->
  List Int ->
  Oracle ->
  List Rule ->
  List (Decl, DeclPos) ->
  List ((Int, Int, String), List String)
collectSplices _ _ _ _ _ [] = []
collectSplices facts live cmtLines orc rules ((d, dp) :: rest) =
  let liveRules =
    filterList (ruleLiveIn live (declPosLine dp, declPosEndLine dp)) rules
  match firstFix orc liveRules d
    Some newDecls =>
      let delta = testVerbDelta d newDecls
      if spanHasComment cmtLines (declPosLine dp) (declPosEndLine dp)
        || not
          (testFixAllowed
            facts
            (declPosLine dp, declPosEndLine dp)
            delta.stopped
            delta.started) then
        collectSplices facts live cmtLines orc rules rest
      else
        (
            (declPosLine dp, declPosEndLine dp, renderDecls newDecls),
            delta.started,
          )
          :: collectSplices facts live cmtLines orc rules rest
    None => collectSplices facts live cmtLines orc rules rest

-- True iff some comment line falls within the inclusive span `[startLine, endLine]`.
spanHasComment : List Int -> Int -> Int -> Bool
spanHasComment cmtLines startLine endLine =
  anyList (l => startLine <= l && l <= endLine) cmtLines

firstFix : Oracle -> List Rule -> Decl -> Option (List Decl)
firstFix _ [] _ = None
firstFix orc (r :: rs) d = match applyRuleFix orc r d
  Some newDecls => Some newDecls
  None => firstFix orc rs d

applyRuleFix : Oracle -> Rule -> Decl -> Option (List Decl)
applyRuleFix orc r d = match r.fix
  Some f => f orc d
  None => None

-- render replacement decls, one per line (printer emits a single decl, no NL).
renderDecls : List Decl -> String
renderDecls ds = joinNl (map declToString ds)

-- apply splices to the source.  `collectSplices` yields them ascending by start
-- line; reversing → descending so each edit leaves lower line numbers valid.
applySplices : String -> List (Int, Int, String) -> String
applySplices src splices = joinNl (foldSplices (splitNl src) (reverseL splices))

foldSplices : List String -> List (Int, Int, String) -> List String
foldSplices lines [] = lines
foldSplices lines ((s, e, txt) :: rest) =
  foldSplices (spliceLines lines s e txt) rest

-- replace the 1-based inclusive line range [s..e] with `txt`'s own lines.
spliceLines : List String -> Int -> Int -> String -> List String
spliceLines lines s e txt = take (s - 1) lines ++ splitNl txt ++ drop e lines

-- ── CLI-flag-style finding filters ────────────────────────────────────────────
-- `--disable`/`--only`/`--deny` (and the `medaka_lint` MCP tool's `disable`/
-- `only`/`deny` args) all filter a `List Finding` by rule name, entirely in
-- terms of `Finding.rule` — no `Rule`-record field access, so these are safe
-- to run from any caller.  Shared by `medaka_cli.mdk` (the `medaka lint` CLI,
-- both human and `--json` modes) and `mcp.mdk` (`medaka_lint`) so the two
-- surfaces can never apply the flags differently.

-- Parse --prefix=v1,v2,... from argv; returns [] if not present.
export
parseLintFlagList : String -> List String -> List String
parseLintFlagList prefix [] = []
parseLintFlagList prefix (x :: rest)
  | startsWith prefix x =
    splitLintNames (stringSlice (stringLength prefix) (stringLength x) x)
  | otherwise = parseLintFlagList prefix rest

-- Split a comma-separated string.  Uses literal ',' to avoid Char-param issues.
-- Exported so a caller with an already-split comma-separated value in hand
-- (rather than a raw `--flag=v1,v2` argv token) — e.g. the `medaka_lint` MCP
-- tool's `deny`/`only`/`disable` args — can reuse the exact same splitter
-- `parseLintFlagList` uses, instead of re-deriving comma-splitting.  NOTE:
-- `splitLintNames ""` returns `[""]`, not `[]` — callers with an optional,
-- possibly-absent value should special-case the empty string themselves
-- (see mcp.mdk's `lintNameListArg`).
export
splitLintNames : String -> List String
splitLintNames s = splitLintNamesGo (stringToChars s) s 0 0 (stringLength s)

splitLintNamesGo : Array Char -> String -> Int -> Int -> Int -> List String
splitLintNamesGo chars s start i n
  | i >= n = [stringSlice start n s]
  | arrayGetUnsafe i chars == ',' =
    stringSlice start i s :: splitLintNamesGo chars s (i + 1) (i + 1) n
  | otherwise = splitLintNamesGo chars s start (i + 1) n

-- Apply finding-level filters.  Operates on Finding.rule (a String) so no
-- Rule-record field access is needed by the caller.
export
applyFindingFilters : List String ->
  List String ->
  List String ->
  List Finding ->
  List Finding
applyFindingFilters disable only deny findings =
  let after1 = applyFindingOnly only findings
  let after2 = applyFindingDisable disable after1
  applyFindingDeny deny after2

-- --only: keep findings whose rule is in the list (no-op when empty).
applyFindingOnly : List String -> List Finding -> List Finding
applyFindingOnly [] findings = findings
applyFindingOnly names findings = lintFindingOnlyGo names findings

lintFindingOnlyGo : List String -> List Finding -> List Finding
lintFindingOnlyGo _ [] = []
lintFindingOnlyGo names (f :: rest)
  | contains f.rule names = f :: lintFindingOnlyGo names rest
  | otherwise = lintFindingOnlyGo names rest

-- --disable: remove findings whose rule is in the list (no-op when empty).
applyFindingDisable : List String -> List Finding -> List Finding
applyFindingDisable [] findings = findings
applyFindingDisable names findings = lintFindingDisableGo names findings

lintFindingDisableGo : List String -> List Finding -> List Finding
lintFindingDisableGo _ [] = []
lintFindingDisableGo names (f :: rest)
  | contains f.rule names = lintFindingDisableGo names rest
  | otherwise = f :: lintFindingDisableGo names rest

-- --deny: promote findings to SevError when their rule is in the list.
export
applyFindingDeny : List String -> List Finding -> List Finding
applyFindingDeny [] findings = findings
applyFindingDeny names findings = lintFindingDenyGo names findings

lintFindingDenyGo : List String -> List Finding -> List Finding
lintFindingDenyGo _ [] = []
lintFindingDenyGo names (f :: rest)
  | contains f.rule names =
    Finding {
        rule = f.rule,
        message = f.message,
        severity = SevError,
        loc = f.loc,
        fix = f.fix,
      }
      :: lintFindingDenyGo names rest
  | otherwise = f :: lintFindingDenyGo names rest

export
isFindingError : Finding -> Bool
isFindingError f = match f.severity
  SevError => True
  SevWarning => False

-- ── rendering ─────────────────────────────────────────────────────────────────

export
findingToDiag : Finding -> Diag
findingToDiag f =
  Diag
    f.severity
    (LintRule f.rule)
    "[\{f.rule}] \{f.message}"
    f.loc
    None
    (map fixToDiagFix f.fix)

-- Run the full lint pipeline (all rules, inline `-- lint-disable-*` suppression,
-- then the `--disable`/`--only`/`--deny` CLI-flag-style filters) over ONE file
-- and return `(path, src, List Diag, Positions, List Decl)` — the per-file
-- triple `driver.diagnostics.cjAllToJson` expects, PLUS the parse the
-- project-rule tier (`runProjectRules`) summarizes.
-- Shared by `medaka lint --json` (medaka_cli.mdk) and the `medaka_lint` MCP
-- tool (mcp.mdk) so both surfaces serialize through the SAME envelope
-- `check --json` uses, with the lint rule name landing in each diagnostic's
-- `code` (via `findingToDiag`).  Uses `readFileSafe` (the same ""-on-read-error
-- helper `checkJsonFile` uses), so an unreadable path parses as empty source
-- and yields `(path, "", [], <positions of "">, [])` — total, no crash, and
-- consistent with `check --json`'s own file-variant behaviour on a missing
-- target. A `Finding` at a nested sub-expression (`exprRuleVisitors`)
-- carries THAT expression's own location,
-- not the enclosing decl's.
-- `idx` is the stdlib reference index.  It is a PARAMETER rather than something
-- this function builds, because both callers (`medaka lint --json`'s
-- `runLintJsonCmd` and `mcp.mdk`'s `medaka_lint`) sequence this over a LIST of
-- paths — building the index here would re-parse the whole stdlib once per
-- target file instead of once per process.
export
lintFileDiagTripleParsed : StdlibIndex ->
  List String ->
  List String ->
  List String ->
  String ->
  <IO> (String, String, List Diag, Positions, List Decl)
lintFileDiagTripleParsed idx disable only deny path =
  let src = readFileSafe path
  match lintParseSource src
    Err e => (path, src, [parseErrDiag path e], Positions [] [] 0 [], [])
    Ok (decls, pos) =>
      let facts = mkFileFactsAt path src decls pos
      let allFindings =
        applySuppressionsDirs
          (factDirectives facts)
          (lintProgramFacts idx (selectRules only disable) path facts pos decls)
      let findings = applyFindingFilters disable only deny allFindings
      (
        path,
        src,
        map findingToDiag (demoteOverComments path src findings),
        pos,
        decls,
      )

-- `lintFileDiagTripleParsed`, dropping the parse — the shape every existing
-- caller that does not need the project-rule tier's inputs still wants.
export
lintFileDiagTriple : StdlibIndex ->
  List String ->
  List String ->
  List String ->
  String ->
  <IO> (String, String, List Diag)
lintFileDiagTriple idx disable only deny path =
  dropParsedTriple (lintFileDiagTripleParsed idx disable only deny path)

dropParsedTriple : (String, String, List Diag, Positions, List Decl) ->
  (String, String, List Diag)
dropParsedTriple (path, src, diags, _, _) = (path, src, diags)

-- One finding per line: `<severity>: [<rule>] <message>` (location-stripped, the
-- golden harness sorts).  Mirror of exhaust.mdk's `exhaustToLines`.  `src` is the
-- raw source text: findings are produced by `lintProgram`, then filtered through
-- the inline-suppression directives (`-- lint-disable-*`) recovered from `src`'s
-- comment side channel (see `applySuppressions`).
-- `idx` is the stdlib reference index, built by the caller
-- (`entries/lint_main.mdk` — THE gate oracle — builds a real one, so the gate
-- and the CLI see the same rule inputs).
export
lintToLines : StdlibIndex ->
  String ->
  String ->
  Positions ->
  List Decl ->
  String
lintToLines idx src path pos prog =
  joinNl
    (map
      findingLine
      (applySuppressions src (lintProgram idx allRules path src pos prog)))

findingLine : Finding -> String
findingLine f = "\{ppSeverity f.severity}: [\{f.rule}] \{f.message}"

-- ── inline suppression directives (ESLint-style) ──────────────────────────────
-- A finding can be silenced by a `--` line comment whose trimmed body starts
-- with one of these directive keywords (chosen to MIRROR ESLint's
-- `eslint-disable-*` family; keep them exactly unless there's a strong reason):
--
--   `-- lint-disable-next-line [rules]`  suppress findings on the NEXT source line
--   `-- lint-disable-line      [rules]`  suppress findings on THIS comment's line
--   `-- lint-disable-file      [rules]`  suppress the rules ANYWHERE in the file
--
-- With NO rule names the directive applies to ALL rules; otherwise it lists rule
-- ids (comma- and/or space-separated, e.g. `rule-match-on-param, rule-stdlib-reimpl`)
-- matched against a Finding's `rule` field.  Unknown rule names are harmless
-- no-ops.  A finding at line L with rule R is suppressed iff SOME directive both
-- covers R (its rule set is empty or contains R) and whose scope includes L.
--
-- SEAM.  Comments are stripped by the lexer before layout, so the parser never
-- sees them and no rule can observe a directive.  Instead findings are produced
-- FIRST by `lintProgram`, then FILTERED here using the lexer's out-of-band
-- comment side channel (`collectComments src`).  The two lint entry points
-- (`compiler/driver/medaka_cli.mdk` report arm + this module's `lintToLines`,
-- used by `compiler/entries/lint_main.mdk`) call `applySuppressions src findings`
-- right after `lintProgram`.  A finding's line comes from its `loc` (the decl's
-- start line, stamped by `declLocList`); a finding without a `loc` can only be
-- silenced by a whole-file directive.

-- Filter out every finding covered by an inline-suppression directive found in
-- the source's comment side channel.
export
applySuppressions : String -> List Finding -> List Finding
applySuppressions src findings =
  applySuppressionsDirs (directivesOfSource src) findings

-- The same filter, but taking the file's ALREADY-PARSED directives instead of
-- re-deriving them from source.  `--cache` (#395) stores a file's directives in
-- its shard, so a cache hit has them in hand and must not re-run
-- `collectDirectives` (which re-lexes the file — the very cost the cache
-- exists to skip).  `applySuppressions` is this function plus the parse, so the
-- cached and uncached paths share ONE suppression implementation and cannot
-- drift apart.
export
applySuppressionsDirs : List Directive -> List Finding -> List Finding
applySuppressionsDirs dirs findings =
  filterList (f => not (isSuppressed dirs f)) findings

-- Project-rule variant: findings anchor to DIFFERENT files, so a single `src`
-- cannot cover them.  Given each file's source (`(path, src)`), silence every
-- finding covered by an inline directive in ITS OWN file's comment side channel.
-- Directives are parsed once per file (not per finding).  General over any
-- project rule; the project-rule report path calls this before flag filters.
export
applySuppressionsMulti : List (String, String) -> List Finding -> List Finding
applySuppressionsMulti srcs findings =
  applySuppressionsMultiDirs (map fileDirectivesOf srcs) findings

-- Pre-parsed-directive counterpart of `applySuppressionsMulti`, for the same
-- reason `applySuppressionsDirs` exists: a `--cache` run already holds every
-- file's directives and must not re-lex to recover them.
export
applySuppressionsMultiDirs : List (String, List Directive) ->
  List Finding ->
  List Finding
applySuppressionsMultiDirs dirTable findings =
  let table = dirTableMap dirTable
  filterList (f => not (findingSuppressedMulti table f)) findings

-- First row per path wins, as the list scan it replaces did.
dirTableMap : List (String, List Directive) -> HashMap String (List Directive)
dirTableMap rows =
  let m = new ()
  let _ = dirTableFill m rows
  m

dirTableFill : HashMap String (List Directive) ->
  List (String, List Directive) ->
  Unit
dirTableFill _ [] = ()
dirTableFill m ((p, ds) :: rest) =
  let _ = if has p m then () else setInPlace p ds m
  dirTableFill m rest

fileDirectivesOf : (String, String) -> (String, List Directive)
fileDirectivesOf (path, src) = (path, directivesOfSource src)

findingSuppressedMulti : HashMap String (List Directive) -> Finding -> Bool
findingSuppressedMulti dirTable f = match get (findingFileOf f) dirTable
  None => False
  Some dirs => isSuppressed dirs f

findingFileOf : Finding -> String
findingFileOf f = match f.loc
  Some (Loc file _ _ _ _) => file
  None => ""

directivesOfSource : String -> List Directive
directivesOfSource src = collectDirectives (collectComments src)

isSuppressed : List Directive -> Finding -> Bool
isSuppressed dirs f = anyList (dirCoversFinding f) dirs

dirCoversFinding : Finding -> Directive -> Bool
dirCoversFinding f (Directive scope names) =
  (isEmptyL names || contains f.rule names)
    && scopeMatches (findingLineNo f) scope

scopeMatches : Option Int -> DirScope -> Bool
scopeMatches _ DScopeFile = True
scopeMatches (Some line) (DScopeLine l) = line == l
scopeMatches None (DScopeLine _) = False

findingLineNo : Finding -> Option Int
findingLineNo f = map ((Loc _ l _ _ _) => l) f.loc

-- ── project-rule runner ───────────────────────────────────────────────────────
-- A project rule's findings relate files, so they come from the rule's
-- `prEvaluate` over every file's summary, on every run.  What a shard stores is
-- the summary, which is a function of one file; the findings are never stored.
-- --only/--disable gate the rules the same way they gate per-file rules.
-- --deny promotion is left to the CLI (which already owns it for per-file
-- findings).

-- The summaries of one file under every selected project rule, `(rule name,
-- summary)`, in registry order.
export
fileSummaries : List String ->
  List String ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List (String, Summary)
fileSummaries only disable path facts pos prog =
  map
    (r => ((r : ProjectRule).name, r.prSummarize path facts pos prog))
    (filterList (projectRuleActive only disable) allProjectRules)

-- Every active project rule over `files`, each `(path, that file's summaries)`.
-- A rule sees only the summaries it made.
export
runProjectRules : List String ->
  List String ->
  StdlibIndex ->
  List (String, List (String, Summary)) ->
  List Finding
runProjectRules only disable idx files =
  runProjectRulesOver allProjectRules only disable idx files

-- `runProjectRules` over a given roster.
export
runProjectRulesOver : List ProjectRule ->
  List String ->
  List String ->
  StdlibIndex ->
  List (String, List (String, Summary)) ->
  List Finding
runProjectRulesOver rules only disable idx files =
  flatMap (runProjectRuleOn only disable idx files) rules

runProjectRuleOn : List String ->
  List String ->
  StdlibIndex ->
  List (String, List (String, Summary)) ->
  ProjectRule ->
  List Finding
runProjectRuleOn only disable idx files r
  | projectRuleActive only disable r =
    map
      (restampSeverity r.severity)
      (r.prEvaluate (projectIndexFor r idx) (summariesOfRule r.name files))
  | otherwise = []

-- The index a project rule's `prEvaluate` is handed, by the same declared-need
-- rule a per-file rule's is.
projectIndexFor : ProjectRule -> StdlibIndex -> ProjectIndex
projectIndexFor r idx =
  if readsIndex r.meta then projectIndexOf idx else emptyProjectIndex

summariesOfRule : String ->
  List (String, List (String, Summary)) ->
  List (String, Summary)
summariesOfRule _ [] = []
summariesOfRule name ((path, ss) :: rest) =
  map (s => (path, snd s)) (filterList (s => fst s == name) ss)
    ++ summariesOfRule name rest

-- Fold project-rule findings into the per-file `(path, src, List Diag)` triples
-- the JSON envelope (`cjAllToJson`) and the `medaka_lint` MCP tool both
-- serialize.  Each `Finding` already carries ITS OWN occurrence's file in
-- `loc` (`emitDupGroup` emits one finding per occurrence), so a finding is
-- appended to the triple whose path matches that file — never aggregated
-- under a new key.  A finding whose file is not already among `triples`
-- would get a synthesized `(file, "", [diag])` entry appended instead of
-- being dropped — a defensive fallback, structurally unreachable from both
-- of today's call sites, since each builds `triples` from exactly the same
-- file list it hands to `runProjectRules`, so every finding's file is
-- already present.  Kept for the day a caller passes a narrower path set
-- than its project rules run over.  A `Finding` with no `loc` (only the
-- project-rule shape used today always sets one) is skipped: there is no
-- file to attribute it to.
export
mergeProjectIntoTriples : List Finding ->
  List (String, String, List Diag) ->
  List (String, String, List Diag)
mergeProjectIntoTriples [] triples = triples
mergeProjectIntoTriples (f :: rest) triples =
  mergeProjectIntoTriples rest (mergeOneFinding f triples)

mergeOneFinding : Finding ->
  List (String, String, List Diag) ->
  List (String, String, List Diag)
mergeOneFinding f triples = match f.loc
  None => triples
  Some (Loc file _ _ _ _) =>
    if anyList (tripleHasPath file) triples then
      map (appendIfPath file (findingToDiag f)) triples
    else
      triples ++ [(file, "", [findingToDiag f])]

tripleHasPath : String -> (String, String, List Diag) -> Bool
tripleHasPath file (path, _, _) = path == file

appendIfPath : String ->
  Diag ->
  (String, String, List Diag) ->
  (String, String, List Diag)
appendIfPath file diag (path, src, diags) =
  if path == file then (path, src, diags ++ [diag]) else (path, src, diags)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Loc" true) (mem "Ty" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "Decl" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "Pat" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false) (mem "exprKind" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseResultPairs" false) (mem "parseWithPositionsOptPairs" false) (mem "prescanErrorPairs" false) (mem "ParseError" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false) (mem "fileOfModuleId" false) (mem "findProjectRootOrSelf" false) (mem "moduleIdOfPath" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" false) (mem "ProjectIndex" false) (mem "combineDigests" false) (mem "emptyProjectIndex" false) (mem "fileRows" false) (mem "stdlibShardDir" false) (mem "projectShardDir" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true) (mem "ppSeverity" false) (mem "readFileSafe" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false) (mem "stringTrim" false) (mem "isSome" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false) (mem "keys" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false) (mem "indexed" false) (mem "nub" false))))
(DUse false (UseGroup ("string") ((mem "indexOf" false) (mem "lines" false))))
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "stripMdk" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Ctx" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "Fixability" true) (mem "ProjectRule" true) (mem "Rule" true) (mem "RuleCheck" true) (mem "RuleMeta" false) (mem "StdlibIndex" true) (mem "Summary" false) (mem "StdlibIndexError" true) (mem "Visitor" true) (mem "factComments" false) (mem "fixToDiagFix" false) (mem "factDupClauses" false) (mem "factScopes" false) (mem "clampApplicability" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "memoNew" false) (mem "mkStdlibIndex" false) (mem "projectIndexOf" false) (mem "stdlibIndexFingerprint" false) (mem "stdlibLocalModAsked" false) (mem "withStdlibLocalMods" false) (mem "needsProjectIndex" false) (mem "needsScopes" false) (mem "needsStdlibIndex" false) (mem "needsWildIndex" false) (mem "readsIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "Use" true) (mem "bindersNamed" false) (mem "bindersNamedIn" false) (mem "buildScopes" false) (mem "usesNamedIn" false) (mem "wildImports" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false) (mem "declLocList" false) (mem "sortUniqS" false) (mem "zipDeclPos" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "demoteOverComments" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupClauseOfDecl" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "allProjectRules" false) (mem "allRules" false) (mem "projectRuleActive" false) (mem "selectRules" false))))
(DTypeSig true "mkFileFacts" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyCon "FileFacts")))))
(DFunDef false "mkFileFacts" ((PVar "src") (PVar "prog") (PVar "pos")) (ERecordCreate "FileFacts" ((fa "ffSrc" (EVar "src")) (fa "ffComments" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "collectComments") (EVar "src"))))) (fa "ffOracle" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildOracle") (EVar "prog"))))) (fa "ffDupClauses" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EVar "flatMap") (EVar "dupClauseOfDecl")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))) (fa "ffScopes" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildScopes") (EVar "prog"))))) (fa "ffLines" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "fromList") (EApp (EVar "lines") (EVar "src")))))) (fa "ffLocalMods" (EListLit)))))
(DTypeSig true "projectWildMods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "projectWildMods" ((PVar "path") (PVar "prog")) (EMatch (EApp (EVar "wildModsOf") (EVar "prog")) (arm (PList) () (EListLit)) (arm (PVar "wild") () (EApp (EApp (EVar "localModsIn") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "path")))) (EVar "wild")))))
(DTypeSig true "wildModsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wildModsOf" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EApp (EVar "joinWith") (ELit (LString ".")))) (EApp (EApp (EVar "flatMap") (EVar "wildPathsOf")) (EVar "prog")))))
(DTypeSig true "localModStates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))))
(DFunDef false "localModStates" (PWild (PList)) (EListLit))
(DFunDef false "localModStates" ((PVar "path") (PVar "mods")) (EBlock (DoLet false false (PVar "roots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "path")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "hasModuleFile") (EVar "roots")) (EVar "m"))))) (EVar "mods")))))
(DTypeSig false "localModsIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "localModsIn" (PWild (PList)) (EListLit))
(DFunDef false "localModsIn" ((PVar "roots") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "localModsIn") (EVar "roots")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "hasModuleFile") (EVar "roots")) (EVar "m")) (EBinOp "::" (EVar "m") (EVar "others")) (EVar "others")))))
(DTypeSig false "hasModuleFile" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "hasModuleFile" ((PList) PWild) (EVar "False"))
(DFunDef false "hasModuleFile" ((PCons (PVar "r") (PVar "rs")) (PVar "m")) (EBinOp "||" (EApp (EVar "fileExists") (EApp (EApp (EVar "fileOfModuleId") (EVar "r")) (EVar "m"))) (EApp (EApp (EVar "hasModuleFile") (EVar "rs")) (EVar "m"))))
(DTypeSig false "wildPathsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildPathsOf" ((PCon "DUse" PWild (PCon "UseWild" (PVar "p")) PWild)) (EListLit (EVar "p")))
(DFunDef false "wildPathsOf" (PWild) (EListLit))
(DTypeSig true "withLocalMods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FileFacts") (TyCon "FileFacts"))))
(DFunDef false "withLocalMods" ((PVar "mods") (PVar "ff")) (ERecordUpdate (EVar "ff") ((fa "ffLocalMods" (EVar "mods")))))
(DTypeSig true "mkFileFactsAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "FileFacts")))))))
(DFunDef false "mkFileFactsAt" ((PVar "path") (PVar "src") (PVar "prog") (PVar "pos")) (EApp (EApp (EVar "withLocalMods") (EApp (EApp (EVar "projectWildMods") (EVar "path")) (EVar "prog"))) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))))
(DTypeSig true "mkFileFactsIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyTuple (TyCon "StdlibIndex") (TyCon "FileFacts")))))))))
(DFunDef false "mkFileFactsIn" ((PVar "idx") (PVar "path") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "wild") (EApp (EVar "wildModsOf") (EVar "prog"))) (DoLet false false (PVar "idxHere") (EApp (EApp (EVar "withStdlibLocalMods") (EApp (EApp (EVar "localModStates") (EVar "path")) (EVar "wild"))) (EVar "idx"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "filterList") (EApp (EVar "stdlibLocalModAsked") (EVar "idxHere"))) (EVar "wild"))) (DoExpr (ETuple (EVar "idxHere") (EApp (EApp (EVar "withLocalMods") (EVar "local")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos")))))))
(DTypeSig true "factDirectives" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "factDirectives" ((PVar "ff")) (EApp (EVar "collectDirectives") (EApp (EVar "factComments") (EVar "ff"))))
(DTypeSig true "lintProgram" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgram" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (EVar "pos")) (EVar "prog")))
(DTypeSig true "lintProgramFacts" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgramFacts" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "rules"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))
(DTypeSig true "ranked" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))))))
(DFunDef false "ranked" (PWild (PList)) (EListLit))
(DFunDef false "ranked" ((PVar "i") (PCons (PVar "r") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EVar "r")) (EApp (EApp (EVar "ranked") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "lintProgramRanked" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "lintProgramRanked" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "enabled") (EApp (EApp (EVar "filterList") (EVar "rankedEnabled")) (EVar "rules"))) (DoLet false false (PVar "visitorSets") (EApp (EApp (EVar "flatMap") (ELam ((PVar "rf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleVisitors") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EApp (EVar "snd") (EVar "rf"))))) (EVar "enabled"))) (DoLet false false (PVar "walked") (EIf (EApp (EVar "isEmptyL") (EVar "visitorSets")) (EListLit) (EApp (EApp (EVar "runVisitors") (EVar "visitorSets")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "enabled")) (EVar "walked")))))
(DTypeSig false "rankedEnabled" (TyFun (TyTuple (TyCon "Int") (TyCon "Rule")) (TyCon "Bool")))
(DFunDef false "rankedEnabled" ((PTuple PWild (PVar "r"))) (EFieldAccess (EVar "r") "enabled"))
(DTypeSig false "ruleVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Visitor"))))))))))
(DFunDef false "ruleVisitors" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PVar "r")) (EMatch (EFieldAccess (EVar "r") "check") (arm (PCon "WholeFile" PWild) () (EListLit)) (arm (PCon "Visits" (PVar "visits")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "visits") (EApp (EApp (EVar "indexFor") (EVar "r")) (EVar "idx"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "indexFor" (TyFun (TyCon "Rule") (TyFun (TyCon "StdlibIndex") (TyCon "StdlibIndex"))))
(DFunDef false "indexFor" ((PVar "r") (PVar "idx")) (EIf (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")) (EVar "idx") (EVar "emptyStdlibIndex")))
(DTypeSig false "ruleFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "ruleFindings" (PWild PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "ruleFindings" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PCons (PTuple (PVar "rank") (PVar "r")) (PVar "rs")) (PVar "walked")) (EMatch (EFieldAccess (EVar "r") "check") (arm (PCon "WholeFile" (PVar "check")) () (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EVar "rank") (EApp (EApp (EVar "restampFinding") (EVar "r")) (EVar "f"))))) (EApp (EApp (EApp (EApp (EApp (EVar "check") (EApp (EApp (EVar "indexFor") (EVar "r")) (EVar "idx"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EVar "walked")))) (arm (PCon "Visits" PWild) () (EMatch (EVar "walked") (arm (PCons (PVar "hits") (PVar "rest")) () (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EVar "rank") (EApp (EApp (EVar "restampFinding") (EVar "r")) (EVar "f"))))) (EVar "hits")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EVar "rest")))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EListLit)))))))
(DTypeSig true "runVisitors" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Visitor"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runVisitors" ((PVar "sets") (PVar "decls")) (EBlock (DoLet false false (PVar "tagged") (EApp (EVar "indexed") (EVar "sets"))) (DoLet false false (PVar "exprHooks") (EApp (EApp (EVar "flatMap") (EApp (EVar "hooksOf") (EVar "exprHookOf"))) (EVar "tagged"))) (DoLet false false (PVar "declHooks") (EApp (EApp (EVar "flatMap") (EApp (EVar "hooksOf") (EVar "declHookOf"))) (EVar "tagged"))) (DoLet false false (PVar "hits") (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "exprHooks")) (EVar "declHooks")) (EListLit)) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "findingsTagged") (EApp (EVar "fst") (EVar "t"))) (EVar "hits")))) (EVar "tagged")))))
(DData Private "ExprHook" () ((variant "ExprHook" (ConPos (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExprKind"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Private "DeclHook" () ((variant "DeclHook" (ConPos (TyCon "Int") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Private "BodyScope" () ((variant "BodyScope" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "BodyKind") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Private "BodyKind" () ((variant "PlainBody" (ConPos)) (variant "TestBody" (ConPos))) ())
(DTypeSig false "hooksOf" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyVar "h")))) (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Visitor"))) (TyApp (TyCon "List") (TyVar "h")))))
(DFunDef false "hooksOf" ((PVar "hookOf") (PTuple (PVar "i") (PVar "vs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "hookOf") (EVar "i"))) (EVar "vs")))
(DTypeSig false "exprHookOf" (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyCon "ExprHook")))))
(DFunDef false "exprHookOf" ((PVar "i") (PCon "OnExpr" (PVar "kinds") (PVar "cb"))) (EListLit (EApp (EApp (EApp (EVar "ExprHook") (EVar "i")) (EApp (EVar "Some") (EVar "kinds"))) (EVar "cb"))))
(DFunDef false "exprHookOf" ((PVar "i") (PCon "OnAnyExpr" (PVar "cb"))) (EListLit (EApp (EApp (EApp (EVar "ExprHook") (EVar "i")) (EVar "None")) (EVar "cb"))))
(DFunDef false "exprHookOf" (PWild (PCon "OnDecl" PWild)) (EListLit))
(DTypeSig false "declHookOf" (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyCon "DeclHook")))))
(DFunDef false "declHookOf" (PWild (PCon "OnExpr" PWild PWild)) (EListLit))
(DFunDef false "declHookOf" (PWild (PCon "OnAnyExpr" PWild)) (EListLit))
(DFunDef false "declHookOf" ((PVar "i") (PCon "OnDecl" (PVar "cb"))) (EListLit (EApp (EApp (EVar "DeclHook") (EVar "i")) (EVar "cb"))))
(DTypeSig false "findingsTagged" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "findingsTagged" ((PVar "i") (PVar "hits")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "h")) (EBinOp "==" (EApp (EVar "fst") (EVar "h")) (EVar "i")))) (EVar "hits"))))
(DTypeSig false "walkDecls" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyApp (TyCon "List") (TyCon "DeclHook")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "walkDecls" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkDecls" ((PVar "exprHooks") (PVar "declHooks") (PVar "acc") (PCons (PTuple (PVar "d") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "bodies") (EApp (EVar "declBodies") (EVar "d"))) (DoLet false false (PVar "acc2") (EMatch (EVar "declHooks") (arm (PList) () (EVar "acc")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "runDeclHooks") (EApp (EApp (EApp (EApp (EVar "scopeCtx") (EApp (EApp (EVar "declScope") (EVar "bodies")) (EVar "loc"))) (EVar "KLoc")) (EVar "loc")) (EVar "None"))) (EVar "d")) (EVar "acc")) (EVar "declHooks"))))) (DoLet false false (PVar "acc3") (EMatch (EVar "exprHooks") (arm (PList) () (EVar "acc2")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "walkBodies") (EVar "exprHooks")) (EVar "loc")) (EVar "acc2")) (EVar "bodies"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "exprHooks")) (EVar "declHooks")) (EVar "acc3")) (EVar "rest")))))
(DTypeSig false "declScope" (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "BodyScope"))))
(DFunDef false "declScope" ((PList) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (ELit (LString ""))) (EListLit)) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "declScope" ((PCons (PCon "DeclBody" (PVar "owner") PWild) PWild) (PVar "loc")) (EApp (EApp (EVar "ownerScope") (EVar "owner")) (EVar "loc")))
(DTypeSig false "ownerScope" (TyFun (TyCon "BodyOwner") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "BodyScope"))))
(DFunDef false "ownerScope" ((PCon "OwnerClause" (PVar "name") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerImplMethod" PWild (PVar "m") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "m")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerIfaceDefault" PWild (PVar "m") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "m")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerTest" (PVar "name")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EListLit)) (EVar "TestBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerProp" (PVar "name") PWild) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EListLit)) (EVar "TestBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerLetGroup" (PVar "name") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DTypeSig false "scopeCtx" (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ctx"))))))
(DFunDef false "scopeCtx" ((PCon "BodyScope" (PVar "name") (PVar "ps") (PVar "kind") (PVar "declLoc")) (PVar "parent") (PVar "span") (PVar "own")) (ERecordCreate "Ctx" ((fa "ctxDeclName" (EVar "name")) (fa "ctxParams" (EVar "ps")) (fa "ctxInTest" (EApp (EVar "isTestBody") (EVar "kind"))) (fa "ctxParent" (EIf (EBinOp "==" (EVar "parent") (EVar "KLoc")) (EVar "None") (EApp (EVar "Some") (EVar "parent")))) (fa "ctxSpan" (EVar "span")) (fa "ctxOwn" (EVar "own")) (fa "ctxDeclLoc" (EVar "declLoc")))))
(DTypeSig false "isTestBody" (TyFun (TyCon "BodyKind") (TyCon "Bool")))
(DFunDef false "isTestBody" ((PCon "TestBody")) (EVar "True"))
(DFunDef false "isTestBody" ((PCon "PlainBody")) (EVar "False"))
(DTypeSig false "runDeclHooks" (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclHook")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "runDeclHooks" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "runDeclHooks" ((PVar "ctx") (PVar "d") (PVar "acc") (PCons (PCon "DeclHook" (PVar "i") (PVar "cb")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "runDeclHooks") (EVar "ctx")) (EVar "d")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EApp (EApp (EVar "cb") (EVar "ctx")) (EVar "d"))) (EVar "acc"))) (EVar "rest")))
(DTypeSig false "pushTagged" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))
(DFunDef false "pushTagged" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "pushTagged" ((PVar "i") (PCons (PVar "f") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EVar "fs")) (EBinOp "::" (ETuple (EVar "i") (EVar "f")) (EVar "acc"))))
(DTypeSig false "walkBodies" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "walkBodies" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkBodies" ((PVar "hooks") (PVar "loc") (PVar "acc") (PCons (PCon "DeclBody" (PVar "owner") (PVar "body")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "walkBodies") (EVar "hooks")) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "hooks")) (EApp (EApp (EVar "ownerScope") (EVar "owner")) (EVar "loc"))) (EVar "KLoc")) (EVar "loc")) (EVar "acc")) (EVar "body"))) (EVar "rest")))
(DTypeSig false "walkExpr" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "walkExpr" ((PVar "hooks") (PVar "scope") (PVar "parent") PWild (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkWrapped") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "l")) (EVar "l")) (EVar "acc")) (EVar "inner")))
(DFunDef false "walkExpr" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "None")) (EVar "acc")) (EVar "e")))
(DTypeSig false "walkWrapped" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "walkWrapped" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "outer") PWild (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkWrapped") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "outer")) (EVar "l")) (EVar "acc")) (EVar "inner")))
(DFunDef false "walkWrapped" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "outer") (PVar "innermost") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EApp (EVar "Some") (EVar "innermost"))) (EApp (EVar "Some") (EVar "outer"))) (EVar "acc")) (EVar "e")))
(DTypeSig false "walkNode" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "walkNode" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "own") (PVar "acc") (PVar "e")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "exprKind") (EVar "e"))) (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EApp (EApp (EApp (EApp (EVar "scopeCtx") (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "own"))) (EVar "k")) (EVar "e")) (EVar "acc")) (EVar "hooks"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkKids") (EVar "hooks")) (EVar "scope")) (EVar "k")) (EVar "span")) (EVar "acc2")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "walkKids" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "walkKids" (PWild PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkKids" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "acc") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkKids") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "acc")) (EVar "c"))) (EVar "cs")))
(DTypeSig false "visitHooks" (TyFun (TyCon "Ctx") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))
(DFunDef false "visitHooks" (PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "visitHooks" ((PVar "ctx") (PVar "k") (PVar "e") (PVar "acc") (PCons (PCon "ExprHook" (PVar "i") (PVar "kinds") (PVar "cb")) (PVar "rest"))) (EIf (EApp (EApp (EVar "hookWants") (EVar "k")) (EVar "kinds")) (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EVar "ctx")) (EVar "k")) (EVar "e")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EApp (EApp (EVar "cb") (EVar "ctx")) (EVar "e"))) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EVar "ctx")) (EVar "k")) (EVar "e")) (EVar "acc")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hookWants" (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExprKind"))) (TyCon "Bool"))))
(DFunDef false "hookWants" (PWild (PCon "None")) (EVar "True"))
(DFunDef false "hookWants" ((PVar "k") (PCon "Some" (PVar "kinds"))) (EApp (EApp (EVar "kindIn") (EVar "k")) (EVar "kinds")))
(DTypeSig false "kindIn" (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "List") (TyCon "ExprKind")) (TyCon "Bool"))))
(DFunDef false "kindIn" (PWild (PList)) (EVar "False"))
(DFunDef false "kindIn" ((PVar "k") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EVar "k") (EVar "x")) (EApp (EApp (EVar "kindIn") (EVar "k")) (EVar "xs"))))
(DTypeSig false "restampFinding" (TyFun (TyCon "Rule") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampFinding" ((PVar "r") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EFieldAccess (EVar "r") "severity")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EApp (EApp (EVar "map") (EApp (EVar "clampFix") (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability"))) (EFieldAccess (EVar "f") "fix"))))))
(DTypeSig false "clampFix" (TyFun (TyCon "Fixability") (TyFun (TyCon "Fix") (TyCon "Fix"))))
(DFunDef false "clampFix" ((PVar "fixability") (PVar "fx")) (EMatch (EApp (EVar "maxApplicability") (EVar "fixability")) (arm (PCon "Some" (PVar "ceiling")) () (ERecordCreate "Fix" ((fa "fixApplicability" (EApp (EApp (EVar "clampApplicability") (EVar "ceiling")) (EFieldAccess (EVar "fx") "fixApplicability"))) (fa "fixEdits" (EFieldAccess (EVar "fx") "fixEdits")) (fa "fixMessage" (EFieldAccess (EVar "fx") "fixMessage"))))) (arm (PCon "None") () (EVar "fx"))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EFieldAccess (EVar "f") "fix")))))
(DTypeSig true "stdlibIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "stdlibIndexNeeded" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "ruleNeedsIndex") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig true "stdlibIndexNeededFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "stdlibIndexNeededFor" ((PVar "only") (PVar "disable") (PVar "paths")) (EBinOp "||" (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EVar "disable")) (EBinOp "&&" (EApp (EApp (EVar "wildIndexNeeded") (EVar "only")) (EVar "disable")) (EApp (EVar "anyPathWild") (EVar "paths")))))
(DTypeSig true "projectIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "projectIndexNeeded" ((PVar "only") (PVar "disable")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsProjectIndex")) (EVar "allRules")) (EVar "only")) (EVar "disable")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsProjectIndex")) (EVar "allProjectRules")) (EVar "only")) (EVar "disable"))))
(DTypeSig false "anyActive" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyActive" ((PVar "declares") (PVar "roster") (PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "activeWith") (EVar "declares")) (EVar "only")) (EVar "disable"))) (EVar "roster")))
(DTypeSig false "activeWith" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool"))))))
(DFunDef false "activeWith" ((PVar "declares") (PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "declares") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "indexForRun" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))
(DFunDef false "indexForRun" ((PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRoster") (EVar "allRules")) (ELit (LString ""))) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRoster" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))))
(DFunDef false "indexForRoster" ((PVar "roster") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRosterIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))) (EVar "roster")) (EVar "root")) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRosterIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))))))
(DFunDef false "indexForRosterIn" ((PVar "sdir") (PVar "shardDir") (PVar "roster") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRostersIn") (EVar "sdir")) (EVar "shardDir")) (EVar "roster")) (EVar "allProjectRules")) (EVar "root")) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRostersIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))))))))
(DFunDef false "indexForRostersIn" ((PVar "sdir") (PVar "shardDir") (PVar "roster") (PVar "projects") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EBlock (DoLet false false (PVar "only2") (EIf (EVar "keepAll") (EListLit) (EVar "only"))) (DoLet false false (PVar "disable2") (EIf (EVar "keepAll") (EListLit) (EVar "disable"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsProjectIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsProjectIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EApp (EApp (EApp (EVar "buildProjectIndexResultRootsIn") (EVar "sdir")) (EVar "shardDir")) (EIf (EBinOp "==" (EVar "root") (ELit (LString ""))) (EApp (EVar "projectRootsOf") (EVar "paths")) (EListLit (EVar "root")))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsStdlibIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsStdlibIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EBinOp "&&" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsWildIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsWildIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EApp (EVar "anyPathWild") (EVar "paths")))) (EApp (EApp (EVar "buildStdlibIndexResultIn") (EVar "sdir")) (EVar "shardDir")) (EApp (EVar "Ok") (EVar "emptyStdlibIndex")))))))
(DTypeSig false "anyProjectActive" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyProjectActive" ((PVar "declares") (PVar "projects") (PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "projectActiveWith") (EVar "declares")) (EVar "only")) (EVar "disable"))) (EVar "projects")))
(DTypeSig false "projectActiveWith" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ProjectRule") (TyCon "Bool"))))))
(DFunDef false "projectActiveWith" ((PVar "declares") (PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EApp (EVar "declares") (EFieldAccess (EVar "r") "meta")) (EApp (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable")) (EVar "r"))))
(DTypeSig false "projectRootsOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "projectRootsOf" ((PVar "paths")) (EApp (EVar "nub") (EApp (EApp (EVar "map") (EVar "projectRootOfPath")) (EVar "paths"))))
(DTypeSig false "projectRootOfPath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "projectRootOfPath" ((PVar "path")) (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EApp (EVar "canonicalizePath") (EVar "path")))))
(DTypeSig false "anyPathWild" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "anyPathWild" ((PList)) (EVar "False"))
(DFunDef false "anyPathWild" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "||" (EApp (EVar "sourceHasWildImport") (EApp (EVar "readFileSafe") (EVar "p"))) (EApp (EVar "anyPathWild") (EVar "rest"))))
(DTypeSig true "wildIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "wildIndexNeeded" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "ruleNeedsWildIndex") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig false "ruleNeedsWildIndex" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleNeedsWildIndex" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "needsWildIndex") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "sourceHasWildImport" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sourceHasWildImport" ((PVar "src")) (EApp (EApp (EVar "anyList") (EVar "isWildImportLine")) (EApp (EVar "splitNl") (EVar "src"))))
(DTypeSig false "isWildImportLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWildImportLine" ((PVar "l")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "import "))) (EVar "l")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (ELit (LString ".*"))) (EVar "l")))))
(DTypeSig false "ruleNeedsScopes" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleNeedsScopes" ((PVar "r")) (EApp (EVar "needsScopes") (EFieldAccess (EVar "r") "meta")))
(DTypeSig false "ruleNeedsIndex" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleNeedsIndex" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "needsStdlibIndex") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "buildStdlibIndexResult" (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))
(DFunDef false "buildStdlibIndexResult" () (EApp (EApp (EVar "buildStdlibIndexResultIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))))
(DTypeSig true "buildStdlibIndexResultIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))
(DFunDef false "buildStdlibIndexResultIn" ((PVar "sdir") (PVar "shardDir")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "digests") (PVar "rows"))) (EApp (EApp (EApp (EApp (EVar "mkStdlibIndex") (EApp (EVar "combineDigests") (EVar "digests"))) (ELit (LString ""))) (EVar "rows")) (EListLit)))) (EApp (EApp (EVar "stdlibRowsResult") (EVar "sdir")) (EVar "shardDir"))))
(DTypeSig true "buildProjectIndexResult" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))
(DFunDef false "buildProjectIndexResult" ((PVar "root")) (EApp (EApp (EApp (EVar "buildProjectIndexResultIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))) (EVar "root")))
(DTypeSig true "buildProjectIndexResultIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))
(DFunDef false "buildProjectIndexResultIn" ((PVar "sdir") (PVar "shardDir") (PVar "root")) (EApp (EApp (EApp (EVar "buildProjectIndexResultRootsIn") (EVar "sdir")) (EVar "shardDir")) (EListLit (EVar "root"))))
(DTypeSig true "buildProjectIndexResultRootsIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))
(DFunDef false "buildProjectIndexResultRootsIn" ((PVar "sdir") (PVar "shardDir") (PVar "roots")) (EBlock (DoLet false false (PTuple (PVar "pdigests") (PVar "prows")) (EApp (EVar "projectRowsOfRoots") (EVar "roots"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sdigests") (PVar "srows"))) (EApp (EApp (EApp (EApp (EVar "mkStdlibIndex") (EApp (EVar "combineDigests") (EVar "sdigests"))) (EApp (EVar "combineDigests") (EVar "pdigests"))) (EVar "srows")) (EVar "prows")))) (EApp (EApp (EVar "stdlibRowsResult") (EVar "sdir")) (EVar "shardDir"))))))
(DTypeSig false "indexStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "indexStamp" (PWild) (EBlock (DoLet false false (PVar "fp") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "fp") (ELit (LString ""))) (EApp (EVar "ruleSetStamp") (ELit LUnit)) (EVar "fp")))))
(DTypeSig false "stdlibRowsResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))))
(DFunDef false "stdlibRowsResult" ((PVar "sdir") (PVar "shardDir")) (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "sdir")) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EListLit) (EListLit)))) (arm (PCon "Some" (PVar "rels")) () (EBlock (DoLet false false (PVar "stamp") (EApp (EVar "indexStamp") (ELit LUnit))) (DoLet false false (PVar "dir") (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (ELit (LString "")) (EVar "shardDir"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "stdlibRowsGo") (EVar "dir")) (EVar "stamp")) (EVar "sdir")) (EVar "rels")))))))
(DTypeSig false "stdlibRowsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))))))
(DFunDef false "stdlibRowsGo" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit))))
(DFunDef false "stdlibRowsGo" ((PVar "dir") (PVar "stamp") (PVar "sdir") (PCons (PVar "rel") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sdir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "rel"))) (ELit (LString "")))) (DoLet false false (PVar "modId") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "rel"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileRows") (EVar "True")) (EVar "lintParseSource")) (EVar "dir")) (EVar "stamp")) (EVar "modId")) (EVar "path")) (arm (PCon "Err" (PTuple (PVar "src") (PVar "e"))) () (EApp (EVar "Err") (ERecordCreate "StdlibIndexError" ((fa "path" (EVar "path")) (fa "source" (EVar "src")) (fa "diagnostic" (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))))) (arm (PCon "Ok" (PTuple (PVar "digest") (PVar "rows"))) () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "ds") (PVar "rs"))) (ETuple (EBinOp "::" (EVar "digest") (EVar "ds")) (EBinOp "++" (EVar "rows") (EVar "rs"))))) (EApp (EApp (EApp (EApp (EVar "stdlibRowsGo") (EVar "dir")) (EVar "stamp")) (EVar "sdir")) (EVar "rest"))))))))
(DTypeSig false "projectRowsOfRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsOfRoots" ((PVar "roots")) (EBlock (DoLet false false (PVar "perRoot") (EApp (EApp (EVar "map") (EVar "projectRowsOf")) (EVar "roots"))) (DoExpr (ETuple (EApp (EApp (EVar "flatMap") (EVar "fst")) (EVar "perRoot")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "perRoot"))))))
(DTypeSig false "projectRowsOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsOf" ((PVar "root")) (EBlock (DoLet false false (PVar "stamp") (EApp (EVar "indexStamp") (ELit LUnit))) (DoLet false false (PVar "dir") (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (ELit (LString "")) (EApp (EVar "projectShardDir") (EVar "root")))) (DoLet false false (PVar "files") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "projectFileRows") (EVar "dir")) (EVar "stamp")) (EVar "root"))) (EApp (EVar "collectMdkFiles") (EVar "root")))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "files")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "files"))))))
(DTypeSig false "projectFileRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "projectFileRows" ((PVar "dir") (PVar "stamp") (PVar "root") (PVar "path")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileRows") (EVar "False")) (EVar "lintParseSource")) (EVar "dir")) (EVar "stamp")) (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "root"))) (EVar "path"))) (EVar "path")) (arm (PCon "Err" PWild) () (ETuple (ELit (LString "")) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "digest") (PVar "rows"))) () (ETuple (EVar "digest") (EVar "rows")))))
(DTypeSig false "lintStdlibDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "lintStdlibDir" () (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EApp (EVar "exeStdlibDir") (ELit LUnit)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "/stdlib"))))) (arm (PCon "None") () (EApp (EVar "exeStdlibDir") (ELit LUnit)))))
(DTypeSig false "exeStdlibDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "exeStdlibDir" (PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))) (ELit (LString "/stdlib"))))
(DTypeSig true "rosterNeeds" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyCon "Bool")))
(DFunDef false "rosterNeeds" ((PVar "roster")) (EApp (EApp (EVar "anyList") (EVar "ruleReadsIndex")) (EVar "roster")))
(DTypeSig false "ruleReadsIndex" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleReadsIndex" ((PVar "r")) (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")))
(DTypeSig true "rankedIndexRules" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule")))))
(DFunDef false "rankedIndexRules" ((PVar "roster")) (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EVar "ruleReadsIndex") (EApp (EVar "snd") (EVar "rf"))))) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "roster"))))
(DTypeSig true "splitByIndex" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))
(DFunDef false "splitByIndex" ((PVar "roster") (PVar "found")) (EBlock (DoLet false false (PVar "indexRanks") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "rankedIndexRules") (EVar "roster")))) (DoExpr (ETuple (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EApp (EVar "fst") (EVar "rf"))) (EVar "indexRanks"))))) (EVar "found")) (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EApp (EVar "elem") (EApp (EVar "fst") (EVar "rf"))) (EVar "indexRanks")))) (EVar "found"))))))
(DTypeSig true "indexKeyFor" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))))
(DFunDef false "indexKeyFor" () (EApp (EVar "indexKeyWith") (EVar "stdlibIndexFingerprint")))
(DTypeSig true "indexKeyWith" (TyFun (TyFun (TyCon "StdlibIndex") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String")))))
(DFunDef false "indexKeyWith" ((PVar "fingerprintOf") (PVar "roster") (PVar "idx")) (EIf (EApp (EVar "rosterNeeds") (EVar "roster")) (EApp (EVar "fingerprintOf") (EVar "idx")) (ELit (LString ""))))
(DTypeSig true "lintParseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "lintParseSource" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "tokens") (PVar "offsets")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "prescanErrorPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "parsed")) () (EApp (EVar "Ok") (EVar "parsed"))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "parseWithPositions") (EVar "src")))) (EApp (EApp (EApp (EVar "parseResultPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))))))
(DTypeSig false "stdlibMemberPaths" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stdlibMemberPaths" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (ELit (LString ""))) (EVar "entries")))))))
(DTypeSig false "memberPathsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "memberPathsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "memberPathsGo" ((PVar "dir") (PVar "prefix") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (EMatch (EApp (EVar "listDir") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "/")))) (EVar "sub"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EVar "prefix")) (EVar "rest"))))))
(DTypeSig false "liveFindingLines" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "liveFindingLines" ((PVar "src") (PVar "facts") (PVar "rules") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "findingRuleLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "emptyStdlibIndex")) (EVar "rules")) (ELit (LString ""))) (EVar "facts")) (EVar "pos")) (EVar "prog")))))
(DTypeSig false "findingRuleLine" (TyFun (TyCon "Finding") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "findingRuleLine" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" PWild (PVar "line") PWild PWild PWild)) () (EListLit (ETuple (EFieldAccess (EVar "f") "rule") (EVar "line")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ruleLiveIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleLiveIn" ((PVar "live") (PTuple (PVar "s") (PVar "e")) (PVar "r")) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EFieldAccess (EVar "r") "name")) (EBinOp "<=" (EVar "s") (EApp (EVar "snd") (EVar "p")))) (EBinOp "<=" (EApp (EVar "snd") (EVar "p")) (EVar "e"))))) (EVar "live")))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmts") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EVar "map") (EVar "commentLine")) (EVar "cmts"))) (DoLet false false (PVar "declPos") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "allFacts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (DoLet false false (PVar "facts") (EIf (EApp (EApp (EVar "anyList") (EVar "ruleNeedsScopes")) (EVar "rules")) (EApp (EVar "Some") (EVar "allFacts")) (EVar "None"))) (DoLet false false (PVar "live") (EApp (EApp (EApp (EApp (EApp (EVar "liveFindingLines") (EVar "src")) (EVar "allFacts")) (EVar "rules")) (EVar "pos")) (EVar "prog"))) (DoLet false false (PVar "tagged") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "declPos"))) (DoLet false false (PTuple (PVar "kept") (PVar "widen")) (EApp (EApp (EApp (EVar "reconcileTestImport") (EVar "cmts")) (EVar "declPos")) (EVar "tagged"))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EApp (EApp (EVar "withWiden") (EVar "widen")) (EVar "kept"))) (EApp (EVar "listLen") (EVar "kept"))))))
(DTypeSig false "withWiden" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "withWiden" ((PCon "None") (PVar "splices")) (EVar "splices"))
(DFunDef false "withWiden" ((PCon "Some" (PVar "sp")) (PVar "splices")) (EApp (EApp (EVar "insertSpliceAsc") (EVar "sp")) (EVar "splices")))
(DTypeSig false "testVerbNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testVerbNames" () (EListLit (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")) (ELit (LString "expectTrue")) (ELit (LString "expectFalse"))))
(DData Private "VerbCount" () ((variant "VerbCount" (ConNamed (field "verbName" (TyCon "String")) (field "verbUses" (TyCon "Int"))))) ())
(DData Private "VerbDelta" () ((variant "VerbDelta" (ConNamed (field "stopped" (TyApp (TyCon "List") (TyCon "String"))) (field "started" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "testVerbCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "VerbCount"))))
(DFunDef false "testVerbCounts" ((PVar "ds")) (EBlock (DoLet false false (PVar "refs") (EApp (EApp (EVar "flatMap") (EVar "declRefs")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ERecordCreate "VerbCount" ((fa "verbName" (EVar "v")) (fa "verbUses" (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "v")))) (EVar "refs")))))))) (EVar "testVerbNames")))))
(DTypeSig false "testVerbDelta" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "VerbDelta"))))
(DFunDef false "testVerbDelta" ((PVar "d") (PVar "newDecls")) (EBlock (DoLet false false (PVar "before") (EApp (EVar "testVerbCounts") (EListLit (EVar "d")))) (DoLet false false (PVar "after") (EApp (EVar "testVerbCounts") (EVar "newDecls"))) (DoLet false false (PVar "moved") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "before"))) (DoExpr (ERecordCreate "VerbDelta" ((fa "stopped" (EApp (EApp (EVar "map") (EVar "verbOf")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "<" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "moved")))) (fa "started" (EApp (EApp (EVar "map") (EVar "verbOf")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "moved")))))))))
(DTypeSig false "verbOf" (TyFun (TyCon "VerbCount") (TyCon "String")))
(DFunDef false "verbOf" ((PVar "c")) (EFieldAccess (EVar "c") "verbName"))
(DTypeSig false "verbUsesIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "VerbCount")) (TyCon "Int"))))
(DFunDef false "verbUsesIn" ((PVar "v") (PVar "cs")) (EMatch (EApp (EApp (EVar "find") (ELam ((PVar "c")) (EBinOp "==" (EFieldAccess (EVar "c") "verbName") (EVar "v")))) (EVar "cs")) (arm (PCon "Some" (PVar "c")) () (EFieldAccess (EVar "c") "verbUses")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "testFixAllowed" (TyFun (TyApp (TyCon "Option") (TyCon "FileFacts")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "testFixAllowed" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "testFixAllowed" ((PCon "None") PWild PWild PWild) (EVar "False"))
(DFunDef false "testFixAllowed" ((PCon "Some" (PVar "facts")) (PTuple (PVar "from") (PVar "to")) (PVar "matched") (PVar "introduced")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "matched")) (EApp (EApp (EVar "allList") (EApp (EApp (EApp (EVar "matchedIsTestVerb") (EVar "fs")) (EVar "from")) (EVar "to"))) (EVar "matched"))) (EApp (EApp (EVar "allList") (EApp (EApp (EApp (EVar "introducedIsFree") (EVar "fs")) (EVar "from")) (EVar "to"))) (EVar "introduced"))))))
(DTypeSig false "matchedIsTestVerb" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "matchedIsTestVerb" ((PVar "fs") (PVar "from") (PVar "to") (PVar "verb")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EApp (EApp (EVar "usesNamedIn") (EVar "fs")) (EVar "from")) (EVar "to")) (EVar "verb"))) (DoExpr (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "uses")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "useIsTestVerb") (EVar "fs")) (EVar "verb"))) (EVar "uses"))))))
(DTypeSig false "useIsTestVerb" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Use") (TyCon "Bool")))))
(DFunDef false "useIsTestVerb" ((PVar "fs") (PVar "verb") (PVar "u")) (EMatch (EFieldAccess (EVar "u") "useBinder") (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "isTestMember") (EVar "verb")) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EVar "elem") (EListLit (ELit (LString "test")))) (EApp (EVar "wildImports") (EVar "fs"))))))
(DTypeSig false "isTestMember" (TyFun (TyCon "String") (TyFun (TyCon "Binder") (TyCon "Bool"))))
(DFunDef false "isTestMember" ((PVar "verb") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BImport")) (EBinOp "==" (EFieldAccess (EVar "b") "binderFrom") (EListLit (ELit (LString "test"))))) (EBinOp "==" (EFieldAccess (EVar "b") "binderOrigin") (EVar "verb"))))
(DTypeSig false "introducedIsFree" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "introducedIsFree" ((PVar "fs") (PVar "from") (PVar "to") (PVar "verb")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EApp (EVar "bindersNamedIn") (EVar "fs")) (EVar "from")) (EVar "to")) (EVar "verb"))) (EApp (EVar "isEmptyL") (EApp (EApp (EVar "filterList") (EVar "unplacedBinder")) (EApp (EApp (EVar "bindersNamed") (EVar "fs")) (EVar "verb"))))) (EApp (EApp (EVar "allList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EListLit (ELit (LString "test")))))) (EApp (EVar "wildImports") (EVar "fs")))) (EApp (EApp (EVar "allList") (EApp (EVar "isTestMember") (EVar "verb"))) (EApp (EApp (EVar "filterList") (EVar "fileLevel")) (EApp (EApp (EVar "bindersNamed") (EVar "fs")) (EVar "verb"))))))
(DTypeSig false "unplacedBinder" (TyFun (TyCon "Binder") (TyCon "Bool")))
(DFunDef false "unplacedBinder" ((PVar "b")) (EMatch (EFieldAccess (EVar "b") "binderSpan") (arm (PCon "Loc" PWild (PLit (LInt 0)) PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "fileLevel" (TyFun (TyCon "Binder") (TyCon "Bool")))
(DFunDef false "fileLevel" ((PVar "b")) (EMatch (EFieldAccess (EVar "b") "binderKind") (arm (PCon "BImport") () (EVar "True")) (arm (PCon "BTopLevel") () (EVar "True")) (arm (PCon "BLetGroup") () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "reconcileTestImport" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))))
(DFunDef false "reconcileTestImport" ((PVar "cmts") (PVar "declPos") (PVar "tagged")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "testGroups") (EVar "declPos"))) (DoLet false false (PVar "listed") (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EApp (EVar "fst") (EVar "g"))))) (EVar "groups"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "anyList") (EVar "isTestWild")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "declPos")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "groups")) (EVar "wild")) (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "tagged")) (EVar "None")) (EBlock (DoLet false false (PVar "missingOf") (ELam ((PVar "verbs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "listed"))))) (EVar "verbs")))) (DoLet false false (PVar "target") (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "groups"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EBinOp "||" (EApp (EVar "isEmptyL") (EApp (EVar "missingOf") (EApp (EVar "snd") (EVar "t")))) (EApp (EVar "isSome") (EVar "target"))))) (EVar "tagged"))) (DoLet false false (PVar "missing") (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (ELam ((PVar "t")) (EApp (EVar "missingOf") (EApp (EVar "snd") (EVar "t"))))) (EVar "kept")))) (DoExpr (EMatch (EVar "target") (arm (PCon "Some" (PTuple (PVar "pub") (PVar "path") (PVar "members") (PVar "loc") (PVar "dp") (PVar "trailing"))) () (EIf (EApp (EVar "isEmptyL") (EVar "missing")) (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "kept")) (EVar "None")) (EBlock (DoLet false false (PVar "widened") (EApp (EApp (EVar "UseGroup") (EVar "path")) (EBinOp "++" (EVar "members") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "v")) (EVar "False")) (EVar "loc")) (EVar "None")))) (EVar "missing"))))) (DoLet false false (PVar "txt") (EBinOp "++" (EApp (EVar "declToString") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "widened")) (EVar "loc"))) (EVar "trailing"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "kept")) (EApp (EVar "Some") (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "txt")))))))) (arm (PCon "None") () (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "kept")) (EVar "None"))))))))))
(DTypeSig false "isTestWild" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTestWild" ((PCon "DUse" PWild (PCon "UseWild" (PVar "path")) PWild)) (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))))
(DFunDef false "isTestWild" (PWild) (EVar "False"))
(DTypeSig false "testGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "UseMember")) (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc") (TyCon "DeclPos"))))))
(DFunDef false "testGroups" ((PList)) (EListLit))
(DFunDef false "testGroups" ((PCons (PTuple (PCon "DUse" (PVar "pub") (PCon "UseGroup" (PVar "path") (PVar "members")) (PVar "loc")) (PVar "dp")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))) (EBinOp "::" (ETuple (EVar "members") (ETuple (EVar "pub") (EVar "path") (EVar "loc") (EVar "dp"))) (EApp (EVar "testGroups") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "testGroups" ((PCons PWild (PVar "rest"))) (EApp (EVar "testGroups") (EVar "rest")))
(DTypeSig false "findWidenable" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "UseMember")) (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc") (TyCon "DeclPos")))) (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Loc") (TyCon "DeclPos") (TyCon "String"))))))
(DFunDef false "findWidenable" (PWild (PList)) (EVar "None"))
(DFunDef false "findWidenable" ((PVar "cmts") (PCons (PTuple (PVar "members") (PTuple (PVar "pub") (PVar "path") (PVar "loc") (PVar "dp"))) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "spanComments") (EVar "cmts")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (arm (PList) () (EApp (EVar "Some") (ETuple (EVar "pub") (EVar "path") (EVar "members") (EVar "loc") (EVar "dp") (ELit (LString ""))))) (arm (PList (PVar "c")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (ETuple (EVar "pub") (EVar "path") (EVar "members") (EVar "loc") (EVar "dp") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "commentText") (EVar "c"))))) (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "rest")))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cmts") (PVar "s") (PVar "e")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp "<=" (EVar "s") (EApp (EVar "commentLine") (EVar "c"))) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "e"))))) (EVar "cmts")))
(DTypeSig false "insertSpliceAsc" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "insertSpliceAsc" ((PVar "sp") (PList)) (EListLit (EVar "sp")))
(DFunDef false "insertSpliceAsc" ((PTuple (PVar "s") (PVar "e") (PVar "t")) (PCons (PTuple (PVar "s2") (PVar "e2") (PVar "t2")) (PVar "rest"))) (EIf (EBinOp "<" (EVar "s") (EVar "s2")) (EBinOp "::" (ETuple (EVar "s") (EVar "e") (EVar "t")) (EBinOp "::" (ETuple (EVar "s2") (EVar "e2") (EVar "t2")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "s2") (EVar "e2") (EVar "t2")) (EApp (EApp (EVar "insertSpliceAsc") (ETuple (EVar "s") (EVar "e") (EVar "t"))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ruleActiveFixable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleActiveFixable" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))) (EApp (EVar "ruleHasFixer") (EVar "r"))))
(DTypeSig false "ruleHasFixer" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleHasFixer" ((PVar "r")) (EApp (EVar "isSome") (EFieldAccess (EVar "r") "fix")))
(DTypeSig false "collectSplices" (TyFun (TyApp (TyCon "Option") (TyCon "FileFacts")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "collectSplices" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "facts") (PVar "live") (PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EBlock (DoLet false false (PVar "liveRules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleLiveIn") (EVar "live")) (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp"))))) (EVar "rules"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "liveRules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EBlock (DoLet false false (PVar "delta") (EApp (EApp (EVar "testVerbDelta") (EVar "d")) (EVar "newDecls"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "testFixAllowed") (EVar "facts")) (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")))) (EFieldAccess (EVar "delta") "stopped")) (EFieldAccess (EVar "delta") "started")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EFieldAccess (EVar "delta") "started")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))))
(DTypeSig false "spanHasComment" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "spanHasComment" ((PVar "cmtLines") (PVar "startLine") (PVar "endLine")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "<=" (EVar "startLine") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "endLine"))))) (EVar "cmtLines")))
(DTypeSig false "firstFix" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "firstFix" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstFix" ((PVar "orc") (PCons (PVar "r") (PVar "rs")) (PVar "d")) (EMatch (EApp (EApp (EApp (EVar "applyRuleFix") (EVar "orc")) (EVar "r")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EApp (EVar "Some") (EVar "newDecls"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rs")) (EVar "d")))))
(DTypeSig false "applyRuleFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Rule") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyRuleFix" ((PVar "orc") (PVar "r") (PVar "d")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "f") (EVar "orc")) (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "renderDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "renderDecls" ((PVar "ds")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "declToString")) (EVar "ds"))))
(DTypeSig false "applySplices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "applySplices" ((PVar "src") (PVar "splices")) (EApp (EVar "joinNl") (EApp (EApp (EVar "foldSplices") (EApp (EVar "splitNl") (EVar "src"))) (EApp (EVar "reverseL") (EVar "splices")))))
(DTypeSig false "foldSplices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "foldSplices" ((PVar "lines") (PList)) (EVar "lines"))
(DFunDef false "foldSplices" ((PVar "lines") (PCons (PTuple (PVar "s") (PVar "e") (PVar "txt")) (PVar "rest"))) (EApp (EApp (EVar "foldSplices") (EApp (EApp (EApp (EApp (EVar "spliceLines") (EVar "lines")) (EVar "s")) (EVar "e")) (EVar "txt"))) (EVar "rest")))
(DTypeSig false "spliceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spliceLines" ((PVar "lines") (PVar "s") (PVar "e") (PVar "txt")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EBinOp "-" (EVar "s") (ELit (LInt 1)))) (EVar "lines")) (EApp (EVar "splitNl") (EVar "txt"))) (EApp (EApp (EVar "drop") (EVar "e")) (EVar "lines"))))
(DTypeSig true "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EFieldAccess (EVar "f") "fix")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EApp (EVar "LintRule") (EFieldAccess (EVar "f") "rule"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EApp (EApp (EVar "map") (EVar "fixToDiagFix")) (EFieldAccess (EVar "f") "fix"))))
(DTypeSig true "lintFileDiagTripleParsed" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileDiagTripleParsed" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EVar "path") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit)) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "decls") (PVar "pos"))) () (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "path")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "factDirectives") (EVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EVar "map") (EVar "findingToDiag")) (EApp (EApp (EApp (EVar "demoteOverComments") (EVar "path")) (EVar "src")) (EVar "findings"))) (EVar "pos") (EVar "decls")))))))))
(DTypeSig true "lintFileDiagTriple" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFileDiagTriple" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EApp (EVar "dropParsedTriple") (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "path"))))
(DTypeSig false "dropParsedTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropParsedTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintToLines" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "lintToLines" ((PVar "idx") (PVar "src") (PVar "path") (PVar "pos") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "findingLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "idx")) (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "findingLine" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingLine" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString ": ["))) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DTypeSig true "applySuppressions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressions" ((PVar "src") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "directivesOfSource") (EVar "src"))) (EVar "findings")))
(DTypeSig true "applySuppressionsDirs" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsDirs" ((PVar "dirs") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f"))))) (EVar "findings")))
(DTypeSig true "applySuppressionsMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMulti" ((PVar "srcs") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EVar "map") (EVar "fileDirectivesOf")) (EVar "srcs"))) (EVar "findings")))
(DTypeSig true "applySuppressionsMultiDirs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMultiDirs" ((PVar "dirTable") (PVar "findings")) (EBlock (DoLet false false (PVar "table") (EApp (EVar "dirTableMap") (EVar "dirTable"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "findingSuppressedMulti") (EVar "table")) (EVar "f"))))) (EVar "findings")))))
(DTypeSig false "dirTableMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "dirTableMap" ((PVar "rows")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "dirTableFill") (EVar "m")) (EVar "rows"))) (DoExpr (EVar "m"))))
(DTypeSig false "dirTableFill" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyCon "Unit"))))
(DFunDef false "dirTableFill" (PWild (PList)) (ELit LUnit))
(DFunDef false "dirTableFill" ((PVar "m") (PCons (PTuple (PVar "p") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "has") (EVar "p")) (EVar "m")) (ELit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "p")) (EVar "ds")) (EVar "m")))) (DoExpr (EApp (EApp (EVar "dirTableFill") (EVar "m")) (EVar "rest")))))
(DTypeSig false "fileDirectivesOf" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "fileDirectivesOf" ((PTuple (PVar "path") (PVar "src"))) (ETuple (EVar "path") (EApp (EVar "directivesOfSource") (EVar "src"))))
(DTypeSig false "findingSuppressedMulti" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive"))) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "findingSuppressedMulti" ((PVar "dirTable") (PVar "f")) (EMatch (EApp (EApp (EVar "get") (EApp (EVar "findingFileOf") (EVar "f"))) (EVar "dirTable")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dirs")) () (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f")))))
(DTypeSig false "findingFileOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingFileOf" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EVar "file")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "directivesOfSource" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "directivesOfSource" ((PVar "src")) (EApp (EVar "collectDirectives") (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "isSuppressed" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "isSuppressed" ((PVar "dirs") (PVar "f")) (EApp (EApp (EVar "anyList") (EApp (EVar "dirCoversFinding") (EVar "f"))) (EVar "dirs")))
(DTypeSig false "dirCoversFinding" (TyFun (TyCon "Finding") (TyFun (TyCon "Directive") (TyCon "Bool"))))
(DFunDef false "dirCoversFinding" ((PVar "f") (PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "names")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names"))) (EApp (EApp (EVar "scopeMatches") (EApp (EVar "findingLineNo") (EVar "f"))) (EVar "scope"))))
(DTypeSig false "scopeMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "DirScope") (TyCon "Bool"))))
(DFunDef false "scopeMatches" (PWild (PCon "DScopeFile")) (EVar "True"))
(DFunDef false "scopeMatches" ((PCon "Some" (PVar "line")) (PCon "DScopeLine" (PVar "l"))) (EBinOp "==" (EVar "line") (EVar "l")))
(DFunDef false "scopeMatches" ((PCon "None") (PCon "DScopeLine" PWild)) (EVar "False"))
(DTypeSig false "findingLineNo" (TyFun (TyCon "Finding") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "findingLineNo" ((PVar "f")) (EApp (EApp (EVar "map") (ELam ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))) (EFieldAccess (EVar "f") "loc")))
(DTypeSig true "fileSummaries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))))))
(DFunDef false "fileSummaries" ((PVar "only") (PVar "disable") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EFieldAccess (EAnnot (EVar "r") (TyCon "ProjectRule")) "name") (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "prSummarize") (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable"))) (EVar "allProjectRules"))))
(DTypeSig true "runProjectRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runProjectRules" ((PVar "only") (PVar "disable") (PVar "idx") (PVar "files")) (EApp (EApp (EApp (EApp (EApp (EVar "runProjectRulesOver") (EVar "allProjectRules")) (EVar "only")) (EVar "disable")) (EVar "idx")) (EVar "files")))
(DTypeSig true "runProjectRulesOver" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runProjectRulesOver" ((PVar "rules") (PVar "only") (PVar "disable") (PVar "idx") (PVar "files")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "runProjectRuleOn") (EVar "only")) (EVar "disable")) (EVar "idx")) (EVar "files"))) (EVar "rules")))
(DTypeSig false "runProjectRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyFun (TyCon "ProjectRule") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runProjectRuleOn" ((PVar "only") (PVar "disable") (PVar "idx") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EFieldAccess (EVar "r") "prEvaluate") (EApp (EApp (EVar "projectIndexFor") (EVar "r")) (EVar "idx"))) (EApp (EApp (EVar "summariesOfRule") (EFieldAccess (EVar "r") "name")) (EVar "files")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectIndexFor" (TyFun (TyCon "ProjectRule") (TyFun (TyCon "StdlibIndex") (TyCon "ProjectIndex"))))
(DFunDef false "projectIndexFor" ((PVar "r") (PVar "idx")) (EIf (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")) (EApp (EVar "projectIndexOf") (EVar "idx")) (EVar "emptyProjectIndex")))
(DTypeSig false "summariesOfRule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))
(DFunDef false "summariesOfRule" (PWild (PList)) (EListLit))
(DFunDef false "summariesOfRule" ((PVar "name") (PCons (PTuple (PVar "path") (PVar "ss")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (ETuple (EVar "path") (EApp (EVar "snd") (EVar "s"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "fst") (EVar "s")) (EVar "name")))) (EVar "ss"))) (EApp (EApp (EVar "summariesOfRule") (EVar "name")) (EVar "rest"))))
(DTypeSig true "mergeProjectIntoTriples" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeProjectIntoTriples" ((PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "mergeProjectIntoTriples" ((PCons (PVar "f") (PVar "rest")) (PVar "triples")) (EApp (EApp (EVar "mergeProjectIntoTriples") (EVar "rest")) (EApp (EApp (EVar "mergeOneFinding") (EVar "f")) (EVar "triples"))))
(DTypeSig false "mergeOneFinding" (TyFun (TyCon "Finding") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeOneFinding" ((PVar "f") (PVar "triples")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "None") () (EVar "triples")) (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "tripleHasPath") (EVar "file"))) (EVar "triples")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "appendIfPath") (EVar "file")) (EApp (EVar "findingToDiag") (EVar "f")))) (EVar "triples")) (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (ELit (LString "")) (EListLit (EApp (EVar "findingToDiag") (EVar "f"))))))))))
(DTypeSig false "tripleHasPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool"))))
(DFunDef false "tripleHasPath" ((PVar "file") (PTuple (PVar "path") PWild PWild)) (EBinOp "==" (EVar "path") (EVar "file")))
(DTypeSig false "appendIfPath" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendIfPath" ((PVar "file") (PVar "diag") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EIf (EBinOp "==" (EVar "path") (EVar "file")) (ETuple (EVar "path") (EVar "src") (EBinOp "++" (EVar "diags") (EListLit (EVar "diag")))) (ETuple (EVar "path") (EVar "src") (EVar "diags"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Loc" true) (mem "Ty" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "Decl" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "Pat" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false) (mem "exprKind" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseResultPairs" false) (mem "parseWithPositionsOptPairs" false) (mem "prescanErrorPairs" false) (mem "ParseError" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false) (mem "fileOfModuleId" false) (mem "findProjectRootOrSelf" false) (mem "moduleIdOfPath" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" false) (mem "ProjectIndex" false) (mem "combineDigests" false) (mem "emptyProjectIndex" false) (mem "fileRows" false) (mem "stdlibShardDir" false) (mem "projectShardDir" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true) (mem "ppSeverity" false) (mem "readFileSafe" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false) (mem "stringTrim" false) (mem "isSome" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false) (mem "keys" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false) (mem "indexed" false) (mem "nub" false))))
(DUse false (UseGroup ("string") ((mem "indexOf" false) (mem "lines" false))))
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "stripMdk" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Ctx" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "Fixability" true) (mem "ProjectRule" true) (mem "Rule" true) (mem "RuleCheck" true) (mem "RuleMeta" false) (mem "StdlibIndex" true) (mem "Summary" false) (mem "StdlibIndexError" true) (mem "Visitor" true) (mem "factComments" false) (mem "fixToDiagFix" false) (mem "factDupClauses" false) (mem "factScopes" false) (mem "clampApplicability" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "memoNew" false) (mem "mkStdlibIndex" false) (mem "projectIndexOf" false) (mem "stdlibIndexFingerprint" false) (mem "stdlibLocalModAsked" false) (mem "withStdlibLocalMods" false) (mem "needsProjectIndex" false) (mem "needsScopes" false) (mem "needsStdlibIndex" false) (mem "needsWildIndex" false) (mem "readsIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "Use" true) (mem "bindersNamed" false) (mem "bindersNamedIn" false) (mem "buildScopes" false) (mem "usesNamedIn" false) (mem "wildImports" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false) (mem "declLocList" false) (mem "sortUniqS" false) (mem "zipDeclPos" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "demoteOverComments" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupClauseOfDecl" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "allProjectRules" false) (mem "allRules" false) (mem "projectRuleActive" false) (mem "selectRules" false))))
(DTypeSig true "mkFileFacts" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyCon "FileFacts")))))
(DFunDef false "mkFileFacts" ((PVar "src") (PVar "prog") (PVar "pos")) (ERecordCreate "FileFacts" ((fa "ffSrc" (EVar "src")) (fa "ffComments" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "collectComments") (EVar "src"))))) (fa "ffOracle" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildOracle") (EVar "prog"))))) (fa "ffDupClauses" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EDictApp "flatMap") (EVar "dupClauseOfDecl")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))) (fa "ffScopes" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildScopes") (EVar "prog"))))) (fa "ffLines" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "fromList") (EApp (EVar "lines") (EVar "src")))))) (fa "ffLocalMods" (EListLit)))))
(DTypeSig true "projectWildMods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "projectWildMods" ((PVar "path") (PVar "prog")) (EMatch (EApp (EVar "wildModsOf") (EVar "prog")) (arm (PList) () (EListLit)) (arm (PVar "wild") () (EApp (EApp (EVar "localModsIn") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "path")))) (EVar "wild")))))
(DTypeSig true "wildModsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wildModsOf" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EApp (EVar "joinWith") (ELit (LString ".")))) (EApp (EApp (EDictApp "flatMap") (EVar "wildPathsOf")) (EVar "prog")))))
(DTypeSig true "localModStates" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))))
(DFunDef false "localModStates" (PWild (PList)) (EListLit))
(DFunDef false "localModStates" ((PVar "path") (PVar "mods")) (EBlock (DoLet false false (PVar "roots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "path")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "hasModuleFile") (EVar "roots")) (EVar "m"))))) (EVar "mods")))))
(DTypeSig false "localModsIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "localModsIn" (PWild (PList)) (EListLit))
(DFunDef false "localModsIn" ((PVar "roots") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "localModsIn") (EVar "roots")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "hasModuleFile") (EVar "roots")) (EVar "m")) (EBinOp "::" (EVar "m") (EVar "others")) (EVar "others")))))
(DTypeSig false "hasModuleFile" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "hasModuleFile" ((PList) PWild) (EVar "False"))
(DFunDef false "hasModuleFile" ((PCons (PVar "r") (PVar "rs")) (PVar "m")) (EBinOp "||" (EApp (EVar "fileExists") (EApp (EApp (EVar "fileOfModuleId") (EVar "r")) (EVar "m"))) (EApp (EApp (EVar "hasModuleFile") (EVar "rs")) (EVar "m"))))
(DTypeSig false "wildPathsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildPathsOf" ((PCon "DUse" PWild (PCon "UseWild" (PVar "p")) PWild)) (EListLit (EVar "p")))
(DFunDef false "wildPathsOf" (PWild) (EListLit))
(DTypeSig true "withLocalMods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FileFacts") (TyCon "FileFacts"))))
(DFunDef false "withLocalMods" ((PVar "mods") (PVar "ff")) (ERecordUpdate (EVar "ff") ((fa "ffLocalMods" (EVar "mods")))))
(DTypeSig true "mkFileFactsAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "FileFacts")))))))
(DFunDef false "mkFileFactsAt" ((PVar "path") (PVar "src") (PVar "prog") (PVar "pos")) (EApp (EApp (EVar "withLocalMods") (EApp (EApp (EVar "projectWildMods") (EVar "path")) (EVar "prog"))) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))))
(DTypeSig true "mkFileFactsIn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyTuple (TyCon "StdlibIndex") (TyCon "FileFacts")))))))))
(DFunDef false "mkFileFactsIn" ((PVar "idx") (PVar "path") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "wild") (EApp (EVar "wildModsOf") (EVar "prog"))) (DoLet false false (PVar "idxHere") (EApp (EApp (EVar "withStdlibLocalMods") (EApp (EApp (EVar "localModStates") (EVar "path")) (EVar "wild"))) (EVar "idx"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "filterList") (EApp (EVar "stdlibLocalModAsked") (EVar "idxHere"))) (EVar "wild"))) (DoExpr (ETuple (EVar "idxHere") (EApp (EApp (EVar "withLocalMods") (EVar "local")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos")))))))
(DTypeSig true "factDirectives" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "factDirectives" ((PVar "ff")) (EApp (EVar "collectDirectives") (EApp (EVar "factComments") (EVar "ff"))))
(DTypeSig true "lintProgram" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgram" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (EVar "pos")) (EVar "prog")))
(DTypeSig true "lintProgramFacts" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgramFacts" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "rules"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))
(DTypeSig true "ranked" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))))))
(DFunDef false "ranked" (PWild (PList)) (EListLit))
(DFunDef false "ranked" ((PVar "i") (PCons (PVar "r") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EVar "r")) (EApp (EApp (EVar "ranked") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig true "lintProgramRanked" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "lintProgramRanked" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "enabled") (EApp (EApp (EVar "filterList") (EVar "rankedEnabled")) (EVar "rules"))) (DoLet false false (PVar "visitorSets") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "rf")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleVisitors") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EApp (EVar "snd") (EVar "rf"))))) (EVar "enabled"))) (DoLet false false (PVar "walked") (EIf (EApp (EVar "isEmptyL") (EVar "visitorSets")) (EListLit) (EApp (EApp (EVar "runVisitors") (EVar "visitorSets")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "enabled")) (EVar "walked")))))
(DTypeSig false "rankedEnabled" (TyFun (TyTuple (TyCon "Int") (TyCon "Rule")) (TyCon "Bool")))
(DFunDef false "rankedEnabled" ((PTuple PWild (PVar "r"))) (EFieldAccess (EVar "r") "enabled"))
(DTypeSig false "ruleVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Visitor"))))))))))
(DFunDef false "ruleVisitors" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PVar "r")) (EMatch (EFieldAccess (EVar "r") "check") (arm (PCon "WholeFile" PWild) () (EListLit)) (arm (PCon "Visits" (PVar "visits")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "visits") (EApp (EApp (EVar "indexFor") (EVar "r")) (EVar "idx"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "indexFor" (TyFun (TyCon "Rule") (TyFun (TyCon "StdlibIndex") (TyCon "StdlibIndex"))))
(DFunDef false "indexFor" ((PVar "r") (PVar "idx")) (EIf (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")) (EVar "idx") (EVar "emptyStdlibIndex")))
(DTypeSig false "ruleFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "ruleFindings" (PWild PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "ruleFindings" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PCons (PTuple (PVar "rank") (PVar "r")) (PVar "rs")) (PVar "walked")) (EMatch (EFieldAccess (EVar "r") "check") (arm (PCon "WholeFile" (PVar "check")) () (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EVar "rank") (EApp (EApp (EVar "restampFinding") (EVar "r")) (EVar "f"))))) (EApp (EApp (EApp (EApp (EApp (EVar "check") (EApp (EApp (EVar "indexFor") (EVar "r")) (EVar "idx"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EVar "walked")))) (arm (PCon "Visits" PWild) () (EMatch (EVar "walked") (arm (PCons (PVar "hits") (PVar "rest")) () (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EVar "rank") (EApp (EApp (EVar "restampFinding") (EVar "r")) (EVar "f"))))) (EVar "hits")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EVar "rest")))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ruleFindings") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog")) (EVar "rs")) (EListLit)))))))
(DTypeSig true "runVisitors" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Visitor"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runVisitors" ((PVar "sets") (PVar "decls")) (EBlock (DoLet false false (PVar "tagged") (EApp (EVar "indexed") (EVar "sets"))) (DoLet false false (PVar "exprHooks") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "hooksOf") (EVar "exprHookOf"))) (EVar "tagged"))) (DoLet false false (PVar "declHooks") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "hooksOf") (EVar "declHookOf"))) (EVar "tagged"))) (DoLet false false (PVar "hits") (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "exprHooks")) (EVar "declHooks")) (EListLit)) (EVar "decls")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "findingsTagged") (EApp (EVar "fst") (EVar "t"))) (EVar "hits")))) (EVar "tagged")))))
(DData Private "ExprHook" () ((variant "ExprHook" (ConPos (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExprKind"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Private "DeclHook" () ((variant "DeclHook" (ConPos (TyCon "Int") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DData Private "BodyScope" () ((variant "BodyScope" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "BodyKind") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Private "BodyKind" () ((variant "PlainBody" (ConPos)) (variant "TestBody" (ConPos))) ())
(DTypeSig false "hooksOf" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyVar "h")))) (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Visitor"))) (TyApp (TyCon "List") (TyVar "h")))))
(DFunDef false "hooksOf" ((PVar "hookOf") (PTuple (PVar "i") (PVar "vs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "hookOf") (EVar "i"))) (EVar "vs")))
(DTypeSig false "exprHookOf" (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyCon "ExprHook")))))
(DFunDef false "exprHookOf" ((PVar "i") (PCon "OnExpr" (PVar "kinds") (PVar "cb"))) (EListLit (EApp (EApp (EApp (EVar "ExprHook") (EVar "i")) (EApp (EVar "Some") (EVar "kinds"))) (EVar "cb"))))
(DFunDef false "exprHookOf" ((PVar "i") (PCon "OnAnyExpr" (PVar "cb"))) (EListLit (EApp (EApp (EApp (EVar "ExprHook") (EVar "i")) (EVar "None")) (EVar "cb"))))
(DFunDef false "exprHookOf" (PWild (PCon "OnDecl" PWild)) (EListLit))
(DTypeSig false "declHookOf" (TyFun (TyCon "Int") (TyFun (TyCon "Visitor") (TyApp (TyCon "List") (TyCon "DeclHook")))))
(DFunDef false "declHookOf" (PWild (PCon "OnExpr" PWild PWild)) (EListLit))
(DFunDef false "declHookOf" (PWild (PCon "OnAnyExpr" PWild)) (EListLit))
(DFunDef false "declHookOf" ((PVar "i") (PCon "OnDecl" (PVar "cb"))) (EListLit (EApp (EApp (EVar "DeclHook") (EVar "i")) (EVar "cb"))))
(DTypeSig false "findingsTagged" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "findingsTagged" ((PVar "i") (PVar "hits")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "h")) (EBinOp "==" (EApp (EVar "fst") (EVar "h")) (EVar "i")))) (EVar "hits"))))
(DTypeSig false "walkDecls" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyApp (TyCon "List") (TyCon "DeclHook")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "walkDecls" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkDecls" ((PVar "exprHooks") (PVar "declHooks") (PVar "acc") (PCons (PTuple (PVar "d") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "bodies") (EApp (EVar "declBodies") (EVar "d"))) (DoLet false false (PVar "acc2") (EMatch (EVar "declHooks") (arm (PList) () (EVar "acc")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "runDeclHooks") (EApp (EApp (EApp (EApp (EVar "scopeCtx") (EApp (EApp (EVar "declScope") (EVar "bodies")) (EVar "loc"))) (EVar "KLoc")) (EVar "loc")) (EVar "None"))) (EVar "d")) (EVar "acc")) (EVar "declHooks"))))) (DoLet false false (PVar "acc3") (EMatch (EVar "exprHooks") (arm (PList) () (EVar "acc2")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "walkBodies") (EVar "exprHooks")) (EVar "loc")) (EVar "acc2")) (EVar "bodies"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "exprHooks")) (EVar "declHooks")) (EVar "acc3")) (EVar "rest")))))
(DTypeSig false "declScope" (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "BodyScope"))))
(DFunDef false "declScope" ((PList) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (ELit (LString ""))) (EListLit)) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "declScope" ((PCons (PCon "DeclBody" (PVar "owner") PWild) PWild) (PVar "loc")) (EApp (EApp (EVar "ownerScope") (EVar "owner")) (EVar "loc")))
(DTypeSig false "ownerScope" (TyFun (TyCon "BodyOwner") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "BodyScope"))))
(DFunDef false "ownerScope" ((PCon "OwnerClause" (PVar "name") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerImplMethod" PWild (PVar "m") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "m")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerIfaceDefault" PWild (PVar "m") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "m")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerTest" (PVar "name")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EListLit)) (EVar "TestBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerProp" (PVar "name") PWild) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EListLit)) (EVar "TestBody")) (EVar "loc")))
(DFunDef false "ownerScope" ((PCon "OwnerLetGroup" (PVar "name") (PVar "ps")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "BodyScope") (EVar "name")) (EVar "ps")) (EVar "PlainBody")) (EVar "loc")))
(DTypeSig false "scopeCtx" (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ctx"))))))
(DFunDef false "scopeCtx" ((PCon "BodyScope" (PVar "name") (PVar "ps") (PVar "kind") (PVar "declLoc")) (PVar "parent") (PVar "span") (PVar "own")) (ERecordCreate "Ctx" ((fa "ctxDeclName" (EVar "name")) (fa "ctxParams" (EVar "ps")) (fa "ctxInTest" (EApp (EVar "isTestBody") (EVar "kind"))) (fa "ctxParent" (EIf (EBinOp "==" (EVar "parent") (EVar "KLoc")) (EVar "None") (EApp (EVar "Some") (EVar "parent")))) (fa "ctxSpan" (EVar "span")) (fa "ctxOwn" (EVar "own")) (fa "ctxDeclLoc" (EVar "declLoc")))))
(DTypeSig false "isTestBody" (TyFun (TyCon "BodyKind") (TyCon "Bool")))
(DFunDef false "isTestBody" ((PCon "TestBody")) (EVar "True"))
(DFunDef false "isTestBody" ((PCon "PlainBody")) (EVar "False"))
(DTypeSig false "runDeclHooks" (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclHook")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "runDeclHooks" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "runDeclHooks" ((PVar "ctx") (PVar "d") (PVar "acc") (PCons (PCon "DeclHook" (PVar "i") (PVar "cb")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "runDeclHooks") (EVar "ctx")) (EVar "d")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EApp (EApp (EVar "cb") (EVar "ctx")) (EVar "d"))) (EVar "acc"))) (EVar "rest")))
(DTypeSig false "pushTagged" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))
(DFunDef false "pushTagged" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "pushTagged" ((PVar "i") (PCons (PVar "f") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EVar "fs")) (EBinOp "::" (ETuple (EVar "i") (EVar "f")) (EVar "acc"))))
(DTypeSig false "walkBodies" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))
(DFunDef false "walkBodies" (PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkBodies" ((PVar "hooks") (PVar "loc") (PVar "acc") (PCons (PCon "DeclBody" (PVar "owner") (PVar "body")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "walkBodies") (EVar "hooks")) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "hooks")) (EApp (EApp (EVar "ownerScope") (EVar "owner")) (EVar "loc"))) (EVar "KLoc")) (EVar "loc")) (EVar "acc")) (EVar "body"))) (EVar "rest")))
(DTypeSig false "walkExpr" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "walkExpr" ((PVar "hooks") (PVar "scope") (PVar "parent") PWild (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkWrapped") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "l")) (EVar "l")) (EVar "acc")) (EVar "inner")))
(DFunDef false "walkExpr" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "None")) (EVar "acc")) (EVar "e")))
(DTypeSig false "walkWrapped" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "walkWrapped" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "outer") PWild (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkWrapped") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "outer")) (EVar "l")) (EVar "acc")) (EVar "inner")))
(DFunDef false "walkWrapped" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "outer") (PVar "innermost") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EApp (EVar "Some") (EVar "innermost"))) (EApp (EVar "Some") (EVar "outer"))) (EVar "acc")) (EVar "e")))
(DTypeSig false "walkNode" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))))
(DFunDef false "walkNode" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "own") (PVar "acc") (PVar "e")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "exprKind") (EVar "e"))) (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EApp (EApp (EApp (EApp (EVar "scopeCtx") (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "own"))) (EVar "k")) (EVar "e")) (EVar "acc")) (EVar "hooks"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkKids") (EVar "hooks")) (EVar "scope")) (EVar "k")) (EVar "span")) (EVar "acc2")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "walkKids" (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyFun (TyCon "BodyScope") (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))))))))))
(DFunDef false "walkKids" (PWild PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkKids" ((PVar "hooks") (PVar "scope") (PVar "parent") (PVar "span") (PVar "acc") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkKids") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "hooks")) (EVar "scope")) (EVar "parent")) (EVar "span")) (EVar "acc")) (EVar "c"))) (EVar "cs")))
(DTypeSig false "visitHooks" (TyFun (TyCon "Ctx") (TyFun (TyCon "ExprKind") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyFun (TyApp (TyCon "List") (TyCon "ExprHook")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))))
(DFunDef false "visitHooks" (PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "visitHooks" ((PVar "ctx") (PVar "k") (PVar "e") (PVar "acc") (PCons (PCon "ExprHook" (PVar "i") (PVar "kinds") (PVar "cb")) (PVar "rest"))) (EIf (EApp (EApp (EVar "hookWants") (EVar "k")) (EVar "kinds")) (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EVar "ctx")) (EVar "k")) (EVar "e")) (EApp (EApp (EApp (EVar "pushTagged") (EVar "i")) (EApp (EApp (EVar "cb") (EVar "ctx")) (EVar "e"))) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "visitHooks") (EVar "ctx")) (EVar "k")) (EVar "e")) (EVar "acc")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hookWants" (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExprKind"))) (TyCon "Bool"))))
(DFunDef false "hookWants" (PWild (PCon "None")) (EVar "True"))
(DFunDef false "hookWants" ((PVar "k") (PCon "Some" (PVar "kinds"))) (EApp (EApp (EVar "kindIn") (EVar "k")) (EVar "kinds")))
(DTypeSig false "kindIn" (TyFun (TyCon "ExprKind") (TyFun (TyApp (TyCon "List") (TyCon "ExprKind")) (TyCon "Bool"))))
(DFunDef false "kindIn" (PWild (PList)) (EVar "False"))
(DFunDef false "kindIn" ((PVar "k") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EVar "k") (EVar "x")) (EApp (EApp (EVar "kindIn") (EVar "k")) (EVar "xs"))))
(DTypeSig false "restampFinding" (TyFun (TyCon "Rule") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampFinding" ((PVar "r") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EFieldAccess (EVar "r") "severity")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EApp (EApp (EMethodRef "map") (EApp (EVar "clampFix") (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability"))) (EFieldAccess (EVar "f") "fix"))))))
(DTypeSig false "clampFix" (TyFun (TyCon "Fixability") (TyFun (TyCon "Fix") (TyCon "Fix"))))
(DFunDef false "clampFix" ((PVar "fixability") (PVar "fx")) (EMatch (EApp (EVar "maxApplicability") (EVar "fixability")) (arm (PCon "Some" (PVar "ceiling")) () (ERecordCreate "Fix" ((fa "fixApplicability" (EApp (EApp (EVar "clampApplicability") (EVar "ceiling")) (EFieldAccess (EVar "fx") "fixApplicability"))) (fa "fixEdits" (EFieldAccess (EVar "fx") "fixEdits")) (fa "fixMessage" (EFieldAccess (EVar "fx") "fixMessage"))))) (arm (PCon "None") () (EVar "fx"))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EFieldAccess (EVar "f") "fix")))))
(DTypeSig true "stdlibIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "stdlibIndexNeeded" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "ruleNeedsIndex") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig true "stdlibIndexNeededFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "stdlibIndexNeededFor" ((PVar "only") (PVar "disable") (PVar "paths")) (EBinOp "||" (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EVar "disable")) (EBinOp "&&" (EApp (EApp (EVar "wildIndexNeeded") (EVar "only")) (EVar "disable")) (EApp (EVar "anyPathWild") (EVar "paths")))))
(DTypeSig true "projectIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "projectIndexNeeded" ((PVar "only") (PVar "disable")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsProjectIndex")) (EVar "allRules")) (EVar "only")) (EVar "disable")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsProjectIndex")) (EVar "allProjectRules")) (EVar "only")) (EVar "disable"))))
(DTypeSig false "anyActive" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyActive" ((PVar "declares") (PVar "roster") (PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "activeWith") (EVar "declares")) (EVar "only")) (EVar "disable"))) (EVar "roster")))
(DTypeSig false "activeWith" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool"))))))
(DFunDef false "activeWith" ((PVar "declares") (PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "declares") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "indexForRun" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))
(DFunDef false "indexForRun" ((PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRoster") (EVar "allRules")) (ELit (LString ""))) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRoster" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))))
(DFunDef false "indexForRoster" ((PVar "roster") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRosterIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))) (EVar "roster")) (EVar "root")) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRosterIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))))))))
(DFunDef false "indexForRosterIn" ((PVar "sdir") (PVar "shardDir") (PVar "roster") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexForRostersIn") (EVar "sdir")) (EVar "shardDir")) (EVar "roster")) (EVar "allProjectRules")) (EVar "root")) (EVar "keepAll")) (EVar "only")) (EVar "disable")) (EVar "paths")))
(DTypeSig true "indexForRostersIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))))))))
(DFunDef false "indexForRostersIn" ((PVar "sdir") (PVar "shardDir") (PVar "roster") (PVar "projects") (PVar "root") (PVar "keepAll") (PVar "only") (PVar "disable") (PVar "paths")) (EBlock (DoLet false false (PVar "only2") (EIf (EVar "keepAll") (EListLit) (EVar "only"))) (DoLet false false (PVar "disable2") (EIf (EVar "keepAll") (EListLit) (EVar "disable"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsProjectIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsProjectIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EApp (EApp (EApp (EVar "buildProjectIndexResultRootsIn") (EVar "sdir")) (EVar "shardDir")) (EIf (EBinOp "==" (EVar "root") (ELit (LString ""))) (EApp (EVar "projectRootsOf") (EVar "paths")) (EListLit (EVar "root")))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsStdlibIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsStdlibIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EBinOp "&&" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "anyActive") (EVar "needsWildIndex")) (EVar "roster")) (EVar "only2")) (EVar "disable2")) (EApp (EApp (EApp (EApp (EVar "anyProjectActive") (EVar "needsWildIndex")) (EVar "projects")) (EVar "only2")) (EVar "disable2"))) (EApp (EVar "anyPathWild") (EVar "paths")))) (EApp (EApp (EVar "buildStdlibIndexResultIn") (EVar "sdir")) (EVar "shardDir")) (EApp (EVar "Ok") (EVar "emptyStdlibIndex")))))))
(DTypeSig false "anyProjectActive" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyProjectActive" ((PVar "declares") (PVar "projects") (PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "projectActiveWith") (EVar "declares")) (EVar "only")) (EVar "disable"))) (EVar "projects")))
(DTypeSig false "projectActiveWith" (TyFun (TyFun (TyCon "RuleMeta") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ProjectRule") (TyCon "Bool"))))))
(DFunDef false "projectActiveWith" ((PVar "declares") (PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EApp (EVar "declares") (EFieldAccess (EVar "r") "meta")) (EApp (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable")) (EVar "r"))))
(DTypeSig false "projectRootsOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "projectRootsOf" ((PVar "paths")) (EApp (EVar "nub") (EApp (EApp (EMethodRef "map") (EVar "projectRootOfPath")) (EVar "paths"))))
(DTypeSig false "projectRootOfPath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "projectRootOfPath" ((PVar "path")) (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EApp (EVar "canonicalizePath") (EVar "path")))))
(DTypeSig false "anyPathWild" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "anyPathWild" ((PList)) (EVar "False"))
(DFunDef false "anyPathWild" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "||" (EApp (EVar "sourceHasWildImport") (EApp (EVar "readFileSafe") (EVar "p"))) (EApp (EVar "anyPathWild") (EVar "rest"))))
(DTypeSig true "wildIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "wildIndexNeeded" ((PVar "only") (PVar "disable")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "ruleNeedsWildIndex") (EVar "only")) (EVar "disable"))) (EVar "allRules")))
(DTypeSig false "ruleNeedsWildIndex" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleNeedsWildIndex" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "needsWildIndex") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "sourceHasWildImport" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sourceHasWildImport" ((PVar "src")) (EApp (EApp (EVar "anyList") (EVar "isWildImportLine")) (EApp (EVar "splitNl") (EVar "src"))))
(DTypeSig false "isWildImportLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWildImportLine" ((PVar "l")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "import "))) (EVar "l")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (ELit (LString ".*"))) (EVar "l")))))
(DTypeSig false "ruleNeedsScopes" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleNeedsScopes" ((PVar "r")) (EApp (EVar "needsScopes") (EFieldAccess (EVar "r") "meta")))
(DTypeSig false "ruleNeedsIndex" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleNeedsIndex" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "needsStdlibIndex") (EFieldAccess (EVar "r") "meta")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig true "buildStdlibIndexResult" (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))
(DFunDef false "buildStdlibIndexResult" () (EApp (EApp (EVar "buildStdlibIndexResultIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))))
(DTypeSig true "buildStdlibIndexResultIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))))
(DFunDef false "buildStdlibIndexResultIn" ((PVar "sdir") (PVar "shardDir")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "digests") (PVar "rows"))) (EApp (EApp (EApp (EApp (EVar "mkStdlibIndex") (EApp (EVar "combineDigests") (EVar "digests"))) (ELit (LString ""))) (EVar "rows")) (EListLit)))) (EApp (EApp (EVar "stdlibRowsResult") (EVar "sdir")) (EVar "shardDir"))))
(DTypeSig true "buildProjectIndexResult" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))
(DFunDef false "buildProjectIndexResult" ((PVar "root")) (EApp (EApp (EApp (EVar "buildProjectIndexResultIn") (EVar "lintStdlibDir")) (EApp (EVar "stdlibShardDir") (ELit LUnit))) (EVar "root")))
(DTypeSig true "buildProjectIndexResultIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))
(DFunDef false "buildProjectIndexResultIn" ((PVar "sdir") (PVar "shardDir") (PVar "root")) (EApp (EApp (EApp (EVar "buildProjectIndexResultRootsIn") (EVar "sdir")) (EVar "shardDir")) (EListLit (EVar "root"))))
(DTypeSig true "buildProjectIndexResultRootsIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex")))))))
(DFunDef false "buildProjectIndexResultRootsIn" ((PVar "sdir") (PVar "shardDir") (PVar "roots")) (EBlock (DoLet false false (PTuple (PVar "pdigests") (PVar "prows")) (EApp (EVar "projectRowsOfRoots") (EVar "roots"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sdigests") (PVar "srows"))) (EApp (EApp (EApp (EApp (EVar "mkStdlibIndex") (EApp (EVar "combineDigests") (EVar "sdigests"))) (EApp (EVar "combineDigests") (EVar "pdigests"))) (EVar "srows")) (EVar "prows")))) (EApp (EApp (EVar "stdlibRowsResult") (EVar "sdir")) (EVar "shardDir"))))))
(DTypeSig false "indexStamp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "indexStamp" (PWild) (EBlock (DoLet false false (PVar "fp") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "fp") (ELit (LString ""))) (EApp (EVar "ruleSetStamp") (ELit LUnit)) (EVar "fp")))))
(DTypeSig false "stdlibRowsResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))))
(DFunDef false "stdlibRowsResult" ((PVar "sdir") (PVar "shardDir")) (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "sdir")) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EListLit) (EListLit)))) (arm (PCon "Some" (PVar "rels")) () (EBlock (DoLet false false (PVar "stamp") (EApp (EVar "indexStamp") (ELit LUnit))) (DoLet false false (PVar "dir") (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (ELit (LString "")) (EVar "shardDir"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "stdlibRowsGo") (EVar "dir")) (EVar "stamp")) (EVar "sdir")) (EVar "rels")))))))
(DTypeSig false "stdlibRowsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))))))
(DFunDef false "stdlibRowsGo" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (ETuple (EListLit) (EListLit))))
(DFunDef false "stdlibRowsGo" ((PVar "dir") (PVar "stamp") (PVar "sdir") (PCons (PVar "rel") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sdir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "rel"))) (ELit (LString "")))) (DoLet false false (PVar "modId") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "rel"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileRows") (EVar "True")) (EVar "lintParseSource")) (EVar "dir")) (EVar "stamp")) (EVar "modId")) (EVar "path")) (arm (PCon "Err" (PTuple (PVar "src") (PVar "e"))) () (EApp (EVar "Err") (ERecordCreate "StdlibIndexError" ((fa "path" (EVar "path")) (fa "source" (EVar "src")) (fa "diagnostic" (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))))) (arm (PCon "Ok" (PTuple (PVar "digest") (PVar "rows"))) () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "ds") (PVar "rs"))) (ETuple (EBinOp "::" (EVar "digest") (EVar "ds")) (EBinOp "++" (EVar "rows") (EVar "rs"))))) (EApp (EApp (EApp (EApp (EVar "stdlibRowsGo") (EVar "dir")) (EVar "stamp")) (EVar "sdir")) (EVar "rest"))))))))
(DTypeSig false "projectRowsOfRoots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsOfRoots" ((PVar "roots")) (EBlock (DoLet false false (PVar "perRoot") (EApp (EApp (EMethodRef "map") (EVar "projectRowsOf")) (EVar "roots"))) (DoExpr (ETuple (EApp (EApp (EDictApp "flatMap") (EVar "fst")) (EVar "perRoot")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "perRoot"))))))
(DTypeSig false "projectRowsOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsOf" ((PVar "root")) (EBlock (DoLet false false (PVar "stamp") (EApp (EVar "indexStamp") (ELit LUnit))) (DoLet false false (PVar "dir") (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (ELit (LString "")) (EApp (EVar "projectShardDir") (EVar "root")))) (DoLet false false (PVar "files") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "projectFileRows") (EVar "dir")) (EVar "stamp")) (EVar "root"))) (EApp (EVar "collectMdkFiles") (EVar "root")))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "files")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "files"))))))
(DTypeSig false "projectFileRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "projectFileRows" ((PVar "dir") (PVar "stamp") (PVar "root") (PVar "path")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileRows") (EVar "False")) (EVar "lintParseSource")) (EVar "dir")) (EVar "stamp")) (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "root"))) (EVar "path"))) (EVar "path")) (arm (PCon "Err" PWild) () (ETuple (ELit (LString "")) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "digest") (PVar "rows"))) () (ETuple (EVar "digest") (EVar "rows")))))
(DTypeSig false "lintStdlibDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "lintStdlibDir" () (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EApp (EVar "exeStdlibDir") (ELit LUnit)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "/stdlib"))))) (arm (PCon "None") () (EApp (EVar "exeStdlibDir") (ELit LUnit)))))
(DTypeSig false "exeStdlibDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "exeStdlibDir" (PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))) (ELit (LString "/stdlib"))))
(DTypeSig true "rosterNeeds" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyCon "Bool")))
(DFunDef false "rosterNeeds" ((PVar "roster")) (EApp (EApp (EVar "anyList") (EVar "ruleReadsIndex")) (EVar "roster")))
(DTypeSig false "ruleReadsIndex" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleReadsIndex" ((PVar "r")) (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")))
(DTypeSig true "rankedIndexRules" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Rule")))))
(DFunDef false "rankedIndexRules" ((PVar "roster")) (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EVar "ruleReadsIndex") (EApp (EVar "snd") (EVar "rf"))))) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "roster"))))
(DTypeSig true "splitByIndex" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Finding")))))))
(DFunDef false "splitByIndex" ((PVar "roster") (PVar "found")) (EBlock (DoLet false false (PVar "indexRanks") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "rankedIndexRules") (EVar "roster")))) (DoExpr (ETuple (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EApp (EVar "fst") (EVar "rf"))) (EVar "indexRanks"))))) (EVar "found")) (EApp (EApp (EVar "filterList") (ELam ((PVar "rf")) (EApp (EApp (EDictApp "elem") (EApp (EVar "fst") (EVar "rf"))) (EVar "indexRanks")))) (EVar "found"))))))
(DTypeSig true "indexKeyFor" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))))
(DFunDef false "indexKeyFor" () (EApp (EVar "indexKeyWith") (EVar "stdlibIndexFingerprint")))
(DTypeSig true "indexKeyWith" (TyFun (TyFun (TyCon "StdlibIndex") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String")))))
(DFunDef false "indexKeyWith" ((PVar "fingerprintOf") (PVar "roster") (PVar "idx")) (EIf (EApp (EVar "rosterNeeds") (EVar "roster")) (EApp (EVar "fingerprintOf") (EVar "idx")) (ELit (LString ""))))
(DTypeSig true "lintParseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "lintParseSource" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "tokens") (PVar "offsets")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "prescanErrorPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "parsed")) () (EApp (EVar "Ok") (EVar "parsed"))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "parseWithPositions") (EVar "src")))) (EApp (EApp (EApp (EVar "parseResultPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))))))
(DTypeSig false "stdlibMemberPaths" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stdlibMemberPaths" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (ELit (LString ""))) (EVar "entries")))))))
(DTypeSig false "memberPathsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "memberPathsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "memberPathsGo" ((PVar "dir") (PVar "prefix") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (EMatch (EApp (EVar "listDir") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "/")))) (EMethodRef "sub"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EVar "prefix")) (EVar "rest"))))))
(DTypeSig false "liveFindingLines" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "liveFindingLines" ((PVar "src") (PVar "facts") (PVar "rules") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "findingRuleLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "emptyStdlibIndex")) (EVar "rules")) (ELit (LString ""))) (EVar "facts")) (EVar "pos")) (EVar "prog")))))
(DTypeSig false "findingRuleLine" (TyFun (TyCon "Finding") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "findingRuleLine" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" PWild (PVar "line") PWild PWild PWild)) () (EListLit (ETuple (EFieldAccess (EVar "f") "rule") (EVar "line")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ruleLiveIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleLiveIn" ((PVar "live") (PTuple (PVar "s") (PVar "e")) (PVar "r")) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EFieldAccess (EVar "r") "name")) (EBinOp "<=" (EVar "s") (EApp (EVar "snd") (EVar "p")))) (EBinOp "<=" (EApp (EVar "snd") (EVar "p")) (EVar "e"))))) (EVar "live")))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmts") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EMethodRef "map") (EVar "commentLine")) (EVar "cmts"))) (DoLet false false (PVar "declPos") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "allFacts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (DoLet false false (PVar "facts") (EIf (EApp (EApp (EVar "anyList") (EVar "ruleNeedsScopes")) (EVar "rules")) (EApp (EVar "Some") (EVar "allFacts")) (EVar "None"))) (DoLet false false (PVar "live") (EApp (EApp (EApp (EApp (EApp (EVar "liveFindingLines") (EVar "src")) (EVar "allFacts")) (EVar "rules")) (EVar "pos")) (EVar "prog"))) (DoLet false false (PVar "tagged") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "declPos"))) (DoLet false false (PTuple (PVar "kept") (PVar "widen")) (EApp (EApp (EApp (EVar "reconcileTestImport") (EVar "cmts")) (EVar "declPos")) (EVar "tagged"))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EApp (EApp (EVar "withWiden") (EVar "widen")) (EVar "kept"))) (EApp (EVar "listLen") (EVar "kept"))))))
(DTypeSig false "withWiden" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "withWiden" ((PCon "None") (PVar "splices")) (EVar "splices"))
(DFunDef false "withWiden" ((PCon "Some" (PVar "sp")) (PVar "splices")) (EApp (EApp (EVar "insertSpliceAsc") (EVar "sp")) (EVar "splices")))
(DTypeSig false "testVerbNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testVerbNames" () (EListLit (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")) (ELit (LString "expectTrue")) (ELit (LString "expectFalse"))))
(DData Private "VerbCount" () ((variant "VerbCount" (ConNamed (field "verbName" (TyCon "String")) (field "verbUses" (TyCon "Int"))))) ())
(DData Private "VerbDelta" () ((variant "VerbDelta" (ConNamed (field "stopped" (TyApp (TyCon "List") (TyCon "String"))) (field "started" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "testVerbCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "VerbCount"))))
(DFunDef false "testVerbCounts" ((PVar "ds")) (EBlock (DoLet false false (PVar "refs") (EApp (EApp (EDictApp "flatMap") (EVar "declRefs")) (EVar "ds"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ERecordCreate "VerbCount" ((fa "verbName" (EVar "v")) (fa "verbUses" (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "v")))) (EVar "refs")))))))) (EVar "testVerbNames")))))
(DTypeSig false "testVerbDelta" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "VerbDelta"))))
(DFunDef false "testVerbDelta" ((PVar "d") (PVar "newDecls")) (EBlock (DoLet false false (PVar "before") (EApp (EVar "testVerbCounts") (EListLit (EVar "d")))) (DoLet false false (PVar "after") (EApp (EVar "testVerbCounts") (EVar "newDecls"))) (DoLet false false (PVar "moved") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "before"))) (DoExpr (ERecordCreate "VerbDelta" ((fa "stopped" (EApp (EApp (EMethodRef "map") (EVar "verbOf")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "<" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "moved")))) (fa "started" (EApp (EApp (EMethodRef "map") (EVar "verbOf")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EApp (EVar "verbUsesIn") (EFieldAccess (EVar "c") "verbName")) (EVar "after")) (EFieldAccess (EVar "c") "verbUses")))) (EVar "moved")))))))))
(DTypeSig false "verbOf" (TyFun (TyCon "VerbCount") (TyCon "String")))
(DFunDef false "verbOf" ((PVar "c")) (EFieldAccess (EVar "c") "verbName"))
(DTypeSig false "verbUsesIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "VerbCount")) (TyCon "Int"))))
(DFunDef false "verbUsesIn" ((PVar "v") (PVar "cs")) (EMatch (EApp (EApp (EDictApp "find") (ELam ((PVar "c")) (EBinOp "==" (EFieldAccess (EVar "c") "verbName") (EVar "v")))) (EVar "cs")) (arm (PCon "Some" (PVar "c")) () (EFieldAccess (EVar "c") "verbUses")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "testFixAllowed" (TyFun (TyApp (TyCon "Option") (TyCon "FileFacts")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "testFixAllowed" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "testFixAllowed" ((PCon "None") PWild PWild PWild) (EVar "False"))
(DFunDef false "testFixAllowed" ((PCon "Some" (PVar "facts")) (PTuple (PVar "from") (PVar "to")) (PVar "matched") (PVar "introduced")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "matched")) (EApp (EApp (EVar "allList") (EApp (EApp (EApp (EVar "matchedIsTestVerb") (EVar "fs")) (EVar "from")) (EVar "to"))) (EVar "matched"))) (EApp (EApp (EVar "allList") (EApp (EApp (EApp (EVar "introducedIsFree") (EVar "fs")) (EVar "from")) (EVar "to"))) (EVar "introduced"))))))
(DTypeSig false "matchedIsTestVerb" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "matchedIsTestVerb" ((PVar "fs") (PVar "from") (PVar "to") (PVar "verb")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EApp (EApp (EVar "usesNamedIn") (EVar "fs")) (EVar "from")) (EVar "to")) (EVar "verb"))) (DoExpr (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "uses")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "useIsTestVerb") (EVar "fs")) (EVar "verb"))) (EVar "uses"))))))
(DTypeSig false "useIsTestVerb" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Use") (TyCon "Bool")))))
(DFunDef false "useIsTestVerb" ((PVar "fs") (PVar "verb") (PVar "u")) (EMatch (EFieldAccess (EVar "u") "useBinder") (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "isTestMember") (EVar "verb")) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EDictApp "elem") (EListLit (ELit (LString "test")))) (EApp (EVar "wildImports") (EVar "fs"))))))
(DTypeSig false "isTestMember" (TyFun (TyCon "String") (TyFun (TyCon "Binder") (TyCon "Bool"))))
(DFunDef false "isTestMember" ((PVar "verb") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BImport")) (EBinOp "==" (EFieldAccess (EVar "b") "binderFrom") (EListLit (ELit (LString "test"))))) (EBinOp "==" (EFieldAccess (EVar "b") "binderOrigin") (EVar "verb"))))
(DTypeSig false "introducedIsFree" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "introducedIsFree" ((PVar "fs") (PVar "from") (PVar "to") (PVar "verb")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EApp (EVar "bindersNamedIn") (EVar "fs")) (EVar "from")) (EVar "to")) (EVar "verb"))) (EApp (EVar "isEmptyL") (EApp (EApp (EVar "filterList") (EVar "unplacedBinder")) (EApp (EApp (EVar "bindersNamed") (EVar "fs")) (EVar "verb"))))) (EApp (EApp (EVar "allList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EListLit (ELit (LString "test")))))) (EApp (EVar "wildImports") (EVar "fs")))) (EApp (EApp (EVar "allList") (EApp (EVar "isTestMember") (EVar "verb"))) (EApp (EApp (EVar "filterList") (EVar "fileLevel")) (EApp (EApp (EVar "bindersNamed") (EVar "fs")) (EVar "verb"))))))
(DTypeSig false "unplacedBinder" (TyFun (TyCon "Binder") (TyCon "Bool")))
(DFunDef false "unplacedBinder" ((PVar "b")) (EMatch (EFieldAccess (EVar "b") "binderSpan") (arm (PCon "Loc" PWild (PLit (LInt 0)) PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "fileLevel" (TyFun (TyCon "Binder") (TyCon "Bool")))
(DFunDef false "fileLevel" ((PVar "b")) (EMatch (EFieldAccess (EVar "b") "binderKind") (arm (PCon "BImport") () (EVar "True")) (arm (PCon "BTopLevel") () (EVar "True")) (arm (PCon "BLetGroup") () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "reconcileTestImport" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))))
(DFunDef false "reconcileTestImport" ((PVar "cmts") (PVar "declPos") (PVar "tagged")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "testGroups") (EVar "declPos"))) (DoLet false false (PVar "listed") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EApp (EVar "fst") (EVar "g"))))) (EVar "groups"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "anyList") (EVar "isTestWild")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "declPos")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "groups")) (EVar "wild")) (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "tagged")) (EVar "None")) (EBlock (DoLet false false (PVar "missingOf") (ELam ((PVar "verbs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "listed"))))) (EVar "verbs")))) (DoLet false false (PVar "target") (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "groups"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EBinOp "||" (EApp (EVar "isEmptyL") (EApp (EVar "missingOf") (EApp (EVar "snd") (EVar "t")))) (EApp (EVar "isSome") (EVar "target"))))) (EVar "tagged"))) (DoLet false false (PVar "missing") (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "t")) (EApp (EVar "missingOf") (EApp (EVar "snd") (EVar "t"))))) (EVar "kept")))) (DoExpr (EMatch (EVar "target") (arm (PCon "Some" (PTuple (PVar "pub") (PVar "path") (PVar "members") (PVar "loc") (PVar "dp") (PVar "trailing"))) () (EIf (EApp (EVar "isEmptyL") (EVar "missing")) (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "kept")) (EVar "None")) (EBlock (DoLet false false (PVar "widened") (EApp (EApp (EVar "UseGroup") (EVar "path")) (EBinOp "++" (EVar "members") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "v")) (EVar "False")) (EVar "loc")) (EVar "None")))) (EVar "missing"))))) (DoLet false false (PVar "txt") (EBinOp "++" (EApp (EVar "declToString") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "widened")) (EVar "loc"))) (EVar "trailing"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "kept")) (EApp (EVar "Some") (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "txt")))))))) (arm (PCon "None") () (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "kept")) (EVar "None"))))))))))
(DTypeSig false "isTestWild" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTestWild" ((PCon "DUse" PWild (PCon "UseWild" (PVar "path")) PWild)) (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))))
(DFunDef false "isTestWild" (PWild) (EVar "False"))
(DTypeSig false "testGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "UseMember")) (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc") (TyCon "DeclPos"))))))
(DFunDef false "testGroups" ((PList)) (EListLit))
(DFunDef false "testGroups" ((PCons (PTuple (PCon "DUse" (PVar "pub") (PCon "UseGroup" (PVar "path") (PVar "members")) (PVar "loc")) (PVar "dp")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))) (EBinOp "::" (ETuple (EVar "members") (ETuple (EVar "pub") (EVar "path") (EVar "loc") (EVar "dp"))) (EApp (EVar "testGroups") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "testGroups" ((PCons PWild (PVar "rest"))) (EApp (EVar "testGroups") (EVar "rest")))
(DTypeSig false "findWidenable" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "UseMember")) (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc") (TyCon "DeclPos")))) (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Loc") (TyCon "DeclPos") (TyCon "String"))))))
(DFunDef false "findWidenable" (PWild (PList)) (EVar "None"))
(DFunDef false "findWidenable" ((PVar "cmts") (PCons (PTuple (PVar "members") (PTuple (PVar "pub") (PVar "path") (PVar "loc") (PVar "dp"))) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "spanComments") (EVar "cmts")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (arm (PList) () (EApp (EVar "Some") (ETuple (EVar "pub") (EVar "path") (EVar "members") (EVar "loc") (EVar "dp") (ELit (LString ""))))) (arm (PList (PVar "c")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (ETuple (EVar "pub") (EVar "path") (EVar "members") (EVar "loc") (EVar "dp") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "commentText") (EVar "c"))))) (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "findWidenable") (EVar "cmts")) (EVar "rest")))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cmts") (PVar "s") (PVar "e")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp "<=" (EVar "s") (EApp (EVar "commentLine") (EVar "c"))) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "e"))))) (EVar "cmts")))
(DTypeSig false "insertSpliceAsc" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "insertSpliceAsc" ((PVar "sp") (PList)) (EListLit (EVar "sp")))
(DFunDef false "insertSpliceAsc" ((PTuple (PVar "s") (PVar "e") (PVar "t")) (PCons (PTuple (PVar "s2") (PVar "e2") (PVar "t2")) (PVar "rest"))) (EIf (EBinOp "<" (EVar "s") (EVar "s2")) (EBinOp "::" (ETuple (EVar "s") (EVar "e") (EVar "t")) (EBinOp "::" (ETuple (EVar "s2") (EVar "e2") (EVar "t2")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "s2") (EVar "e2") (EVar "t2")) (EApp (EApp (EVar "insertSpliceAsc") (ETuple (EVar "s") (EVar "e") (EVar "t"))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ruleActiveFixable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleActiveFixable" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))) (EApp (EVar "ruleHasFixer") (EVar "r"))))
(DTypeSig false "ruleHasFixer" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleHasFixer" ((PVar "r")) (EApp (EVar "isSome") (EFieldAccess (EVar "r") "fix")))
(DTypeSig false "collectSplices" (TyFun (TyApp (TyCon "Option") (TyCon "FileFacts")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "collectSplices" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "facts") (PVar "live") (PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EBlock (DoLet false false (PVar "liveRules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleLiveIn") (EVar "live")) (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp"))))) (EVar "rules"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "liveRules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EBlock (DoLet false false (PVar "delta") (EApp (EApp (EVar "testVerbDelta") (EVar "d")) (EVar "newDecls"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "testFixAllowed") (EVar "facts")) (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")))) (EFieldAccess (EVar "delta") "stopped")) (EFieldAccess (EVar "delta") "started")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EFieldAccess (EVar "delta") "started")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "facts")) (EVar "live")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))))
(DTypeSig false "spanHasComment" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "spanHasComment" ((PVar "cmtLines") (PVar "startLine") (PVar "endLine")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "<=" (EVar "startLine") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "endLine"))))) (EVar "cmtLines")))
(DTypeSig false "firstFix" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "firstFix" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstFix" ((PVar "orc") (PCons (PVar "r") (PVar "rs")) (PVar "d")) (EMatch (EApp (EApp (EApp (EVar "applyRuleFix") (EVar "orc")) (EVar "r")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EApp (EVar "Some") (EVar "newDecls"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rs")) (EVar "d")))))
(DTypeSig false "applyRuleFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Rule") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyRuleFix" ((PVar "orc") (PVar "r") (PVar "d")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "f") (EVar "orc")) (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "renderDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "renderDecls" ((PVar "ds")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "declToString")) (EVar "ds"))))
(DTypeSig false "applySplices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "applySplices" ((PVar "src") (PVar "splices")) (EApp (EVar "joinNl") (EApp (EApp (EVar "foldSplices") (EApp (EVar "splitNl") (EVar "src"))) (EApp (EVar "reverseL") (EVar "splices")))))
(DTypeSig false "foldSplices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "foldSplices" ((PVar "lines") (PList)) (EVar "lines"))
(DFunDef false "foldSplices" ((PVar "lines") (PCons (PTuple (PVar "s") (PVar "e") (PVar "txt")) (PVar "rest"))) (EApp (EApp (EVar "foldSplices") (EApp (EApp (EApp (EApp (EVar "spliceLines") (EVar "lines")) (EVar "s")) (EVar "e")) (EVar "txt"))) (EVar "rest")))
(DTypeSig false "spliceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spliceLines" ((PVar "lines") (PVar "s") (PVar "e") (PVar "txt")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EBinOp "-" (EVar "s") (ELit (LInt 1)))) (EVar "lines")) (EApp (EVar "splitNl") (EVar "txt"))) (EApp (EApp (EVar "drop") (EVar "e")) (EVar "lines"))))
(DTypeSig true "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")) (fa "fix" (EFieldAccess (EVar "f") "fix")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EApp (EVar "LintRule") (EFieldAccess (EVar "f") "rule"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EApp (EApp (EMethodRef "map") (EVar "fixToDiagFix")) (EFieldAccess (EVar "f") "fix"))))
(DTypeSig true "lintFileDiagTripleParsed" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileDiagTripleParsed" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EVar "path") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit)) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "decls") (PVar "pos"))) () (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "path")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "factDirectives") (EVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EMethodRef "map") (EVar "findingToDiag")) (EApp (EApp (EApp (EVar "demoteOverComments") (EVar "path")) (EVar "src")) (EVar "findings"))) (EVar "pos") (EVar "decls")))))))))
(DTypeSig true "lintFileDiagTriple" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFileDiagTriple" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EApp (EVar "dropParsedTriple") (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "path"))))
(DTypeSig false "dropParsedTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropParsedTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintToLines" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "lintToLines" ((PVar "idx") (PVar "src") (PVar "path") (PVar "pos") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "findingLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "idx")) (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "findingLine" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingLine" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString ": ["))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DTypeSig true "applySuppressions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressions" ((PVar "src") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "directivesOfSource") (EVar "src"))) (EVar "findings")))
(DTypeSig true "applySuppressionsDirs" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsDirs" ((PVar "dirs") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f"))))) (EVar "findings")))
(DTypeSig true "applySuppressionsMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMulti" ((PVar "srcs") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EMethodRef "map") (EVar "fileDirectivesOf")) (EVar "srcs"))) (EVar "findings")))
(DTypeSig true "applySuppressionsMultiDirs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMultiDirs" ((PVar "dirTable") (PVar "findings")) (EBlock (DoLet false false (PVar "table") (EApp (EVar "dirTableMap") (EVar "dirTable"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "findingSuppressedMulti") (EVar "table")) (EVar "f"))))) (EVar "findings")))))
(DTypeSig false "dirTableMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "dirTableMap" ((PVar "rows")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "dirTableFill") (EVar "m")) (EVar "rows"))) (DoExpr (EVar "m"))))
(DTypeSig false "dirTableFill" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyCon "Unit"))))
(DFunDef false "dirTableFill" (PWild (PList)) (ELit LUnit))
(DFunDef false "dirTableFill" ((PVar "m") (PCons (PTuple (PVar "p") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "has") (EVar "p")) (EVar "m")) (ELit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "p")) (EVar "ds")) (EVar "m")))) (DoExpr (EApp (EApp (EVar "dirTableFill") (EVar "m")) (EVar "rest")))))
(DTypeSig false "fileDirectivesOf" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "fileDirectivesOf" ((PTuple (PVar "path") (PVar "src"))) (ETuple (EVar "path") (EApp (EVar "directivesOfSource") (EVar "src"))))
(DTypeSig false "findingSuppressedMulti" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Directive"))) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "findingSuppressedMulti" ((PVar "dirTable") (PVar "f")) (EMatch (EApp (EApp (EVar "get") (EApp (EVar "findingFileOf") (EVar "f"))) (EVar "dirTable")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dirs")) () (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f")))))
(DTypeSig false "findingFileOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingFileOf" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EVar "file")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "directivesOfSource" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "directivesOfSource" ((PVar "src")) (EApp (EVar "collectDirectives") (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "isSuppressed" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "isSuppressed" ((PVar "dirs") (PVar "f")) (EApp (EApp (EVar "anyList") (EApp (EVar "dirCoversFinding") (EVar "f"))) (EVar "dirs")))
(DTypeSig false "dirCoversFinding" (TyFun (TyCon "Finding") (TyFun (TyCon "Directive") (TyCon "Bool"))))
(DFunDef false "dirCoversFinding" ((PVar "f") (PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "names")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names"))) (EApp (EApp (EVar "scopeMatches") (EApp (EVar "findingLineNo") (EVar "f"))) (EVar "scope"))))
(DTypeSig false "scopeMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "DirScope") (TyCon "Bool"))))
(DFunDef false "scopeMatches" (PWild (PCon "DScopeFile")) (EVar "True"))
(DFunDef false "scopeMatches" ((PCon "Some" (PVar "line")) (PCon "DScopeLine" (PVar "l"))) (EBinOp "==" (EVar "line") (EVar "l")))
(DFunDef false "scopeMatches" ((PCon "None") (PCon "DScopeLine" PWild)) (EVar "False"))
(DTypeSig false "findingLineNo" (TyFun (TyCon "Finding") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "findingLineNo" ((PVar "f")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))) (EFieldAccess (EVar "f") "loc")))
(DTypeSig true "fileSummaries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))))))
(DFunDef false "fileSummaries" ((PVar "only") (PVar "disable") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EFieldAccess (EAnnot (EVar "r") (TyCon "ProjectRule")) "name") (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "prSummarize") (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))))) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable"))) (EVar "allProjectRules"))))
(DTypeSig true "runProjectRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runProjectRules" ((PVar "only") (PVar "disable") (PVar "idx") (PVar "files")) (EApp (EApp (EApp (EApp (EApp (EVar "runProjectRulesOver") (EVar "allProjectRules")) (EVar "only")) (EVar "disable")) (EVar "idx")) (EVar "files")))
(DTypeSig true "runProjectRulesOver" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runProjectRulesOver" ((PVar "rules") (PVar "only") (PVar "disable") (PVar "idx") (PVar "files")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "runProjectRuleOn") (EVar "only")) (EVar "disable")) (EVar "idx")) (EVar "files"))) (EVar "rules")))
(DTypeSig false "runProjectRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyFun (TyCon "ProjectRule") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runProjectRuleOn" ((PVar "only") (PVar "disable") (PVar "idx") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "projectRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EFieldAccess (EVar "r") "prEvaluate") (EApp (EApp (EVar "projectIndexFor") (EVar "r")) (EVar "idx"))) (EApp (EApp (EVar "summariesOfRule") (EFieldAccess (EVar "r") "name")) (EVar "files")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectIndexFor" (TyFun (TyCon "ProjectRule") (TyFun (TyCon "StdlibIndex") (TyCon "ProjectIndex"))))
(DFunDef false "projectIndexFor" ((PVar "r") (PVar "idx")) (EIf (EApp (EVar "readsIndex") (EFieldAccess (EVar "r") "meta")) (EApp (EVar "projectIndexOf") (EVar "idx")) (EVar "emptyProjectIndex")))
(DTypeSig false "summariesOfRule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))
(DFunDef false "summariesOfRule" (PWild (PList)) (EListLit))
(DFunDef false "summariesOfRule" ((PVar "name") (PCons (PTuple (PVar "path") (PVar "ss")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (ETuple (EVar "path") (EApp (EVar "snd") (EVar "s"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "s")) (EBinOp "==" (EApp (EVar "fst") (EVar "s")) (EVar "name")))) (EVar "ss"))) (EApp (EApp (EVar "summariesOfRule") (EVar "name")) (EVar "rest"))))
(DTypeSig true "mergeProjectIntoTriples" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeProjectIntoTriples" ((PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "mergeProjectIntoTriples" ((PCons (PVar "f") (PVar "rest")) (PVar "triples")) (EApp (EApp (EVar "mergeProjectIntoTriples") (EVar "rest")) (EApp (EApp (EVar "mergeOneFinding") (EVar "f")) (EVar "triples"))))
(DTypeSig false "mergeOneFinding" (TyFun (TyCon "Finding") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeOneFinding" ((PVar "f") (PVar "triples")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "None") () (EVar "triples")) (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "tripleHasPath") (EVar "file"))) (EVar "triples")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "appendIfPath") (EVar "file")) (EApp (EVar "findingToDiag") (EVar "f")))) (EVar "triples")) (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (ELit (LString "")) (EListLit (EApp (EVar "findingToDiag") (EVar "f"))))))))))
(DTypeSig false "tripleHasPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool"))))
(DFunDef false "tripleHasPath" ((PVar "file") (PTuple (PVar "path") PWild PWild)) (EBinOp "==" (EVar "path") (EVar "file")))
(DTypeSig false "appendIfPath" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendIfPath" ((PVar "file") (PVar "diag") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EIf (EBinOp "==" (EVar "path") (EVar "file")) (ETuple (EVar "path") (EVar "src") (EBinOp "++" (EVar "diags") (EListLit (EVar "diag")))) (ETuple (EVar "path") (EVar "src") (EVar "diags"))))
