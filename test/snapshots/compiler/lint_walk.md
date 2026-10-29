# META
source_lines=1002
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_walk.mdk — the lint runner: `lintProgram*`, per-file
-- facts, the autofix driver, finding filters, inline suppressions, the cross-file
-- runner and the stdlib-index builders.  The CLI filters and severity-overrides
-- the registry's rules and hands them in, so this module knows nothing about flags.

import frontend.ast.{
  letBindName,
  Loc(..),
  Ty(..),
  UsePath(..),
  UseMember(..),
  useMemberLocal,
  IfaceMethod(..),
  Decl(..),
  ExternDecl(..),
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
  reverseL,
  splitNl,
  splitOnChar,
  joinWith,
  startsWith,
  endsWith,
  dedup,
  isSome,
}
import hash_map.{HashMap, new, get, setInPlace, has, keys, findWithDefault}
import list.{take, drop}
import tools.printer.{declToString}
import support.path.{dirOf, stripMdk}
import regex.{RegexError(..)}
import frontend.marker.{declRefs, localBoundNames}
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
  CrossFileRule(..),
  DirScope(..),
  Directive(..),
  FileFacts(..),
  Finding(..),
  Rule(..),
  StdlibIndex(..),
  StdlibIndexError(..),
  factComments,
  factDupClauses,
  memoNew,
}
import tools.lint_shared.{
  collectDirectives,
  declLocList,
  ruleNameDuplicateBody,
  stdlibIndexRule,
  sortUniqS,
  zipDeclPos,
}
import tools.lint_rules_staging.{dupClauseOfDecl, dupJoin, dupOccsOfClauses}
import tools.lint_registry.{
  allCrossFileRules, allRules, crossRuleActive, selectRules
}

export
mkFileFacts : String -> List Decl -> Positions -> FileFacts
mkFileFacts src prog pos = FileFacts {
  ffSrc = src,
  ffComments = memoNew (_ => collectComments src),
  ffOracle = memoNew (_ => buildOracle prog),
  ffDupClauses = memoNew (_ => flatMap dupClauseOfDecl (declLocList pos prog)),
}

-- The file's inline-suppression directives, off the shared comment channel.
export
factDirectives : FileFacts -> List Directive
factDirectives ff = collectDirectives (factComments ff)

-- The file's cross-file duplicate-body occurrences (what `--cache` persists),
-- off the clause keys the same-file rule also reads.
export
factDupOccs : String -> FileFacts -> List (String, Int, String, String)
factDupOccs path ff = dupOccsOfClauses path (factDupClauses ff)

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
-- comment/directive/key needs share the rules' derivations.
export
lintProgramFacts : StdlibIndex ->
  List Rule ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
lintProgramFacts idx rules path facts pos prog =
  flatMap (runRuleOn idx path facts pos prog) rules

runRuleOn : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  Rule ->
  List Finding
runRuleOn idx path facts pos prog r
  | r.enabled =
    map (restampSeverity r.severity) (r.check idx path facts pos prog)
  | otherwise = []

restampSeverity : Severity -> Finding -> Finding
restampSeverity sev f =
  Finding { rule = f.rule, message = f.message, severity = sev, loc = f.loc }

-- Whether `rule-stdlib-reimpl` — the sole `Rule` whose `check` reads its
-- `StdlibIndex` argument — is in the active `--only`/`--disable` set. Mirrors
-- `ruleActiveFixable`'s only/disable semantics (the `enabled`/fixer checks
-- that helper also makes don't apply here: the registry always enables this
-- rule). A caller uses this to decide whether `buildStdlibIndexResult` is worth
-- its cost at all.
export
stdlibIndexNeeded : List String -> List String -> Bool
stdlibIndexNeeded only disable =
  (isEmptyL only || contains stdlibIndexRule only)
    && not (contains stdlibIndexRule disable)

export
buildStdlibIndexResult : <IO> Result StdlibIndexError StdlibIndex
buildStdlibIndexResult =
  map
    (triples => mkStdlibIndex (groupStdlibSigs triples))
    (stdlibSigTriplesResult lintStdlibDir)

-- The sorted name list is computed here, once, not per linted file.
mkStdlibIndex : HashMap String (List (String, Ty)) -> StdlibIndex
mkStdlibIndex m = StdlibIndex m (sortUniqS (keys m))

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

