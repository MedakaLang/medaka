# META
source_lines=2550
stages=DESUGAR,MARK
# SOURCE
import support.diag_codes.{DiagCode(..), codeText}
import tools.syntax_queries.{
  strictDocumentSymbols, symbolsFromRecovered, wholeLineRange, innerDecl,
  jPosition, jRange
}
import tools.snapshot_syntax.{
  PreparedSyntax, parseSnapshotSyntax, prepareSnapshotSyntaxWithCheckedDecls,
  defaultParseOptions, snapshotSyntaxSource
}
import tools.syntax_cache.{
  SyntaxCache, emptySyntaxCache, defaultSyntaxCacheLimits, lookupSyntax,
  insertSyntax, invalidateSyntax, syntaxCacheEntryLimit
}
import frontend.syntax_source.{
  syntaxStructural, syntaxIndex, syntaxTokens, syntaxTokenSpans, SourceSpan(..)
}
import frontend.parse_result.{parsedDecls, parsedPositions}

import tools.lsp_diagnostics.{
  diagnosticJsonOr, diagnosticWithRange, parseDiagnosticJson,
  parseDiagnosticActions, snapshotJson
}
import tools.source_snapshot.{
  SourceSnapshot, SourceRevision(..), SnapshotId(..), makeSnapshot
}
import frontend.parse_diagnostic.{diagnosticCode, diagnosticLoc}
import driver.parse_diag_adapter.{parseDiagnosticToDiag}
-- lint-disable-file rule-duplicate-body
-- (A handful of small pure cursor/env helpers here — identifierAt/
--  prefixBefore/lookupSchemeL/jHover/… — are intentionally mirrored in
--  compiler/entries/playground_main.mdk, which cannot import this module: doing so
--  drags tools.fmt + io into that entry's graph and trips a pre-existing
--  multi-module flat-union conflation.  The duplication is deliberate; see the
--  note atop playground_main.mdk.)
-- compiler/tools/lsp.mdk — self-hosted Language Server (Stage 4 Phase B.10)
--
-- Slices B.10.0 + B.10.1:
--   B.10.0 — JSON-RPC-over-stdio skeleton: Content-Length framing, the
--            `initialize` handshake, `initialized`/`shutdown`/`exit`.
--   B.10.1 — textDocument/didOpen + didChange → publishDiagnostics
--            (decl-level fidelity; the compiler AST is location-stripped so
--            resolve/typecheck diagnostics span the whole document, parse
--            errors use parseResult's located line/col).
--
-- Framing (`Content-Length: N\r\n\r\n` then exactly
-- N body bytes) and the initialize capability set, but only advertises
-- what B.10 implements: textDocumentSync = Full (1).  Hover/completion/
-- definition/symbols/highlight/inlay and the ELoc expr-level ranges are LATER
-- slices and are deliberately NOT advertised here.
--
-- The runtime/core prelude sources are threaded in from the driver
-- (lsp_main.mdk reads them once at startup) so `analyze` can run the full
-- resolve+typecheck pipeline per document.

import array.{sliceClamped}
import json.{
  Json(..),
  jObject,
  jArray,
  stringify,
  parse,
  get,
  asString,
  asInt,
  asArray,
}
import driver.diagnostics.{
  Diag,
  diagIdIsSyntax,
  Severity(..),
  mkDiag,
  fileFront,
  FrontOutput(..),
  analyzeProjectKeyedSources,
  projectEntryAnalysisOr,
  GraphId,
  graphIdSame,
  stdlibExportsReader,
  clearProjectPassEntries,
}
import driver.loader.{
  findProjectRootOrSelf, parseCachedLocated, retainParsed,
  clearLoadedSourceRecords
}
import support.ordmap.{OrdMap, omEmpty, omLookup, omFromNames, omHasKey}
import support.stage_count.{stageBump}
import support.path.{dirOf}
import support.source_index.{
  SourceIndex, indexSource, sourcePositionToOffset, offsetToSourcePosition,
  offsetToUtf16Position
}
import tools.lsp_positions.{locToLspRange, lspPositionToOffset, jRangeOfLoc}
import driver.profile_select.{carryProjectProfile, manifestPathOf}
import frontend.parser.{
  ParseError,
  parseResult,
  parseLocatedResult,
  parseErrorDiagnostic,
  parseWithPositions,
  parseWithPositionsOpt,
  positionsDecls,
  Positions,
  DeclPos,
  declPosLine,
  declPosEndLine,
  declPosNameLoc,
  declPosChildLocs,
}
import frontend.lexer.{Token(..), tokenizeWithOffsetPairs}
import frontend.desugar_cache.{desugaredPrelude, preludeGeneration}
import support.char.{isIdentChar}
import support.util.{maxI, utf8Len, joinWith, startsWith, contains, allList}
import string.{stripCR, toInt}
import regex.{Regex, Match, mustCompile, escape, findAll, find}
import frontend.desugar.{desugar}
import types.repr.{Scheme(..)}
import types.publish.{
  PubScheme(..),
  PartialAnalysis(..),
  TcReport(..),
  pubSchemes,
  ppPubScheme,
  publishedEntrySchemes,
}
import types.typecheck.{driveInputsFor, checkOneReportK, entrySplit}
import types.target_profile.{selectedProfile}
import tools.fmt.{formatSourceChecked}
import tools.refindex.{
  RefIndex, buildRefIndexProjectWithParsed, binderAt, usesOf, defsOf
}
import list.{sortBy, zipWith}
import frontend.ast.{
  fieldName,
  ifaceMethodName,
  implMethodName,
  letBindName,
  Decl(..),
  ExternDecl(..),
  Ty(..),
  Loc(..),
  Variant,
  ConPayload(..),
  Field,
  IfaceMethod,
  ImplMethod,
  LetBind,
  UsePath(..),
}

-- ── open-document store ─────────────────────────────────────────────────────
-- uri → source text.  A plain association list; LSP sessions open a handful of
-- files, so linear scan is fine.  The second field is the project manifests
-- whose `[target]` diagnostic is currently published, so a repaired manifest
-- gets it cleared.  The third is what each buffer's last publish kept for
-- hover, completion and inlay to answer from (`Kept`).

public export data Docs =
  Docs (List (String, String)) (List String) (List (String, Kept)) (List (String, Option Int)) (List (String, Int)) Int SyntaxCache

-- What the last publish of a buffer kept, with the buffer source it analyzed.
-- A single-document publish keeps the env its drive gave.  A project publish
-- keeps the entry's analysis and the identity of the graph its load read; a
-- request answers from it only while a fresh load reads the same graph, so a
-- sibling edited in another buffer or on disk makes it a miss.
export data Kept =
  | KeptOne String HoverEnv
  | KeptGraph String GraphId PartialAnalysis

-- Exported alongside `Docs`/`uriOfPath` so `medaka_references` (mcp.mdk) can
-- build a single-buffer table and reuse `referencesResult` verbatim — the
-- SAME code path the LSP handler runs, per #254's "one code path" design.
export
emptyDocs : Docs
emptyDocs = Docs [] [] [] [] [] 0 (emptySyntaxCache defaultSyntaxCacheLimits)

export
docsPut : String -> String -> Docs -> Docs
docsPut uri src (Docs xs flagged kept versions generations next cache) =
  Docs
    ((uri, src) :: docsRemove uri xs)
    flagged
    kept
    versions
    ((uri, next) :: docsRemove uri generations)
    (next + 1)
    (invalidateSyntax uri cache)

-- Replace what `uri`'s publish kept; `None` drops the previous entry.
docsKeep : String -> Option Kept -> Docs -> Docs
docsKeep uri k (Docs xs flagged kept versions generations next cache) =
  let rest = docsRemove uri kept
  let kept2 = match k
    Some v => (uri, v) :: rest
    None => rest
  Docs xs flagged kept2 versions generations next cache

docsKept : String -> Docs -> Option Kept
docsKept uri (Docs _ _ kept _ _ _ _) = docsLookup uri kept

docsRemove : String -> List (String, a) -> List (String, a)
docsRemove _ [] = []
docsRemove uri ((k, v) :: rest)
  | k == uri = docsRemove uri rest
  | otherwise = (k, v) :: docsRemove uri rest

docsVersion : String -> Docs -> Option Int
docsVersion uri (Docs _ _ _ versions _ _ _) =
  optionOr None (docsLookup uri versions)

docsSetVersion : String -> Option Int -> Docs -> Docs
docsSetVersion uri version (Docs xs flagged kept versions generations next cache) =
  Docs
    xs
    flagged
    kept
    ((uri, version) :: docsRemove uri versions)
    generations
    next
    cache

docsSnapshot : String -> Docs -> Option SourceSnapshot
docsSnapshot uri docs = match docs
  Docs _ _ _ _ generations _ _ => match docsLookup uri generations
    Some generation =>
      map
        (makeSnapshot uri (docsVersion uri docs) generation)
        (docsGet uri docs)
    None => None

docsRevision : String -> Docs -> Option SourceRevision
docsRevision uri (docs@(Docs _ _ _ _ generations _ _)) = do
  generation <- docsLookup uri generations
  text <- docsGet uri docs
  Some (SourceRevision uri (docsVersion uri docs) generation text)

docsResident : String -> Docs -> Option PreparedSyntax
docsResident uri (docs@(Docs _ _ _ _ _ _ cache)) = do
  (SourceRevision _ version generation _) <- docsRevision uri docs
  lookupSyntax (SnapshotId uri generation) version defaultParseOptions cache

docsPrepared : String -> Docs -> Option PreparedSyntax
docsPrepared uri docs = docsResident uri docs

docsPrepare : String -> Docs -> Docs
docsPrepare uri docs = fst (docsPrepareResult uri docs)

docsPrepareResult : String -> Docs -> (Docs, Option PreparedSyntax)
docsPrepareResult uri (docs@(Docs xs flagged kept versions generations next cache)) =
  match (docsResident uri docs, docsRevision uri docs)
    (Some prepared, _) => (docs, Some prepared)
    (_, None) => (docs, None)
    (None, Some (revision@(SourceRevision _ _ _ text))) =>
      let prepared = match omLookup text !projectParseCache
        Some decls =>
          prepareSnapshotSyntaxWithCheckedDecls
            defaultParseOptions
            revision
            decls
        None => parseSnapshotSyntax revision
      (
        Docs
          xs
          flagged
          kept
          versions
          generations
          next
          (insertSyntax defaultParseOptions prepared cache),
        Some prepared,
      )

export
structuralParsed : PreparedSyntax -> Option (List Decl, Positions)
structuralParsed prepared = do
  syntax <- snapshotSyntaxSource prepared
  parsed <- syntaxStructural syntax
  Some (parsedDecls parsed, parsedPositions parsed)

-- ── JSON helpers ────────────────────────────────────────────────────────────

-- Loc-less diagnostics retain their whole-line range.
wholeDocRange : String -> Json
wholeDocRange src =
  match offsetToUtf16Position (indexSource src) (stringLength src)
    Some (line, _) => jRange 0 0 line 0
    None => JNull

diagsToJson : String -> List Diag -> List Json
diagsToJson src diags =
  let index = indexSource src
  map (diagnosticJsonOr index (wholeDocRange src)) diags

-- ── document store accessor (request handlers) ──────────────────────────────
-- Look up an open document's source by uri.  Request handlers (formatting/
-- documentSymbol/definition/highlight) read the buffer the client last sent.
docsGet : String -> Docs -> Option String
docsGet uri (Docs xs _ _ _ _ _ _) = docsLookup uri xs

docsLookup : String -> List (String, a) -> Option a
docsLookup _ [] = None
docsLookup uri ((k, v) :: rest)
  | k == uri = Some v
  | otherwise = docsLookup uri rest

-- ── textDocument/formatting ─────────────────────────────────────────────────
fullDocRangeFmt : String -> Json
fullDocRangeFmt src =
  match offsetToUtf16Position (indexSource src) (stringLength src)
    Some (line, col) => jRange 0 0 line col
    None => JNull

-- Run the formatter; if the text is
-- unchanged return [] (no edits); otherwise return ONE TextEdit replacing the
-- whole document through EOF. A parse failure yields [] here: the source
-- is lexed once and `formatSourceChecked` returns the parse error instead of
-- panicking.
formattingEdits : String -> List Json
formattingEdits src = match tokenizeWithOffsetPairs src
  (toks, pairs) => match formatSourceChecked src toks pairs
    Err _ => []
    Ok formatted =>
      if formatted == src then
        []
      else
        [
          jObject [
            ("range", fullDocRangeFmt src),
            ("newText", JString formatted),
          ],
        ]
-- unparseable → no edits (client keeps buffer)

-- ── identifier-at-cursor + occurrence scan (pure string ops) ────────────────

-- Expand left/right from `pos` over identifier chars; returns (start, stopExcl).
identStart : Array Char -> Int -> Int
identStart arr i
  | i <= 0 = 0
  | isIdentChar (arrayGetUnsafe (i - 1) arr) = identStart arr (i - 1)
  | otherwise = i

identStop : Array Char -> Int -> Int -> Int
identStop arr len i
  | i + 1 >= len = i + 1
  | isIdentChar (arrayGetUnsafe (i + 1) arr) = identStop arr len (i + 1)
  | otherwise = i + 1

-- The identifier under (line, col), or None if the cursor isn't on one.
identifierAt : String -> Int -> Int -> Option String
identifierAt src line col =
  identifierAtIndexed (indexSource src) (stringToChars src) line col

identifierAtIndexed : SourceIndex -> Array Char -> Int -> Int -> Option String
identifierAtIndexed index arr line col =
  let len = arrayLength arr
  match sourcePositionToOffset index (line + 1) col
    None => None
    Some pos =>
      if pos >= len || not (isIdentChar (arrayGetUnsafe pos arr)) then
        None
      else
        let s = identStart arr pos
        let e = identStop arr len pos
        Some (stringFromChars (sliceClamped s e arr))

-- A whole-source word-boundary occurrence scan: every offset where `name`
-- appears as a standalone identifier.  Returns the offsets in source order.
--
-- The boundary check runs on each match's OWN position afterward (match,
-- then test the neighbors) rather than folded into the pattern, for the
-- same reason `lint.mdk`'s `wordReadIn` keeps it out of the pattern: a
-- consuming boundary class baked in would make two occurrences separated by
-- exactly one boundary char invisible to a left-to-right non-overlapping
-- scan.
occurrences : String -> String -> List Int
occurrences src name =
  if stringLength name == 0 then
    []
  else
    let arr = stringToChars src
    let len = arrayLength arr
    filterMap (occStart arr len) (findAll (mustCompile (escape name)) src)

occStart : Array Char -> Int -> Match -> Option Int
occStart arr len m =
  if (m.start == 0 || not (isIdentChar (arrayGetUnsafe (m.start - 1) arr)))
    && (m.end == len || not (isIdentChar (arrayGetUnsafe m.end arr))) then
    Some m.start
  else
    None

-- documentHighlight ranges (one per occurrence) of `name` in `src`.
highlightRanges : String -> String -> List Json
highlightRanges src name =
  let index = indexSource src
  let nlen = stringLength name
  filterMap (occToHighlight index nlen) (occurrences src name)

occToHighlight : SourceIndex -> Int -> Int -> Option Json
occToHighlight index nlen off = match (
  offsetToUtf16Position index off,
  offsetToUtf16Position index (off + nlen),
)
  (Some (sl, sc), Some (el, ec)) =>
    Some (jObject [("range", jRange sl sc el ec)])
  _ => None