-- ── cache-staleness guard for `--cache` ─────────────────────────────────────
-- `rule-stdlib-reimpl` (and only it, among `allRules`) reads content
-- `--cache`'s key never sees: `buildStdlibIndexResult` parses the stdlib source tree
-- from disk at runtime, not the running binary `lint_cache.ruleSetStamp`
-- hashes. Editing `stdlib/list.mdk` changes what this rule reports for an
-- UNCHANGED compiler/sqlite file, so a cached shard for that file would
-- silently keep serving the pre-edit answer forever — a wrong hit, exactly
-- the failure mode `lint_cache.mdk`'s module doc forbids. Folded into the
-- cache stamp by the caller (`lintCacheCtx`, `medaka_cli.mdk`) alongside
-- `ruleSetStamp`, so any stdlib edit invalidates every shard, the same way a
-- rule-logic change does (#2327).
export
stdlibFingerprint : <IO> String
stdlibFingerprint = match stdlibMemberPaths lintStdlibDir
  None => ""
  Some names =>
    let joined = stdlibFingerprintGo lintStdlibDir names
    -- Hashed down to a fixed-size digest rather than stored raw: this string
    -- lands in EVERY shard's `stamp` field (`lint_cache.storeEntries`), so
    -- keeping it compact matters the same way `contentHashOf`'s two-lane
    -- digest does. `listLen names` guards against the all-files-missing
    -- degenerate case ("" for both an empty stdlib and a 0-file listDir)
    -- collapsing into the same fingerprint as a genuinely absent stdlib.
    "\{hashString joined}.\{listLen names}"

stdlibFingerprintGo : String -> List String -> <IO> String
stdlibFingerprintGo _ [] = ""
stdlibFingerprintGo dir (n :: rest) =
  let path = "\{dir}/\{n}"
  let h = hashString (readFileSafe path)
  "\{n}:\{h};\{stdlibFingerprintGo dir rest}"

-- (module, name, declared type) for every exported signature in the stdlib's
-- `.mdk` files.  A directory that will not list yields [] — the
-- degradation path, silent by design (lint printing compiler-internal chatter to
-- stdout would break every caller that diffs its output, exactly as
-- `lintCacheCtx` argues for `--cache`).
stdlibSigTriplesResult : String ->
  <IO> Result StdlibIndexError (List (String, String, Ty))
stdlibSigTriplesResult dir = match stdlibMemberPaths dir
  None => Ok []
  Some paths => stdlibSigsGo dir paths

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

stdlibSigsGo : String ->
  List String ->
  <IO> Result StdlibIndexError (List (String, String, Ty))
stdlibSigsGo _ [] = Ok []
stdlibSigsGo dir (relPath :: rest) =
  let path = "\{dir}/\{relPath}"
  let src = readFileSafe path
  match lintParseSource src
    Err e => Err StdlibIndexError {
      path = path,
      source = src,
      diagnostic = parseErrDiag path e,
    }
    Ok (decls, _) =>
      let modName = joinWith "." (splitOnChar '/' (stripMdk relPath))
      let sigs = flatMap (d => stampModule modName (exportedSigPair d)) decls
      map (sigs ++ _) (stdlibSigsGo dir rest)

-- Group the flat triples by NAME, preserving stdlib-file order within a name.
-- Appending rather than overwriting is the whole point: `setInPlace` alone
-- would keep one module's `reverse` and drop the other's without a word.
groupStdlibSigs : List (String, String, Ty) ->
  HashMap String (List (String, Ty))
groupStdlibSigs triples =
  let m = new ()
  let _ = groupStdlibSigsInto triples m
  m

groupStdlibSigsInto : List (String, String, Ty) ->
  HashMap String (List (String, Ty)) ->
  Unit
groupStdlibSigsInto [] _ = ()
groupStdlibSigsInto ((modName, name, ty) :: rest) m =
  let _ = setInPlace name (findWithDefault [] name m ++ [(modName, ty)]) m
  groupStdlibSigsInto rest m

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

stampModule : String -> List (String, Ty) -> List (String, String, Ty)
stampModule modName pairs = map (p => (modName, fst p, snd p)) pairs

-- Only EXPORTED declarations: an unexported stdlib helper is not a name user
-- code can be reimplementing.  `DExtern` carries a declared type the same way,
-- so an `export extern` counts — today `stdlib/runtime.mdk` writes its externs
-- bare (prelude-global, not `export`-marked), so that arm matches nothing yet;
-- it is here so the index does not silently need a second edit if that changes.
exportedSigPair : Decl -> List (String, Ty)
exportedSigPair (DTypeSig True name ty _) = [(name, ty)]
exportedSigPair (DExtern (ExternDecl { edPub = True, edName = name, edTy = ty, ... })) =
  [(name, ty)]
exportedSigPair (DAttrib _ d) = exportedSigPair d
exportedSigPair _ = []

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
  let scope = testVerbScope prog declPos
  let tagged = collectSplices scope cmtLines orc rules declPos
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

-- The test verbs a decl list calls, read off the AST (never the rendered text,
-- where a string literal could name a verb).
testVerbsIn : List Decl -> List String
testVerbsIn ds =
  let refs = flatMap declRefs ds
  filterList (v => contains v refs) testVerbNames

-- Which test verb names mean the `test` module's verb in this file.
--   blocked  names bound by something other than the `test` import: a top-level
--            definition (function, extern, let-group binding, interface
--            method), a member of another module's selective import, or a local
--            binder anywhere in the file.  The local check is file-wide rather
--            than per-scope: it over-skips a fix next to an unrelated binder of
--            the same name and never under-skips.  A name arriving through
--            another module's `import m.*` is not visible from the AST alone,
--            so it is not blocked.
--   resolved names the file imports from `test` itself: a member of an
--            `import test.{…}` group under its own name, or every verb when
--            `import test.*` is present.
testVerbScope : List Decl -> List (Decl, DeclPos) -> (List String, List String)
testVerbScope prog declPos =
  let bound =
    flatMap topLevelBinders prog
      ++ flatMap foreignImportNames prog
      ++ localBoundNames prog
  let blocked = filterList (v => contains v bound) testVerbNames
  let wild = anyList isTestWild prog
  let listed = flatMap (g => map useMemberLocal (fst g)) (testGroups declPos)
  let resolved =
    if wild then
      testVerbNames
    else
      filterList (v => contains v listed) testVerbNames
  (blocked, resolved)

topLevelBinders : Decl -> List String
topLevelBinders (DFunDef _ n _ _ _ _) = [n]
topLevelBinders (DExtern (ExternDecl { edName = n, ... })) = [n]
topLevelBinders (DLetGroup _ binds) = map letBindName binds
topLevelBinders (DInterface { methods, ... }) = map ifaceMethodNameOf methods
topLevelBinders (DAttrib _ d) = topLevelBinders d
topLevelBinders _ = []

ifaceMethodNameOf : IfaceMethod -> String
ifaceMethodNameOf (IfaceMethod n _ _ _) = n

-- Local names an `import m.{…}` group brings in, for every module but `test`.
foreignImportNames : Decl -> List String
foreignImportNames (DUse _ (UseGroup path members) _)
  | path == ["test"] = []
  | otherwise = map useMemberLocal members
foreignImportNames _ = []

-- A fix whose rewrite touches a `test` verb is applied only when every verb it
-- matched or introduces is not blocked and every verb it matched is the `test`
-- module's own (`resolved`).  Matching `expectEqual` by name alone would
-- otherwise rewrite a file's own `expectEqual` into a call to a verb that file
-- never imported, and introducing a name the file already binds would silently
-- call that binding instead.
testFixAllowed : (List String, List String) ->
  List String ->
  List String ->
  Bool
testFixAllowed (blocked, resolved) matched introduced =
  isEmptyL introduced
    || not (anyList (v => contains v blocked) (matched ++ introduced))
      && allList (v => contains v resolved) matched

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
ruleHasFixer r = match r.fix
  Some _ => True
  None => False

-- one (startLine, endLine, replacementText) per fixed decl, in source order.
--
-- COMMENT-LOSS SAFETY-NET (mirrors `medaka fmt`'s verbatim bail).  The printer
-- carries NO comments, so splicing printer output over a decl's `[startLine,
-- endLine]` span would silently DELETE any comment inside that span.  So before
-- emitting a splice we check `spanHasComment`: if the decl's span contains an
-- interior comment line we SKIP the fix (the rule still WARNS; the source is
-- left untouched).  A leading doc-comment ABOVE the decl is on a line
-- `< declPosLine` → outside the span → the fix is still allowed (no over-bail).
collectSplices : (List String, List String) ->
  List Int ->
  Oracle ->
  List Rule ->
  List (Decl, DeclPos) ->
  List ((Int, Int, String), List String)
collectSplices _ _ _ _ [] = []
collectSplices scope cmtLines orc rules ((d, dp) :: rest) =
  match firstFix orc rules d
    Some newDecls =>
      let matched = testVerbsIn [d]
      let introduced =
        filterList (v => not (contains v matched)) (testVerbsIn newDecls)
      if spanHasComment cmtLines (declPosLine dp) (declPosEndLine dp)
        || not (testFixAllowed scope matched introduced) then
        collectSplices scope cmtLines orc rules rest
      else
        (
            (declPosLine dp, declPosEndLine dp, renderDecls newDecls),
            introduced,
          )
          :: collectSplices scope cmtLines orc rules rest
    None => collectSplices scope cmtLines orc rules rest

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
  Diag f.severity (LintRule f.rule) "[\{f.rule}] \{f.message}" f.loc None None

-- Run the full lint pipeline (all rules, inline `-- lint-disable-*` suppression,
-- then the `--disable`/`--only`/`--deny` CLI-flag-style filters) over ONE file
-- and return `(path, src, List Diag, Positions, List Decl)` — the per-file
-- triple `driver.diagnostics.cjAllToJson` expects, PLUS the parse the
-- cross-file tier (`runCrossFileRules`) needs as `(path, Positions, decls)`.
-- Shared by `medaka lint --json` (medaka_cli.mdk) and the `medaka_lint` MCP
-- tool (mcp.mdk) so both surfaces serialize through the SAME envelope
-- `check --json` uses, with the lint rule name landing in each diagnostic's
-- `code` (via `findingToDiag`).  Uses `readFileSafe` (the same ""-on-read-error
-- helper `checkJsonFile` uses), so an unreadable path parses as empty source
-- and yields `(path, "", [], <positions of "">, [])` — total, no crash, and
-- consistent with `check --json`'s own file-variant behaviour on a missing
-- target. A `Finding` at a nested sub-expression (`exprRuleFindings`)
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
      let facts = mkFileFacts src decls pos
      let allFindings =
        applySuppressionsDirs
          (factDirectives facts)
          (lintProgramFacts idx (selectRules only disable) path facts pos decls)
      let findings = applyFindingFilters disable only deny allFindings
      (path, src, map findingToDiag findings, pos, decls)

-- `lintFileDiagTripleParsed`, dropping the parse — the shape every existing
-- caller that does not need the cross-file tier's inputs still wants.
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

-- Cross-file variant: findings anchor to DIFFERENT files, so a single `src`
-- cannot cover them.  Given each file's source (`(path, src)`), silence every
-- finding covered by an inline directive in ITS OWN file's comment side channel.
-- Directives are parsed once per file (not per finding).  General over any
-- cross-file rule; the cross-file report path calls this before flag filters.
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

-- ── cross-file runner ─────────────────────────────────────────────────────────
-- Run the enabled cross-file rules over every target file, honoring the same
-- --only/--disable name filters the per-file rules use.  --deny promotion is
-- left to the CLI (which already owns it for per-file findings).
export
runCrossFileRules : List String ->
  List String ->
  List (String, Positions, List Decl) ->
  List Finding
runCrossFileRules only disable files =
  flatMap (runCrossRuleOn only disable files) allCrossFileRules

runCrossRuleOn : List String ->
  List String ->
  List (String, Positions, List Decl) ->
  CrossFileRule ->
  List Finding
runCrossRuleOn only disable files r
  | crossRuleActive only disable r =
    map (restampSeverity r.severity) (r.check files)
  | otherwise = []

-- Fold cross-file findings into the per-file `(path, src, List Diag)` triples
-- the JSON envelope (`cjAllToJson`) and the `medaka_lint` MCP tool both
-- serialize.  Each `Finding` already carries ITS OWN occurrence's file in
-- `loc` (`emitDupGroup` emits one finding per occurrence), so a finding is
-- appended to the triple whose path matches that file — never aggregated
-- under a new key.  A finding whose file is not already among `triples`
-- would get a synthesized `(file, "", [diag])` entry appended instead of
-- being dropped — a defensive fallback, structurally unreachable from both
-- of today's call sites, since each builds `triples` from exactly the same
-- file list it hands to `runCrossFileRules`, so every finding's file is
-- already present.  Kept for the day a caller passes a narrower path set
-- than its cross-file rules run over.  A `Finding` with no `loc` (only the
-- cross-file rule shape used today always sets one) is skipped: there is no
-- file to attribute it to.
export
mergeCrossFileIntoTriples : List Finding ->
  List (String, String, List Diag) ->
  List (String, String, List Diag)
mergeCrossFileIntoTriples [] triples = triples
mergeCrossFileIntoTriples (f :: rest) triples =
  mergeCrossFileIntoTriples rest (mergeOneFinding f triples)

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

-- ── the cross-file tier, reached from CACHED per-file inputs (#395) ────────────
-- `runCrossFileRules` needs every file's `(path, Positions, decls)` — i.e. a
-- PARSE of every target, which is exactly what `--cache` skips.  So a cached run
-- reaches the tier through the occurrence lists it persisted per file instead.
--
-- ⚠️ THE SOUNDNESS SEAM.  `fileDupOccs` is the per-file input of ONE rule.  This
-- entry point is therefore only equivalent to `runCrossFileRules` while
-- `allCrossFileRules` is exactly `[duplicateBodyRule]` — a second cross-file
-- rule would have its own per-file inputs, which nothing here caches or feeds
-- it, and it would SILENTLY NOT RUN under `--cache`.  That is a whole rule
-- reporting nothing while exiting 0: this repo's defining failure mode.
--
-- Rather than trust a future agent to read this comment, `crossFileCacheSound`
-- DERIVES the answer from the live registry, and the CLI refuses `--cache`
-- (falling back to a full uncached run) when it goes False.  Adding a cross-file
-- rule then costs a slower lint, never a wrong one — the #395 invariant: a miss
-- is always safe, a wrong hit is silent wrongness.
export
crossFileCacheSound : Bool
crossFileCacheSound = match allCrossFileRules
  [r] => r.name == ruleNameDuplicateBody
  _ => False

-- Cached counterpart of `runCrossFileRules`: same --only/--disable gating, same
-- severity restamp, same join — but fed occurrences instead of parses.  Callers
-- MUST check `crossFileCacheSound` first (see above).
export
runCrossFileRulesFromOccs : List String ->
  List String ->
  List (String, Int, String, String) ->
  List Finding
runCrossFileRulesFromOccs only disable occs =
  flatMap (runCrossRuleFromOccs only disable occs) allCrossFileRules

-- The `r.name == ruleNameDuplicateBody` conjunct is belt-and-braces behind the
-- CLI's `crossFileCacheSound` check: it means a caller that ignores that check
-- still cannot run `dupJoin` under some OTHER rule's name and severity — it just
-- gets the dup rule alone, which is what the guard would have caught anyway.
runCrossRuleFromOccs : List String ->
  List String ->
  List (String, Int, String, String) ->
  CrossFileRule ->
  List Finding
runCrossRuleFromOccs only disable occs r
  | crossRuleActive only disable r && r.name == ruleNameDuplicateBody =
    map (restampSeverity r.severity) (dupJoin occs)
  | otherwise = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Loc" true) (mem "Ty" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "Decl" true) (mem "ExternDecl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseResultPairs" false) (mem "parseWithPositionsOptPairs" false) (mem "prescanErrorPairs" false) (mem "ParseError" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true) (mem "ppSeverity" false) (mem "readFileSafe" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false) (mem "isSome" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false) (mem "keys" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Rule" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "factComments" false) (mem "factDupClauses" false) (mem "memoNew" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false) (mem "declLocList" false) (mem "ruleNameDuplicateBody" false) (mem "stdlibIndexRule" false) (mem "sortUniqS" false) (mem "zipDeclPos" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "dupClauseOfDecl" false) (mem "dupJoin" false) (mem "dupOccsOfClauses" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRules" false) (mem "crossRuleActive" false) (mem "selectRules" false))))
(DTypeSig true "mkFileFacts" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyCon "FileFacts")))))
(DFunDef false "mkFileFacts" ((PVar "src") (PVar "prog") (PVar "pos")) (ERecordCreate "FileFacts" ((fa "ffSrc" (EVar "src")) (fa "ffComments" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "collectComments") (EVar "src"))))) (fa "ffOracle" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildOracle") (EVar "prog"))))) (fa "ffDupClauses" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EVar "flatMap") (EVar "dupClauseOfDecl")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))))
(DTypeSig true "factDirectives" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "factDirectives" ((PVar "ff")) (EApp (EVar "collectDirectives") (EApp (EVar "factComments") (EVar "ff"))))
(DTypeSig true "factDupOccs" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "factDupOccs" ((PVar "path") (PVar "ff")) (EApp (EApp (EVar "dupOccsOfClauses") (EVar "path")) (EApp (EVar "factDupClauses") (EVar "ff"))))
(DTypeSig true "lintProgram" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgram" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (EVar "pos")) (EVar "prog")))
(DTypeSig true "lintProgramFacts" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgramFacts" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "runRuleOn") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EVar "rules")))
(DTypeSig false "runRuleOn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "runRuleOn" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PVar "r")) (EIf (EFieldAccess (EVar "r") "enabled") (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "check") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")))))
(DTypeSig true "stdlibIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "stdlibIndexNeeded" ((PVar "only") (PVar "disable")) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EVar "stdlibIndexRule")) (EVar "only"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "stdlibIndexRule")) (EVar "disable")))))
(DTypeSig true "buildStdlibIndexResult" (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))
(DFunDef false "buildStdlibIndexResult" () (EApp (EApp (EVar "map") (ELam ((PVar "triples")) (EApp (EVar "mkStdlibIndex") (EApp (EVar "groupStdlibSigs") (EVar "triples"))))) (EApp (EVar "stdlibSigTriplesResult") (EVar "lintStdlibDir"))))
(DTypeSig false "mkStdlibIndex" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyCon "StdlibIndex")))
(DFunDef false "mkStdlibIndex" ((PVar "m")) (EApp (EApp (EVar "StdlibIndex") (EVar "m")) (EApp (EVar "sortUniqS") (EApp (EVar "keys") (EVar "m")))))
(DTypeSig false "lintStdlibDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "lintStdlibDir" () (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EApp (EVar "exeStdlibDir") (ELit LUnit)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "/stdlib"))))) (arm (PCon "None") () (EApp (EVar "exeStdlibDir") (ELit LUnit)))))
(DTypeSig false "exeStdlibDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "exeStdlibDir" (PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))) (ELit (LString "/stdlib"))))
(DTypeSig true "stdlibFingerprint" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "stdlibFingerprint" () (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "lintStdlibDir")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "names")) () (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "stdlibFingerprintGo") (EVar "lintStdlibDir")) (EVar "names"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "joined")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "listLen") (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "stdlibFingerprintGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "stdlibFingerprintGo" (PWild (PList)) (ELit (LString "")))
(DFunDef false "stdlibFingerprintGo" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "h") (EApp (EVar "hashString") (EApp (EVar "readFileSafe") (EVar "path")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "h"))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EApp (EVar "stdlibFingerprintGo") (EVar "dir")) (EVar "rest")))) (ELit (LString ""))))))
(DTypeSig false "stdlibSigTriplesResult" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty")))))))
(DFunDef false "stdlibSigTriplesResult" ((PVar "dir")) (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "dir")) (arm (PCon "None") () (EApp (EVar "Ok") (EListLit))) (arm (PCon "Some" (PVar "paths")) () (EApp (EApp (EVar "stdlibSigsGo") (EVar "dir")) (EVar "paths")))))
(DTypeSig true "lintParseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "lintParseSource" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "tokens") (PVar "offsets")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "prescanErrorPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "parsed")) () (EApp (EVar "Ok") (EVar "parsed"))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "parseWithPositions") (EVar "src")))) (EApp (EApp (EApp (EVar "parseResultPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))))))
(DTypeSig false "stdlibSigsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "stdlibSigsGo" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "stdlibSigsGo" ((PVar "dir") (PCons (PVar "relPath") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "relPath"))) (ELit (LString "")))) (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (ERecordCreate "StdlibIndexError" ((fa "path" (EVar "path")) (fa "source" (EVar "src")) (fa "diagnostic" (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))))) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "modName") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "relPath"))))) (DoLet false false (PVar "sigs") (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "stampModule") (EVar "modName")) (EApp (EVar "exportedSigPair") (EVar "d"))))) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "sigs") (EVar "_s")))) (EApp (EApp (EVar "stdlibSigsGo") (EVar "dir")) (EVar "rest"))))))))))
(DTypeSig false "groupStdlibSigs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "groupStdlibSigs" ((PVar "triples")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupStdlibSigsInto") (EVar "triples")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupStdlibSigsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyCon "Unit"))))
(DFunDef false "groupStdlibSigsInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "groupStdlibSigsInto" ((PCons (PTuple (PVar "modName") (PVar "name") (PVar "ty")) (PVar "rest")) (PVar "m")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")) (EListLit (ETuple (EVar "modName") (EVar "ty"))))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupStdlibSigsInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "stdlibMemberPaths" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stdlibMemberPaths" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (ELit (LString ""))) (EVar "entries")))))))
(DTypeSig false "memberPathsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "memberPathsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "memberPathsGo" ((PVar "dir") (PVar "prefix") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (EMatch (EApp (EVar "listDir") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "/")))) (EVar "sub"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EVar "prefix")) (EVar "rest"))))))
(DTypeSig false "stampModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stampModule" ((PVar "modName") (PVar "pairs")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "modName") (EApp (EVar "fst") (EVar "p")) (EApp (EVar "snd") (EVar "p"))))) (EVar "pairs")))
(DTypeSig false "exportedSigPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "exportedSigPair" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "exportedSigPair" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "name")) (rf "edTy" (PVar "ty"))) true))) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "exportedSigPair" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedSigPair") (EVar "d")))
(DFunDef false "exportedSigPair" (PWild) (EListLit))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmts") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EVar "map") (EVar "commentLine")) (EVar "cmts"))) (DoLet false false (PVar "declPos") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "testVerbScope") (EVar "prog")) (EVar "declPos"))) (DoLet false false (PVar "tagged") (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "declPos"))) (DoLet false false (PTuple (PVar "kept") (PVar "widen")) (EApp (EApp (EApp (EVar "reconcileTestImport") (EVar "cmts")) (EVar "declPos")) (EVar "tagged"))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EApp (EApp (EVar "withWiden") (EVar "widen")) (EVar "kept"))) (EApp (EVar "listLen") (EVar "kept"))))))
(DTypeSig false "withWiden" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "withWiden" ((PCon "None") (PVar "splices")) (EVar "splices"))
(DFunDef false "withWiden" ((PCon "Some" (PVar "sp")) (PVar "splices")) (EApp (EApp (EVar "insertSpliceAsc") (EVar "sp")) (EVar "splices")))
(DTypeSig false "testVerbNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testVerbNames" () (EListLit (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")) (ELit (LString "expectTrue")) (ELit (LString "expectFalse"))))
(DTypeSig false "testVerbsIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testVerbsIn" ((PVar "ds")) (EBlock (DoLet false false (PVar "refs") (EApp (EApp (EVar "flatMap") (EVar "declRefs")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "refs")))) (EVar "testVerbNames")))))
(DTypeSig false "testVerbScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "testVerbScope" ((PVar "prog") (PVar "declPos")) (EBlock (DoLet false false (PVar "bound") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "topLevelBinders")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "foreignImportNames")) (EVar "prog"))) (EApp (EVar "localBoundNames") (EVar "prog")))) (DoLet false false (PVar "blocked") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "bound")))) (EVar "testVerbNames"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "anyList") (EVar "isTestWild")) (EVar "prog"))) (DoLet false false (PVar "listed") (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EApp (EVar "fst") (EVar "g"))))) (EApp (EVar "testGroups") (EVar "declPos")))) (DoLet false false (PVar "resolved") (EIf (EVar "wild") (EVar "testVerbNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "listed")))) (EVar "testVerbNames")))) (DoExpr (ETuple (EVar "blocked") (EVar "resolved")))))
(DTypeSig false "topLevelBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelBinders" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "topLevelBinders" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true))) (EListLit (EVar "n")))
(DFunDef false "topLevelBinders" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "topLevelBinders" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "ifaceMethodNameOf")) (EVar "methods")))
(DFunDef false "topLevelBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topLevelBinders") (EVar "d")))
(DFunDef false "topLevelBinders" (PWild) (EListLit))
(DTypeSig false "ifaceMethodNameOf" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameOf" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "foreignImportNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "foreignImportNames" ((PCon "DUse" PWild (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EIf (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EVar "members")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "foreignImportNames" (PWild) (EListLit))
(DTypeSig false "testFixAllowed" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "testFixAllowed" ((PTuple (PVar "blocked") (PVar "resolved")) (PVar "matched") (PVar "introduced")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "introduced")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "blocked")))) (EBinOp "++" (EVar "matched") (EVar "introduced")))) (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "resolved")))) (EVar "matched")))))
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
(DFunDef false "ruleHasFixer" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collectSplices" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "collectSplices" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "scope") (PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EBlock (DoLet false false (PVar "matched") (EApp (EVar "testVerbsIn") (EListLit (EVar "d")))) (DoLet false false (PVar "introduced") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "matched"))))) (EApp (EVar "testVerbsIn") (EVar "newDecls")))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testFixAllowed") (EVar "scope")) (EVar "matched")) (EVar "introduced")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EVar "introduced")) (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))
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
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EApp (EVar "LintRule") (EFieldAccess (EVar "f") "rule"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "lintFileDiagTripleParsed" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileDiagTripleParsed" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EVar "path") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit)) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "decls") (PVar "pos"))) () (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "factDirectives") (EVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EVar "map") (EVar "findingToDiag")) (EVar "findings")) (EVar "pos") (EVar "decls")))))))))
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
(DTypeSig true "runCrossFileRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRules" ((PVar "only") (PVar "disable") (PVar "files")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleOn") (EVar "only")) (EVar "disable")) (EVar "files"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleOn" ((PVar "only") (PVar "disable") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EFieldAccess (EVar "r") "check") (EVar "files"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mergeCrossFileIntoTriples" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeCrossFileIntoTriples" ((PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "mergeCrossFileIntoTriples" ((PCons (PVar "f") (PVar "rest")) (PVar "triples")) (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "rest")) (EApp (EApp (EVar "mergeOneFinding") (EVar "f")) (EVar "triples"))))
(DTypeSig false "mergeOneFinding" (TyFun (TyCon "Finding") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeOneFinding" ((PVar "f") (PVar "triples")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "None") () (EVar "triples")) (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "tripleHasPath") (EVar "file"))) (EVar "triples")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "appendIfPath") (EVar "file")) (EApp (EVar "findingToDiag") (EVar "f")))) (EVar "triples")) (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (ELit (LString "")) (EListLit (EApp (EVar "findingToDiag") (EVar "f"))))))))))
(DTypeSig false "tripleHasPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool"))))
(DFunDef false "tripleHasPath" ((PVar "file") (PTuple (PVar "path") PWild PWild)) (EBinOp "==" (EVar "path") (EVar "file")))
(DTypeSig false "appendIfPath" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendIfPath" ((PVar "file") (PVar "diag") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EIf (EBinOp "==" (EVar "path") (EVar "file")) (ETuple (EVar "path") (EVar "src") (EBinOp "++" (EVar "diags") (EListLit (EVar "diag")))) (ETuple (EVar "path") (EVar "src") (EVar "diags"))))
(DTypeSig true "crossFileCacheSound" (TyCon "Bool"))
(DFunDef false "crossFileCacheSound" () (EMatch (EVar "allCrossFileRules") (arm (PList (PVar "r")) () (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (arm PWild () (EVar "False"))))
(DTypeSig true "runCrossFileRulesFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRulesFromOccs" ((PVar "only") (PVar "disable") (PVar "occs")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleFromOccs") (EVar "only")) (EVar "disable")) (EVar "occs"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleFromOccs" ((PVar "only") (PVar "disable") (PVar "occs") (PVar "r")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EVar "dupJoin") (EVar "occs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Loc" true) (mem "Ty" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false) (mem "IfaceMethod" true) (mem "Decl" true) (mem "ExternDecl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseResultPairs" false) (mem "parseWithPositionsOptPairs" false) (mem "prescanErrorPairs" false) (mem "ParseError" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true) (mem "ppSeverity" false) (mem "readFileSafe" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false) (mem "isSome" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false) (mem "keys" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false) (mem "localBoundNames" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Rule" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "factComments" false) (mem "factDupClauses" false) (mem "memoNew" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false) (mem "declLocList" false) (mem "ruleNameDuplicateBody" false) (mem "stdlibIndexRule" false) (mem "sortUniqS" false) (mem "zipDeclPos" false))))
(DUse false (UseGroup ("tools" "lint_rules_staging") ((mem "dupClauseOfDecl" false) (mem "dupJoin" false) (mem "dupOccsOfClauses" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRules" false) (mem "crossRuleActive" false) (mem "selectRules" false))))
(DTypeSig true "mkFileFacts" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyCon "FileFacts")))))
(DFunDef false "mkFileFacts" ((PVar "src") (PVar "prog") (PVar "pos")) (ERecordCreate "FileFacts" ((fa "ffSrc" (EVar "src")) (fa "ffComments" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "collectComments") (EVar "src"))))) (fa "ffOracle" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EVar "buildOracle") (EVar "prog"))))) (fa "ffDupClauses" (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EDictApp "flatMap") (EVar "dupClauseOfDecl")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))))
(DTypeSig true "factDirectives" (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "factDirectives" ((PVar "ff")) (EApp (EVar "collectDirectives") (EApp (EVar "factComments") (EVar "ff"))))
(DTypeSig true "factDupOccs" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "factDupOccs" ((PVar "path") (PVar "ff")) (EApp (EApp (EVar "dupOccsOfClauses") (EVar "path")) (EApp (EVar "factDupClauses") (EVar "ff"))))
(DTypeSig true "lintProgram" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgram" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "prog")) (EVar "pos"))) (EVar "pos")) (EVar "prog")))
(DTypeSig true "lintProgramFacts" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "lintProgramFacts" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "runRuleOn") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EVar "rules")))
(DTypeSig false "runRuleOn" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "runRuleOn" ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "prog") (PVar "r")) (EIf (EFieldAccess (EVar "r") "enabled") (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "check") (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "prog"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")))))
(DTypeSig true "stdlibIndexNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "stdlibIndexNeeded" ((PVar "only") (PVar "disable")) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EVar "stdlibIndexRule")) (EVar "only"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "stdlibIndexRule")) (EVar "disable")))))
(DTypeSig true "buildStdlibIndexResult" (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyCon "StdlibIndex"))))
(DFunDef false "buildStdlibIndexResult" () (EApp (EApp (EMethodRef "map") (ELam ((PVar "triples")) (EApp (EVar "mkStdlibIndex") (EApp (EVar "groupStdlibSigs") (EVar "triples"))))) (EApp (EVar "stdlibSigTriplesResult") (EVar "lintStdlibDir"))))
(DTypeSig false "mkStdlibIndex" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyCon "StdlibIndex")))
(DFunDef false "mkStdlibIndex" ((PVar "m")) (EApp (EApp (EVar "StdlibIndex") (EVar "m")) (EApp (EVar "sortUniqS") (EApp (EVar "keys") (EVar "m")))))
(DTypeSig false "lintStdlibDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "lintStdlibDir" () (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EApp (EVar "exeStdlibDir") (ELit LUnit)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "/stdlib"))))) (arm (PCon "None") () (EApp (EVar "exeStdlibDir") (ELit LUnit)))))
(DTypeSig false "exeStdlibDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "exeStdlibDir" (PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))) (ELit (LString "/stdlib"))))
(DTypeSig true "stdlibFingerprint" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "stdlibFingerprint" () (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "lintStdlibDir")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "names")) () (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "stdlibFingerprintGo") (EVar "lintStdlibDir")) (EVar "names"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "joined")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "listLen") (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "stdlibFingerprintGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "stdlibFingerprintGo" (PWild (PList)) (ELit (LString "")))
(DFunDef false "stdlibFingerprintGo" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "h") (EApp (EVar "hashString") (EApp (EVar "readFileSafe") (EVar "path")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "stdlibFingerprintGo") (EVar "dir")) (EVar "rest")))) (ELit (LString ""))))))
(DTypeSig false "stdlibSigTriplesResult" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty")))))))
(DFunDef false "stdlibSigTriplesResult" ((PVar "dir")) (EMatch (EApp (EVar "stdlibMemberPaths") (EVar "dir")) (arm (PCon "None") () (EApp (EVar "Ok") (EListLit))) (arm (PCon "Some" (PVar "paths")) () (EApp (EApp (EVar "stdlibSigsGo") (EVar "dir")) (EVar "paths")))))
(DTypeSig true "lintParseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "lintParseSource" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "tokens") (PVar "offsets")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "prescanErrorPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (arm (PCon "Some" (PVar "parsed")) () (EApp (EVar "Ok") (EVar "parsed"))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "parseWithPositions") (EVar "src")))) (EApp (EApp (EApp (EVar "parseResultPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))))))
(DTypeSig false "stdlibSigsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "StdlibIndexError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "stdlibSigsGo" (PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "stdlibSigsGo" ((PVar "dir") (PCons (PVar "relPath") (PVar "rest"))) (EBlock (DoLet false false (PVar "path") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "relPath"))) (ELit (LString "")))) (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (ERecordCreate "StdlibIndexError" ((fa "path" (EVar "path")) (fa "source" (EVar "src")) (fa "diagnostic" (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))))) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "modName") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "relPath"))))) (DoLet false false (PVar "sigs") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "stampModule") (EVar "modName")) (EApp (EVar "exportedSigPair") (EVar "d"))))) (EVar "decls"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "sigs") (EVar "_s")))) (EApp (EApp (EVar "stdlibSigsGo") (EVar "dir")) (EVar "rest"))))))))))
(DTypeSig false "groupStdlibSigs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "groupStdlibSigs" ((PVar "triples")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupStdlibSigsInto") (EVar "triples")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupStdlibSigsInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyCon "Unit"))))
(DFunDef false "groupStdlibSigsInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "groupStdlibSigsInto" ((PCons (PTuple (PVar "modName") (PVar "name") (PVar "ty")) (PVar "rest")) (PVar "m")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "m")) (EListLit (ETuple (EVar "modName") (EVar "ty"))))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupStdlibSigsInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "stdlibMemberPaths" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stdlibMemberPaths" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "entries")) () (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (ELit (LString ""))) (EVar "entries")))))))
(DTypeSig false "memberPathsGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "memberPathsGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "memberPathsGo" ((PVar "dir") (PVar "prefix") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (EMatch (EApp (EVar "listDir") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "/")))) (EMethodRef "sub"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EVar "memberPathsGo") (EVar "dir")) (EVar "prefix")) (EVar "rest"))))))
(DTypeSig false "stampModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "stampModule" ((PVar "modName") (PVar "pairs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "modName") (EApp (EVar "fst") (EVar "p")) (EApp (EVar "snd") (EVar "p"))))) (EVar "pairs")))
(DTypeSig false "exportedSigPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "exportedSigPair" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "exportedSigPair" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "name")) (rf "edTy" (PVar "ty"))) true))) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "exportedSigPair" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedSigPair") (EVar "d")))
(DFunDef false "exportedSigPair" (PWild) (EListLit))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmts") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EMethodRef "map") (EVar "commentLine")) (EVar "cmts"))) (DoLet false false (PVar "declPos") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "testVerbScope") (EVar "prog")) (EVar "declPos"))) (DoLet false false (PVar "tagged") (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "declPos"))) (DoLet false false (PTuple (PVar "kept") (PVar "widen")) (EApp (EApp (EApp (EVar "reconcileTestImport") (EVar "cmts")) (EVar "declPos")) (EVar "tagged"))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EApp (EApp (EVar "withWiden") (EVar "widen")) (EVar "kept"))) (EApp (EVar "listLen") (EVar "kept"))))))
(DTypeSig false "withWiden" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "withWiden" ((PCon "None") (PVar "splices")) (EVar "splices"))
(DFunDef false "withWiden" ((PCon "Some" (PVar "sp")) (PVar "splices")) (EApp (EApp (EVar "insertSpliceAsc") (EVar "sp")) (EVar "splices")))
(DTypeSig false "testVerbNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testVerbNames" () (EListLit (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")) (ELit (LString "expectTrue")) (ELit (LString "expectFalse"))))
(DTypeSig false "testVerbsIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testVerbsIn" ((PVar "ds")) (EBlock (DoLet false false (PVar "refs") (EApp (EApp (EDictApp "flatMap") (EVar "declRefs")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "refs")))) (EVar "testVerbNames")))))
(DTypeSig false "testVerbScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "testVerbScope" ((PVar "prog") (PVar "declPos")) (EBlock (DoLet false false (PVar "bound") (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "topLevelBinders")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "foreignImportNames")) (EVar "prog"))) (EApp (EVar "localBoundNames") (EVar "prog")))) (DoLet false false (PVar "blocked") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "bound")))) (EVar "testVerbNames"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "anyList") (EVar "isTestWild")) (EVar "prog"))) (DoLet false false (PVar "listed") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EApp (EVar "fst") (EVar "g"))))) (EApp (EVar "testGroups") (EVar "declPos")))) (DoLet false false (PVar "resolved") (EIf (EVar "wild") (EVar "testVerbNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "listed")))) (EVar "testVerbNames")))) (DoExpr (ETuple (EVar "blocked") (EVar "resolved")))))
(DTypeSig false "topLevelBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelBinders" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "topLevelBinders" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true))) (EListLit (EVar "n")))
(DFunDef false "topLevelBinders" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "topLevelBinders" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNameOf")) (EVar "methods")))
(DFunDef false "topLevelBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topLevelBinders") (EVar "d")))
(DFunDef false "topLevelBinders" (PWild) (EListLit))
(DTypeSig false "ifaceMethodNameOf" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameOf" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "foreignImportNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "foreignImportNames" ((PCon "DUse" PWild (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EIf (EBinOp "==" (EVar "path") (EListLit (ELit (LString "test")))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EVar "members")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "foreignImportNames" (PWild) (EListLit))
(DTypeSig false "testFixAllowed" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "testFixAllowed" ((PTuple (PVar "blocked") (PVar "resolved")) (PVar "matched") (PVar "introduced")) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "introduced")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "blocked")))) (EBinOp "++" (EVar "matched") (EVar "introduced")))) (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "resolved")))) (EVar "matched")))))
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
(DFunDef false "ruleHasFixer" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collectSplices" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "collectSplices" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "scope") (PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EBlock (DoLet false false (PVar "matched") (EApp (EVar "testVerbsIn") (EListLit (EVar "d")))) (DoLet false false (PVar "introduced") (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "matched"))))) (EApp (EVar "testVerbsIn") (EVar "newDecls")))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "testFixAllowed") (EVar "scope")) (EVar "matched")) (EVar "introduced")))) (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EVar "introduced")) (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "scope")) (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))
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
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EApp (EVar "LintRule") (EFieldAccess (EVar "f") "rule"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "lintFileDiagTripleParsed" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileDiagTripleParsed" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EVar "path") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit)) (EListLit))) (arm (PCon "Ok" (PTuple (PVar "decls") (PVar "pos"))) () (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "factDirectives") (EVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable"))) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EMethodRef "map") (EVar "findingToDiag")) (EVar "findings")) (EVar "pos") (EVar "decls")))))))))
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
(DTypeSig true "runCrossFileRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRules" ((PVar "only") (PVar "disable") (PVar "files")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleOn") (EVar "only")) (EVar "disable")) (EVar "files"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleOn" ((PVar "only") (PVar "disable") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EFieldAccess (EVar "r") "check") (EVar "files"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mergeCrossFileIntoTriples" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeCrossFileIntoTriples" ((PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "mergeCrossFileIntoTriples" ((PCons (PVar "f") (PVar "rest")) (PVar "triples")) (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "rest")) (EApp (EApp (EVar "mergeOneFinding") (EVar "f")) (EVar "triples"))))
(DTypeSig false "mergeOneFinding" (TyFun (TyCon "Finding") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mergeOneFinding" ((PVar "f") (PVar "triples")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "None") () (EVar "triples")) (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "tripleHasPath") (EVar "file"))) (EVar "triples")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "appendIfPath") (EVar "file")) (EApp (EVar "findingToDiag") (EVar "f")))) (EVar "triples")) (EBinOp "++" (EVar "triples") (EListLit (ETuple (EVar "file") (ELit (LString "")) (EListLit (EApp (EVar "findingToDiag") (EVar "f"))))))))))
(DTypeSig false "tripleHasPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool"))))
(DFunDef false "tripleHasPath" ((PVar "file") (PTuple (PVar "path") PWild PWild)) (EBinOp "==" (EVar "path") (EVar "file")))
(DTypeSig false "appendIfPath" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendIfPath" ((PVar "file") (PVar "diag") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EIf (EBinOp "==" (EVar "path") (EVar "file")) (ETuple (EVar "path") (EVar "src") (EBinOp "++" (EVar "diags") (EListLit (EVar "diag")))) (ETuple (EVar "path") (EVar "src") (EVar "diags"))))
(DTypeSig true "crossFileCacheSound" (TyCon "Bool"))
(DFunDef false "crossFileCacheSound" () (EMatch (EVar "allCrossFileRules") (arm (PList (PVar "r")) () (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (arm PWild () (EVar "False"))))
(DTypeSig true "runCrossFileRulesFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRulesFromOccs" ((PVar "only") (PVar "disable") (PVar "occs")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleFromOccs") (EVar "only")) (EVar "disable")) (EVar "occs"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleFromOccs" ((PVar "only") (PVar "disable") (PVar "occs") (PVar "r")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EVar "dupJoin") (EVar "occs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