-- ── textDocument/documentSymbol ─────────────────────────────────────────────
-- parseWithPositions → zip decls with their DeclPos (1-based line..end_line) →
-- one DocumentSymbol per decl: { name, kind, range, selectionRange, children }.
-- Consecutive same-name decls (a signature + its clauses, or a multi-clause
-- function) COLLAPSE to a single outline symbol spanning them (#300 part 3), so a
-- 2-clause `dirGo` is one entry, not three.  `range` is decl-level: (line-1,
-- 0)..(end_line-1, 0).  `selectionRange` is the decl's real NAME-token span
-- (#331, `DeclPos`'s third field / `declPosNameLoc`) — for `DImpl` this is
-- its head TYPE's `TyCon` token, falling back to the `impl` keyword for a
-- fully-parametric head (F4/increment 5) — or the same col-0 `range` on the
-- rare miss.  Child symbols (variant ctors/fields/methods/let-binds) carry
-- their OWN name spans (increment 2).  SymbolKind codes are the LSP spec
-- integers (Struct=23,
-- Method=6, Field=8, Enum=10, EnumMember=22, Interface=11, Class=5,
-- Function=12, Variable=13, TypeParameter=26, Event=24).  Mirrors
-- symbol_of_decl's kind mapping + child nesting.

export
documentSymbols : String -> List Json
documentSymbols src = strictDocumentSymbols src

-- ── textDocument/definition ─────────────────────────────────────────────────
-- identifier-at-cursor → first decl that DEFINES that name → THAT NAME's own
-- span as a Location { uri, range }.  #331 increment 5 (Part B): a query name
-- can be a decl's OWN name (the type/function/interface/… name itself) or one
-- of its CHILDREN (variant ctor / record field / interface|impl method /
-- let-bind) — these want DIFFERENT spans (`declPosNameLoc` vs the matching
-- entry of `declPosChildLocs`), so go-to-definition on a child now lands on
-- the child, not the parent decl.  Own-name is checked FIRST: a
-- single-constructor `data Wrapper = Wrapper Int` (ctor name == type name, a
-- common idiom) still resolves to the TYPE name, matching prior behavior.
-- Mirror decl_defines / find_definition_loc.

-- Does `d` define `name` as its OWN name (as opposed to a CHILD's — see
-- `declChildNames`)? `DImpl` has no own name (only methods, all children), so
-- it is always False here.
declOwnNameMatches : Decl -> String -> Bool
declOwnNameMatches d name = match innerDecl d
  DTypeSig _ n _ _ => n == name
  DExtern (ExternDecl { edName = n, ... }) => n == name
  DFunDef _ n _ _ _ _ => n == name
  DLetGroup _ binds => anyName (map letBindName binds) name
  DData { dataName = n } => n == name
  DInterface { name = n, ... } => n == name
  DImpl { ... } => False
  DTypeAlias { tyAliasName = n } => n == name
  DNewtype { newtypeName = n, newtypeCtor = c } => n == name || c == name
  DUse _ _ _ => False
  DProp _ n _ _ => n == name
  DTest _ n _ => n == name
  DEffect _ n _ _ _ _ => n == name
  DAttrib _ _ => False

-- `d`'s CHILD names, in the SAME order `declPosChildLocs`/`symbolPartsOfDecl`
-- emit them. ⚠️ THE ORDERING INVARIANT: index `k` here must be index `k` in
-- `declPosChildLocs` — a mismatch attaches a `Loc` to the WRONG child, a
-- silent wrong answer (same invariant `declChildSpansOf`, parser.mdk, names).
-- `[]` for decl kinds with no children.
declChildNames : Decl -> List String
declChildNames d = match innerDecl d
  DData { dataCtors = vs } => dataChildNames vs
  DInterface { methods = ms, ... } => map ifaceMethodName ms
  DImpl { methods = ms, ... } => map implMethodName ms
  DLetGroup _ binds => map letBindName binds
  _ => []

-- Mirrors `variantKids`'s traversal exactly: a nameOmitted record variant
-- (`data X = { … }`) expands to one entry per field; any other variant
-- contributes its single ctor name.
dataChildNames : List Variant -> List String
dataChildNames [] = []
dataChildNames ((Variant _ (ConNamed fs True)) :: vs) =
  map fieldName fs ++ dataChildNames vs
dataChildNames ((Variant vn _) :: vs) = vn :: dataChildNames vs

anyName : List String -> String -> Bool
anyName [] _ = False
anyName (x :: xs) name = x == name || anyName xs name

-- 0-based index of the first occurrence of `name` in `xs`, or `None`.
indexOfName : String -> List String -> Option Int
indexOfName name xs = indexOfNameGo name xs 0

indexOfNameGo : String -> List String -> Int -> Option Int
indexOfNameGo _ [] _ = None
indexOfNameGo name (x :: xs) i =
  if x == name then Some i else indexOfNameGo name xs (i + 1)

-- The `Option Loc` at 0-based index `i` of `ls`, or `None` if out of range.
locAtIndex : Int -> List (Option Loc) -> Option Loc
locAtIndex _ [] = None
locAtIndex 0 (l :: _) = l
locAtIndex i (_ :: ls) = locAtIndex (i - 1) ls

-- The DeclPos of the first decl defining `name`, or None.
definitionRangeParsed : String ->
  String ->
  Option (List Decl, Positions) ->
  Option Json
definitionRangeParsed _ _ None = None
definitionRangeParsed src name (Some (decls, positions)) =
  defZip
    (indexSource src)
    (stringLength src)
    decls
    (positionsDecls positions)
    name

-- #331: the go-to-definition RANGE for `name` in the decl (`d`, `p`) that
-- defines it — own-name span first, else the matching child's span
-- (increment 5, Part B) — falling back to the old (line, 0)..(end_line, 0)
-- whole-decl range only when the parser's name-finder didn't resolve a span
-- for that particular name.
defZip : SourceIndex ->
  Int ->
  List Decl ->
  List DeclPos ->
  String ->
  Option Json
defZip index len (d :: ds) (p :: ps) name =
  match defZipDeclMatch index len d p name
    Some j => Some j
    None => defZip index len ds ps name
defZip _ _ _ _ _ = None

defZipDeclMatch : SourceIndex -> Int -> Decl -> DeclPos -> String -> Option Json
defZipDeclMatch index len d p name
  | declOwnNameMatches d name =
    Some (defZipLocOr index len (declPosNameLoc p) p)
  | otherwise =
    map
      (k => defZipLocOr index len (locAtIndex k (declPosChildLocs p)) p)
      (indexOfName name (declChildNames d))

defZipLocOr : SourceIndex -> Int -> Option Loc -> DeclPos -> Json
defZipLocOr index _ (Some l) _ = jRangeOfLoc index l
defZipLocOr index len None p =
  wholeLineRange index len (declPosLine p - 1) (declPosEndLine p)

-- ── typecheck-env build (hover / completion / inlayHint) ────────────────────
-- The handlers run `checkProgram prog`
-- (which prepends the prelude) and look names up in the returned env.  The
-- handlers need the FULL visible env — a hover or a completion lands on a
-- prelude name (`map`, `println`) as readily as on one the buffer declares — so
-- this returns the prelude's schemes as well as the buffer's own.
--
-- This is the MODULE arm, via `checkOneSchemeFullK`
-- (the buffer is a degenerate one-module graph, `"__user__"` as its id, matching
-- `checkOneToLinesWithRuntime`'s own rootId convention).  It hands back
-- `(preludeSchemes, ownSchemes)` separately; the flat env this file's three
-- consumers want is `own ++ prelude`, OWN FIRST — `lookupSchemeL` (hover,
-- inlayHints) is a linear first-match scan, so a buffer binding that shadows a
-- prelude name must come first or the prelude's scheme silently wins the lookup
-- (#2054's shape on the Flat arm; see `checkModulesEntryFullSplitK`'s note).
-- Returns None when the buffer doesn't parse (the OCaml handlers bail the same
-- way on a parse failure).
-- The buffer is parsed through `parseLocatedResult`, not `parseResult`: the
-- LOCATED entry is the only one that sets the parser's loc-state refs, so it is
-- the only one whose `PVar`/`PAs` binders carry a REAL `Loc`.  `recordLocalBind`
-- now keeps those spans (#2092) and the hover path selects a local by position,
-- so an unlocated parse here would silently degrade every single-file buffer's
-- binders to a placeholder span and put the prelude back in front of a local
-- that shadows it.  The import-bearing path already parses located (the loader
-- uses `parseLocatedResult`).  Prelude sources go through the S-1 memoized
-- `parsePrelude` (the cheap unlocated entry, cached) and are parsed FIRST, so
-- the live loc-state at typecheck time is this buffer's.
docEnv : String -> String -> String -> Option HoverEnv
docEnv runtimeSrc coreSrc src =
  let runtimeDecls = desugaredPrelude runtimeSrc
  let coreDecls = desugaredPrelude coreSrc
  match parseLocatedResult src
    Err _ => None
    Ok userRaw =>
      let userDecls = desugar userRaw
      let preludeKey = Some (preludeGeneration runtimeSrc coreSrc)
      let report = checkOneReportK (driveInputsFor
        !selectedProfile
        False
        []) False preludeKey runtimeDecls coreDecls (
        "__user__",
        userDecls,
      )
      Some (reportEnv report)

-- The single-document env of a drive's report: own schemes first, then the
-- prelude's (see `docEnv`), with the locals and seed of its partial analysis.
reportEnv : TcReport -> HoverEnv
reportEnv report =
  let (preludeSchemes, ownSchemes, _, _) = entrySplit report
  hoverEnvOf (ownSchemes ++ preludeSchemes) report.trPartial

-- `docEnv` answered from what the buffer's last publish kept, when that
-- publish analyzed exactly `src`; otherwise a fresh drive.
docEnvFor : String -> String -> String -> String -> Docs -> Option HoverEnv
docEnvFor runtimeSrc coreSrc uri src docs = match docsKept uri docs
  Some (KeptOne keptSrc env) =>
    if keptSrc == src then Some env else docEnv runtimeSrc coreSrc src
  _ => docEnv runtimeSrc coreSrc src

-- The lookup tiers one drive gave a document: the entry's schemes (own first),
-- then the locals and the import seed its `PartialAnalysis` holds.
data HoverEnv = HoverEnv {
  heSchemes : List (String, PubScheme),
  heLocals : List (String, PubScheme, Option Loc),
  heSeed : List (String, PubScheme),
}

hoverEnvOf : List (String, PubScheme) -> PartialAnalysis -> HoverEnv
hoverEnvOf schemes pa = HoverEnv {
  heSchemes = schemes,
  heLocals = pa.paLocals,
  heSeed = pa.paSeed,
}

-- Lookup a name's Scheme in the env (mirror repl.mdk lookupScheme / OCaml
-- List.assoc_opt).
lookupSchemeL : String -> List (String, a) -> Option a
lookupSchemeL _ [] = None
lookupSchemeL name ((n, s) :: rest)
  | name == n = Some s
  | otherwise = lookupSchemeL name rest

-- ── textDocument/hover ──────────────────────────────────────────────────────
-- handle_hover: identifier-at-cursor → checkProgram
-- env → lookup → a Hover whose contents is a Markdown MarkupContent rendering
--   ```medaka
--   <name> : <type>
--   ```
-- (exactly the OCaml format string).  Null when off an identifier or not in env.
-- Extension over the OCaml oracle: when the name isn't a top-level/global binding,
-- fall back to the locals the drive captured (let-bound names, lambda/clause
-- params, match binders), so local variables also show their inferred type on
-- hover.
-- Produce the hover Json for the cursor position.  Resolve the identifier FIRST
-- (cheap), then build the env (potentially loading the project graph), so an
-- off-identifier hover never pays for a typecheck/load.
hoverFor : String -> String -> String -> String -> Json -> Docs -> <IO> Json
hoverFor runtimeSrc coreSrc uri src params docs = match sourceCursor src params
  Some (line, col) => match identifierAt src line col
    None => JNull
    Some name => match hoverEnvFor runtimeSrc coreSrc uri src docs
      None => JNull
      Some env => match hoverSchemeAt name src line col env
        None => JNull
        Some hit => jHover name (ppHoverScheme hit)
  _ => JNull

-- Stateless type-at-point for the `medaka mcp` `medaka_type_at` tool (#251) — and
-- the shared query substrate #255 reuses.  It is `hoverFor` with two differences:
-- it takes the (0-based, LSP-style) line/col as plain Ints rather than fishing
-- them out of a synthetic params Json, and it returns the rendered `<name> :
-- <type>` as PLAIN TEXT (no markdown/JSON wrapper) so the MCP layer drops it
-- straight into a tool-result content block.  The ORDER mirrors hoverFor:
-- resolve the identifier first (cheap), THEN build the env, which carries the
-- locals and the import seed its drive captured.  The buffer is seeded into
-- `docs` under its own uri so the import-bearing project load (projectEntryEnv) sees exactly this
-- text as the entry module; imported siblings resolve from disk through the
-- loader's read/disk fallback (readModuleProgF).  None ⇒ off any identifier or
-- not in scope — the caller maps that to a clean "no symbol" result, never a
-- crash.
export
typeAtPoint : String ->
  String ->
  String ->
  String ->
  Int ->
  Int ->
  <IO> Option String
typeAtPoint runtimeSrc coreSrc filePath src line col =
  match typeAtPoints runtimeSrc coreSrc filePath src line [col]
    [answer] => answer
    _ => None

-- `typeAtPoint` at each of `cols` on `line`, all answered from ONE env: the
-- env is built once, and only when some column is on an identifier.
export
typeAtPoints : String ->
  String ->
  String ->
  String ->
  Int ->
  List Int ->
  <IO> List (Option String)
typeAtPoints runtimeSrc coreSrc filePath src line cols =
  typeAtPointsWithIndex
    (indexSource src)
    runtimeSrc
    coreSrc
    filePath
    src
    line
    cols

export
typeAtPointsWithIndex : SourceIndex ->
  String ->
  String ->
  String ->
  String ->
  Int ->
  List Int ->
  <IO> List (Option String)
typeAtPointsWithIndex index runtimeSrc coreSrc filePath src line cols =
  let chars = stringToChars src
  let positions =
    map
      (col =>
        sourceCursorIndexed index (jObject [("position", jPosition line col)]))
      cols
  let names =
    map
      (pos => do
        (ln, col) <- pos
        identifierAtIndexed index chars ln col)
      positions
  if allList isNone names then
    map (_ => None) cols
  else
    let uri = uriOfPath filePath
    let docs = docsPut uri src emptyDocs
    match hoverEnvFor runtimeSrc coreSrc uri src docs
      None => map (_ => None) cols
      Some env =>
        let parsed = map snd (parseWithPositionsOpt src)
        zipWith (typeAtPosition parsed env) names positions

typeAtPosition : Option Positions ->
  HoverEnv ->
  Option String ->
  Option (Int, Int) ->
  Option String
typeAtPosition _ _ _ None = None
typeAtPosition _ _ None _ = None
typeAtPosition parsed env (Some name) (Some (line, col)) =
  map
    (hit => stringConcat [name, " : ", ppHoverScheme hit])
    (hoverSchemeAtParsed name parsed line col env)

-- The hover lookup env for the buffer.  A buffer with a non-core sibling import
-- goes through the multi-module project pipeline (`projectEntryEnv`: it loads the
-- import graph and builds the env from the drive's `PartialAnalysis`, the entry's
-- own schemes plus its locals and import-scoped seed), so imported names resolve.
-- A single-file buffer keeps the fast `docEnv` path (core + runtime + this buffer
-- only).
hoverEnvFor : String ->
  String ->
  String ->
  String ->
  Docs ->
  <IO> Option HoverEnv
hoverEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src = projectEntryEnv runtimeSrc coreSrc uri src docs
  | otherwise = docEnvFor runtimeSrc coreSrc uri src docs

-- Load the import graph rooted at this buffer (same loader/cache/read disk-
-- fallback as publishProjectDiagnostics) and return the ENTRY module's own
-- schemes, with the entry's locals + import-scoped seed (runtime + core +
-- imported names) from the drive's `PartialAnalysis`.  The analysis the
-- buffer's last publish kept answers when that publish read `src` and the
-- graph this load read; otherwise the load is driven.
projectEntryEnv : String ->
  String ->
  String ->
  String ->
  Docs ->
  <IO> Option HoverEnv
projectEntryEnv runtimeSrc coreSrc uri src docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRootOrSelf (dirOf rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  map
    (pa => hoverEnvOf (publishedEntrySchemes pa.paSchemes) pa)
    (projectEntryAnalysisOr
      (keptGraph uri src docs)
      projectCache
      projectParseCache
      read
      rootFile
      [projectDir, stdlibDir]
      runtimeSrc
      coreSrc)

-- The entry analysis `uri`'s last publish kept, if it analyzed `src` over the
-- graph `current` names.
keptGraph : String -> String -> Docs -> GraphId -> Option PartialAnalysis
keptGraph uri src docs current = match docsKept uri docs
  Some (KeptGraph keptSrc keptId pa) =>
    if keptSrc == src && graphIdSame keptId current then Some pa else None
  _ => None

-- A hover or completion hit, tagged by the tier that answered it.  An env hit
-- carries the context its binding was published with, and so do a local and a
-- seed hit: each was frozen with its own context when the drive captured it.
-- The tag records which tier answered (F2, the #2054 family).
data HoverHit = EnvHit PubScheme | LocalHit PubScheme | SeedHit PubScheme

-- The locals without their binder spans.
localSchemes : List (String, PubScheme, Option Loc) -> List (String, PubScheme)
localSchemes = map ((n, s, _) => (n, s))

-- Resolve a hovered name's scheme: the returned typecheck env (globals +
-- top-level) first, then the locals (let/param/match binders) and the seed
-- (runtime.mdk externs) — neither of which the env carries.
hoverScheme : String -> HoverEnv -> Option HoverHit
hoverScheme name env = match lookupSchemeL name env.heSchemes
  Some p => Some (EnvHit p)
  None => match lookupSchemeL name (localSchemes env.heLocals)
    Some s => Some (LocalHit s)
    None => map SeedHit (lookupSchemeL name env.heSeed)

-- POSITION-AWARE hoverScheme (#2092).  `hoverScheme`'s tier order asks `env`
-- (own top-level ++ the WHOLE prelude) first, so a local binder whose bare name
-- collides with a prelude standalone — `let count = 5` against the prelude's
-- `count : Foldable b => (a -> Bool) -> b a -> Int` — could never answer: the
-- prelude's scheme won the very first lookup, at every cursor position in the
-- buffer.
--
-- The fix is NOT a tier reorder.  Putting locals unconditionally first would
-- hand every occurrence of the name anywhere in the buffer to whichever local
-- happens to sit first in `localBindRefs`, including occurrences lexically
-- outside that binder's scope, or before it.  Instead the local tier is
-- consulted first ONLY when a local binding of that name actually covers the
-- cursor; otherwise the original `env` → local → seed order runs untouched, so
-- every non-shadowing hover in the buffer answers exactly as before.
hoverSchemeAt : String -> String -> Int -> Int -> HoverEnv -> Option HoverHit
hoverSchemeAt name src line col env =
  hoverSchemeAtParsed name (map snd (parseWithPositionsOpt src)) line col env

hoverSchemeAtParsed : String ->
  Option Positions ->
  Int ->
  Int ->
  HoverEnv ->
  Option HoverHit
hoverSchemeAtParsed name parsed line col env =
  match localSchemeAt name line col parsed env.heLocals
    Some s => Some (LocalHit s)
    None => hoverScheme name env

-- The scheme of the local binding of `name` that is in scope at the (0-based,
-- LSP-style) cursor, or None when no local binding of that name covers it.
--
-- SCOPE APPROXIMATION, stated plainly: `recordLocalBind` captures the binder's
-- own span, not the extent of the region the binding governs, so "covers the
-- cursor" is read as *the binder starts at or before the cursor AND both sit in
-- the same top-level declaration* — the enclosing-decl range coming from the
-- parser's `DeclPos` channel (1-based, the same one `documentSymbols` uses).
-- Among the binders that qualify, the LAST one to start wins (the innermost /
-- most recent shadow).  That is deliberately narrower than "any local of this
-- name": a `let count = …` in one top-level definition must not answer for a
-- bare prelude `count` used in a different one, and a binder BELOW the cursor
-- must not answer for a use above it.  It is still an approximation upward — a
-- binder in a sibling `match` arm of the same declaration is treated as
-- covering.  This specific failure mode — a sibling arm's binder shadowing an
-- unrelated prelude use in the SAME declaration — could not manifest before
-- this local tier existed: the old `hoverScheme` had no position-aware local
-- tier at all, so `env` (prelude-first) always won regardless of position,
-- giving the correct prelude answer for this shape.  This local tier is what
-- introduces the sibling-arm mis-attribution.  Tracked as #2254 (per-arm
-- scoping); not fixed here.
localSchemeAt : String ->
  Int ->
  Int ->
  Option Positions ->
  List (String, PubScheme, Option Loc) ->
  Option PubScheme
localSchemeAt _ _ _ None _ = None
localSchemeAt name line col (Some pos) locals =
  let decls = positionsDecls pos
  let cl = line + 1
  match declIndexAt decls 0 cl
    None => None
    Some di => latestLocal None (localCandidates name cl col di decls locals)

-- Index of the top-level decl whose start..end line range contains `l` (1-based).
declIndexAt : List DeclPos -> Int -> Int -> Option Int
declIndexAt [] _ _ = None
declIndexAt (p :: rest) i l
  | declPosLine p <= l && l <= declPosEndLine p = Some i
  | otherwise = declIndexAt rest (i + 1) l

declIndexIs : List DeclPos -> Int -> Int -> Bool
declIndexIs decls l di = match declIndexAt decls 0 l
  None => False
  Some j => j == di

-- (l1, c1) is at or before (l2, c2).
locAtOrBefore : Int -> Int -> Int -> Int -> Bool
locAtOrBefore l1 c1 l2 c2 = l1 < l2 || l1 == l2 && c1 <= c2

-- The recorded locals of `name` that could be in scope at (cl, cc), as
-- (binder line, binder col, scheme).  A binder with no `Loc` (a desugared
-- do-bind, say) can never qualify — it has no position to compare.
localCandidates : String ->
  Int ->
  Int ->
  Int ->
  List DeclPos ->
  List (String, PubScheme, Option Loc) ->
  List (Int, Int, PubScheme)
localCandidates _ _ _ _ _ [] = []
localCandidates name cl cc di decls ((n, sch, Some (Loc _ bl bc _ _)) :: rest)
  | n == name && locAtOrBefore bl bc cl cc && declIndexIs decls bl di =
    (bl, bc, sch) :: localCandidates name cl cc di decls rest
localCandidates name cl cc di decls (_ :: rest) =
  localCandidates name cl cc di decls rest

-- The candidate whose binder starts LAST (innermost shadow wins).
latestLocal : Option (Int, Int, PubScheme) ->
  List (Int, Int, PubScheme) ->
  Option PubScheme
latestLocal None [] = None
latestLocal (Some (_, _, s)) [] = Some s
latestLocal None (c :: rest) = latestLocal (Some c) rest
latestLocal (Some (pl, pc, ps)) ((bl, bc, bs) :: rest)
  | locAtOrBefore pl pc bl bc = latestLocal (Some (bl, bc, bs)) rest
  | otherwise = latestLocal (Some (pl, pc, ps)) rest

-- Render a hit with the context it was published with: an own binding never
-- takes the prelude's context, and a prelude binding takes its own.
ppHoverScheme : HoverHit -> String
ppHoverScheme (EnvHit p) = ppPubScheme p
ppHoverScheme (LocalHit p) = ppPubScheme p
ppHoverScheme (SeedHit p) = ppPubScheme p

-- Build the Hover { contents: MarkupContent{ kind:"markdown", value } } object.
jHover : String -> String -> Json
jHover name ty =
  let value = stringConcat ["```medaka\n", name, " : ", ty, "\n```"]
  jObject [
    (
      "contents",
      jObject [("kind", JString "markdown"), ("value", JString value)],
    ),
  ]

handleHover : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleHover runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => hoverFor runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

-- ── textDocument/completion ─────────────────────────────────────────────────
-- handle_completion: the identifier prefix ending
-- just before the cursor → env names with that prefix → CompletionItem[]
-- { label, kind, detail }.  kind = Function (3) for every item; detail = ppScheme.  Names are
-- emitted in env order, deduplicated, prefix-filtered — mirroring
-- filter_completions.
prefixBefore : String -> Int -> Int -> String
prefixBefore src line col =
  let arr = stringToChars src
  let len = arrayLength arr
  match sourcePositionToOffset (indexSource src) (line + 1) 0
    None => ""
    Some lineStart =>
      let stop = lineStart + col - 1
      if stop < lineStart then
        ""
      else if stop >= len then
        ""
      else if not (isIdentChar (arrayGetUnsafe stop arr)) then
        ""
      else
        let start = prefixStart arr lineStart stop
        stringSlice start (stop + 1) src

-- Walk left from `stop` over identifier chars, not past the line start.
prefixStart : Array Char -> Int -> Int -> Int
prefixStart arr lineStart i
  | i <= lineStart = lineStart
  | isIdentChar (arrayGetUnsafe (i - 1) arr) = prefixStart arr lineStart (i - 1)
  | otherwise = i

-- startsWith → support/util.mdk (imported above).

-- Filter env to names matching the prefix, deduplicating (first occurrence
-- wins).  Mirror filter_completions.
-- Each entry carries the tier tag `completionEnvFor` stamped on its slice before
-- concatenating them (see `HoverHit`).  Tagging happens at the slice, not here,
-- because by the time the slices are one flat list the tiers are indistinguishable.
filterCompletions : String ->
  List String ->
  List (String, HoverHit) ->
  List Json
filterCompletions _ _ [] = []
filterCompletions prefix seen ((n, hit) :: rest)
  | startsWith prefix n && not (anyName seen n) =
    jCompletionItem n (ppHoverScheme hit)
      :: filterCompletions prefix (n :: seen) rest
  | otherwise = filterCompletions prefix seen rest

-- One CompletionItem { label, kind, detail }.  kind 3 = Function (LSP spec).
jCompletionItem : String -> String -> Json
jCompletionItem label detail = jObject [
  ("label", JString label),
  ("kind", JInt 3),
  ("detail", JString detail),
]

completionFor : String ->
  String ->
  String ->
  String ->
  Json ->
  Docs ->
  <IO> Json
completionFor runtimeSrc coreSrc uri src params docs =
  match sourceCursor src params
    Some (line, col) => match completionEnvFor runtimeSrc coreSrc uri src docs
      None => JNull
      Some env =>
        let prefix = prefixBefore src line col
        jArray (filterCompletions prefix [] env)
    _ => JNull

-- Completion suggests names from the env directly, so for a project buffer the
-- env must be the FULL visible set: the entry's own schemes + its locals + its
-- import-scoped seed (core + runtime + imported names).  A single-file buffer
-- keeps `docEnv`'s schemes alone — adding the seed/locals there would change the
-- single-file completion golden.
completionEnvFor : String ->
  String ->
  String ->
  String ->
  Docs ->
  <IO> Option (List (String, HoverHit))
completionEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src =
    map
      (env =>
        tagTier EnvHit env.heSchemes
          ++ tagTier LocalHit (localSchemes env.heLocals)
          ++ tagTier SeedHit env.heSeed)
      (projectEntryEnv runtimeSrc coreSrc uri src docs)
  | otherwise =
    map
      (env => tagTier EnvHit env.heSchemes)
      (docEnvFor runtimeSrc coreSrc uri src docs)

-- Stamp one completion-env slice with its tier.  Order across the slices is
-- unchanged, so `filterCompletions`' first-occurrence-wins dedup still resolves a
-- shadowed name to exactly the entry it did before.
tagTier : (s -> HoverHit) -> List (String, s) -> List (String, HoverHit)
tagTier tag = map (b => (fst b, tag (snd b)))

handleCompletion : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleCompletion runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => completionFor runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

-- ── textDocument/inlayHint ──────────────────────────────────────────────────
-- For each top-level decl that
-- binds a value (DFunDef, or the first name of a DLetGroup) AND has no explicit
-- DTypeSig in the program AND is in the typecheck env, emit one hint at the
-- column right after its name on its start line, labelled `: <ppScheme>` with
-- paddingLeft.  #331: now placed from the decl's real NAME-token `Loc`
-- (`declPosNameLoc` — end column is exact, no scanning) when available;
-- `columnAfterName`'s col-0 leading-identifier scan survives only as the
-- fallback for the (should-not-happen for `DFunDef`/`DLetGroup`) `None` case.

-- The binding name a decl introduces a value hint for, or None (mirror
-- decl_binding_name: only DFunDef + DLetGroup-first).
declBindingName : Decl -> Option String
declBindingName d = match innerDecl d
  DFunDef _ n _ _ _ _ => Some n
  DLetGroup _ binds => match binds
    (LetBind n _ _ _) :: _ => Some n
    [] => None
  _ => None

-- Whether `prog` carries an explicit DTypeSig for `name` (mirror has_explicit_sig).
hasExplicitSig : List Decl -> String -> Bool
hasExplicitSig [] _ = False
hasExplicitSig (d :: rest) name = match innerDecl d
  DTypeSig _ n _ _ => n == name || hasExplicitSig rest name
  _ => hasExplicitSig rest name

-- Column right after the name on the decl's start line (0-based `line`).  Scan
-- from char 0 over identifier chars; None if the line has no leading identifier.
-- Intentionally kept (not retired) as `inlayNamePos`'s `None` fallback — full F5 retirement stays deferred.
columnAfterName : SourceIndex -> Array Char -> Int -> Option Int
columnAfterName index arr line =
  let len = arrayLength arr
  do
    lineStart <- sourcePositionToOffset index (line + 1) 0
    let endCol = identRunLen arr len lineStart 0
    if endCol == 0 then None else Some endCol

-- Length of the leading identifier run starting at byte `i` (stops at EOL/EOF).
identRunLen : Array Char -> Int -> Int -> Int -> Int
identRunLen arr len i acc
  | i >= len = acc
  | arrayGetUnsafe i arr == '\n' = acc
  | isIdentChar (arrayGetUnsafe i arr) = identRunLen arr len (i + 1) (acc + 1)
  | otherwise = acc

-- inlay hints for a buffer: zip parse decls with positions, filter to
-- unsignatured value bindings present in the env, place one hint each.  The
-- env is hover's (`hoverEnvFor`), so an import-bearing buffer's hints come
-- from its project analysis, not from the buffer typechecked alone.
inlayHints : String -> String -> String -> String -> Docs -> <IO> List Json
inlayHints runtimeSrc coreSrc uri src docs =
  match hoverEnvFor runtimeSrc coreSrc uri src docs
    None => []
    Some env => match parseWithPositionsOpt src
      None => []
      Some (decls, positions) =>
        inlayZip
          (indexSource src)
          (stringToChars src)
          decls
          decls
          (positionsDecls positions)
          env.heSchemes

-- The (0-based line, col) right after a decl's name: the real name `Loc`'s end
-- position (#331) when there is one, else the old `columnAfterName` heuristic
-- over the decl's start line.
inlayNamePos : SourceIndex -> Array Char -> DeclPos -> Option (Int, Int)
inlayNamePos index arr p = match declPosNameLoc p
  Some (Loc _ _ _ el ec) => do
    off <- sourcePositionToOffset index el ec
    offsetToUtf16Position index off
  None =>
    map
      (col => (declPosLine p - 1, col))
      (columnAfterName index arr (declPosLine p - 1))

-- decls passed twice: `allDecls` for the has-explicit-sig scan, `ds` walked.
-- `name` always comes from `declBindingName d`, i.e. the BUFFER's own top-level
-- binder, and the env lists the buffer's own schemes first, so the hit renders
-- the context the buffer's binding was published with.
inlayZip : SourceIndex ->
  Array Char ->
  List Decl ->
  List Decl ->
  List DeclPos ->
  List (String, PubScheme) ->
  List Json
inlayZip index arr allDecls (d :: ds) (p :: ps) env = match declBindingName d
  None => inlayZip index arr allDecls ds ps env
  Some name =>
    if hasExplicitSig allDecls name then
      inlayZip index arr allDecls ds ps env
    else match lookupSchemeL name env
      None => inlayZip index arr allDecls ds ps env
      Some sch => match inlayNamePos index arr p
        None => inlayZip index arr allDecls ds ps env
        Some (line, col) =>
          jInlayHint line col (stringConcat [": ", ppPubScheme sch])
            :: inlayZip index arr allDecls ds ps env
inlayZip _ _ _ _ _ _ = []

-- One InlayHint { position, label, paddingLeft } (mirror the OCaml create).
jInlayHint : Int -> Int -> String -> Json
jInlayHint line col label = jObject [
  ("position", jPosition line col),
  ("label", JString label),
  ("paddingLeft", JBool True),
]

handleInlayHint : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleInlayHint runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (inlayHints runtimeSrc coreSrc uri src docs)
  writeMessage (responseMsg idJson result)

-- ── request-position helpers ────────────────────────────────────────────────
sourceCursor : String -> Json -> Option (Int, Int)
sourceCursor src params = sourceCursorIndexed (indexSource src) params

sourceCursorIndexed : SourceIndex -> Json -> Option (Int, Int)
sourceCursorIndexed index params = do
  pos <- get "position" params
  off <- lspPositionToOffset index pos
  map ((line, col) => (line - 1, col)) (offsetToSourcePosition index off)

-- params.textDocument.uri for a request.
requestUri : Json -> Option String
requestUri params = fieldStr "uri" (fieldOr "textDocument" params)

-- ── logging (crash diagnosis) ───────────────────────────────────────────────
--
-- Append-only session log so an unrecoverable panic leaves the CRASHING message
-- as the last line: each incoming body is logged BEFORE dispatch, and a
-- "handled" marker is logged AFTER dispatch returns.  A `recv` with no following
-- `handled` ⇒ the panic was in that message's dispatch.  Path: $MEDAKA_LSP_LOG,
-- else /tmp/medaka-lsp.log.  appendFile opens/appends/closes each call, so every
-- line is durable before the next step (no buffering to strand a pre-crash
-- entry).  Always on during the soak/dev phase; gate behind an env flag if noisy.
-- Each line is prefixed with the wall-clock epoch seconds (`wallTimeSec`, native
-- since the extern was wired) so log entries correlate to when a crash happened.
logFilePath : Unit -> <IO> String
logFilePath _ = match getEnv "MEDAKA_LSP_LOG"
  Some v => if v == "" then "/tmp/medaka-lsp.log" else v
  None => "/tmp/medaka-lsp.log"

logLine : String -> <IO> Unit
logLine s =
  let ts = wallTimeSec ()
  let _ =
    appendFile (logFilePath ()) (stringConcat [floatToString ts, " ", s, "\n"])
  ()

-- ── JSON-RPC framing ────────────────────────────────────────────────────────

-- Write a JSON value as a Content-Length-framed JSON-RPC packet to stdout,
-- then flush (the buffered stdout would otherwise strand the response).
writeMessage : Json -> <IO> Unit
writeMessage j =
  let body = stringify j
  let n = utf8Len body
  let header = stringConcat ["Content-Length: ", intToString n, "\r\n\r\n"]
  let _ = putStr header
  let _ = putStr body
  flushStdout ()

-- Content-Length counts BYTES on the wire, but `stringLength` counts Unicode
-- CODEPOINTS.  Medaka source routinely carries multibyte UTF-8 (em-dashes,
-- arrows, box-drawing in comments), and any response embedding that text (a
-- diagnostic, a documentSymbol body) would otherwise under-declare its length —
-- the client then reads too few bytes and the frame boundary slips ("Header must
-- provide a Content-Length property", server shutdown).  utf8Len / utf8CharWidth
-- live in `compiler/support/util.mdk` (imported above).

-- A JSON-RPC response envelope: { jsonrpc, id, result }.
export
responseMsg : Json -> Json -> Json
responseMsg idJson result =
  jObject [("jsonrpc", JString "2.0"), ("id", idJson), ("result", result)]

-- A JSON-RPC notification envelope: { jsonrpc, method, params }.
notificationMsg : String -> Json -> Json
notificationMsg meth params = jObject [
  ("jsonrpc", JString "2.0"),
  ("method", JString meth),
  ("params", params),
]

-- ── header reading ──────────────────────────────────────────────────────────
--
-- Read header lines via readLineOpt until a blank line, accumulating the
-- Content-Length.  readLineOpt strips the trailing '\n'; a CRLF line therefore
-- arrives as "...\r", so we trim a trailing '\r'.  Returns the byte length, or
-- None at EOF (clean shutdown of the input stream).

public export data Headers = Headers Int

readHeaders : Int -> <IO> Option Int
readHeaders lenAcc = match readLineOpt ()
  None => None
  Some raw =>
    let line = stripCR raw
    if line == "" then
      Some lenAcc
    else
      let lenAcc2 = match parseContentLength line
        Some n => n
        None => lenAcc
      readHeaders lenAcc2
-- EOF mid-stream

-- blank line ends the header block

-- Parse "Content-Length: <n>" (case-sensitive, as clients emit it).  Returns
-- the integer N or None if this header line is something else. Not anchored
-- at the end: the hand-rolled parser this replaces stopped at the first
-- non-digit and returned what it had, so trailing text after the digits
-- (there never is any, in practice) is tolerated rather than rejected —
-- preserved here by `find` rather than `isFullMatch`.
contentLengthRe : Regex
contentLengthRe = mustCompile "^Content-Length: *([0-9]+)"

parseContentLength : String -> Option Int
parseContentLength line = match find contentLengthRe line
  None => None
  Some m => match m.groups
    [Some g] => toInt g.text
    _ => None

{- ── textDocument/semanticTokens/full ────────────────────────────────────────

   Lexer-driven semantic highlighting.  The TextMate grammar in the VSCode
   extension is regex and can't parse, so the SAME type name colors
   inconsistently (e.g. in `f : List (Expr, Expr) -> Expr` the comma-followed
   `Expr` is mis-scoped vs the trailing one).  The lexer already disambiguates
   `TUpper` (type) from `TIdent` (variable), so server-emitted semantic tokens
   fix it deterministically.

   Legend (index = the `tokenType` int on the wire — keep in lockstep with
   `semanticLegend` / `semanticTokensOptions`):
     0 keyword  1 type  2 function  3 variable  4 string  5 number  6 operator

   Positions: token spans are codepoint offsets; synthetic layout tokens have
   empty spans and are filtered. SourceIndex converts offsets to zero-based
   UTF-16 positions. The wire format is delta-encoded:
   5 ints per token `[deltaLine, deltaChar, length, tokenType, tokenModifiers]`,
   tokens in start order (the lexer stream already is). -}

-- The legend, in index order.  These are standard semantic-token scope names;
-- the THEME maps them to colors.  Two are chosen for hue, not literal meaning, so
-- roles get real contrast in Cursor Dark (the most common case):
--   * type names → `class` (entity.name.type.class = blue #87c3ff), since plain
--     `type` shares the warm hue of `function` and would be indistinguishable.
--   * constructors → `macro` (#a8cc7c green), since `enumMember` is a near-default
--     light grey (#d6d6dd) that reads as plain text.
--   * typeclasses (interfaces) → `selfParameter` (#cc7c8a rose), so they read apart
--     from plain types (blue); `interface`/`enum` fall back to the warm `type` hue.
--   0 keyword  1 class(type)  2 macro(constructor)  3 function  4 property(field)
--   5 string   6 number  7 selfParameter(typeclass/interface)
semanticLegend : List String
semanticLegend = [
  "keyword",
  "class",
  "macro",
  "function",
  "property",
  "string",
  "number",
  "selfParameter",
]

semanticTokensOptions : Json
semanticTokensOptions = jObject [
  (
    "legend",
    jObject [
      ("tokenTypes", jArray (map JString semanticLegend)),
      ("tokenModifiers", jArray []),
    ],
  ),
  ("full", JBool True),
]

{- Token → semantic role, threaded with a small syntactic CONTEXT so the same
   token SHAPE colors by ROLE: an uppercase name is a `type` in type position but
   an `enumMember` (constructor) in expression/pattern position; a lowercase name
   is a `function` only at a definition head (top-level, line start) — references,
   locals and params stay default foreground.  No AST/parse is needed (the AST has
   no per-occurrence spans) and no parser changes: a single ordered pass over the
   token stream tracks indent depth, line-start, and a type/expr/data/record mode.
   Layout tokens (NEWLINE/INDENT/DEDENT) carry the depth/line-start signal and emit
   no token.  Robust on unparseable buffers (pure token walk). -}

-- Decides how an uppercase name is colored at this point.
--
-- There is no `MRecord` mode here: its only producer was the removed
-- `record` keyword (`nextMode TRecord _ = MRecord`).  Freeing `record` as an
-- ordinary identifier (#62) deleted that producer, so the mode is
-- unreachable.  This is not a highlighting regression: the
-- token it keyed on could not appear in any program that parsed, so no valid
-- source ever entered the mode — today's record fields live in `data X = { … }`
-- and are already coloured by the `MDataHead`/`MDataVariant` path.
data SMode =
  | MExpr
  | MType
  | MDataHead
  | MDataVariant
  | MDataPayload
  | MIfaceOne
  | MIfaceMany

-- depth (indent nesting; 0 = top level), lineStart (next token begins a logical
-- line), mode.
data SemCtx = SemCtx Int Bool SMode

isKeywordTok : Token -> Bool
isKeywordTok TLet = True
isKeywordTok TRec = True
isKeywordTok TWith = True
isKeywordTok TMut = True
isKeywordTok TIn = True
isKeywordTok TIf = True
isKeywordTok TThen = True
isKeywordTok TElse = True
isKeywordTok TMatch = True
isKeywordTok TData = True
isKeywordTok TInterface = True
isKeywordTok TDefault = True
isKeywordTok TImpl = True
isKeywordTok TImport = True
isKeywordTok TExport = True
isKeywordTok TPublic = True
isKeywordTok TWhere = True
isKeywordTok TOf = True
isKeywordTok TRequires = True
isKeywordTok TDo = True
isKeywordTok TAs = True
isKeywordTok TExtern = True
isKeywordTok TDeriving = True
isKeywordTok TType = True
isKeywordTok TNewtype = True
isKeywordTok TProp = True
isKeywordTok TTest = True
isKeywordTok TBench = True
isKeywordTok TEffect = True
isKeywordTok TFunction = True
isKeywordTok _ = False

-- An uppercase name's role given the current mode: constructor in expr/variant
-- position, type otherwise.
upperRole : SMode -> Int
upperRole MExpr = 2
upperRole MDataVariant = 2
upperRole _ = 1

-- The legend index for a token (None = leave default fg), given depth/lineStart/mode.
roleOf : Token -> Int -> Bool -> SMode -> Option Int
roleOf (TUpper _) _ _ MIfaceOne = Some 7  -- interface/impl name → typeclass
roleOf (TUpper _) _ _ MIfaceMany = Some 7  -- requires/deriving names → typeclass
roleOf (TUpper _) _ _ mode = Some (upperRole mode)
roleOf (TIdent _) depth lineStart _ =
  if lineStart && depth == 0 then
    Some 3  -- top-level definition head
  else
    None  -- local / param / reference
roleOf (TBacktickIdent _) _ _ _ = Some 3
roleOf (TString _) _ _ _ = Some 5
roleOf (TChar _) _ _ _ = Some 5
roleOf (TInterpOpen _) _ _ _ = Some 5
roleOf (TInterpMid _) _ _ _ = Some 5
roleOf (TInterpEnd _) _ _ _ = Some 5
roleOf (TInt _ _) _ _ _ = Some 6
roleOf (TWideInt _ _ _) _ _ _ = Some 6
roleOf (TFloat _) _ _ _ = Some 6
roleOf (TBool _) _ _ _ = Some 0
roleOf t _ _ _ = if isKeywordTok t then Some 0 else None

-- The mode AFTER consuming a token.
nextMode : Token -> SMode -> SMode
nextMode TData _ = MDataHead
nextMode TNewtype _ = MDataHead
nextMode TInterface _ = MIfaceOne
nextMode TImpl _ = MIfaceOne
nextMode TRequires _ = MIfaceMany
nextMode TDeriving _ = MIfaceMany
nextMode TExtern _ = MType
nextMode TType _ = MType
nextMode TOf _ = MType
nextMode TWhere _ = MExpr
nextMode (TUpper _) MIfaceOne = MType
nextMode TColon _ = MType
nextMode TEqual MDataHead = MDataVariant
nextMode TEqual _ = MExpr
nextMode TPipe MDataVariant = MDataVariant
nextMode TPipe MDataPayload = MDataVariant
nextMode (TUpper _) MDataVariant = MDataPayload
nextMode _ mode = mode

{- A classified token ready for delta-encoding: absolute 0-based line + char,
   UTF-16 length, and the legend index. -}
public export data SemTok = SemTok Int Int Int Int

-- Classify one token: its role (None = emit nothing) + the updated context.
-- Layout tokens update depth/line-start; a real token may flip the mode and
-- always clears line-start.
classify : Token -> SemCtx -> (Option Int, SemCtx)
classify TIndent (SemCtx depth ls mode) = (None, SemCtx (depth + 1) ls mode)
classify TDedent (SemCtx depth ls mode) = (None, SemCtx (depth - 1) ls mode)
classify TNewline (SemCtx depth _ mode) =
  let mode2 = if depth <= 0 then MExpr else mode
  (None, SemCtx depth True mode2)
classify tok (SemCtx depth ls mode) =
  (roleOf tok depth ls mode, SemCtx depth False (nextMode tok mode))

{- Build the absolute SemTok list, threading the context.  Filters tokens with no
   role, empty/synthetic spans (start == end), and any token straddling a line
   boundary (LSP forbids multi-line tokens; only a triple-quoted string could, and
   those stay with TextMate). -}
semToksOf : SourceIndex ->
  List Token ->
  List (Int, Int) ->
  SemCtx ->
  Result String (List SemTok)
semToksOf _ [] _ _ = Ok []
semToksOf _ _ [] _ = Err "semantic token spans ended before the token stream"
semToksOf arr (t :: ts) ((s, e) :: ps) ctx = match classify t ctx
  (roleOpt, ctx2) => match roleOpt
    None => semToksOf arr ts ps ctx2
    Some ty =>
      if s >= e then
        semToksOf arr ts ps ctx2
      else match (offsetToUtf16Position arr s, offsetToUtf16Position arr e)
        (Some (sl, sc), Some (el, ec)) =>
          if sl == el then
            map (SemTok sl sc (ec - sc) ty :: _) (semToksOf arr ts ps ctx2)
          else
            semToksOf arr ts ps ctx2
        _ => Err "semantic token endpoint is not a source boundary"

{- Delta-encode the (start-ordered) SemTok list into the flat 5-int LSP array.
   prevLine/prevChar start at 0, so the first token's deltaLine is its absolute
   line; deltaChar is relative to prevChar only when deltaLine == 0. -}
encodeSemToks : Int -> Int -> List SemTok -> List Int
encodeSemToks _ _ [] = []
encodeSemToks prevLine prevChar ((SemTok line ch len ty) :: rest) =
  let dLine = line - prevLine
  let dChar = if dLine == 0 then ch - prevChar else ch
  dLine :: dChar :: len :: ty :: 0 :: encodeSemToks line ch rest

-- The full semantic-tokens `data` array (flat ints) for a source string.
semanticTokensData : String -> Result String (List Int)
semanticTokensData src =
  let arr = indexSource src
  match tokenizeWithOffsetPairs src
    (toks, pairs) =>
      map (encodeSemToks 0 0) (semToksOf arr toks pairs (SemCtx 0 True MExpr))

semanticTokensPrepared : PreparedSyntax -> Result String (List Int)
semanticTokensPrepared prepared = match snapshotSyntaxSource prepared
  None => Err "syntax unavailable"
  Some syntax =>
    let pairs =
      map ((SourceSpan a b) => (a, b)) (toList (syntaxTokenSpans syntax))
    map
      (encodeSemToks 0 0)
      (semToksOf
        (syntaxIndex syntax)
        (toList (syntaxTokens syntax))
        pairs
        (SemCtx 0 True MExpr))

-- ── request dispatch ────────────────────────────────────────────────────────
--
-- The driver loops: read headers → read body → parse JSON → dispatch.  The
-- state threaded through the loop is the Docs store; the runtime/core prelude
-- sources are constants for the session.

-- The `initialize` result: serverInfo + the B.10 capability set.
-- textDocumentSync = 1 (Full).  B.10.3 adds the decl/textual providers:
-- formatting / documentSymbol / definition / documentHighlight (each a plain
-- `true`).  The richer providers
-- (hover/completion/inlayHint) and ELoc expr-precise ranges are later slices.
-- `serverVersion` is threaded in from the driver (medaka_cli.mdk's
-- `medakaVersion`), the same way tools/mcp.mdk threads its own: this module
-- sits below the CLI in the dependency graph and cannot import it.
initializeResultFor : String -> Json
initializeResultFor serverVersion = jObject [
  (
    "capabilities",
    jObject [
      ("textDocumentSync", JInt 1),
      ("codeActionProvider", JBool True),
      ("documentFormattingProvider", JBool True),
      ("documentSymbolProvider", JBool True),
      ("definitionProvider", JBool True),
      ("documentHighlightProvider", JBool True),
      ("referencesProvider", JBool True),
      ("hoverProvider", JBool True),
      ("completionProvider", jObject []),
      ("inlayHintProvider", JBool True),
      ("semanticTokensProvider", semanticTokensOptions),
    ],
  ),
  (
    "serverInfo",
    jObject [("name", JString "medaka-lsp"), ("version", JString serverVersion)],
  ),
]

parseErrorDiags : SourceSnapshot -> String -> ParseError -> List Json
parseErrorDiags snapshot src e =
  let diagnostic = parseErrorDiagnostic e
  [
    parseDiagnosticJson
      snapshot
      (wholeDocRange src)
      (parseDiagnosticToDiag "" diagnostic)
      diagnostic,
  ]

publishDiagnosticsList : String -> List Json -> <IO> Unit
publishDiagnosticsList uri diags =
  let params = jObject [("uri", JString uri), ("diagnostics", jArray diags)]
  writeMessage (notificationMsg "textDocument/publishDiagnostics" params)

-- Single-document diagnostics over the buffer's located decls, through
-- `frontEnd` unguarded.  Returns the typecheck drive's report, `None` when
-- resolve rejected the buffer and nothing was driven.
publishDiagnosticsFrom : String ->
  String ->
  String ->
  String ->
  List Decl ->
  <IO> Option TcReport
publishDiagnosticsFrom runtimeSrc coreSrc uri src decls =
  let front =
    fileFront
      (stdlibExportsReader (lspMedakaRoot "." ++ "/stdlib"))
      ""
      True
      runtimeSrc
      coreSrc
      decls
  let diags = flatMap snd front.foDiags
  let _ = publishDiagnosticsList uri (diagsToJson src diags)
  map (_ => front.foReport) front.foDriven

-- ── B.10.5: project-wide (multi-file) diagnostics ───────────────────────────
--
-- When the edited buffer imports a sibling module, run analyzeProject over the
-- whole import graph (with the OPEN BUFFERS as unsaved-source overrides) and
-- publish one publishDiagnostics PER affected file.
-- A buffer with no (non-core)
-- imports keeps the single-document path (publishDiagnosticsFrom above).
--
-- Simplifications (consistent with the single-root compiler
-- loader, which has no medaka.toml / multi-root support — see loader.mdk):
--   * project_dir = the DIRECTORY OF THE EDITED FILE (the loader's default root),
--     not a medaka.toml / .git walk-up (no Project_config port in compiler).
--   * last-good source cache is a SESSION-LIVED module Ref (projectCache), so a
--     buffer that currently fails to parse falls back to its last-parsed source
--     across didChange events (mirror analyze_project's last_good_source Hashtbl)
--     without threading extra state through the serve loop.

-- session-lived last-good-source cache (file path → last source that parsed).
projectCache : Ref (List (String, String))
projectCache = Ref []

-- session-lived parse memo (source string → located decls): lets an import-bearing
-- buffer's UNCHANGED dependency modules skip re-parsing on every didChange (the
-- ~80% cost of an import-bearing keystroke — see driver.loader.parseCachedLocated).
-- Shared by the diagnostics path AND the project-aware hover/completion path so
-- both reuse the same parsed deps.  Source-keyed (pure parse ⇒ equal source ⇒ equal
-- decls), bounded inside loadProgramFilesLocatedCached.
projectParseCache : Ref (OrdMap (List Decl))
projectParseCache = Ref omEmpty

retainOpenProjectSources : Docs -> Unit
retainOpenProjectSources (Docs xs _ _ _ _ _ _) =
  let openPaths = omFromNames (map ((uri, _) => pathOfUri uri) xs) omEmpty
  projectCache := filter ((path, _) => omHasKey path openPaths) !projectCache

clearSessionSourceOwners : Unit -> Unit
clearSessionSourceOwners () =
  clearLoadedSourceRecords ()
  clearProjectPassEntries ()

-- file:// URI ↔ filesystem path.  LSP clients send `file://<abs-path>`; the
-- loader works in plain paths.  pathOfUri strips the scheme; uriOfPath re-adds
-- it (so a loader file path maps back to the Docs key for the read override).
pathOfUri : String -> String
pathOfUri uri =
  if stringLength uri >= 7 && stringSlice 0 7 uri == "file://" then
    stringSlice 7 (stringLength uri) uri
  else
    uri

export
uriOfPath : String -> String
uriOfPath path =
  if stringLength path >= 7 && stringSlice 0 7 path == "file://" then
    path
  else
    stringConcat ["file://", path]

-- True when the buffer has a non-core `import` (→ project / multi-file path).
bufferHasImports : String -> Bool
bufferHasImports src = match parseResult src
  Err _ => False
  Ok decls => anyImport decls
-- unparseable → single-doc path squiggles it

anyImport : List Decl -> Bool
anyImport [] = False
anyImport ((DUse _ path _) :: rest) = not (isCoreImport path) || anyImport rest
anyImport (_ :: rest) = anyImport rest

-- core is the implicit prelude — an `import core.{…}` is not a sibling dep.
isCoreImport : UsePath -> Bool
isCoreImport p = useHead p == "core"

useHead : UsePath -> String
useHead (UseName ns) = headOr "" ns
useHead (UseGroup ns _) = headOr "" ns
useHead (UseWild ns) = headOr "" ns
useHead (UseAlias ns _) = headOr "" ns

headOr : String -> List String -> String
headOr d [] = d
headOr _ (x :: _) = x

-- Run analyzeProject over the graph rooted at the edited file and publish one
-- notification per file in the result (clean files → []).  `docs` already holds
-- the just-edited buffer; the read override maps a loader file path back to the
-- Docs buffer for that uri (unsaved buffers shadow disk).
--
-- Roots mirror the build/run loader (`medaka_cli` runRunCmd): the edited file's
-- directory first (user modules shadow stdlib), then MEDAKA_ROOT/stdlib so an
-- `import json` / other stdlib module resolves (without this, a buffer importing
-- a stdlib module reports a spurious `UnknownModule`).
publishProjectDiagnostics : String ->
  String ->
  String ->
  String ->
  Docs ->
  <IO> Option Kept
publishProjectDiagnostics runtimeSrc coreSrc uri text docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRootOrSelf (dirOf rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  -- #1362: the single-doc path (`publishDiagnosticsFrom`) runs `fileFront` UNGUARDED
  -- (no internal-extern restriction, no `--allow-internal` concept in the
  -- LSP); kept unguarded here too (`allowInternal = True`, `trustedMods = []`)
  -- so a live-edit session never flags what a build-time `check` wouldn't.
  let (keyed, results, sources) =
    analyzeProjectKeyedSources
      (stdlibExportsReader stdlibDir)
      True
      []
      projectCache
      projectParseCache
      read
      rootFile
      [projectDir, stdlibDir]
      runtimeSrc
      coreSrc
  let _ = publishEach docs sources results
  -- A resolve-blocked entry is not the last module the drive checked, so its
  -- report holds another module's locals and seed: nothing is kept.
  match keyed
    Some ((report, _), graph) =>
      if report.trPartial.paModule == graph.giEntry then
        Some (KeptGraph text graph report.trPartial)
      else
        None
    None => None
-- Module root = nearest ancestor with medaka.toml (NOT the file's own dir), so
-- a nested module's imports (rooted at the project dir) resolve.  Falls back to
-- the file's dir when there's no medaka.toml.

-- MEDAKA_ROOT (where stdlib/ lives), or `dflt` when unset/empty.  Mirrors
-- build_cmd.envOr but kept local so the LSP graph doesn't pull in build_cmd.
lspMedakaRoot : String -> <IO> String
lspMedakaRoot dflt = match getEnv "MEDAKA_ROOT"
  Some v => if v == "" then dflt else v
  None => dflt

-- Publish a publishDiagnostics notification for each (file, diags) bucket,
-- mapping the loader file path back to a file:// uri (mirror DocumentUri.of_path).
hasParseDiagnosticFix : Diag -> Bool
hasParseDiagnosticFix (Diag _ code _ _ _ (Some _)) = diagIdIsSyntax code
hasParseDiagnosticFix _ = False

publishEach : Docs -> OrdMap String -> List (String, List Diag) -> <IO> Unit
publishEach _ _ [] = ()
publishEach docs sources ((file, ds) :: rest) =
  let uri = uriOfPath file
  -- Disk reads must only run when neither in-memory source is available.
  -- lint-disable-next-line rule-orelse-staircase
  let src = match docsGet uri docs
    Some text => Some text
    None => match omLookup file sources
      Some text => Some text
      None => sourceForPath docs file
  let params = jObject [
    ("uri", JString uri),
    (
      "diagnostics",
      jArray (match src
        Some text =>
          if not (any hasParseDiagnosticFix ds) then
            diagsToJson text ds
          else match docsSnapshot uri docs
            Some snapshot => match parseLocatedResult text
              Err e =>
                map
                  (d =>
                    parseDiagnosticJson
                      snapshot
                      (wholeDocRange text)
                      d
                      (parseErrorDiagnostic e))
                  ds
              Ok _ => diagsToJson text ds
            None => diagsToJson text ds
        None => map (diagnosticWithRange (jRange 0 0 0 0)) ds),
    ),
  ]
  let _ =
    writeMessage (notificationMsg "textDocument/publishDiagnostics" params)
  publishEach docs sources rest

-- Choose the single-document or project path for a freshly-edited buffer.
publishFor : String -> String -> String -> String -> Docs -> <IO> Docs
publishFor runtimeSrc coreSrc uri text docs =
  let docs2 = selectProjectProfileFor (pathOfUri uri) docs
  let kept = publishForSelected runtimeSrc coreSrc uri text docs2
  docsKeep uri kept docs2

-- The profile this analysis typechecks under is the one of the project holding
-- `file`, chosen afresh per analysis because one server serves many projects.
-- A manifest whose `[target]` cannot be read is published as a diagnostic on
-- the manifest and the file is analyzed under no profile.
selectProjectProfileFor : String -> Docs -> <IO> Docs
selectProjectProfileFor file docs = match carryProjectProfile None file
  Ok _ => clearFlaggedManifest file docs
  Err msg => match manifestPathOf file
    None => docs
    Some path =>
      let _ = publishEach docs omEmpty [
        (
          path,
          [mkDiag SevError RModuleLoad msg (Some (Loc path 1 1 1 1))],
        ),
      ]
      docsFlag path docs

clearFlaggedManifest : String -> Docs -> <IO> Docs
clearFlaggedManifest file docs = match manifestPathOf file
  None => docs
  Some path =>
    if docsFlagged path docs then
      let _ = publishEach docs omEmpty [(path, [])]
      docsUnflag path docs
    else
      docs

docsFlagged : String -> Docs -> Bool
docsFlagged path (Docs _ flagged _ _ _ _ _) = contains path flagged

docsFlag : String -> Docs -> Docs
docsFlag path (Docs xs flagged kept versions generations next cache) =
  if contains path flagged then
    Docs xs flagged kept versions generations next cache
  else
    Docs xs (path :: flagged) kept versions generations next cache

docsUnflag : String -> Docs -> Docs
docsUnflag path (Docs xs flagged kept versions generations next cache) =
  Docs xs (filter (/= path) flagged) kept versions generations next cache

publishForSelected : String ->
  String ->
  String ->
  String ->
  Docs ->
  <IO> Option Kept
publishForSelected runtimeSrc coreSrc uri text docs =
  match parseCachedLocated projectParseCache text
    Err e =>
      match docsSnapshot uri docs
        Some snapshot =>
          publishDiagnosticsList uri (parseErrorDiags snapshot text e)
        None => publishDiagnosticsList uri []
      None
    Ok decls =>
      if anyImport decls then
        publishProjectDiagnostics runtimeSrc coreSrc uri text docs
      else
        -- a one-module graph: the parse memo keeps this buffer's parse alone
        retainParsed projectParseCache [text]
        match publishDiagnosticsFrom runtimeSrc coreSrc uri text decls
          Some report =>
            if report.trPartial.paModule == "__user__" then
              Some (KeptOne text (reportEnv report))
            else
              None
          None => None

-- Extract a textDocument/{didOpen,didChange} uri + text and publish.
-- didOpen:   params.textDocument.{uri,text}
-- didChange: params.textDocument.uri + params.contentChanges[last].text
--            (Full sync: the last change replaces the whole document).
handleDidOpen : String -> String -> Json -> Docs -> <IO> Docs
handleDidOpen runtimeSrc coreSrc params docs =
  match fieldStr "uri" (fieldOr "textDocument" params)
    None => docs
    Some uri => match fieldStr "text" (fieldOr "textDocument" params)
      None => docs
      Some text =>
        let version = asInt (fieldOr "version" (fieldOr "textDocument" params))
        let docs2 = docsSetVersion uri version (docsPut uri text docs)
        publishFor runtimeSrc coreSrc uri text docs2

handleDidChange : String -> String -> Json -> Docs -> <IO> Docs
handleDidChange runtimeSrc coreSrc params docs =
  match fieldStr "uri" (fieldOr "textDocument" params)
    None => docs
    Some uri => match lastChangeText (fieldOr "contentChanges" params)
      None => docs
      Some text =>
        let version = asInt (fieldOr "version" (fieldOr "textDocument" params))
        let docs2 = docsSetVersion uri version (docsPut uri text docs)
        publishFor runtimeSrc coreSrc uri text docs2

samePosition : Json -> Json -> Bool
samePosition a b =
  asInt (fieldOr "line" a) == asInt (fieldOr "line" b)
    && asInt (fieldOr "character" a) == asInt (fieldOr "character" b)
    && asInt (fieldOr "line" a) /= None
    && asInt (fieldOr "character" a) /= None

sameRange : Json -> Json -> Bool
sameRange a b =
  samePosition (fieldOr "start" a) (fieldOr "start" b)
    && samePosition (fieldOr "end" a) (fieldOr "end" b)

actionDiagnosticMatches : SourceSnapshot -> String -> Json -> Json -> Bool
actionDiagnosticMatches snapshot code range diagnostic =
  let expected = snapshotJson snapshot
  let actual = fieldOr "data" diagnostic
  fieldStr "uri" actual == fieldStr "uri" expected
    && asInt (fieldOr "generation" actual)
      == asInt (fieldOr "generation" expected)
    && fieldOr "code" diagnostic == JString code
    && sameRange (fieldOr "range" diagnostic) range

handleCodeAction : Json -> Json -> Docs -> <IO> Unit
handleCodeAction id params docs =
  let result = match requestUri params
    None => []
    Some uri => match (docsGet uri docs, docsSnapshot uri docs)
      (Some text, Some snapshot) => match parseLocatedResult text
        Err e =>
          let pd = parseErrorDiagnostic e
          let range =
            optionOr JNull (locToLspRange (indexSource text) (diagnosticLoc pd))
          let context = fieldOr "context" params
          let diagnostics =
            fieldOr "diagnostics" context
              |> asArray
              |> map toList
              |> optionOr []
          if any
            (actionDiagnosticMatches
              snapshot
              (codeText (diagnosticCode pd))
              range)
            diagnostics then
            parseDiagnosticActions snapshot [pd]
          else
            []
        Ok _ => []
      _ => []
  writeMessage (responseMsg id (jArray result))

-- ── B.10.3 request handlers ─────────────────────────────────────────────────
-- Each looks the doc up in the store and writes a JSON-RPC response.  A missing
-- doc / no-identifier-at-cursor yields the LSP "no result" — JNull (mirroring
-- the OCaml handlers returning None, which the rpc layer renders as null).

-- textDocument/formatting → TextEdit[] (or [] when already formatted).
handleFormatting : Json -> Json -> Docs -> <IO> Unit
handleFormatting idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (formattingEdits src)
  writeMessage (responseMsg idJson result)

-- textDocument/documentSymbol → DocumentSymbol[].
handleDocumentSymbol : Json -> Json -> Docs -> <IO> Unit
handleDocumentSymbol idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match (docsRevision uri docs, docsPrepared uri docs)
      (Some revision, Some prepared) =>
        match symbolsFromRecovered revision prepared
          Err _ => JNull
          Ok symbols => jArray symbols
      _ => JNull
  writeMessage (responseMsg idJson result)

cursorIdentifier : String -> Json -> Option (Int, Int, String)
cursorIdentifier src params = do
  (line, col) <- sourceCursor src params
  name <- identifierAt src line col
  Some (line, col, name)

projectRefIndexPrepared : String ->
  String ->
  String ->
  Docs ->
  <IO> (RefIndex, Docs, Option PreparedSyntax)
projectRefIndexPrepared runtimeSrc coreSrc rootFile docs =
  let projectDir = findProjectRootOrSelf (dirOf rootFile)
  let rootUri = uriOfPath rootFile
  let (initial, rootPrepared) = docsPrepareResult rootUri docs
  let current = Ref initial
  let (Docs _ _ _ _ _ _ cache) = docs
  let budget =
    Ref
      (max
        0
        (max 1 (syntaxCacheEntryLimit cache)
          - (match docsResident rootUri docs
            None => 1
            Some _ => 0)))
  let root = Ref rootPrepared
  let read = path => docsGet (uriOfPath path) !current
  let parse =
    path src =>
      let uri = uriOfPath path
      match docsGet uri !current
        Some text if text == src =>
          let before =
            if path == rootFile then !root else docsResident uri !current
          let prepared = match before
            None if !budget > 0 =>
              budget := !budget - 1
              let (updated, fresh) = docsPrepareResult uri !current
              current := updated
              fresh
            _ => before
          match prepared
            Some value => match snapshotSyntaxSource value
              Some _ =>
                let _ = stageBump "lsp.project.parsed_hit"
                structuralParsed value
              None => parseWithPositionsOpt src
            None => parseWithPositionsOpt src
        _ => parseWithPositionsOpt src
  let idx =
    buildRefIndexProjectWithParsed read parse projectDir runtimeSrc coreSrc
  (idx, !current, !root)

-- textDocument/definition → Location[] (singleton) or null.
handleDefinition : String -> String -> Json -> Json -> Docs -> <IO> Docs
handleDefinition runtimeSrc coreSrc idJson params docs =
  let (result, updated) = match requestUri params
    None => (JNull, docs)
    Some uri => match docsGet uri docs
      None => (JNull, docs)
      Some src =>
        projectDefinitionPrepared runtimeSrc coreSrc uri src params docs
  let _ = writeMessage (responseMsg idJson result)
  updated

projectDefinitionPrepared : String ->
  String ->
  String ->
  String ->
  Json ->
  Docs ->
  <IO> (Json, Docs)
projectDefinitionPrepared runtimeSrc coreSrc uri src params docs =
  match cursorIdentifier src params
    None => (JNull, docs)
    Some (line, col, _) =>
      let rootFile = pathOfUri uri
      let (idx, updated, root) =
        projectRefIndexPrepared runtimeSrc coreSrc rootFile docs
      let result = match binderAt idx rootFile (line + 1) col
        None => definitionResultParsed uri src params (match root
          None => parseWithPositionsOpt src
          Some prepared => match snapshotSyntaxSource prepared
            None => parseWithPositionsOpt src
            Some _ => structuralParsed prepared)
        Some key =>
          jArray (locationsJson updated (sortBy compareUseLoc (defsOf idx key)))
      (result, updated)

-- Exported for `medaka_definition` (#255) — intra-file only: `definitionRange`
-- scans decls in the SAME `src` it's given and never resolves an import, so a
-- cross-file name simply falls through to `None` → `JNull`, never a wrong
-- same-file match.  `uri` is echoed VERBATIM into the response's `range`'s
-- sibling `uri` field — the MCP handler passes the caller's own `file` string
-- through unmodified (no `uriOfPath` wrapping) so a relative request path stays
-- relative in the result (path-stable for a golden).
export
definitionResult : String -> String -> Json -> Json
definitionResult uri src params =
  definitionResultParsed uri src params (parseWithPositionsOpt src)

export
definitionResultParsed : String ->
  String ->
  Json ->
  Option (List Decl, Positions) ->
  Json
definitionResultParsed uri src params parsed = match cursorIdentifier src params
  Some (_, _, name) => match definitionRangeParsed src name parsed
    None => JNull
    Some range => jArray [jObject [("uri", JString uri), ("range", range)]]
  None => JNull

-- Resolve a set of columns using one index and one parse.
export
definitionResultsWithIndex : SourceIndex ->
  String ->
  String ->
  Int ->
  List Int ->
  List Json
definitionResultsWithIndex index uri src line cols =
  definitionResultsParsed index uri src line cols (parseWithPositionsOpt src)

export
definitionResultsParsed : SourceIndex ->
  String ->
  String ->
  Int ->
  List Int ->
  Option (List Decl, Positions) ->
  List Json
definitionResultsParsed index uri src line cols parsed =
  let chars = stringToChars src
  map
    (col =>
      definitionIndexed uri (arrayLength chars) index chars parsed line col)
    cols

definitionIndexed : String ->
  Int ->
  SourceIndex ->
  Array Char ->
  Option (List Decl, Positions) ->
  Int ->
  Int ->
  Json
definitionIndexed uri sourceLength index chars parsed line col =
  match sourceCursorIndexed index (jObject [("position", jPosition line col)])
    None => JNull
    Some (ln, cp) => match identifierAtIndexed index chars ln cp
      None => JNull
      Some name => match parsed
        None => JNull
        Some (decls, positions) =>
          match defZip index sourceLength decls (positionsDecls positions) name
            None => JNull
            Some range =>
              jArray [jObject [("uri", JString uri), ("range", range)]]

-- textDocument/references → Location[] (cross-file, #254 Stage 1). Shares the
-- MVP substrate with the `medaka_references` MCP tool (mcp.mdk calls this
-- SAME function): build (or load-and-build) the whole-project reference index
-- rooted at this buffer's project, resolve the click to a `BinderKey` via
-- `binderAt`, then emit every recorded use — plus the def site when
-- `includeDeclaration` (default true, F6) — as `{uri, range}` pairs across
-- files. A position off any identifier, or one that resolves to nothing
-- indexed (unparseable sibling, external/prelude symbol with zero project
-- uses, …), returns `[]` — NEVER a crash, NEVER a wrong hit (F2 best-effort).
-- `identifierAt` gates the (potentially whole-project) index build the same
-- way `hoverFor`/`typeAtPoint` gate their env build: resolve the cheap,
-- pure check first, only pay for the project load on an actual identifier.
handleReferences : String -> String -> Json -> Json -> Docs -> <IO> Docs
handleReferences runtimeSrc coreSrc idJson params docs =
  let (result, updated) = match requestUri params
    None => (JNull, docs)
    Some uri => match docsGet uri docs
      None => (JNull, docs)
      Some src =>
        referencesResultPrepared runtimeSrc coreSrc uri src params docs
  let _ = writeMessage (responseMsg idJson result)
  updated

-- Exported for `medaka_references` (#254) — TRUE WHOLE-PROJECT scope, not
-- one entry's import closure (#254 Stage 1.1: the entry-rooted
-- `buildRefIndex` only walks the clicked file's OWN imports downward, so a
-- query on a leaf module's DEFINITION missed every use in a file that
-- IMPORTS it — a reverse-dependent is never on that closure. `findProjectRoot`
-- + `tools.refindex.buildRefIndexProject` fixes this: enumerate every `.mdk`
-- under the project root and index all of them, so a click anywhere in the
-- project finds uses anywhere else in the project). `binderAt`/`usesOf`/
-- `defsOf` resolve through import origin + re-export chains + lexical scope
-- (never spelling), so shadowing, `import m as A`, selective/`as`-renamed
-- imports, and same-name-in-two-modules are each resolved correctly by
-- construction (docs/design/REFERENCES-RENAME-DESIGN.md §5). `uri` is the
-- Docs-table key for the CLICKED buffer (so unsaved edits there win, exactly
-- like `projectEntryEnv`); every OTHER project file is read through the same
-- `docs`-then-disk override the loader already uses elsewhere, so an unsaved
-- sibling buffer's edits are seen too. Each result entry's own `uri` is a
-- `file://` URI built from the index's recorded (loader-)path via
-- `uriOfPath`, independent of the query's own `uri` shape. F1 (locked):
-- intra-project only — `buildRefIndexProject` enumerates under the project
-- root alone, never the separate stdlib root, so it never descends into
-- stdlib/prelude bodies.
export
referencesResult : String ->
  String ->
  String ->
  String ->
  Json ->
  Docs ->
  <IO> Json
referencesResult runtimeSrc coreSrc uri src params docs =
  let (result, _) =
    referencesResultPrepared runtimeSrc coreSrc uri src params docs
  result

referencesResultPrepared : String ->
  String ->
  String ->
  String ->
  Json ->
  Docs ->
  <IO> (Json, Docs)
referencesResultPrepared runtimeSrc coreSrc uri src params docs =
  match cursorIdentifier src params
    None => (jArray [], docs)
    Some (line, col, _) =>
      let rootFile = pathOfUri uri
      let (idx, updated, _) =
        projectRefIndexPrepared runtimeSrc coreSrc rootFile docs
      let result = match binderAt idx rootFile (line + 1) col
        None => jArray []
        Some key =>
          jArray
            (referenceLocations updated idx key (includeDeclarationOf params))
      (result, updated)

-- Every recorded use of `key`, plus its def site(s) when `includeDecl`. `defsOf`
-- is `[]` for an external/prelude key (F1: intra-project scope), which correctly
-- drops the declaration line.
--
-- `defsOf` is plural (#964): a MULTI-CLAUSE top-level function is N separate
-- `DFunDef` decls sharing ONE BinderKey, so it has N clause-head def sites and
-- find-references must report EVERY one. Reporting just one head silently omitted
-- the others — an incomplete result here, and a source-corrupting one for a
-- rename built on the same set.
--
-- NO DEDUP IS DONE HERE, and that is a claim about the INDEX, not an oversight:
--   * def-vs-use — a def site is never also a use (`recordDef` never pushes into
--     `refs`), so the two lists cannot overlap;
--   * def-vs-def — `refindex.mdk`'s `pushDef` refuses a (uri, span) it already
--     holds, so `defsOf` cannot itself repeat one.
-- The second half is load-bearing and was NOT free: `defsOfDecl` records a record
-- field once PER VARIANT at the enclosing `data` decl's single name `Loc`, so
-- without that check `data T = A { x : Int } | B { x : Int }` would put the same
-- range in this list twice — and two edits over an identical range in one
-- `WorkspaceEdit` is rejected by strict LSP clients and double-applied by lenient
-- ones. If either invariant above is ever weakened, dedup MUST appear here.
--
-- DETERMINISM: sorted by (path, start line, start char) BEFORE rendering —
-- neither `usesOf`'s underlying `Ref`-list nor the whole-project build order
-- (`buildRefIndexProject`, refindex.mdk) is guaranteed stable across
-- runs/machines (the build order itself now sorts too, but this output-level
-- sort is the robust fix: it makes the RESULT order-stable no matter how the
-- index was built). #912 bounced the merge queue on exactly this — one
-- runner's golden didn't match another's. The def site is sorted IN with the
-- uses, not pinned to the front — nothing in the spec/F6 requires it first.
referenceLocations : Docs -> RefIndex -> String -> Bool -> <IO> List Json
referenceLocations docs idx key includeDecl =
  let uses = usesOf idx key
  let all = if includeDecl then defsOf idx key ++ uses else uses
  locationsJson docs (sortBy compareUseLoc all)

-- (path, then start line, then start char) — see `referenceLocations`.
compareUseLoc : (String, Loc) -> (String, Loc) -> Ordering
compareUseLoc (p1, Loc _ sl1 sc1 _ _) (p2, Loc _ sl2 sc2 _ _) =
  match compare p1 p2
    Lt => Lt
    Gt => Gt
    Eq => match compare sl1 sl2
      Lt => Lt
      Gt => Gt
      Eq => compare sc1 sc2

sourceForPath : Docs -> String -> <IO> Option String
sourceForPath docs path = match docsGet (uriOfPath path) docs
  Some src => Some src
  None => match readFile path
    Ok src => Some src
    Err _ => None

locationsJson : Docs -> List (String, Loc) -> <IO> List Json
locationsJson _ [] = []
locationsJson docs ((path, loc) :: rest) =
  let index = map indexSource (sourceForPath docs path)
  locationsForPath docs path index ((path, loc) :: rest)

locationsForPath : Docs ->
  String ->
  Option SourceIndex ->
  List (String, Loc) ->
  <IO> List Json
locationsForPath docs path index rows = go rows
  where
    go [] = []
    go ((next, loc) :: rest) =
      if next /= path then
        locationsJson docs ((next, loc) :: rest)
      else
        let tail = go rest
        match index
          None => tail
          Some idx => match locToLspRange idx loc
            None => tail
            Some range =>
              jObject [("uri", JString (uriOfPath path)), ("range", range)]
                :: tail

-- `params.context.includeDeclaration` (LSP `ReferenceContext`). Missing
-- `context`/field, or a non-bool value, defaults to `True` (F6, locked).
includeDeclarationOf : Json -> Bool
includeDeclarationOf params = match get "context" params
  None => True
  Some ctx => match get "includeDeclaration" ctx
    Some (JBool b) => b
    _ => True

-- textDocument/documentHighlight → DocumentHighlight[].
handleHighlight : Json -> Json -> Docs -> <IO> Unit
handleHighlight idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => highlightResult src params
  writeMessage (responseMsg idJson result)

highlightResult : String -> Json -> Json
highlightResult src params = match cursorIdentifier src params
  Some (_, _, name) => jArray (highlightRanges src name)
  None => JNull

-- textDocument/semanticTokens/full → { data: [int] } (delta-encoded).
handleSemanticTokens : Json -> Json -> Docs -> <IO> Unit
handleSemanticTokens idJson params docs =
  let result = match requestUri params
    None => Ok JNull
    Some uri => match docsGet uri docs
      None => Ok JNull
      Some src =>
        map
          (tokens => jObject [("data", jArray (map JInt tokens))])
          (match docsPrepared uri docs
            Some prepared => match snapshotSyntaxSource prepared
              Some _ => semanticTokensPrepared prepared
              None => semanticTokensData src
            None => semanticTokensData src)
  match result
    Ok value => writeMessage (responseMsg idJson value)
    Err message =>
      writeMessage
        (jObject [
          ("jsonrpc", JString "2.0"),
          ("id", idJson),
          (
            "error",
            jObject [("code", JInt (-32603)), ("message", JString message)],
          ),
        ])

-- The `.text` of the LAST element of a contentChanges JArray (Full sync).
lastChangeText : Json -> Option String
lastChangeText (JArray arr)
  | arrayLength arr == 0 = None
  | otherwise = fieldStr "text" (arrayGetUnsafe (arrayLength arr - 1) arr)
lastChangeText _ = None

-- json field accessors specialized to the shapes we read.
export
fieldOr : String -> Json -> Json
fieldOr key j = match get key j
  Some v => v
  None => JNull

export
fieldStr : String -> Json -> Option String
fieldStr key j = match get key j
  Some v => asString v
  None => None

-- The request `id` (number or string), passed through verbatim into responses.
-- We keep it as the raw Json so a string id round-trips unchanged.
requestId : Json -> Json
requestId msg = fieldOr "id" msg

export
methodOf : Json -> Option String
methodOf msg = fieldStr "method" msg

-- Dispatch one decoded message.  Returns the (possibly updated) Docs store and
-- a flag: True = keep looping, False = `exit` was received (stop).
public export data Step = Step Docs Bool

dispatch : String -> String -> String -> Json -> Docs -> <IO> Step
dispatch runtimeSrc coreSrc serverVersion msg docs = match methodOf msg
  None => Step docs True
  Some meth =>
    if meth == "initialize" then
      let _ =
        writeMessage
          (responseMsg (requestId msg) (initializeResultFor serverVersion))
      Step docs True
    else if meth == "initialized" then
      Step docs True
    else if meth == "textDocument/didOpen" then
      let docs2 = handleDidOpen runtimeSrc coreSrc (fieldOr "params" msg) docs
      Step docs2 True
    else if meth == "textDocument/didChange" then
      let docs2 = handleDidChange runtimeSrc coreSrc (fieldOr "params" msg) docs
      Step docs2 True
    else if meth == "textDocument/didClose" then
      let uri = fieldStr "uri" (fieldOr "textDocument" (fieldOr "params" msg))
      let docs2 = match (uri, docs)
        (Some u, Docs xs flagged kept versions generations next cache) =>
          Docs
            (docsRemove u xs)
            flagged
            (docsRemove u kept)
            (docsRemove u versions)
            (docsRemove u generations)
            next
            (invalidateSyntax u cache)
        _ => docs
      let _ = match docs2
        Docs xs _ _ _ _ _ _ =>
          let _ = retainParsed projectParseCache (map snd xs)
          let _ = retainOpenProjectSources docs2
          if isEmpty xs then clearSessionSourceOwners ()
      Step docs2 True
    else if meth == "textDocument/codeAction" then
      let _ = handleCodeAction (requestId msg) (fieldOr "params" msg) docs
      Step docs True
    else if meth == "textDocument/formatting" then
      let _ = handleFormatting (requestId msg) (fieldOr "params" msg) docs
      Step docs True
    else if meth == "textDocument/documentSymbol" then
      let docs2 = match requestUri (fieldOr "params" msg)
        Some uri => docsPrepare uri docs
        None => docs
      let _ = handleDocumentSymbol (requestId msg) (fieldOr "params" msg) docs2
      Step docs2 True
    else if meth == "textDocument/definition" then
      let docs2 =
        handleDefinition
          runtimeSrc
          coreSrc
          (requestId msg)
          (fieldOr "params" msg)
          docs
      Step docs2 True
    else if meth == "textDocument/documentHighlight" then
      let _ = handleHighlight (requestId msg) (fieldOr "params" msg) docs
      Step docs True
    else if meth == "textDocument/references" then
      let docs2 =
        handleReferences
          runtimeSrc
          coreSrc
          (requestId msg)
          (fieldOr "params" msg)
          docs
      Step docs2 True
    else if meth == "textDocument/hover" then
      let _ =
        handleHover
          runtimeSrc
          coreSrc
          (requestId msg)
          (fieldOr "params" msg)
          docs
      Step docs True
    else if meth == "textDocument/completion" then
      let _ =
        handleCompletion
          runtimeSrc
          coreSrc
          (requestId msg)
          (fieldOr "params" msg)
          docs
      Step docs True
    else if meth == "textDocument/inlayHint" then
      let _ =
        handleInlayHint
          runtimeSrc
          coreSrc
          (requestId msg)
          (fieldOr "params" msg)
          docs
      Step docs True
    else if meth == "textDocument/semanticTokens/full" then
      let docs2 = match requestUri (fieldOr "params" msg)
        Some uri => docsPrepare uri docs
        None => docs
      let _ = handleSemanticTokens (requestId msg) (fieldOr "params" msg) docs2
      Step docs2 True
    else if meth == "shutdown" then
      let _ = writeMessage (responseMsg (requestId msg) JNull)
      Step docs True
    else if meth == "exit" then
      let _ = logLine "exit (clean shutdown)"
      Step docs False
    else
      Step docs True  -- unrecognized method — ignore
-- a response/unknown — ignore, keep going

-- stop the loop

-- ── the framed read/dispatch loop ───────────────────────────────────────────

-- Read one full message (headers + body), parse it, dispatch.  Returns the
-- next Step, or a terminal Step on EOF.
serveOnce : String -> String -> String -> Docs -> <IO> Step
serveOnce runtimeSrc coreSrc serverVersion docs = match readHeaders 0
  None => Step docs False
  Some len => match readExactly len
    None => Step docs False
    Some body =>
      let _ = logLine (stringConcat ["recv ", body])
      match parse body
        Err _ =>
          let _ = logLine "  parse-error: malformed JSON body (skipped)"
          Step docs True
        Ok msg =>
          let step = dispatch runtimeSrc coreSrc serverVersion msg docs
          let _ = logLine "  handled"
          step
-- input stream closed

-- short read / EOF mid-body

-- malformed JSON body — skip, keep going

-- The session loop: serve messages until `exit` or EOF.
serve : String -> String -> String -> Docs -> <IO> Unit
serve runtimeSrc coreSrc serverVersion docs =
  match serveOnce runtimeSrc coreSrc serverVersion docs
    Step _ False => unit
    Step docs2 True => serve runtimeSrc coreSrc serverVersion docs2

-- Public entry point for the driver.  `serverVersion` is reported in the
-- `initialize` response's serverInfo; see `initializeResultFor`.
export
runServer : String -> String -> String -> <IO> Unit
runServer runtimeSrc coreSrc serverVersion =
  let _ = logLine "=== medaka-lsp session start ==="
  projectCache := []
  projectParseCache := omEmpty
  let _ = serve runtimeSrc coreSrc serverVersion emptyDocs
  projectCache := []
  projectParseCache := omEmpty
  clearSessionSourceOwners ()

export
unit : Unit
unit = ()
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true) (mem "codeText" false))))
(DUse false (UseGroup ("tools" "syntax_queries") ((mem "strictDocumentSymbols" false) (mem "symbolsFromRecovered" false) (mem "wholeLineRange" false) (mem "innerDecl" false) (mem "jPosition" false) (mem "jRange" false))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "PreparedSyntax" false) (mem "parseSnapshotSyntax" false) (mem "prepareSnapshotSyntaxWithCheckedDecls" false) (mem "defaultParseOptions" false) (mem "snapshotSyntaxSource" false))))
(DUse false (UseGroup ("tools" "syntax_cache") ((mem "SyntaxCache" false) (mem "emptySyntaxCache" false) (mem "defaultSyntaxCacheLimits" false) (mem "lookupSyntax" false) (mem "insertSyntax" false) (mem "invalidateSyntax" false) (mem "syntaxCacheEntryLimit" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "syntaxStructural" false) (mem "syntaxIndex" false) (mem "syntaxTokens" false) (mem "syntaxTokenSpans" false) (mem "SourceSpan" true))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "parsedDecls" false) (mem "parsedPositions" false))))
(DUse false (UseGroup ("tools" "lsp_diagnostics") ((mem "diagnosticJsonOr" false) (mem "diagnosticWithRange" false) (mem "parseDiagnosticJson" false) (mem "parseDiagnosticActions" false) (mem "snapshotJson" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" false) (mem "SourceRevision" true) (mem "SnapshotId" true) (mem "makeSnapshot" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "diagnosticCode" false) (mem "diagnosticLoc" false))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("array") ((mem "sliceClamped" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "diagIdIsSyntax" false) (mem "Severity" true) (mem "mkDiag" false) (mem "fileFront" false) (mem "FrontOutput" true) (mem "analyzeProjectKeyedSources" false) (mem "projectEntryAnalysisOr" false) (mem "GraphId" false) (mem "graphIdSame" false) (mem "stdlibExportsReader" false) (mem "clearProjectPassEntries" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRootOrSelf" false) (mem "parseCachedLocated" false) (mem "retainParsed" false) (mem "clearLoadedSourceRecords" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToSourcePosition" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false) (mem "lspPositionToOffset" false) (mem "jRangeOfLoc" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "carryProjectProfile" false) (mem "manifestPathOf" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "parseErrorDiagnostic" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "Positions" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false) (mem "toInt" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "escape" false) (mem "findAll" false) (mem "find" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "PartialAnalysis" true) (mem "TcReport" true) (mem "pubSchemes" false) (mem "ppPubScheme" false) (mem "publishedEntrySchemes" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "driveInputsFor" false) (mem "checkOneReportK" false) (mem "entrySplit" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false))))
(DUse false (UseGroup ("tools" "refindex") ((mem "RefIndex" false) (mem "buildRefIndexProjectWithParsed" false) (mem "binderAt" false) (mem "usesOf" false) (mem "defsOf" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false) (mem "zipWith" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "fieldName" false) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" true))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Kept"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int") (TyCon "SyntaxCache")))) ())
(DData Abstract "Kept" () ((variant "KeptOne" (ConPos (TyCon "String") (TyCon "HoverEnv"))) (variant "KeptGraph" (ConPos (TyCon "String") (TyCon "GraphId") (TyCon "PartialAnalysis")))) ())
(DTypeSig true "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (ELit (LInt 0))) (EApp (EVar "emptySyntaxCache") (EVar "defaultSyntaxCacheLimits"))))
(DTypeSig true "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EBinOp "::" (ETuple (EVar "uri") (EVar "next")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "generations")))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache"))))
(DTypeSig false "docsKeep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Kept")) (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsKeep" ((PVar "uri") (PVar "k") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "kept"))) (DoLet false false (PVar "kept2") (EMatch (EVar "k") (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (ETuple (EVar "uri") (EVar "v")) (EVar "rest"))) (arm (PCon "None") () (EVar "rest")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept2")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")))))
(DTypeSig false "docsKept" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "Kept")))))
(DFunDef false "docsKept" ((PVar "uri") (PCon "Docs" PWild PWild (PVar "kept") PWild PWild PWild PWild)) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "kept")))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "docsVersion" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "docsVersion" ((PVar "uri") (PCon "Docs" PWild PWild PWild (PVar "versions") PWild PWild PWild)) (EApp (EApp (EVar "optionOr") (EVar "None")) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "versions"))))
(DTypeSig false "docsSetVersion" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsSetVersion" ((PVar "uri") (PVar "version") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EBinOp "::" (ETuple (EVar "uri") (EVar "version")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "versions")))) (EVar "generations")) (EVar "next")) (EVar "cache")))
(DTypeSig false "docsSnapshot" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "SourceSnapshot")))))
(DFunDef false "docsSnapshot" ((PVar "uri") (PVar "docs")) (EMatch (EVar "docs") (arm (PCon "Docs" PWild PWild PWild PWild (PVar "generations") PWild PWild) () (EMatch (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "generations")) (arm (PCon "Some" (PVar "generation")) () (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "makeSnapshot") (EVar "uri")) (EApp (EApp (EVar "docsVersion") (EVar "uri")) (EVar "docs"))) (EVar "generation"))) (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "docsRevision" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "SourceRevision")))))
(DFunDef false "docsRevision" ((PVar "uri") (PAs "docs" (PCon "Docs" PWild PWild PWild PWild (PVar "generations") PWild PWild))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "generations"))) (ELam ((PVar "generation")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs"))) (ELam ((PVar "text")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "SourceRevision") (EVar "uri")) (EApp (EApp (EVar "docsVersion") (EVar "uri")) (EVar "docs"))) (EVar "generation")) (EVar "text"))))))))
(DTypeSig false "docsResident" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))
(DFunDef false "docsResident" ((PVar "uri") (PAs "docs" (PCon "Docs" PWild PWild PWild PWild PWild PWild (PVar "cache")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "SourceRevision" PWild (PVar "version") (PVar "generation") PWild) () (EApp (EApp (EApp (EApp (EVar "lookupSyntax") (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation"))) (EVar "version")) (EVar "defaultParseOptions")) (EVar "cache")))))))
(DTypeSig false "docsPrepared" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))
(DFunDef false "docsPrepared" ((PVar "uri") (PVar "docs")) (EApp (EApp (EVar "docsResident") (EVar "uri")) (EVar "docs")))
(DTypeSig false "docsPrepare" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsPrepare" ((PVar "uri") (PVar "docs")) (EApp (EVar "fst") (EApp (EApp (EVar "docsPrepareResult") (EVar "uri")) (EVar "docs"))))
(DTypeSig false "docsPrepareResult" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyTuple (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax"))))))
(DFunDef false "docsPrepareResult" ((PVar "uri") (PAs "docs" (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache")))) (EMatch (ETuple (EApp (EApp (EVar "docsResident") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "prepared")) PWild) () (ETuple (EVar "docs") (EApp (EVar "Some") (EVar "prepared")))) (arm (PTuple PWild (PCon "None")) () (ETuple (EVar "docs") (EVar "None"))) (arm (PTuple (PCon "None") (PCon "Some" (PAs "revision" (PCon "SourceRevision" PWild PWild PWild (PVar "text"))))) () (EBlock (DoLet false false (PVar "prepared") (EMatch (EApp (EApp (EVar "omLookup") (EVar "text")) (EUnOp "!" (EVar "projectParseCache"))) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EApp (EVar "prepareSnapshotSyntaxWithCheckedDecls") (EVar "defaultParseOptions")) (EVar "revision")) (EVar "decls"))) (arm (PCon "None") () (EApp (EVar "parseSnapshotSyntax") (EVar "revision"))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EApp (EApp (EApp (EVar "insertSyntax") (EVar "defaultParseOptions")) (EVar "prepared")) (EVar "cache"))) (EApp (EVar "Some") (EVar "prepared"))))))))
(DTypeSig true "structuralParsed" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "structuralParsed" ((PVar "prepared")) (EApp (EApp (EVar "andThen") (EApp (EVar "snapshotSyntaxSource") (EVar "prepared"))) (ELam ((PVar "syntax")) (EApp (EApp (EVar "andThen") (EApp (EVar "syntaxStructural") (EVar "syntax"))) (ELam ((PVar "parsed")) (EApp (EVar "Some") (ETuple (EApp (EVar "parsedDecls") (EVar "parsed")) (EApp (EVar "parsedPositions") (EVar "parsed")))))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (arm (PCon "Some" (PTuple (PVar "line") PWild)) () (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (ELit (LInt 0)))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "diagsToJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "diagsToJson" ((PVar "src") (PVar "diags")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "diagnosticJsonOr") (EVar "index")) (EApp (EVar "wholeDocRange") (EVar "src")))) (EVar "diags")))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild)) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "formatted")) () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringToChars") (EVar "src"))) (EVar "line")) (EVar "col")))
(DTypeSig false "identifierAtIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "identifierAtIndexed" ((PVar "index") (PVar "arr") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EBinOp "||" (EBinOp ">=" (EVar "pos") (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr"))))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "arr"))))))))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 0))) (EListLit) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EVar "occStart") (EVar "arr")) (EVar "len"))) (EApp (EApp (EVar "findAll") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "name")))) (EVar "src")))))))
(DTypeSig false "occStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "occStart" ((PVar "arr") (PVar "len") (PVar "m")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "start") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EFieldAccess (EVar "m") "start") (ELit (LInt 1)))) (EVar "arr"))))) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "end") (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EFieldAccess (EVar "m") "end")) (EVar "arr")))))) (EApp (EVar "Some") (EFieldAccess (EVar "m") "start")) (EVar "None")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EVar "occToHighlight") (EVar "index")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "occToHighlight" ((PVar "index") (PVar "nlen") (PVar "off")) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "off")) (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EBinOp "+" (EVar "off") (EVar "nlen")))) (arm (PTuple (PCon "Some" (PTuple (PVar "sl") (PVar "sc"))) (PCon "Some" (PTuple (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))) (arm PWild () (EVar "None"))))
(DTypeSig true "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EApp (EVar "strictDocumentSymbols") (EVar "src")))
(DTypeSig false "declOwnNameMatches" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declOwnNameMatches" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PRec "DData" ((rf "dataName" (PVar "n"))) false) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DImpl" () true) () (EVar "False")) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "c"))) false) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "declChildNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declChildNames" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EVar "dataChildNames") (EVar "vs"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "ms"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "ms"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))
(DTypeSig false "dataChildNames" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataChildNames" ((PList)) (EListLit))
(DFunDef false "dataChildNames" ((PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")) (EApp (EVar "dataChildNames") (EVar "vs"))))
(DFunDef false "dataChildNames" ((PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EVar "vn") (EApp (EVar "dataChildNames") (EVar "vs"))))
(DTypeSig false "anyName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyName" ((PList) PWild) (EVar "False"))
(DFunDef false "anyName" ((PCons (PVar "x") (PVar "xs")) (PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "anyName") (EVar "xs")) (EVar "name"))))
(DTypeSig false "indexOfName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOfName" ((PVar "name") (PVar "xs")) (EApp (EApp (EApp (EVar "indexOfNameGo") (EVar "name")) (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "indexOfNameGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "indexOfNameGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "indexOfNameGo" ((PVar "name") (PCons (PVar "x") (PVar "xs")) (PVar "i")) (EIf (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EVar "indexOfNameGo") (EVar "name")) (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "locAtIndex" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "locAtIndex" (PWild (PList)) (EVar "None"))
(DFunDef false "locAtIndex" ((PLit (LInt 0)) (PCons (PVar "l") PWild)) (EVar "l"))
(DFunDef false "locAtIndex" ((PVar "i") (PCons PWild (PVar "ls"))) (EApp (EApp (EVar "locAtIndex") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "ls")))
(DTypeSig false "definitionRangeParsed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "definitionRangeParsed" (PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "definitionRangeParsed" ((PVar "src") (PVar "name") (PCon "Some" (PTuple (PVar "decls") (PVar "positions")))) (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))
(DTypeSig false "defZip" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))))
(DFunDef false "defZip" ((PVar "index") (PVar "len") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "defZipDeclMatch") (EVar "index")) (EVar "len")) (EVar "d")) (EVar "p")) (EVar "name")) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EVar "j"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EVar "index")) (EVar "len")) (EVar "ds")) (EVar "ps")) (EVar "name")))))
(DFunDef false "defZip" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "defZipDeclMatch" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))))
(DFunDef false "defZipDeclMatch" ((PVar "index") (PVar "len") (PVar "d") (PVar "p") (PVar "name")) (EIf (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "defZipLocOr") (EVar "index")) (EVar "len")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EVar "p"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EVar "defZipLocOr") (EVar "index")) (EVar "len")) (EApp (EApp (EVar "locAtIndex") (EVar "k")) (EApp (EVar "declPosChildLocs") (EVar "p")))) (EVar "p")))) (EApp (EApp (EVar "indexOfName") (EVar "name")) (EApp (EVar "declChildNames") (EVar "d")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "defZipLocOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclPos") (TyCon "Json"))))))
(DFunDef false "defZipLocOr" ((PVar "index") PWild (PCon "Some" (PVar "l")) PWild) (EApp (EApp (EVar "jRangeOfLoc") (EVar "index")) (EVar "l")))
(DFunDef false "defZipLocOr" ((PVar "index") (PVar "len") (PCon "None") (PVar "p")) (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EVar "index")) (EVar "len")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (EApp (EVar "declPosEndLine") (EVar "p"))))
(DTypeSig false "docEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "HoverEnv"))))))
(DFunDef false "docEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoLet false false (PVar "report") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneReportK") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (ETuple (ELit (LString "__user__")) (EVar "userDecls")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "reportEnv") (EVar "report"))))))))))
(DTypeSig false "reportEnv" (TyFun (TyCon "TcReport") (TyCon "HoverEnv")))
(DFunDef false "reportEnv" ((PVar "report")) (EBlock (DoLet false false (PTuple (PVar "preludeSchemes") (PVar "ownSchemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (EApp (EApp (EVar "hoverEnvOf") (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (EFieldAccess (EVar "report") "trPartial")))))
(DTypeSig false "docEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "HoverEnv"))))))))
(DFunDef false "docEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EMatch (EApp (EApp (EVar "docsKept") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PCon "KeptOne" (PVar "keptSrc") (PVar "env"))) () (EIf (EBinOp "==" (EVar "keptSrc") (EVar "src")) (EApp (EVar "Some") (EVar "env")) (EApp (EApp (EApp (EVar "docEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))) (arm PWild () (EApp (EApp (EApp (EVar "docEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))
(DData Private "HoverEnv" () ((variant "HoverEnv" (ConNamed (field "heSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "heLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "heSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DTypeSig false "hoverEnvOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "PartialAnalysis") (TyCon "HoverEnv"))))
(DFunDef false "hoverEnvOf" ((PVar "schemes") (PVar "pa")) (ERecordCreate "HoverEnv" ((fa "heSchemes" (EVar "schemes")) (fa "heLocals" (EFieldAccess (EVar "pa") "paLocals")) (fa "heSeed" (EFieldAccess (EVar "pa") "paSeed")))))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAt") (EVar "name")) (EVar "src")) (EVar "line")) (EVar "col")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "hit")) () (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "ppHoverScheme") (EVar "hit")))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig true "typeAtPoint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typeAtPoint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filePath")) (EVar "src")) (EVar "line")) (EListLit (EVar "col"))) (arm (PList (PVar "answer")) () (EVar "answer")) (arm PWild () (EVar "None"))))
(DTypeSig true "typeAtPoints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "typeAtPoints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "cols")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPointsWithIndex") (EApp (EVar "indexSource") (EVar "src"))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filePath")) (EVar "src")) (EVar "line")) (EVar "cols")))
(DTypeSig true "typeAtPointsWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))))))))
(DFunDef false "typeAtPointsWithIndex" ((PVar "index") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "cols")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "positions") (EApp (EApp (EVar "map") (ELam ((PVar "col")) (EApp (EApp (EVar "sourceCursorIndexed") (EVar "index")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col")))))))) (EVar "cols"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "pos")) (EApp (EApp (EVar "andThen") (EVar "pos")) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ln") (PVar "col")) () (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EVar "index")) (EVar "chars")) (EVar "ln")) (EVar "col")))))))) (EVar "positions"))) (DoExpr (EIf (EApp (EApp (EVar "allList") (EVar "isNone")) (EVar "names")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EVar "cols")) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "filePath"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EVar "cols"))) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "parsed") (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "parseWithPositionsOpt") (EVar "src")))) (DoExpr (EApp (EApp (EApp (EVar "zipWith") (EApp (EApp (EVar "typeAtPosition") (EVar "parsed")) (EVar "env"))) (EVar "names")) (EVar "positions"))))))))))))
(DTypeSig false "typeAtPosition" (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyCon "HoverEnv") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "typeAtPosition" (PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "typeAtPosition" (PWild PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "typeAtPosition" ((PVar "parsed") (PVar "env") (PCon "Some" (PVar "name")) (PCon "Some" (PTuple (PVar "line") (PVar "col")))) (EApp (EApp (EVar "map") (ELam ((PVar "hit")) (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " : ")) (EApp (EVar "ppHoverScheme") (EVar "hit")))))) (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAtParsed") (EVar "name")) (EVar "parsed")) (EVar "line")) (EVar "col")) (EVar "env"))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "HoverEnv")))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "docEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "HoverEnv")))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "pa")) (EApp (EApp (EVar "hoverEnvOf") (EApp (EVar "publishedEntrySchemes") (EFieldAccess (EVar "pa") "paSchemes"))) (EVar "pa")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysisOr") (EApp (EApp (EApp (EVar "keptGraph") (EVar "uri")) (EVar "src")) (EVar "docs"))) (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))))))
(DTypeSig false "keptGraph" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyFun (TyCon "GraphId") (TyApp (TyCon "Option") (TyCon "PartialAnalysis")))))))
(DFunDef false "keptGraph" ((PVar "uri") (PVar "src") (PVar "docs") (PVar "current")) (EMatch (EApp (EApp (EVar "docsKept") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PCon "KeptGraph" (PVar "keptSrc") (PVar "keptId") (PVar "pa"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "keptSrc") (EVar "src")) (EApp (EApp (EVar "graphIdSame") (EVar "keptId")) (EVar "current"))) (EApp (EVar "Some") (EVar "pa")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DData Private "HoverHit" () ((variant "EnvHit" (ConPos (TyCon "PubScheme"))) (variant "LocalHit" (ConPos (TyCon "PubScheme"))) (variant "SeedHit" (ConPos (TyCon "PubScheme")))) ())
(DTypeSig false "localSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "localSchemes" () (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "s") PWild)) (ETuple (EVar "n") (EVar "s")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EFieldAccess (EVar "env") "heSchemes")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Some") (EApp (EVar "EnvHit") (EVar "p")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "localSchemes") (EFieldAccess (EVar "env") "heLocals"))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EVar "LocalHit") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "map") (EVar "SeedHit")) (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EFieldAccess (EVar "env") "heSeed"))))))))
(DTypeSig false "hoverSchemeAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit"))))))))
(DFunDef false "hoverSchemeAt" ((PVar "name") (PVar "src") (PVar "line") (PVar "col") (PVar "env")) (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAtParsed") (EVar "name")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "parseWithPositionsOpt") (EVar "src")))) (EVar "line")) (EVar "col")) (EVar "env")))
(DTypeSig false "hoverSchemeAtParsed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit"))))))))
(DFunDef false "hoverSchemeAtParsed" ((PVar "name") (PVar "parsed") (PVar "line") (PVar "col") (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "localSchemeAt") (EVar "name")) (EVar "line")) (EVar "col")) (EVar "parsed")) (EFieldAccess (EVar "env") "heLocals")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EVar "LocalHit") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")))))
(DTypeSig false "localSchemeAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "Option") (TyCon "PubScheme"))))))))
(DFunDef false "localSchemeAt" (PWild PWild PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "localSchemeAt" ((PVar "name") (PVar "line") (PVar "col") (PCon "Some" (PVar "pos")) (PVar "locals")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "positionsDecls") (EVar "pos"))) (DoLet false false (PVar "cl") (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "declIndexAt") (EVar "decls")) (ELit (LInt 0))) (EVar "cl")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "di")) () (EApp (EApp (EVar "latestLocal") (EVar "None")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "col")) (EVar "di")) (EVar "decls")) (EVar "locals"))))))))
(DTypeSig false "declIndexAt" (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declIndexAt" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "declIndexAt" ((PCons (PVar "p") (PVar "rest")) (PVar "i") (PVar "l")) (EIf (EBinOp "&&" (EBinOp "<=" (EApp (EVar "declPosLine") (EVar "p")) (EVar "l")) (EBinOp "<=" (EVar "l") (EApp (EVar "declPosEndLine") (EVar "p")))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "declIndexAt") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declIndexIs" (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "declIndexIs" ((PVar "decls") (PVar "l") (PVar "di")) (EMatch (EApp (EApp (EApp (EVar "declIndexAt") (EVar "decls")) (ELit (LInt 0))) (EVar "l")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "j")) () (EBinOp "==" (EVar "j") (EVar "di")))))
(DTypeSig false "locAtOrBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "locAtOrBefore" ((PVar "l1") (PVar "c1") (PVar "l2") (PVar "c2")) (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))))
(DTypeSig false "localCandidates" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))))))))))
(DFunDef false "localCandidates" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "localCandidates" ((PVar "name") (PVar "cl") (PVar "cc") (PVar "di") (PVar "decls") (PCons (PTuple (PVar "n") (PVar "sch") (PCon "Some" (PCon "Loc" PWild (PVar "bl") (PVar "bc") PWild PWild))) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "locAtOrBefore") (EVar "bl")) (EVar "bc")) (EVar "cl")) (EVar "cc"))) (EApp (EApp (EApp (EVar "declIndexIs") (EVar "decls")) (EVar "bl")) (EVar "di"))) (EBinOp "::" (ETuple (EVar "bl") (EVar "bc") (EVar "sch")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "cc")) (EVar "di")) (EVar "decls")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "localCandidates" ((PVar "name") (PVar "cl") (PVar "cc") (PVar "di") (PVar "decls") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "cc")) (EVar "di")) (EVar "decls")) (EVar "rest")))
(DTypeSig false "latestLocal" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))) (TyApp (TyCon "Option") (TyCon "PubScheme")))))
(DFunDef false "latestLocal" ((PCon "None") (PList)) (EVar "None"))
(DFunDef false "latestLocal" ((PCon "Some" (PTuple PWild PWild (PVar "s"))) (PList)) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "latestLocal" ((PCon "None") (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (EVar "c"))) (EVar "rest")))
(DFunDef false "latestLocal" ((PCon "Some" (PTuple (PVar "pl") (PVar "pc") (PVar "ps"))) (PCons (PTuple (PVar "bl") (PVar "bc") (PVar "bs")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EApp (EVar "locAtOrBefore") (EVar "pl")) (EVar "pc")) (EVar "bl")) (EVar "bc")) (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (ETuple (EVar "bl") (EVar "bc") (EVar "bs")))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (ETuple (EVar "pl") (EVar "pc") (EVar "ps")))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ppHoverScheme" (TyFun (TyCon "HoverHit") (TyCon "String")))
(DFunDef false "ppHoverScheme" ((PCon "EnvHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DFunDef false "ppHoverScheme" ((PCon "LocalHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DFunDef false "ppHoverScheme" ((PCon "SeedHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EApp (EVar "indexSource") (EVar "src"))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "hit")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EVar "ppHoverScheme") (EVar "hit"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EVar "map") (ELam ((PVar "env")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "tagTier") (EVar "EnvHit")) (EFieldAccess (EVar "env") "heSchemes")) (EApp (EApp (EVar "tagTier") (EVar "LocalHit")) (EApp (EVar "localSchemes") (EFieldAccess (EVar "env") "heLocals")))) (EApp (EApp (EVar "tagTier") (EVar "SeedHit")) (EFieldAccess (EVar "env") "heSeed"))))) (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (ELam ((PVar "env")) (EApp (EApp (EVar "tagTier") (EVar "EnvHit")) (EFieldAccess (EVar "env") "heSchemes")))) (EApp (EApp (EApp (EApp (EApp (EVar "docEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tagTier" (TyFun (TyFun (TyVar "s") (TyCon "HoverHit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "s"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit"))))))
(DFunDef false "tagTier" ((PVar "tag")) (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "tag") (EApp (EVar "snd") (EVar "b")))))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild PWild PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "columnAfterName" ((PVar "index") (PVar "arr") (PVar "line")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0)))) (ELam ((PVar "lineStart")) (ELet false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol")))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringToChars") (EVar "src"))) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EFieldAccess (EVar "env") "heSchemes")))))))
(DTypeSig false "inlayNamePos" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "inlayNamePos" ((PVar "index") (PVar "arr") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec"))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "off")) (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "off"))))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam ((PVar "col")) (ETuple (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EApp (EVar "columnAfterName") (EVar "index")) (EVar "arr")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "inlayZip" ((PVar "index") (PVar "arr") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EApp (EVar "inlayNamePos") (EVar "index")) (EVar "arr")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EVar "line")) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EVar "ppPubScheme") (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "sourceCursor" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "sourceCursor" ((PVar "src") (PVar "params")) (EApp (EApp (EVar "sourceCursorIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EVar "params")))
(DTypeSig false "sourceCursorIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "sourceCursorIndexed" ((PVar "index") (PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "get") (ELit (LString "position"))) (EVar "params"))) (ELam ((PVar "pos")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "lspPositionToOffset") (EVar "index")) (EVar "pos"))) (ELam ((PVar "off")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "line") (PVar "col"))) (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EVar "offsetToSourcePosition") (EVar "index")) (EVar "off"))))))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig true "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "contentLengthRe" (TyCon "Regex"))
(DFunDef false "contentLengthRe" () (EApp (EVar "mustCompile") (ELit (LString "^Content-Length: *([0-9]+)"))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EMatch (EApp (EApp (EVar "find") (EVar "contentLengthRe")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PList (PCon "Some" (PVar "g"))) () (EApp (EVar "toInt") (EFieldAccess (EVar "g") "text"))) (arm PWild () (EVar "None"))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
(DData Private "SemCtx" () ((variant "SemCtx" (ConPos (TyCon "Int") (TyCon "Bool") (TyCon "SMode")))) ())
(DTypeSig false "isKeywordTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isKeywordTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRec")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWith")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMut")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TData")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TInterface")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDo")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TAs")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExtern")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDeriving")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TType")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TNewtype")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TProp")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TTest")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TBench")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TEffect")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TFunction")) (EVar "True"))
(DFunDef false "isKeywordTok" (PWild) (EVar "False"))
(DTypeSig false "upperRole" (TyFun (TyCon "SMode") (TyCon "Int")))
(DFunDef false "upperRole" ((PCon "MExpr")) (ELit (LInt 2)))
(DFunDef false "upperRole" ((PCon "MDataVariant")) (ELit (LInt 2)))
(DFunDef false "upperRole" (PWild) (ELit (LInt 1)))
(DTypeSig false "roleOf" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "SMode") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceOne")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceMany")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PVar "mode")) (EApp (EVar "Some") (EApp (EVar "upperRole") (EVar "mode"))))
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") PWild) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EVar "None")))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TWideInt" PWild PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataVariant")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataPayload")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MDataVariant")) (EVar "MDataPayload"))
(DFunDef false "nextMode" (PWild (PVar "mode")) (EVar "mode"))
(DData Public "SemTok" () ((variant "SemTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "classify" (TyFun (TyCon "Token") (TyFun (TyCon "SemCtx") (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SemCtx")))))
(DFunDef false "classify" ((PCon "TIndent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TDedent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TNewline") (PCon "SemCtx" (PVar "depth") PWild (PVar "mode"))) (EBlock (DoLet false false (PVar "mode2") (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "MExpr") (EVar "mode"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "True")) (EVar "mode2"))))))
(DFunDef false "classify" ((PVar "tok") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EApp (EApp (EApp (EApp (EVar "roleOf") (EVar "tok")) (EVar "depth")) (EVar "ls")) (EVar "mode")) (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "False")) (EApp (EApp (EVar "nextMode") (EVar "tok")) (EVar "mode")))))
(DTypeSig false "semToksOf" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SemTok"))))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EApp (EVar "Err") (ELit (LString "semantic token spans ended before the token stream"))))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "offsetToUtf16Position") (EVar "arr")) (EVar "e"))) (arm (PTuple (PCon "Some" (PTuple (PVar "sl") (PVar "sc"))) (PCon "Some" (PTuple (PVar "el") (PVar "ec")))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "semantic token endpoint is not a source boundary")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EVar "map") (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "semanticTokensPrepared" (TyFun (TyCon "PreparedSyntax") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "semanticTokensPrepared" ((PVar "prepared")) (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "syntax unavailable")))) (arm (PCon "Some" (PVar "syntax")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (ELam ((PCon "SourceSpan" (PVar "a") (PVar "b"))) (ETuple (EVar "a") (EVar "b")))) (EApp (EVar "toList") (EApp (EVar "syntaxTokenSpans") (EVar "syntax"))))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EApp (EVar "syntaxIndex") (EVar "syntax"))) (EApp (EVar "toList") (EApp (EVar "syntaxTokens") (EVar "syntax")))) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "initializeResultFor" ((PVar "serverVersion")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "codeActionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "referencesProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "serverVersion")))))))))
(DTypeSig false "parseErrorDiags" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "parseErrorDiags" ((PVar "snapshot") (PVar "src") (PVar "e")) (EBlock (DoLet false false (PVar "diagnostic") (EApp (EVar "parseErrorDiagnostic") (EVar "e"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "parseDiagnosticJson") (EVar "snapshot")) (EApp (EVar "wholeDocRange") (EVar "src"))) (EApp (EApp (EVar "parseDiagnosticToDiag") (ELit (LString ""))) (EVar "diagnostic"))) (EVar "diagnostic"))))))
(DTypeSig false "publishDiagnosticsList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "publishDiagnosticsList" ((PVar "uri") (PVar "diags")) (EBlock (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "publishDiagnosticsFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "TcReport")))))))))
(DFunDef false "publishDiagnosticsFrom" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "front") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EApp (EVar "stdlibExportsReader") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib"))))) (ELit (LString ""))) (EVar "True")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "decls"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false PWild (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EApp (EApp (EVar "diagsToJson") (EVar "src")) (EVar "diags")))) (DoExpr (EApp (EApp (EVar "map") (ELam (PWild) (EFieldAccess (EVar "front") "foReport"))) (EFieldAccess (EVar "front") "foDriven")))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "retainOpenProjectSources" (TyFun (TyCon "Docs") (TyCon "Unit")))
(DFunDef false "retainOpenProjectSources" ((PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "openPaths") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "uri") PWild)) (EApp (EVar "pathOfUri") (EVar "uri")))) (EVar "xs"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EApp (EApp (EVar "filter") (ELam ((PTuple (PVar "path") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "path")) (EVar "openPaths")))) (EUnOp "!" (EVar "projectCache")))))))
(DTypeSig false "clearSessionSourceOwners" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "clearSessionSourceOwners" ((PLit LUnit)) (EBlock (DoExpr (EApp (EVar "clearLoadedSourceRecords") (ELit LUnit))) (DoExpr (EApp (EVar "clearProjectPassEntries") (ELit LUnit)))))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig true "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "bufferHasImports" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bufferHasImports" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "decls")) () (EApp (EVar "anyImport") (EVar "decls")))))
(DTypeSig false "anyImport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyImport" ((PList)) (EVar "False"))
(DFunDef false "anyImport" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCoreImport") (EVar "path"))) (EApp (EVar "anyImport") (EVar "rest"))))
(DFunDef false "anyImport" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyImport") (EVar "rest")))
(DTypeSig false "isCoreImport" (TyFun (TyCon "UsePath") (TyCon "Bool")))
(DFunDef false "isCoreImport" ((PVar "p")) (EBinOp "==" (EApp (EVar "useHead") (EVar "p")) (ELit (LString "core"))))
(DTypeSig false "useHead" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useHead" ((PCon "UseName" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseWild" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DTypeSig false "headOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "headOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "headOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Kept")))))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PTuple (PVar "keyed") (PVar "results") (PVar "sources")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectKeyedSources") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (EVar "True")) (EListLit)) (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "sources")) (EVar "results"))) (DoExpr (EMatch (EVar "keyed") (arm (PCon "Some" (PTuple (PTuple (PVar "report") PWild) (PVar "graph"))) () (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "report") "trPartial") "paModule") (EFieldAccess (EVar "graph") "giEntry")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "KeptGraph") (EVar "text")) (EVar "graph")) (EFieldAccess (EVar "report") "trPartial"))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "hasParseDiagnosticFix" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "hasParseDiagnosticFix" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild (PCon "Some" PWild))) (EApp (EVar "diagIdIsSyntax") (EVar "code")))
(DFunDef false "hasParseDiagnosticFix" (PWild) (EVar "False"))
(DTypeSig false "publishEach" (TyFun (TyCon "Docs") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "publishEach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PVar "docs") (PVar "sources") (PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "src") (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "Some") (EVar "text"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "file")) (EVar "sources")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "Some") (EVar "text"))) (arm (PCon "None") () (EApp (EApp (EVar "sourceForPath") (EVar "docs")) (EVar "file"))))))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EMatch (EVar "src") (arm (PCon "Some" (PVar "text")) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "any") (EVar "hasParseDiagnosticFix")) (EVar "ds"))) (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds")) (EMatch (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "snapshot")) () (EMatch (EApp (EVar "parseLocatedResult") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EVar "parseDiagnosticJson") (EVar "snapshot")) (EApp (EVar "wholeDocRange") (EVar "text"))) (EVar "d")) (EApp (EVar "parseErrorDiagnostic") (EVar "e"))))) (EVar "ds"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds"))))) (arm (PCon "None") () (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds")))))) (arm (PCon "None") () (EApp (EApp (EVar "map") (EApp (EVar "diagnosticWithRange") (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))) (EVar "ds"))))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "sources")) (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EVar "selectProjectProfileFor") (EApp (EVar "pathOfUri") (EVar "uri"))) (EVar "docs"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EApp (EApp (EVar "publishForSelected") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EApp (EApp (EApp (EVar "docsKeep") (EVar "uri")) (EVar "kept")) (EVar "docs2")))))
(DTypeSig false "selectProjectProfileFor" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))
(DFunDef false "selectProjectProfileFor" ((PVar "file") (PVar "docs")) (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "file")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "clearFlaggedManifest") (EVar "file")) (EVar "docs"))) (arm (PCon "Err" (PVar "msg")) () (EMatch (EApp (EVar "manifestPathOf") (EVar "file")) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "omEmpty")) (EListLit (ETuple (EVar "path") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1)))))))))) (DoExpr (EApp (EApp (EVar "docsFlag") (EVar "path")) (EVar "docs")))))))))
(DTypeSig false "clearFlaggedManifest" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))
(DFunDef false "clearFlaggedManifest" ((PVar "file") (PVar "docs")) (EMatch (EApp (EVar "manifestPathOf") (EVar "file")) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "path")) () (EIf (EApp (EApp (EVar "docsFlagged") (EVar "path")) (EVar "docs")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "omEmpty")) (EListLit (ETuple (EVar "path") (EListLit))))) (DoExpr (EApp (EApp (EVar "docsUnflag") (EVar "path")) (EVar "docs")))) (EVar "docs")))))
(DTypeSig false "docsFlagged" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Bool"))))
(DFunDef false "docsFlagged" ((PVar "path") (PCon "Docs" PWild (PVar "flagged") PWild PWild PWild PWild PWild)) (EApp (EApp (EVar "contains") (EVar "path")) (EVar "flagged")))
(DTypeSig false "docsFlag" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsFlag" ((PVar "path") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EIf (EApp (EApp (EVar "contains") (EVar "path")) (EVar "flagged")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EBinOp "::" (EVar "path") (EVar "flagged"))) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache"))))
(DTypeSig false "docsUnflag" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsUnflag" ((PVar "path") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "path")))) (EVar "flagged"))) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")))
(DTypeSig false "publishForSelected" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Kept")))))))))
(DFunDef false "publishForSelected" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EMatch (EApp (EApp (EVar "parseCachedLocated") (EVar "projectParseCache")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EMatch (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "snapshot")) () (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EApp (EApp (EApp (EVar "parseErrorDiags") (EVar "snapshot")) (EVar "text")) (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EListLit))))) (DoExpr (EVar "None")))) (arm (PCon "Ok" (PVar "decls")) () (EIf (EApp (EVar "anyImport") (EVar "decls")) (EApp (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs")) (EBlock (DoExpr (EApp (EApp (EVar "retainParsed") (EVar "projectParseCache")) (EListLit (EVar "text")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "publishDiagnosticsFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "decls")) (arm (PCon "Some" (PVar "report")) () (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "report") "trPartial") "paModule") (ELit (LString "__user__"))) (EApp (EVar "Some") (EApp (EApp (EVar "KeptOne") (EVar "text")) (EApp (EVar "reportEnv") (EVar "report")))) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "version") (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "version"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))) (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsSetVersion") (EVar "uri")) (EVar "version")) (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2")))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "version") (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "version"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))) (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsSetVersion") (EVar "uri")) (EVar "version")) (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2")))))))))
(DTypeSig false "samePosition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "samePosition" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "a"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "b")))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "a"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "b"))))) (EBinOp "/=" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "a"))) (EVar "None"))) (EBinOp "/=" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "a"))) (EVar "None"))))
(DTypeSig false "sameRange" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "sameRange" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "samePosition") (EApp (EApp (EVar "fieldOr") (ELit (LString "start"))) (EVar "a"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "start"))) (EVar "b"))) (EApp (EApp (EVar "samePosition") (EApp (EApp (EVar "fieldOr") (ELit (LString "end"))) (EVar "a"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "end"))) (EVar "b")))))
(DTypeSig false "actionDiagnosticMatches" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))))
(DFunDef false "actionDiagnosticMatches" ((PVar "snapshot") (PVar "code") (PVar "range") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "snapshotJson") (EVar "snapshot"))) (DoLet false false (PVar "actual") (EApp (EApp (EVar "fieldOr") (ELit (LString "data"))) (EVar "diagnostic"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EVar "actual")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EVar "expected"))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "generation"))) (EVar "actual"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "generation"))) (EVar "expected"))))) (EBinOp "==" (EApp (EApp (EVar "fieldOr") (ELit (LString "code"))) (EVar "diagnostic")) (EApp (EVar "JString") (EVar "code")))) (EApp (EApp (EVar "sameRange") (EApp (EApp (EVar "fieldOr") (ELit (LString "range"))) (EVar "diagnostic"))) (EVar "range"))))))
(DTypeSig false "handleCodeAction" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleCodeAction" ((PVar "id") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "uri")) () (EMatch (ETuple (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "text")) (PCon "Some" (PVar "snapshot"))) () (EMatch (EApp (EVar "parseLocatedResult") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "pd") (EApp (EVar "parseErrorDiagnostic") (EVar "e"))) (DoLet false false (PVar "range") (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EApp (EVar "indexSource") (EVar "text"))) (EApp (EVar "diagnosticLoc") (EVar "pd"))))) (DoLet false false (PVar "context") (EApp (EApp (EVar "fieldOr") (ELit (LString "context"))) (EVar "params"))) (DoLet false false (PVar "diagnostics") (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EApp (EVar "fieldOr") (ELit (LString "diagnostics"))) (EVar "context")) (EVar "asArray")) (EApp (EVar "map") (EVar "toList"))) (EApp (EVar "optionOr") (EListLit)))) (DoExpr (EIf (EApp (EApp (EVar "any") (EApp (EApp (EApp (EVar "actionDiagnosticMatches") (EVar "snapshot")) (EApp (EVar "codeText") (EApp (EVar "diagnosticCode") (EVar "pd")))) (EVar "range"))) (EVar "diagnostics")) (EApp (EApp (EVar "parseDiagnosticActions") (EVar "snapshot")) (EListLit (EVar "pd"))) (EListLit))))) (arm (PCon "Ok" PWild) () (EListLit)))) (arm PWild () (EListLit)))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "id")) (EApp (EVar "jArray") (EVar "result")))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (ETuple (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsPrepared") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "revision")) (PCon "Some" (PVar "prepared"))) () (EMatch (EApp (EApp (EVar "symbolsFromRecovered") (EVar "revision")) (EVar "prepared")) (arm (PCon "Err" PWild) () (EVar "JNull")) (arm (PCon "Ok" (PVar "symbols")) () (EApp (EVar "jArray") (EVar "symbols"))))) (arm PWild () (EVar "JNull")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "cursorIdentifier" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "cursorIdentifier" ((PVar "src") (PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "line") (PVar "col")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col"))) (ELam ((PVar "name")) (EApp (EVar "Some") (ETuple (EVar "line") (EVar "col") (EVar "name"))))))))))
(DTypeSig false "projectRefIndexPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "RefIndex") (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))))))
(DFunDef false "projectRefIndexPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "rootFile") (PVar "docs")) (EBlock (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "rootUri") (EApp (EVar "uriOfPath") (EVar "rootFile"))) (DoLet false false (PTuple (PVar "initial") (PVar "rootPrepared")) (EApp (EApp (EVar "docsPrepareResult") (EVar "rootUri")) (EVar "docs"))) (DoLet false false (PVar "current") (EApp (EVar "Ref") (EVar "initial"))) (DoLet false false (PCon "Docs" PWild PWild PWild PWild PWild PWild (PVar "cache")) (EVar "docs")) (DoLet false false (PVar "budget") (EApp (EVar "Ref") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EApp (EApp (EVar "max") (ELit (LInt 1))) (EApp (EVar "syntaxCacheEntryLimit") (EVar "cache"))) (EMatch (EApp (EApp (EVar "docsResident") (EVar "rootUri")) (EVar "docs")) (arm (PCon "None") () (ELit (LInt 1))) (arm (PCon "Some" PWild) () (ELit (LInt 0)))))))) (DoLet false false (PVar "root") (EApp (EVar "Ref") (EVar "rootPrepared"))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EUnOp "!" (EVar "current"))))) (DoLet false false (PVar "parse") (ELam ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EUnOp "!" (EVar "current"))) (arm (PCon "Some" (PVar "text")) ((GBool (EBinOp "==" (EVar "text") (EVar "src")))) (EBlock (DoLet false false (PVar "before") (EIf (EBinOp "==" (EVar "path") (EVar "rootFile")) (EUnOp "!" (EVar "root")) (EApp (EApp (EVar "docsResident") (EVar "uri")) (EUnOp "!" (EVar "current"))))) (DoLet false false (PVar "prepared") (EMatch (EVar "before") (arm (PCon "None") ((GBool (EBinOp ">" (EUnOp "!" (EVar "budget")) (ELit (LInt 0))))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "budget")) (EBinOp "-" (EUnOp "!" (EVar "budget")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "updated") (PVar "fresh")) (EApp (EApp (EVar "docsPrepareResult") (EVar "uri")) (EUnOp "!" (EVar "current")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "current")) (EVar "updated"))) (DoExpr (EVar "fresh")))) (arm PWild () (EVar "before")))) (DoExpr (EMatch (EVar "prepared") (arm (PCon "Some" (PVar "value")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "value")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lsp.project.parsed_hit")))) (DoExpr (EApp (EVar "structuralParsed") (EVar "value"))))) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))))) (arm PWild () (EApp (EVar "parseWithPositionsOpt") (EVar "src")))))))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EApp (EVar "buildRefIndexProjectWithParsed") (EVar "read")) (EVar "parse")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (ETuple (EVar "idx") (EUnOp "!" (EVar "current")) (EUnOp "!" (EVar "root"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "handleDefinition" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "updated")) (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDefinitionPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result")))) (DoExpr (EVar "updated"))))
(DTypeSig false "projectDefinitionPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "Json") (TyCon "Docs"))))))))))
(DFunDef false "projectDefinitionPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col") PWild)) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PTuple (PVar "idx") (PVar "updated") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "projectRefIndexPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rootFile")) (EVar "docs"))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "definitionResultParsed") (EVar "uri")) (EVar "src")) (EVar "params")) (EMatch (EVar "root") (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))) (arm (PCon "Some" (PVar "prepared")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))) (arm (PCon "Some" PWild) () (EApp (EVar "structuralParsed") (EVar "prepared")))))))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EVar "locationsJson") (EVar "updated")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")))))))) (DoExpr (ETuple (EVar "result") (EVar "updated")))))))
(DTypeSig true "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EApp (EApp (EApp (EApp (EVar "definitionResultParsed") (EVar "uri")) (EVar "src")) (EVar "params")) (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))
(DTypeSig true "definitionResultParsed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyCon "Json"))))))
(DFunDef false "definitionResultParsed" ((PVar "uri") (PVar "src") (PVar "params") (PVar "parsed")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple PWild PWild (PVar "name"))) () (EMatch (EApp (EApp (EApp (EVar "definitionRangeParsed") (EVar "src")) (EVar "name")) (EVar "parsed")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig true "definitionResultsWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "definitionResultsWithIndex" ((PVar "index") (PVar "uri") (PVar "src") (PVar "line") (PVar "cols")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionResultsParsed") (EVar "index")) (EVar "uri")) (EVar "src")) (EVar "line")) (EVar "cols")) (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))
(DTypeSig true "definitionResultsParsed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "definitionResultsParsed" ((PVar "index") (PVar "uri") (PVar "src") (PVar "line") (PVar "cols") (PVar "parsed")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionIndexed") (EVar "uri")) (EApp (EVar "arrayLength") (EVar "chars"))) (EVar "index")) (EVar "chars")) (EVar "parsed")) (EVar "line")) (EVar "col")))) (EVar "cols")))))
(DTypeSig false "definitionIndexed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))))))
(DFunDef false "definitionIndexed" ((PVar "uri") (PVar "sourceLength") (PVar "index") (PVar "chars") (PVar "parsed") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "sourceCursorIndexed") (EVar "index")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col")))))) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PTuple (PVar "ln") (PVar "cp"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EVar "index")) (EVar "chars")) (EVar "ln")) (EVar "cp")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EVar "parsed") (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EVar "index")) (EVar "sourceLength")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range")))))))))))))))
(DTypeSig false "handleReferences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "handleReferences" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "updated")) (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResultPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result")))) (DoExpr (EVar "updated"))))
(DTypeSig true "referencesResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "referencesResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResultPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))) (DoExpr (EVar "result"))))
(DTypeSig false "referencesResultPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "Json") (TyCon "Docs"))))))))))
(DFunDef false "referencesResultPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "None") () (ETuple (EApp (EVar "jArray") (EListLit)) (EVar "docs"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col") PWild)) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PTuple (PVar "idx") (PVar "updated") PWild) (EApp (EApp (EApp (EApp (EVar "projectRefIndexPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rootFile")) (EVar "docs"))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EApp (EVar "referenceLocations") (EVar "updated")) (EVar "idx")) (EVar "key")) (EApp (EVar "includeDeclarationOf") (EVar "params"))))))) (DoExpr (ETuple (EVar "result") (EVar "updated")))))))
(DTypeSig false "referenceLocations" (TyFun (TyCon "Docs") (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "referenceLocations" ((PVar "docs") (PVar "idx") (PVar "key") (PVar "includeDecl")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))) (DoLet false false (PVar "all") (EIf (EVar "includeDecl") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (EVar "uses")) (EVar "uses"))) (DoExpr (EApp (EApp (EVar "locationsJson") (EVar "docs")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EVar "all"))))))
(DTypeSig false "compareUseLoc" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Ordering"))))
(DFunDef false "compareUseLoc" ((PTuple (PVar "p1") (PCon "Loc" PWild (PVar "sl1") (PVar "sc1") PWild PWild)) (PTuple (PVar "p2") (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") PWild PWild))) (EMatch (EApp (EApp (EVar "compare") (EVar "p1")) (EVar "p2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "sl1")) (EVar "sl2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "sc1")) (EVar "sc2")))))))
(DTypeSig false "sourceForPath" (TyFun (TyCon "Docs") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "sourceForPath" ((PVar "docs") (PVar "path")) (EMatch (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "Some") (EVar "src"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Some") (EVar "src"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "locationsJson" (TyFun (TyCon "Docs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "locationsJson" (PWild (PList)) (EListLit))
(DFunDef false "locationsJson" ((PVar "docs") (PCons (PTuple (PVar "path") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "index") (EApp (EApp (EVar "map") (EVar "indexSource")) (EApp (EApp (EVar "sourceForPath") (EVar "docs")) (EVar "path")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "locationsForPath") (EVar "docs")) (EVar "path")) (EVar "index")) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EVar "rest"))))))
(DTypeSig false "locationsForPath" (TyFun (TyCon "Docs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "locationsForPath" ((PVar "docs") (PVar "path") (PVar "index") (PVar "rows")) (ELetGroup ((lgb "go" (clause ((PList)) (EListLit)) (clause ((PCons (PTuple (PVar "next") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "/=" (EVar "next") (EVar "path")) (EApp (EApp (EVar "locationsJson") (EVar "docs")) (EBinOp "::" (ETuple (EVar "next") (EVar "loc")) (EVar "rest"))) (EBlock (DoLet false false (PVar "tail") (EApp (EVar "go") (EVar "rest"))) (DoExpr (EMatch (EVar "index") (arm (PCon "None") () (EVar "tail")) (arm (PCon "Some" (PVar "idx")) () (EMatch (EApp (EApp (EVar "locToLspRange") (EVar "idx")) (EVar "loc")) (arm (PCon "None") () (EVar "tail")) (arm (PCon "Some" (PVar "range")) () (EBinOp "::" (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "range")) (EVar "range")))) (EVar "tail")))))))))))) (EApp (EVar "go") (EVar "rows"))))
(DTypeSig false "includeDeclarationOf" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "includeDeclarationOf" ((PVar "params")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "context"))) (EVar "params")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "ctx")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "includeDeclaration"))) (EVar "ctx")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "True"))))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple PWild PWild (PVar "name"))) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "JNull"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "JNull"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "map") (ELam ((PVar "tokens")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JInt")) (EVar "tokens")))))))) (EMatch (EApp (EApp (EVar "docsPrepared") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "prepared")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "Some" PWild) () (EApp (EVar "semanticTokensPrepared") (EVar "prepared"))) (arm (PCon "None") () (EApp (EVar "semanticTokensData") (EVar "src"))))) (arm (PCon "None") () (EApp (EVar "semanticTokensData") (EVar "src")))))))))) (DoExpr (EMatch (EVar "result") (arm (PCon "Ok" (PVar "value")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "value")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "writeMessage") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EUnOp "-" (ELit (LInt 32603))))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message"))))))))))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig true "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig true "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig true "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EVar "initializeResultFor") (EVar "serverVersion"))))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didClose"))) (EBlock (DoLet false false (PVar "uri") (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))))) (DoLet false false (PVar "docs2") (EMatch (ETuple (EVar "uri") (EVar "docs")) (arm (PTuple (PCon "Some" (PVar "u")) (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "xs"))) (EVar "flagged")) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "kept"))) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "versions"))) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "generations"))) (EVar "next")) (EApp (EApp (EVar "invalidateSyntax") (EVar "u")) (EVar "cache")))) (arm PWild () (EVar "docs")))) (DoLet false false PWild (EMatch (EVar "docs2") (arm (PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainParsed") (EVar "projectParseCache")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "xs")))) (DoLet false false PWild (EApp (EVar "retainOpenProjectSources") (EVar "docs2"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "xs")) (EApp (EVar "clearSessionSourceOwners") (ELit LUnit)) (ELit LUnit))))))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/codeAction"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleCodeAction") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false (PVar "docs2") (EMatch (EApp (EVar "requestUri") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (arm (PCon "Some" (PVar "uri")) () (EApp (EApp (EVar "docsPrepare") (EVar "uri")) (EVar "docs"))) (arm (PCon "None") () (EVar "docs")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs2"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EApp (EVar "handleDefinition") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/references"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EApp (EVar "handleReferences") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false (PVar "docs2") (EMatch (EApp (EVar "requestUri") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (arm (PCon "Some" (PVar "uri")) () (EApp (EApp (EVar "docsPrepare") (EVar "uri")) (EVar "docs"))) (arm (PCon "None") () (EVar "docs")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs2"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "docs")) (EMatch (EApp (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectParseCache")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "emptyDocs"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectParseCache")) (EVar "omEmpty"))) (DoExpr (EApp (EVar "clearSessionSourceOwners") (ELit LUnit)))))
(DTypeSig true "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true) (mem "codeText" false))))
(DUse false (UseGroup ("tools" "syntax_queries") ((mem "strictDocumentSymbols" false) (mem "symbolsFromRecovered" false) (mem "wholeLineRange" false) (mem "innerDecl" false) (mem "jPosition" false) (mem "jRange" false))))
(DUse false (UseGroup ("tools" "snapshot_syntax") ((mem "PreparedSyntax" false) (mem "parseSnapshotSyntax" false) (mem "prepareSnapshotSyntaxWithCheckedDecls" false) (mem "defaultParseOptions" false) (mem "snapshotSyntaxSource" false))))
(DUse false (UseGroup ("tools" "syntax_cache") ((mem "SyntaxCache" false) (mem "emptySyntaxCache" false) (mem "defaultSyntaxCacheLimits" false) (mem "lookupSyntax" false) (mem "insertSyntax" false) (mem "invalidateSyntax" false) (mem "syntaxCacheEntryLimit" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "syntaxStructural" false) (mem "syntaxIndex" false) (mem "syntaxTokens" false) (mem "syntaxTokenSpans" false) (mem "SourceSpan" true))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "parsedDecls" false) (mem "parsedPositions" false))))
(DUse false (UseGroup ("tools" "lsp_diagnostics") ((mem "diagnosticJsonOr" false) (mem "diagnosticWithRange" false) (mem "parseDiagnosticJson" false) (mem "parseDiagnosticActions" false) (mem "snapshotJson" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" false) (mem "SourceRevision" true) (mem "SnapshotId" true) (mem "makeSnapshot" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "diagnosticCode" false) (mem "diagnosticLoc" false))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("array") ((mem "sliceClamped" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "get" false) (mem "asString" false) (mem "asInt" false) (mem "asArray" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "diagIdIsSyntax" false) (mem "Severity" true) (mem "mkDiag" false) (mem "fileFront" false) (mem "FrontOutput" true) (mem "analyzeProjectKeyedSources" false) (mem "projectEntryAnalysisOr" false) (mem "GraphId" false) (mem "graphIdSame" false) (mem "stdlibExportsReader" false) (mem "clearProjectPassEntries" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRootOrSelf" false) (mem "parseCachedLocated" false) (mem "retainParsed" false) (mem "clearLoadedSourceRecords" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToSourcePosition" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false) (mem "lspPositionToOffset" false) (mem "jRangeOfLoc" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "carryProjectProfile" false) (mem "manifestPathOf" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "parseErrorDiagnostic" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "Positions" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false) (mem "toInt" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "escape" false) (mem "findAll" false) (mem "find" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "PartialAnalysis" true) (mem "TcReport" true) (mem "pubSchemes" false) (mem "ppPubScheme" false) (mem "publishedEntrySchemes" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "driveInputsFor" false) (mem "checkOneReportK" false) (mem "entrySplit" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false))))
(DUse false (UseGroup ("tools" "refindex") ((mem "RefIndex" false) (mem "buildRefIndexProjectWithParsed" false) (mem "binderAt" false) (mem "usesOf" false) (mem "defsOf" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false) (mem "zipWith" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "fieldName" false) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" true))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Kept"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int") (TyCon "SyntaxCache")))) ())
(DData Abstract "Kept" () ((variant "KeptOne" (ConPos (TyCon "String") (TyCon "HoverEnv"))) (variant "KeptGraph" (ConPos (TyCon "String") (TyCon "GraphId") (TyCon "PartialAnalysis")))) ())
(DTypeSig true "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (ELit (LInt 0))) (EApp (EVar "emptySyntaxCache") (EVar "defaultSyntaxCacheLimits"))))
(DTypeSig true "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EBinOp "::" (ETuple (EVar "uri") (EVar "next")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "generations")))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EVar "invalidateSyntax") (EVar "uri")) (EVar "cache"))))
(DTypeSig false "docsKeep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Kept")) (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsKeep" ((PVar "uri") (PVar "k") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "kept"))) (DoLet false false (PVar "kept2") (EMatch (EVar "k") (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (ETuple (EVar "uri") (EVar "v")) (EVar "rest"))) (arm (PCon "None") () (EVar "rest")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept2")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")))))
(DTypeSig false "docsKept" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "Kept")))))
(DFunDef false "docsKept" ((PVar "uri") (PCon "Docs" PWild PWild (PVar "kept") PWild PWild PWild PWild)) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "kept")))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "docsVersion" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "docsVersion" ((PVar "uri") (PCon "Docs" PWild PWild PWild (PVar "versions") PWild PWild PWild)) (EApp (EApp (EVar "optionOr") (EVar "None")) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "versions"))))
(DTypeSig false "docsSetVersion" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsSetVersion" ((PVar "uri") (PVar "version") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EBinOp "::" (ETuple (EVar "uri") (EVar "version")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "versions")))) (EVar "generations")) (EVar "next")) (EVar "cache")))
(DTypeSig false "docsSnapshot" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "SourceSnapshot")))))
(DFunDef false "docsSnapshot" ((PVar "uri") (PVar "docs")) (EMatch (EVar "docs") (arm (PCon "Docs" PWild PWild PWild PWild (PVar "generations") PWild PWild) () (EMatch (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "generations")) (arm (PCon "Some" (PVar "generation")) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "makeSnapshot") (EVar "uri")) (EApp (EApp (EVar "docsVersion") (EVar "uri")) (EVar "docs"))) (EVar "generation"))) (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "docsRevision" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "SourceRevision")))))
(DFunDef false "docsRevision" ((PVar "uri") (PAs "docs" (PCon "Docs" PWild PWild PWild PWild (PVar "generations") PWild PWild))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "generations"))) (ELam ((PVar "generation")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs"))) (ELam ((PVar "text")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "SourceRevision") (EVar "uri")) (EApp (EApp (EVar "docsVersion") (EVar "uri")) (EVar "docs"))) (EVar "generation")) (EVar "text"))))))))
(DTypeSig false "docsResident" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))
(DFunDef false "docsResident" ((PVar "uri") (PAs "docs" (PCon "Docs" PWild PWild PWild PWild PWild PWild (PVar "cache")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "SourceRevision" PWild (PVar "version") (PVar "generation") PWild) () (EApp (EApp (EApp (EApp (EVar "lookupSyntax") (EApp (EApp (EVar "SnapshotId") (EVar "uri")) (EVar "generation"))) (EVar "version")) (EVar "defaultParseOptions")) (EVar "cache")))))))
(DTypeSig false "docsPrepared" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))
(DFunDef false "docsPrepared" ((PVar "uri") (PVar "docs")) (EApp (EApp (EVar "docsResident") (EVar "uri")) (EVar "docs")))
(DTypeSig false "docsPrepare" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsPrepare" ((PVar "uri") (PVar "docs")) (EApp (EVar "fst") (EApp (EApp (EVar "docsPrepareResult") (EVar "uri")) (EVar "docs"))))
(DTypeSig false "docsPrepareResult" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyTuple (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax"))))))
(DFunDef false "docsPrepareResult" ((PVar "uri") (PAs "docs" (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache")))) (EMatch (ETuple (EApp (EApp (EVar "docsResident") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "prepared")) PWild) () (ETuple (EVar "docs") (EApp (EVar "Some") (EVar "prepared")))) (arm (PTuple PWild (PCon "None")) () (ETuple (EVar "docs") (EVar "None"))) (arm (PTuple (PCon "None") (PCon "Some" (PAs "revision" (PCon "SourceRevision" PWild PWild PWild (PVar "text"))))) () (EBlock (DoLet false false (PVar "prepared") (EMatch (EApp (EApp (EVar "omLookup") (EVar "text")) (EUnOp "!" (EVar "projectParseCache"))) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EApp (EVar "prepareSnapshotSyntaxWithCheckedDecls") (EVar "defaultParseOptions")) (EVar "revision")) (EVar "decls"))) (arm (PCon "None") () (EApp (EVar "parseSnapshotSyntax") (EVar "revision"))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EApp (EApp (EApp (EVar "insertSyntax") (EVar "defaultParseOptions")) (EVar "prepared")) (EVar "cache"))) (EApp (EVar "Some") (EVar "prepared"))))))))
(DTypeSig true "structuralParsed" (TyFun (TyCon "PreparedSyntax") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "structuralParsed" ((PVar "prepared")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "snapshotSyntaxSource") (EVar "prepared"))) (ELam ((PVar "syntax")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "syntaxStructural") (EVar "syntax"))) (ELam ((PVar "parsed")) (EApp (EVar "Some") (ETuple (EApp (EVar "parsedDecls") (EVar "parsed")) (EApp (EVar "parsedPositions") (EVar "parsed")))))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (arm (PCon "Some" (PTuple (PVar "line") PWild)) () (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (ELit (LInt 0)))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "diagsToJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "diagsToJson" ((PVar "src") (PVar "diags")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "diagnosticJsonOr") (EMethodRef "index")) (EApp (EVar "wholeDocRange") (EVar "src")))) (EVar "diags")))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild)) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "formatted")) () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringToChars") (EVar "src"))) (EVar "line")) (EVar "col")))
(DTypeSig false "identifierAtIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "identifierAtIndexed" ((PVar "index") (PVar "arr") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EBinOp "||" (EBinOp ">=" (EVar "pos") (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr"))))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "arr"))))))))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 0))) (EListLit) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EVar "occStart") (EVar "arr")) (EVar "len"))) (EApp (EApp (EVar "findAll") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "name")))) (EVar "src")))))))
(DTypeSig false "occStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "occStart" ((PVar "arr") (PVar "len") (PVar "m")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "start") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EFieldAccess (EVar "m") "start") (ELit (LInt 1)))) (EVar "arr"))))) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "end") (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EFieldAccess (EVar "m") "end")) (EVar "arr")))))) (EApp (EVar "Some") (EFieldAccess (EVar "m") "start")) (EVar "None")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EVar "occToHighlight") (EMethodRef "index")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "occToHighlight" ((PVar "index") (PVar "nlen") (PVar "off")) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "off")) (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EBinOp "+" (EVar "off") (EVar "nlen")))) (arm (PTuple (PCon "Some" (PTuple (PVar "sl") (PVar "sc"))) (PCon "Some" (PTuple (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))) (arm PWild () (EVar "None"))))
(DTypeSig true "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EApp (EVar "strictDocumentSymbols") (EVar "src")))
(DTypeSig false "declOwnNameMatches" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declOwnNameMatches" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PRec "DData" ((rf "dataName" (PVar "n"))) false) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DImpl" () true) () (EVar "False")) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "c"))) false) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "declChildNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declChildNames" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) () (EApp (EVar "dataChildNames") (EVar "vs"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "ms"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "ms"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))
(DTypeSig false "dataChildNames" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataChildNames" ((PList)) (EListLit))
(DFunDef false "dataChildNames" ((PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")) (EApp (EVar "dataChildNames") (EVar "vs"))))
(DFunDef false "dataChildNames" ((PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EVar "vn") (EApp (EVar "dataChildNames") (EVar "vs"))))
(DTypeSig false "anyName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyName" ((PList) PWild) (EVar "False"))
(DFunDef false "anyName" ((PCons (PVar "x") (PVar "xs")) (PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "anyName") (EVar "xs")) (EVar "name"))))
(DTypeSig false "indexOfName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOfName" ((PVar "name") (PVar "xs")) (EApp (EApp (EApp (EVar "indexOfNameGo") (EVar "name")) (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "indexOfNameGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "indexOfNameGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "indexOfNameGo" ((PVar "name") (PCons (PVar "x") (PVar "xs")) (PVar "i")) (EIf (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EVar "indexOfNameGo") (EVar "name")) (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "locAtIndex" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "locAtIndex" (PWild (PList)) (EVar "None"))
(DFunDef false "locAtIndex" ((PLit (LInt 0)) (PCons (PVar "l") PWild)) (EVar "l"))
(DFunDef false "locAtIndex" ((PVar "i") (PCons PWild (PVar "ls"))) (EApp (EApp (EVar "locAtIndex") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "ls")))
(DTypeSig false "definitionRangeParsed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "definitionRangeParsed" (PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "definitionRangeParsed" ((PVar "src") (PVar "name") (PCon "Some" (PTuple (PVar "decls") (PVar "positions")))) (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringLength") (EVar "src"))) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))
(DTypeSig false "defZip" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))))
(DFunDef false "defZip" ((PVar "index") (PVar "len") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "defZipDeclMatch") (EMethodRef "index")) (EVar "len")) (EVar "d")) (EVar "p")) (EVar "name")) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EVar "j"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EMethodRef "index")) (EVar "len")) (EVar "ds")) (EVar "ps")) (EVar "name")))))
(DFunDef false "defZip" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "defZipDeclMatch" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))))
(DFunDef false "defZipDeclMatch" ((PVar "index") (PVar "len") (PVar "d") (PVar "p") (PVar "name")) (EIf (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "defZipLocOr") (EMethodRef "index")) (EVar "len")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EVar "p"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EVar "defZipLocOr") (EMethodRef "index")) (EVar "len")) (EApp (EApp (EVar "locAtIndex") (EVar "k")) (EApp (EVar "declPosChildLocs") (EVar "p")))) (EVar "p")))) (EApp (EApp (EVar "indexOfName") (EVar "name")) (EApp (EVar "declChildNames") (EVar "d")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "defZipLocOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclPos") (TyCon "Json"))))))
(DFunDef false "defZipLocOr" ((PVar "index") PWild (PCon "Some" (PVar "l")) PWild) (EApp (EApp (EVar "jRangeOfLoc") (EMethodRef "index")) (EVar "l")))
(DFunDef false "defZipLocOr" ((PVar "index") (PVar "len") (PCon "None") (PVar "p")) (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EMethodRef "index")) (EVar "len")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (EApp (EVar "declPosEndLine") (EVar "p"))))
(DTypeSig false "docEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "HoverEnv"))))))
(DFunDef false "docEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoLet false false (PVar "report") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneReportK") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (ETuple (ELit (LString "__user__")) (EVar "userDecls")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "reportEnv") (EVar "report"))))))))))
(DTypeSig false "reportEnv" (TyFun (TyCon "TcReport") (TyCon "HoverEnv")))
(DFunDef false "reportEnv" ((PVar "report")) (EBlock (DoLet false false (PTuple (PVar "preludeSchemes") (PVar "ownSchemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (EApp (EApp (EVar "hoverEnvOf") (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (EFieldAccess (EVar "report") "trPartial")))))
(DTypeSig false "docEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "HoverEnv"))))))))
(DFunDef false "docEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EMatch (EApp (EApp (EVar "docsKept") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PCon "KeptOne" (PVar "keptSrc") (PVar "env"))) () (EIf (EBinOp "==" (EVar "keptSrc") (EVar "src")) (EApp (EVar "Some") (EVar "env")) (EApp (EApp (EApp (EVar "docEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))) (arm PWild () (EApp (EApp (EApp (EVar "docEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))
(DData Private "HoverEnv" () ((variant "HoverEnv" (ConNamed (field "heSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "heLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "heSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DTypeSig false "hoverEnvOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "PartialAnalysis") (TyCon "HoverEnv"))))
(DFunDef false "hoverEnvOf" ((PVar "schemes") (PVar "pa")) (ERecordCreate "HoverEnv" ((fa "heSchemes" (EVar "schemes")) (fa "heLocals" (EFieldAccess (EVar "pa") "paLocals")) (fa "heSeed" (EFieldAccess (EVar "pa") "paSeed")))))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAt") (EVar "name")) (EVar "src")) (EVar "line")) (EVar "col")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "hit")) () (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "ppHoverScheme") (EVar "hit")))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig true "typeAtPoint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typeAtPoint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPoints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filePath")) (EVar "src")) (EVar "line")) (EListLit (EVar "col"))) (arm (PList (PVar "answer")) () (EVar "answer")) (arm PWild () (EVar "None"))))
(DTypeSig true "typeAtPoints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "typeAtPoints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "cols")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeAtPointsWithIndex") (EApp (EVar "indexSource") (EVar "src"))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filePath")) (EVar "src")) (EVar "line")) (EVar "cols")))
(DTypeSig true "typeAtPointsWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))))))))
(DFunDef false "typeAtPointsWithIndex" ((PVar "index") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "cols")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "positions") (EApp (EApp (EMethodRef "map") (ELam ((PVar "col")) (EApp (EApp (EVar "sourceCursorIndexed") (EMethodRef "index")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col")))))))) (EVar "cols"))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pos")) (EApp (EApp (EMethodRef "andThen") (EVar "pos")) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ln") (PVar "col")) () (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EMethodRef "index")) (EVar "chars")) (EVar "ln")) (EVar "col")))))))) (EVar "positions"))) (DoExpr (EIf (EApp (EApp (EVar "allList") (EVar "isNone")) (EVar "names")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EVar "cols")) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "filePath"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EVar "cols"))) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "parsed") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "parseWithPositionsOpt") (EVar "src")))) (DoExpr (EApp (EApp (EApp (EVar "zipWith") (EApp (EApp (EVar "typeAtPosition") (EVar "parsed")) (EVar "env"))) (EVar "names")) (EVar "positions"))))))))))))
(DTypeSig false "typeAtPosition" (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyCon "HoverEnv") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "typeAtPosition" (PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "typeAtPosition" (PWild PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "typeAtPosition" ((PVar "parsed") (PVar "env") (PCon "Some" (PVar "name")) (PCon "Some" (PTuple (PVar "line") (PVar "col")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "hit")) (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " : ")) (EApp (EVar "ppHoverScheme") (EVar "hit")))))) (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAtParsed") (EVar "name")) (EVar "parsed")) (EVar "line")) (EVar "col")) (EVar "env"))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "HoverEnv")))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "docEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "HoverEnv")))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "pa")) (EApp (EApp (EVar "hoverEnvOf") (EApp (EVar "publishedEntrySchemes") (EFieldAccess (EVar "pa") "paSchemes"))) (EVar "pa")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysisOr") (EApp (EApp (EApp (EVar "keptGraph") (EVar "uri")) (EVar "src")) (EVar "docs"))) (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))))))
(DTypeSig false "keptGraph" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyFun (TyCon "GraphId") (TyApp (TyCon "Option") (TyCon "PartialAnalysis")))))))
(DFunDef false "keptGraph" ((PVar "uri") (PVar "src") (PVar "docs") (PVar "current")) (EMatch (EApp (EApp (EVar "docsKept") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PCon "KeptGraph" (PVar "keptSrc") (PVar "keptId") (PVar "pa"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "keptSrc") (EVar "src")) (EApp (EApp (EVar "graphIdSame") (EVar "keptId")) (EVar "current"))) (EApp (EVar "Some") (EVar "pa")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DData Private "HoverHit" () ((variant "EnvHit" (ConPos (TyCon "PubScheme"))) (variant "LocalHit" (ConPos (TyCon "PubScheme"))) (variant "SeedHit" (ConPos (TyCon "PubScheme")))) ())
(DTypeSig false "localSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "localSchemes" () (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "s") PWild)) (ETuple (EVar "n") (EVar "s")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EFieldAccess (EVar "env") "heSchemes")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Some") (EApp (EVar "EnvHit") (EVar "p")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "localSchemes") (EFieldAccess (EVar "env") "heLocals"))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EVar "LocalHit") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (EVar "SeedHit")) (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EFieldAccess (EVar "env") "heSeed"))))))))
(DTypeSig false "hoverSchemeAt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit"))))))))
(DFunDef false "hoverSchemeAt" ((PVar "name") (PVar "src") (PVar "line") (PVar "col") (PVar "env")) (EApp (EApp (EApp (EApp (EApp (EVar "hoverSchemeAtParsed") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "parseWithPositionsOpt") (EVar "src")))) (EVar "line")) (EVar "col")) (EVar "env")))
(DTypeSig false "hoverSchemeAtParsed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HoverEnv") (TyApp (TyCon "Option") (TyCon "HoverHit"))))))))
(DFunDef false "hoverSchemeAtParsed" ((PVar "name") (PVar "parsed") (PVar "line") (PVar "col") (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "localSchemeAt") (EVar "name")) (EVar "line")) (EVar "col")) (EVar "parsed")) (EFieldAccess (EVar "env") "heLocals")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EVar "LocalHit") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")))))
(DTypeSig false "localSchemeAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Positions")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "Option") (TyCon "PubScheme"))))))))
(DFunDef false "localSchemeAt" (PWild PWild PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "localSchemeAt" ((PVar "name") (PVar "line") (PVar "col") (PCon "Some" (PVar "pos")) (PVar "locals")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "positionsDecls") (EVar "pos"))) (DoLet false false (PVar "cl") (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "declIndexAt") (EVar "decls")) (ELit (LInt 0))) (EVar "cl")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "di")) () (EApp (EApp (EVar "latestLocal") (EVar "None")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "col")) (EVar "di")) (EVar "decls")) (EVar "locals"))))))))
(DTypeSig false "declIndexAt" (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declIndexAt" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "declIndexAt" ((PCons (PVar "p") (PVar "rest")) (PVar "i") (PVar "l")) (EIf (EBinOp "&&" (EBinOp "<=" (EApp (EVar "declPosLine") (EVar "p")) (EVar "l")) (EBinOp "<=" (EVar "l") (EApp (EVar "declPosEndLine") (EVar "p")))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "declIndexAt") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declIndexIs" (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "declIndexIs" ((PVar "decls") (PVar "l") (PVar "di")) (EMatch (EApp (EApp (EApp (EVar "declIndexAt") (EVar "decls")) (ELit (LInt 0))) (EVar "l")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "j")) () (EBinOp "==" (EVar "j") (EVar "di")))))
(DTypeSig false "locAtOrBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "locAtOrBefore" ((PVar "l1") (PVar "c1") (PVar "l2") (PVar "c2")) (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))))
(DTypeSig false "localCandidates" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))))))))))
(DFunDef false "localCandidates" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "localCandidates" ((PVar "name") (PVar "cl") (PVar "cc") (PVar "di") (PVar "decls") (PCons (PTuple (PVar "n") (PVar "sch") (PCon "Some" (PCon "Loc" PWild (PVar "bl") (PVar "bc") PWild PWild))) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "locAtOrBefore") (EVar "bl")) (EVar "bc")) (EVar "cl")) (EVar "cc"))) (EApp (EApp (EApp (EVar "declIndexIs") (EVar "decls")) (EVar "bl")) (EVar "di"))) (EBinOp "::" (ETuple (EVar "bl") (EVar "bc") (EVar "sch")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "cc")) (EVar "di")) (EVar "decls")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "localCandidates" ((PVar "name") (PVar "cl") (PVar "cc") (PVar "di") (PVar "decls") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localCandidates") (EVar "name")) (EVar "cl")) (EVar "cc")) (EVar "di")) (EVar "decls")) (EVar "rest")))
(DTypeSig false "latestLocal" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PubScheme"))) (TyApp (TyCon "Option") (TyCon "PubScheme")))))
(DFunDef false "latestLocal" ((PCon "None") (PList)) (EVar "None"))
(DFunDef false "latestLocal" ((PCon "Some" (PTuple PWild PWild (PVar "s"))) (PList)) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "latestLocal" ((PCon "None") (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (EVar "c"))) (EVar "rest")))
(DFunDef false "latestLocal" ((PCon "Some" (PTuple (PVar "pl") (PVar "pc") (PVar "ps"))) (PCons (PTuple (PVar "bl") (PVar "bc") (PVar "bs")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EApp (EVar "locAtOrBefore") (EVar "pl")) (EVar "pc")) (EVar "bl")) (EVar "bc")) (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (ETuple (EVar "bl") (EVar "bc") (EVar "bs")))) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EVar "latestLocal") (EApp (EVar "Some") (ETuple (EVar "pl") (EVar "pc") (EVar "ps")))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ppHoverScheme" (TyFun (TyCon "HoverHit") (TyCon "String")))
(DFunDef false "ppHoverScheme" ((PCon "EnvHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DFunDef false "ppHoverScheme" ((PCon "LocalHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DFunDef false "ppHoverScheme" ((PCon "SeedHit" (PVar "p"))) (EApp (EVar "ppPubScheme") (EVar "p")))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EApp (EVar "indexSource") (EVar "src"))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "hit")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EVar "ppHoverScheme") (EVar "hit"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "env")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "tagTier") (EVar "EnvHit")) (EFieldAccess (EVar "env") "heSchemes")) (EApp (EApp (EVar "tagTier") (EVar "LocalHit")) (EApp (EVar "localSchemes") (EFieldAccess (EVar "env") "heLocals")))) (EApp (EApp (EVar "tagTier") (EVar "SeedHit")) (EFieldAccess (EVar "env") "heSeed"))))) (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (ELam ((PVar "env")) (EApp (EApp (EVar "tagTier") (EVar "EnvHit")) (EFieldAccess (EVar "env") "heSchemes")))) (EApp (EApp (EApp (EApp (EApp (EVar "docEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tagTier" (TyFun (TyFun (TyVar "s") (TyCon "HoverHit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "s"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HoverHit"))))))
(DFunDef false "tagTier" ((PVar "tag")) (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "tag") (EApp (EVar "snd") (EVar "b")))))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild PWild PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "columnAfterName" ((PVar "index") (PVar "arr") (PVar "line")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0)))) (ELam ((PVar "lineStart")) (ELet false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol")))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EApp (EVar "indexSource") (EVar "src"))) (EApp (EVar "stringToChars") (EVar "src"))) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EFieldAccess (EVar "env") "heSchemes")))))))
(DTypeSig false "inlayNamePos" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "inlayNamePos" ((PVar "index") (PVar "arr") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec"))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "off")) (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "off"))))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "col")) (ETuple (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EApp (EVar "columnAfterName") (EMethodRef "index")) (EVar "arr")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "inlayZip" ((PVar "index") (PVar "arr") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EMethodRef "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EMethodRef "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EMethodRef "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EApp (EVar "inlayNamePos") (EMethodRef "index")) (EVar "arr")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EMethodRef "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EVar "line")) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EVar "ppPubScheme") (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EMethodRef "index")) (EVar "arr")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "sourceCursor" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "sourceCursor" ((PVar "src") (PVar "params")) (EApp (EApp (EVar "sourceCursorIndexed") (EApp (EVar "indexSource") (EVar "src"))) (EVar "params")))
(DTypeSig false "sourceCursorIndexed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "sourceCursorIndexed" ((PVar "index") (PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "get") (ELit (LString "position"))) (EVar "params"))) (ELam ((PVar "pos")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "lspPositionToOffset") (EMethodRef "index")) (EVar "pos"))) (ELam ((PVar "off")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "line") (PVar "col"))) (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EVar "offsetToSourcePosition") (EMethodRef "index")) (EVar "off"))))))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig true "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "contentLengthRe" (TyCon "Regex"))
(DFunDef false "contentLengthRe" () (EApp (EVar "mustCompile") (ELit (LString "^Content-Length: *([0-9]+)"))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EMatch (EApp (EApp (EDictApp "find") (EVar "contentLengthRe")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PList (PCon "Some" (PVar "g"))) () (EApp (EVar "toInt") (EFieldAccess (EVar "g") "text"))) (arm PWild () (EVar "None"))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
(DData Private "SemCtx" () ((variant "SemCtx" (ConPos (TyCon "Int") (TyCon "Bool") (TyCon "SMode")))) ())
(DTypeSig false "isKeywordTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isKeywordTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRec")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWith")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMut")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TData")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TInterface")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDo")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TAs")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExtern")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDeriving")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TType")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TNewtype")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TProp")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TTest")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TBench")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TEffect")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TFunction")) (EVar "True"))
(DFunDef false "isKeywordTok" (PWild) (EVar "False"))
(DTypeSig false "upperRole" (TyFun (TyCon "SMode") (TyCon "Int")))
(DFunDef false "upperRole" ((PCon "MExpr")) (ELit (LInt 2)))
(DFunDef false "upperRole" ((PCon "MDataVariant")) (ELit (LInt 2)))
(DFunDef false "upperRole" (PWild) (ELit (LInt 1)))
(DTypeSig false "roleOf" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "SMode") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceOne")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceMany")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PVar "mode")) (EApp (EVar "Some") (EApp (EVar "upperRole") (EVar "mode"))))
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") PWild) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EVar "None")))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TWideInt" PWild PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataVariant")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataPayload")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MDataVariant")) (EVar "MDataPayload"))
(DFunDef false "nextMode" (PWild (PVar "mode")) (EVar "mode"))
(DData Public "SemTok" () ((variant "SemTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "classify" (TyFun (TyCon "Token") (TyFun (TyCon "SemCtx") (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SemCtx")))))
(DFunDef false "classify" ((PCon "TIndent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TDedent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TNewline") (PCon "SemCtx" (PVar "depth") PWild (PVar "mode"))) (EBlock (DoLet false false (PVar "mode2") (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "MExpr") (EVar "mode"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "True")) (EVar "mode2"))))))
(DFunDef false "classify" ((PVar "tok") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EApp (EApp (EApp (EApp (EVar "roleOf") (EVar "tok")) (EVar "depth")) (EVar "ls")) (EVar "mode")) (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "False")) (EApp (EApp (EVar "nextMode") (EVar "tok")) (EVar "mode")))))
(DTypeSig false "semToksOf" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SemTok"))))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EApp (EVar "Err") (ELit (LString "semantic token spans ended before the token stream"))))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "offsetToUtf16Position") (EVar "arr")) (EVar "e"))) (arm (PTuple (PCon "Some" (PTuple (PVar "sl") (PVar "sc"))) (PCon "Some" (PTuple (PVar "el") (PVar "ec")))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "semantic token endpoint is not a source boundary")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "semanticTokensPrepared" (TyFun (TyCon "PreparedSyntax") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "semanticTokensPrepared" ((PVar "prepared")) (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "syntax unavailable")))) (arm (PCon "Some" (PVar "syntax")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (ELam ((PCon "SourceSpan" (PVar "a") (PVar "b"))) (ETuple (EVar "a") (EVar "b")))) (EApp (EMethodRef "toList") (EApp (EVar "syntaxTokenSpans") (EVar "syntax"))))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EApp (EVar "syntaxIndex") (EVar "syntax"))) (EApp (EMethodRef "toList") (EApp (EVar "syntaxTokens") (EVar "syntax")))) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResultFor" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "initializeResultFor" ((PVar "serverVersion")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "codeActionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "referencesProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (EVar "serverVersion")))))))))
(DTypeSig false "parseErrorDiags" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "parseErrorDiags" ((PVar "snapshot") (PVar "src") (PVar "e")) (EBlock (DoLet false false (PVar "diagnostic") (EApp (EVar "parseErrorDiagnostic") (EVar "e"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "parseDiagnosticJson") (EVar "snapshot")) (EApp (EVar "wholeDocRange") (EVar "src"))) (EApp (EApp (EVar "parseDiagnosticToDiag") (ELit (LString ""))) (EVar "diagnostic"))) (EVar "diagnostic"))))))
(DTypeSig false "publishDiagnosticsList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "publishDiagnosticsList" ((PVar "uri") (PVar "diags")) (EBlock (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "publishDiagnosticsFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "TcReport")))))))))
(DFunDef false "publishDiagnosticsFrom" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "front") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EApp (EVar "stdlibExportsReader") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib"))))) (ELit (LString ""))) (EVar "True")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "decls"))) (DoLet false false (PVar "diags") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false PWild (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EApp (EApp (EVar "diagsToJson") (EVar "src")) (EVar "diags")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam (PWild) (EFieldAccess (EVar "front") "foReport"))) (EFieldAccess (EVar "front") "foDriven")))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "retainOpenProjectSources" (TyFun (TyCon "Docs") (TyCon "Unit")))
(DFunDef false "retainOpenProjectSources" ((PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "openPaths") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "uri") PWild)) (EApp (EVar "pathOfUri") (EVar "uri")))) (EVar "xs"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EApp (EApp (EMethodRef "filter") (ELam ((PTuple (PVar "path") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "path")) (EVar "openPaths")))) (EUnOp "!" (EVar "projectCache")))))))
(DTypeSig false "clearSessionSourceOwners" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "clearSessionSourceOwners" ((PLit LUnit)) (EBlock (DoExpr (EApp (EVar "clearLoadedSourceRecords") (ELit LUnit))) (DoExpr (EApp (EVar "clearProjectPassEntries") (ELit LUnit)))))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig true "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "bufferHasImports" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bufferHasImports" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "decls")) () (EApp (EVar "anyImport") (EVar "decls")))))
(DTypeSig false "anyImport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyImport" ((PList)) (EVar "False"))
(DFunDef false "anyImport" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCoreImport") (EVar "path"))) (EApp (EVar "anyImport") (EVar "rest"))))
(DFunDef false "anyImport" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyImport") (EVar "rest")))
(DTypeSig false "isCoreImport" (TyFun (TyCon "UsePath") (TyCon "Bool")))
(DFunDef false "isCoreImport" ((PVar "p")) (EBinOp "==" (EApp (EVar "useHead") (EVar "p")) (ELit (LString "core"))))
(DTypeSig false "useHead" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useHead" ((PCon "UseName" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseWild" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DTypeSig false "headOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "headOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "headOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Kept")))))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PTuple (PVar "keyed") (PVar "results") (PVar "sources")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectKeyedSources") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (EVar "True")) (EListLit)) (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "sources")) (EVar "results"))) (DoExpr (EMatch (EVar "keyed") (arm (PCon "Some" (PTuple (PTuple (PVar "report") PWild) (PVar "graph"))) () (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "report") "trPartial") "paModule") (EFieldAccess (EVar "graph") "giEntry")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "KeptGraph") (EVar "text")) (EVar "graph")) (EFieldAccess (EVar "report") "trPartial"))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "hasParseDiagnosticFix" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "hasParseDiagnosticFix" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild (PCon "Some" PWild))) (EApp (EVar "diagIdIsSyntax") (EVar "code")))
(DFunDef false "hasParseDiagnosticFix" (PWild) (EVar "False"))
(DTypeSig false "publishEach" (TyFun (TyCon "Docs") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "publishEach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PVar "docs") (PVar "sources") (PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "src") (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "Some") (EVar "text"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "file")) (EVar "sources")) (arm (PCon "Some" (PVar "text")) () (EApp (EVar "Some") (EVar "text"))) (arm (PCon "None") () (EApp (EApp (EVar "sourceForPath") (EVar "docs")) (EVar "file"))))))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EMatch (EVar "src") (arm (PCon "Some" (PVar "text")) () (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "any") (EVar "hasParseDiagnosticFix")) (EVar "ds"))) (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds")) (EMatch (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "snapshot")) () (EMatch (EApp (EVar "parseLocatedResult") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EVar "parseDiagnosticJson") (EVar "snapshot")) (EApp (EVar "wholeDocRange") (EVar "text"))) (EVar "d")) (EApp (EVar "parseErrorDiagnostic") (EVar "e"))))) (EVar "ds"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds"))))) (arm (PCon "None") () (EApp (EApp (EVar "diagsToJson") (EVar "text")) (EVar "ds")))))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (EApp (EVar "diagnosticWithRange") (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))) (EVar "ds"))))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "sources")) (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EVar "selectProjectProfileFor") (EApp (EVar "pathOfUri") (EVar "uri"))) (EVar "docs"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EApp (EApp (EVar "publishForSelected") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EApp (EApp (EApp (EVar "docsKeep") (EVar "uri")) (EVar "kept")) (EVar "docs2")))))
(DTypeSig false "selectProjectProfileFor" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))
(DFunDef false "selectProjectProfileFor" ((PVar "file") (PVar "docs")) (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "None")) (EVar "file")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "clearFlaggedManifest") (EVar "file")) (EVar "docs"))) (arm (PCon "Err" (PVar "msg")) () (EMatch (EApp (EVar "manifestPathOf") (EVar "file")) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "omEmpty")) (EListLit (ETuple (EVar "path") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1)))))))))) (DoExpr (EApp (EApp (EVar "docsFlag") (EVar "path")) (EVar "docs")))))))))
(DTypeSig false "clearFlaggedManifest" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))
(DFunDef false "clearFlaggedManifest" ((PVar "file") (PVar "docs")) (EMatch (EApp (EVar "manifestPathOf") (EVar "file")) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "path")) () (EIf (EApp (EApp (EVar "docsFlagged") (EVar "path")) (EVar "docs")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "publishEach") (EVar "docs")) (EVar "omEmpty")) (EListLit (ETuple (EVar "path") (EListLit))))) (DoExpr (EApp (EApp (EVar "docsUnflag") (EVar "path")) (EVar "docs")))) (EVar "docs")))))
(DTypeSig false "docsFlagged" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Bool"))))
(DFunDef false "docsFlagged" ((PVar "path") (PCon "Docs" PWild (PVar "flagged") PWild PWild PWild PWild PWild)) (EApp (EApp (EVar "contains") (EVar "path")) (EVar "flagged")))
(DTypeSig false "docsFlag" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsFlag" ((PVar "path") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EIf (EApp (EApp (EVar "contains") (EVar "path")) (EVar "flagged")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EVar "flagged")) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EBinOp "::" (EVar "path") (EVar "flagged"))) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache"))))
(DTypeSig false "docsUnflag" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs"))))
(DFunDef false "docsUnflag" ((PVar "path") (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EVar "xs")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "path")))) (EVar "flagged"))) (EVar "kept")) (EVar "versions")) (EVar "generations")) (EVar "next")) (EVar "cache")))
(DTypeSig false "publishForSelected" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Kept")))))))))
(DFunDef false "publishForSelected" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EMatch (EApp (EApp (EVar "parseCachedLocated") (EVar "projectParseCache")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EMatch (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "snapshot")) () (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EApp (EApp (EApp (EVar "parseErrorDiags") (EVar "snapshot")) (EVar "text")) (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EVar "publishDiagnosticsList") (EVar "uri")) (EListLit))))) (DoExpr (EVar "None")))) (arm (PCon "Ok" (PVar "decls")) () (EIf (EApp (EVar "anyImport") (EVar "decls")) (EApp (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs")) (EBlock (DoExpr (EApp (EApp (EVar "retainParsed") (EVar "projectParseCache")) (EListLit (EVar "text")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "publishDiagnosticsFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "decls")) (arm (PCon "Some" (PVar "report")) () (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "report") "trPartial") "paModule") (ELit (LString "__user__"))) (EApp (EVar "Some") (EApp (EApp (EVar "KeptOne") (EVar "text")) (EApp (EVar "reportEnv") (EVar "report")))) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "version") (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "version"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))) (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsSetVersion") (EVar "uri")) (EVar "version")) (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2")))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "version") (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "version"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))) (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsSetVersion") (EVar "uri")) (EVar "version")) (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2")))))))))
(DTypeSig false "samePosition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "samePosition" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "a"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "b")))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "a"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "b"))))) (EBinOp "/=" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "line"))) (EVar "a"))) (EVar "None"))) (EBinOp "/=" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "character"))) (EVar "a"))) (EVar "None"))))
(DTypeSig false "sameRange" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))
(DFunDef false "sameRange" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "samePosition") (EApp (EApp (EVar "fieldOr") (ELit (LString "start"))) (EVar "a"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "start"))) (EVar "b"))) (EApp (EApp (EVar "samePosition") (EApp (EApp (EVar "fieldOr") (ELit (LString "end"))) (EVar "a"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "end"))) (EVar "b")))))
(DTypeSig false "actionDiagnosticMatches" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Bool"))))))
(DFunDef false "actionDiagnosticMatches" ((PVar "snapshot") (PVar "code") (PVar "range") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "expected") (EApp (EVar "snapshotJson") (EVar "snapshot"))) (DoLet false false (PVar "actual") (EApp (EApp (EVar "fieldOr") (ELit (LString "data"))) (EVar "diagnostic"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EVar "actual")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EVar "expected"))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "generation"))) (EVar "actual"))) (EApp (EVar "asInt") (EApp (EApp (EVar "fieldOr") (ELit (LString "generation"))) (EVar "expected"))))) (EBinOp "==" (EApp (EApp (EVar "fieldOr") (ELit (LString "code"))) (EVar "diagnostic")) (EApp (EVar "JString") (EVar "code")))) (EApp (EApp (EVar "sameRange") (EApp (EApp (EVar "fieldOr") (ELit (LString "range"))) (EVar "diagnostic"))) (EVar "range"))))))
(DTypeSig false "handleCodeAction" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleCodeAction" ((PVar "id") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "uri")) () (EMatch (ETuple (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsSnapshot") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "text")) (PCon "Some" (PVar "snapshot"))) () (EMatch (EApp (EVar "parseLocatedResult") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "pd") (EApp (EVar "parseErrorDiagnostic") (EVar "e"))) (DoLet false false (PVar "range") (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EApp (EVar "indexSource") (EVar "text"))) (EApp (EVar "diagnosticLoc") (EVar "pd"))))) (DoLet false false (PVar "context") (EApp (EApp (EVar "fieldOr") (ELit (LString "context"))) (EVar "params"))) (DoLet false false (PVar "diagnostics") (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EApp (EVar "fieldOr") (ELit (LString "diagnostics"))) (EVar "context")) (EVar "asArray")) (EApp (EMethodRef "map") (EMethodRef "toList"))) (EApp (EVar "optionOr") (EListLit)))) (DoExpr (EIf (EApp (EApp (EDictApp "any") (EApp (EApp (EApp (EVar "actionDiagnosticMatches") (EVar "snapshot")) (EApp (EVar "codeText") (EApp (EVar "diagnosticCode") (EVar "pd")))) (EVar "range"))) (EVar "diagnostics")) (EApp (EApp (EVar "parseDiagnosticActions") (EVar "snapshot")) (EListLit (EVar "pd"))) (EListLit))))) (arm (PCon "Ok" PWild) () (EListLit)))) (arm PWild () (EListLit)))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "id")) (EApp (EVar "jArray") (EVar "result")))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (ETuple (EApp (EApp (EVar "docsRevision") (EVar "uri")) (EVar "docs")) (EApp (EApp (EVar "docsPrepared") (EVar "uri")) (EVar "docs"))) (arm (PTuple (PCon "Some" (PVar "revision")) (PCon "Some" (PVar "prepared"))) () (EMatch (EApp (EApp (EVar "symbolsFromRecovered") (EVar "revision")) (EVar "prepared")) (arm (PCon "Err" PWild) () (EVar "JNull")) (arm (PCon "Ok" (PVar "symbols")) () (EApp (EVar "jArray") (EVar "symbols"))))) (arm PWild () (EVar "JNull")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "cursorIdentifier" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "cursorIdentifier" ((PVar "src") (PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sourceCursor") (EVar "src")) (EVar "params"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "line") (PVar "col")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col"))) (ELam ((PVar "name")) (EApp (EVar "Some") (ETuple (EVar "line") (EVar "col") (EVar "name"))))))))))
(DTypeSig false "projectRefIndexPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "RefIndex") (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "PreparedSyntax")))))))))
(DFunDef false "projectRefIndexPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "rootFile") (PVar "docs")) (EBlock (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "rootFile")))) (DoLet false false (PVar "rootUri") (EApp (EVar "uriOfPath") (EVar "rootFile"))) (DoLet false false (PTuple (PVar "initial") (PVar "rootPrepared")) (EApp (EApp (EVar "docsPrepareResult") (EVar "rootUri")) (EVar "docs"))) (DoLet false false (PVar "current") (EApp (EVar "Ref") (EVar "initial"))) (DoLet false false (PCon "Docs" PWild PWild PWild PWild PWild PWild (PVar "cache")) (EVar "docs")) (DoLet false false (PVar "budget") (EApp (EVar "Ref") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EApp (EVar "syntaxCacheEntryLimit") (EVar "cache"))) (EMatch (EApp (EApp (EVar "docsResident") (EVar "rootUri")) (EVar "docs")) (arm (PCon "None") () (ELit (LInt 1))) (arm (PCon "Some" PWild) () (ELit (LInt 0)))))))) (DoLet false false (PVar "root") (EApp (EVar "Ref") (EVar "rootPrepared"))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EUnOp "!" (EVar "current"))))) (DoLet false false (PVar "parse") (ELam ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EUnOp "!" (EVar "current"))) (arm (PCon "Some" (PVar "text")) ((GBool (EBinOp "==" (EVar "text") (EVar "src")))) (EBlock (DoLet false false (PVar "before") (EIf (EBinOp "==" (EVar "path") (EVar "rootFile")) (EUnOp "!" (EVar "root")) (EApp (EApp (EVar "docsResident") (EVar "uri")) (EUnOp "!" (EVar "current"))))) (DoLet false false (PVar "prepared") (EMatch (EVar "before") (arm (PCon "None") ((GBool (EBinOp ">" (EUnOp "!" (EVar "budget")) (ELit (LInt 0))))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "budget")) (EBinOp "-" (EUnOp "!" (EVar "budget")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "updated") (PVar "fresh")) (EApp (EApp (EVar "docsPrepareResult") (EVar "uri")) (EUnOp "!" (EVar "current")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "current")) (EVar "updated"))) (DoExpr (EVar "fresh")))) (arm PWild () (EVar "before")))) (DoExpr (EMatch (EVar "prepared") (arm (PCon "Some" (PVar "value")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "value")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lsp.project.parsed_hit")))) (DoExpr (EApp (EVar "structuralParsed") (EVar "value"))))) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))))) (arm PWild () (EApp (EVar "parseWithPositionsOpt") (EVar "src")))))))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EApp (EVar "buildRefIndexProjectWithParsed") (EVar "read")) (EVar "parse")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (ETuple (EVar "idx") (EUnOp "!" (EVar "current")) (EUnOp "!" (EVar "root"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "handleDefinition" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "updated")) (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDefinitionPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result")))) (DoExpr (EVar "updated"))))
(DTypeSig false "projectDefinitionPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "Json") (TyCon "Docs"))))))))))
(DFunDef false "projectDefinitionPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col") PWild)) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PTuple (PVar "idx") (PVar "updated") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "projectRefIndexPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rootFile")) (EVar "docs"))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "definitionResultParsed") (EVar "uri")) (EVar "src")) (EVar "params")) (EMatch (EVar "root") (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))) (arm (PCon "Some" (PVar "prepared")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "None") () (EApp (EVar "parseWithPositionsOpt") (EVar "src"))) (arm (PCon "Some" PWild) () (EApp (EVar "structuralParsed") (EVar "prepared")))))))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EVar "locationsJson") (EVar "updated")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")))))))) (DoExpr (ETuple (EVar "result") (EVar "updated")))))))
(DTypeSig true "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EApp (EApp (EApp (EApp (EVar "definitionResultParsed") (EVar "uri")) (EVar "src")) (EVar "params")) (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))
(DTypeSig true "definitionResultParsed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyCon "Json"))))))
(DFunDef false "definitionResultParsed" ((PVar "uri") (PVar "src") (PVar "params") (PVar "parsed")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple PWild PWild (PVar "name"))) () (EMatch (EApp (EApp (EApp (EVar "definitionRangeParsed") (EVar "src")) (EVar "name")) (EVar "parsed")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig true "definitionResultsWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "definitionResultsWithIndex" ((PVar "index") (PVar "uri") (PVar "src") (PVar "line") (PVar "cols")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionResultsParsed") (EMethodRef "index")) (EVar "uri")) (EVar "src")) (EVar "line")) (EVar "cols")) (EApp (EVar "parseWithPositionsOpt") (EVar "src"))))
(DTypeSig true "definitionResultsParsed" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "definitionResultsParsed" ((PVar "index") (PVar "uri") (PVar "src") (PVar "line") (PVar "cols") (PVar "parsed")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "definitionIndexed") (EVar "uri")) (EApp (EVar "arrayLength") (EVar "chars"))) (EMethodRef "index")) (EVar "chars")) (EVar "parsed")) (EVar "line")) (EVar "col")))) (EVar "cols")))))
(DTypeSig false "definitionIndexed" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))))))
(DFunDef false "definitionIndexed" ((PVar "uri") (PVar "sourceLength") (PVar "index") (PVar "chars") (PVar "parsed") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "sourceCursorIndexed") (EMethodRef "index")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col")))))) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PTuple (PVar "ln") (PVar "cp"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "identifierAtIndexed") (EMethodRef "index")) (EVar "chars")) (EVar "ln")) (EVar "cp")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EVar "parsed") (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "defZip") (EMethodRef "index")) (EVar "sourceLength")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range")))))))))))))))
(DTypeSig false "handleReferences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs"))))))))
(DFunDef false "handleReferences" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "updated")) (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (ETuple (EVar "JNull") (EVar "docs"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResultPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result")))) (DoExpr (EVar "updated"))))
(DTypeSig true "referencesResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "referencesResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PTuple (PVar "result") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResultPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))) (DoExpr (EVar "result"))))
(DTypeSig false "referencesResultPrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyTuple (TyCon "Json") (TyCon "Docs"))))))))))
(DFunDef false "referencesResultPrepared" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "None") () (ETuple (EApp (EVar "jArray") (EListLit)) (EVar "docs"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col") PWild)) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PTuple (PVar "idx") (PVar "updated") PWild) (EApp (EApp (EApp (EApp (EVar "projectRefIndexPrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rootFile")) (EVar "docs"))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EApp (EVar "referenceLocations") (EVar "updated")) (EVar "idx")) (EVar "key")) (EApp (EVar "includeDeclarationOf") (EVar "params"))))))) (DoExpr (ETuple (EVar "result") (EVar "updated")))))))
(DTypeSig false "referenceLocations" (TyFun (TyCon "Docs") (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "referenceLocations" ((PVar "docs") (PVar "idx") (PVar "key") (PVar "includeDecl")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))) (DoLet false false (PVar "all") (EIf (EVar "includeDecl") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (EVar "uses")) (EVar "uses"))) (DoExpr (EApp (EApp (EVar "locationsJson") (EVar "docs")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EDictApp "all"))))))
(DTypeSig false "compareUseLoc" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Ordering"))))
(DFunDef false "compareUseLoc" ((PTuple (PVar "p1") (PCon "Loc" PWild (PVar "sl1") (PVar "sc1") PWild PWild)) (PTuple (PVar "p2") (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") PWild PWild))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "p1")) (EVar "p2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "sl1")) (EVar "sl2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "sc1")) (EVar "sc2")))))))
(DTypeSig false "sourceForPath" (TyFun (TyCon "Docs") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "sourceForPath" ((PVar "docs") (PVar "path")) (EMatch (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "Some") (EVar "src"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EApp (EVar "Some") (EVar "src"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "locationsJson" (TyFun (TyCon "Docs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "locationsJson" (PWild (PList)) (EListLit))
(DFunDef false "locationsJson" ((PVar "docs") (PCons (PTuple (PVar "path") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "index") (EApp (EApp (EMethodRef "map") (EVar "indexSource")) (EApp (EApp (EVar "sourceForPath") (EVar "docs")) (EVar "path")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "locationsForPath") (EVar "docs")) (EVar "path")) (EMethodRef "index")) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EVar "rest"))))))
(DTypeSig false "locationsForPath" (TyFun (TyCon "Docs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "locationsForPath" ((PVar "docs") (PVar "path") (PVar "index") (PVar "rows")) (ELetGroup ((lgb "go" (clause ((PList)) (EListLit)) (clause ((PCons (PTuple (PVar "next") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "/=" (EVar "next") (EVar "path")) (EApp (EApp (EVar "locationsJson") (EVar "docs")) (EBinOp "::" (ETuple (EVar "next") (EVar "loc")) (EVar "rest"))) (EBlock (DoLet false false (PVar "tail") (EApp (EVar "go") (EVar "rest"))) (DoExpr (EMatch (EMethodRef "index") (arm (PCon "None") () (EVar "tail")) (arm (PCon "Some" (PVar "idx")) () (EMatch (EApp (EApp (EVar "locToLspRange") (EVar "idx")) (EVar "loc")) (arm (PCon "None") () (EVar "tail")) (arm (PCon "Some" (PVar "range")) () (EBinOp "::" (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "range")) (EVar "range")))) (EVar "tail")))))))))))) (EApp (EVar "go") (EVar "rows"))))
(DTypeSig false "includeDeclarationOf" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "includeDeclarationOf" ((PVar "params")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "context"))) (EVar "params")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "ctx")) () (EMatch (EApp (EApp (EVar "get") (ELit (LString "includeDeclaration"))) (EVar "ctx")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "True"))))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (EApp (EApp (EVar "cursorIdentifier") (EVar "src")) (EVar "params")) (arm (PCon "Some" (PTuple PWild PWild (PVar "name"))) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "JNull"))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "JNull"))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "tokens")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (EVar "tokens")))))))) (EMatch (EApp (EApp (EVar "docsPrepared") (EVar "uri")) (EVar "docs")) (arm (PCon "Some" (PVar "prepared")) () (EMatch (EApp (EVar "snapshotSyntaxSource") (EVar "prepared")) (arm (PCon "Some" PWild) () (EApp (EVar "semanticTokensPrepared") (EVar "prepared"))) (arm (PCon "None") () (EApp (EVar "semanticTokensData") (EVar "src"))))) (arm (PCon "None") () (EApp (EVar "semanticTokensData") (EVar "src")))))))))) (DoExpr (EMatch (EVar "result") (arm (PCon "Ok" (PVar "value")) () (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "value")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "writeMessage") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EUnOp "-" (ELit (LInt 32603))))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message"))))))))))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig true "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig true "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig true "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EVar "initializeResultFor") (EVar "serverVersion"))))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didClose"))) (EBlock (DoLet false false (PVar "uri") (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))))) (DoLet false false (PVar "docs2") (EMatch (ETuple (EVar "uri") (EVar "docs")) (arm (PTuple (PCon "Some" (PVar "u")) (PCon "Docs" (PVar "xs") (PVar "flagged") (PVar "kept") (PVar "versions") (PVar "generations") (PVar "next") (PVar "cache"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Docs") (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "xs"))) (EVar "flagged")) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "kept"))) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "versions"))) (EApp (EApp (EVar "docsRemove") (EVar "u")) (EVar "generations"))) (EVar "next")) (EApp (EApp (EVar "invalidateSyntax") (EVar "u")) (EVar "cache")))) (arm PWild () (EVar "docs")))) (DoLet false false PWild (EMatch (EVar "docs2") (arm (PCon "Docs" (PVar "xs") PWild PWild PWild PWild PWild PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainParsed") (EVar "projectParseCache")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "xs")))) (DoLet false false PWild (EApp (EVar "retainOpenProjectSources") (EVar "docs2"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "xs")) (EApp (EVar "clearSessionSourceOwners") (ELit LUnit)) (ELit LUnit))))))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/codeAction"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleCodeAction") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false (PVar "docs2") (EMatch (EApp (EVar "requestUri") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (arm (PCon "Some" (PVar "uri")) () (EApp (EApp (EVar "docsPrepare") (EVar "uri")) (EVar "docs"))) (arm (PCon "None") () (EVar "docs")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs2"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EApp (EVar "handleDefinition") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/references"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EApp (EVar "handleReferences") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false (PVar "docs2") (EMatch (EApp (EVar "requestUri") (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (arm (PCon "Some" (PVar "uri")) () (EApp (EApp (EVar "docsPrepare") (EVar "uri")) (EVar "docs"))) (arm (PCon "None") () (EVar "docs")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs2"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion") (PVar "docs")) (EMatch (EApp (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "serverVersion")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectParseCache")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "serverVersion")) (EVar "emptyDocs"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectCache")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "projectParseCache")) (EVar "omEmpty"))) (DoExpr (EApp (EVar "clearSessionSourceOwners") (ELit LUnit)))))
(DTypeSig true "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
