# META
source_lines=3478
stages=DESUGAR,MARK
# SOURCE
import support.diag_codes.{DiagCode(..)}
import driver.parse_diag_adapter.{parseDiagnosticToDiag}
import driver.main_autoprint.{executedMainInputs}
import support.source_index.{
  indexSource, sourcePositionToOffset, offsetToUtf16Position
}
import types.capability_manifest.{EntryKey(..)}
-- compiler/driver/diagnostics.mdk — structured error pipeline (Phase A.4)
--
-- Runs all pipeline stages accumulating diagnostics
-- WITHOUT exit-on-first-error, returning a structured List Diag.
--
-- B.10.2b: the compiler AST carries expr-level spans via the transparent
-- `ELoc` wrapper, and typecheck pairs each error with the span of the innermost
-- enclosing construct at the push site (`checkProgramDiags` returns `(msg, Option Loc)`).  So
-- `Diag` carries an `Option Loc` — `Some` for type errors (expr-level span),
-- `None` for resolve / guard / match-exhaustiveness diagnostics, which the
-- compiler pipeline does not yet attribute to a span (they fall back to the
-- whole-document range in the LSP).
--
-- Output format for the diff gate (diagdump --analyze):
--   "error: <message>"   or   "warning: <message>"
-- one per line, sorted by the harness.

import frontend.ast.{
  Decl(..), Expr(..), Loc(..), Pat, Ty, UsePath(..), UseMember(..),
  useMemberLocal
}
import frontend.parser.{
  parse,
  parseLocated,
  parseResult,
  ParseError,
  parseErrorDiagnostic,
}
import frontend.desugar_cache.{desugaredPrelude, preludeGeneration}
import frontend.desugar.{desugar, checkDerives}
import frontend.resolve.{
  ResError,
  resolveProgram,
  resolveProgramG2,
  internalGuardFor,
  ppResError,
  resErrorLoc,
  resErrorCode,
  resErrorDidYouMean,
  resErrorIsPrivateName,
  resolveModuleG,
  resolveModulesErrorsByFile,
  importedCtorDeclsStep,
  withStdlibExports,
  hintableUnboundNames,
  exportedValueNames,
}
import frontend.visibility.{ModuleExports, coreExports, useModuleIds}
import list.{drop, last}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omHasKey,
  omLookup,
  omFromPairs,
  omKeys,
  omSize,
  omRestrict,
}
import frontend.exhaust.{checkGuardExhaustivenessWith}
import frontend.marker.{
  preludeStandaloneShadows,
  preludeStandaloneSet,
  preludeStandaloneShadowsWith,
}
import types.repr.{Scheme}
import types.publish.{
  PubScheme(..), pubSchemes, TcReport(..), PartialAnalysis(..), partialAnalysis,
  noEntryTables, publishedEntrySchemes
}
import types.typecheck.{
  TcDiag(..),
  chainFullKey,
  checkModulesChainReportFor,
  checkModulesEntryFullReportK,
  checkModulesPartialK,
  driveInputsFor,
  dropModSchemes,
  entrySplit,
  ModDiags,
  schemeLines,
  tcMsg,
}
import types.tc_types.{DriveInputs(..), DriveOutputs(..), emptyDriveOutputs}
import types.target_profile.{selectedProfile}
import types.module_interface.{retainModuleInterfaces}
-- #2738: the two colliding signatures are SURFACE types, and this is the one
-- surface-type renderer in the tree (`tools/doc.mdk`'s `ppTyP` is private to the
-- doc generator).  Imported here, at the driver, rather than into
-- `types/typecheck.mdk`, so the detector's home layer gains no edge to `tools/`.
import tools.printer.{ppTy}
import driver.loader.{
  LoadError(..),
  loadProgramFilesLocatedCached,
  loadProgramFilesLocatedCachedE,
  loadProgramFilesLocatedCachedSourcesE,
  loadedSourceOf,
  stdinEntry,
  parseCachedLocated,
  loadProgramFilesLocatedE,
  dropPathTriple,
  projectTrustedMods,
  stdlibOwnership,
  entrySearchRoots,
  findImportLoc,
  unknownModuleIdOf,
  availableModulesText,
  availableModulesHint,
  availableModuleIds,
  fileOfModuleId,
  modIdToPath,
}
import support.path.{dirOf}
import driver.main_autoprint.{valueMainCandidate}
import support.util.{
  joinNl,
  listLen,
  lookupAssoc,
  startsWith,
  anyList,
  allList,
  filterList,
  contains,
  joinDot,
  isSome,
  lenKey,
  reverseL,
}
import support.timer.{takePerfSink}
import support.stage_count.{stageExit}
import backend.wasm_symbols.{
  SymbolDefect,
  defectCode,
  defectMessage,
  defectOrigin,
}
import backend.llvm_symbols as LlvmSymbols
import support.symbol_origin.{SymbolOrigin, originPosition}
import json.{Json(..), jObject, stringify}
import types.tc_shadow.{importedStandaloneShadows, importedStandaloneShadowsIn}

-- ── types ──────────────────────────────────────────────────────────────────

export import driver.diagnostic_value.{
  Severity(..), Fix(..), Diag(..), DiagId(..), mkDiag, diagIdText, diagIdKind,
  diagIdIsSyntax
}

-- The edit for a did-you-mean at [loc].  A PrivateNameAccess carries the
-- statement's span when the dotted import form (`import m.name`) has no member
-- location, and an edit anchored there would overwrite the wrong text; it gets
-- a fix only when its span is exactly the misspelled name.
didYouMeanFix : ResError -> String -> String -> Loc -> Option Fix
didYouMeanFix e bad sug (Loc f sl sc el ec) =
  if resErrorIsPrivateName e
    && not (el == sl && ec == sc + stringLength bad) then
    None
  else
    Some (Fix (Loc f sl sc sl (sc + stringLength bad)) sug)

-- Build the (help, fix) pair for a resolve error's structured suggestion.  Only
-- did-you-mean yields both today: `help` is prose; `fix` replaces the misspelled
-- identifier's OWN span (its loc start, end = start + name length) with the
-- suggested name — an exact, single-span, agent-applicable edit.
export
resErrorHelpFix : ResError -> (Option String, Option Fix)
resErrorHelpFix e = match resErrorDidYouMean e
  Some (bad, sug) =>
    let help = Some "did you mean `\{sug}`?"
    let fix = match resErrorLoc e
      Some l => didYouMeanFix e bad sug l
      None => None
    (help, fix)
  None => (None, None)

-- Convert a resolve error to a Diag, attaching structured help/fix (did-you-mean).
export
diagOfResError : ResError -> Diag
diagOfResError e =
  let (help, fix) = resErrorHelpFix e
  Diag SevError (Coded (resErrorCode e)) (ppResError e) (resErrorLoc e) help fix

-- ── the stdlib import hint ──────────────────────────────────────────────────
--
-- An unbound name that a stdlib module exports gets "did you forget to
-- import …", even when the file imports nothing.  Resolve only knows the
-- modules a program loads, so the names the rest of the stdlib exports come in
-- through `exportsFor`, an explicit argument of every analysis below: given the
-- unbound names, it returns (module id, which of them that module exports).
-- `hintResErrors` calls it only when resolve reported an unbound name, so a
-- program that resolves reads no extra module.  The CLI passes
-- `stdlibExportsReader` over its stdlib directory, the playground a reader over
-- the modules it ships, and a caller with no stdlib to offer `noStdlibExports`.
export
hintResErrors : (List String -> <e> List (String, List String)) ->
  List ResError ->
  <e> List ResError
hintResErrors exportsFor errs = match hintableUnboundNames errs
  [] => errs
  names => withStdlibExports (exportsFor names) errs

export
noStdlibExports : List String -> List (String, List String)
noStdlibExports _ = []

-- The stdlib modules under `stdlibDir` that export any of `names`.
export
stdlibExportsReader : String -> List String -> <IO> List (String, List String)
stdlibExportsReader stdlibDir names =
  exportsAmong
    names
    (sourcesMentioning stdlibDir (availableModuleIds stdlibDir) names)

-- The source of each module of `ids` under `root` whose text mentions one of
-- `names`, keyed by module id.  This is how an unbound name's import hint reads
-- the stdlib, so it runs only after resolve has reported an unbound name: a
-- program that resolves reads none of these files.  A module whose text never
-- spells a name cannot export it, so the substring test spares the parser that
-- module; an unreadable file contributes nothing.
export
sourcesMentioning : String ->
  List String ->
  List String ->
  <IO> List (String, String)
sourcesMentioning _ _ [] = []
sourcesMentioning root ids names = flatMap (sourceMentioning root names) ids

sourceMentioning : String -> List String -> String -> <IO> List (String, String)
sourceMentioning root names mid = match readFile (fileOfModuleId root mid)
  Ok src =>
    if any (n => isSome (stringIndexOf n src)) names then [(mid, src)] else []
  Err _ => []

-- (module id, which of `names` it exports) for each module source given, with
-- modules that export none of them, or fail to parse, left out.
export
exportsAmong : List String ->
  List (String, String) ->
  List (String, List String)
exportsAmong names srcs = flatMap (moduleExportsAmong names) srcs

moduleExportsAmong : List String ->
  (String, String) ->
  List (String, List String)
moduleExportsAmong names (mid, src) = match parseResult src
  Err _ => []
  Ok decls =>
    match filterList (n => contains n names) (exportedValueNames decls)
      [] => []
      found => [(mid, found)]

-- Convert a typecheck error `TcDiag` to a Diag.  #159: the code, span, and any
-- structured help/fix (e.g. the record-field did-you-mean that
-- `pushTypeErrorHelpFixAt` attaches) now ride INSIDE the TcDiag — no message-keyed
-- side-channel lookup.
--
-- ⚠️ `SevError` is HARDCODED here ON PURPOSE, and the TcDiag's own `severity` field
-- is deliberately NOT consulted — do not "fix" this to read that field.  The
-- `typeErrors` channel this converts is not a pure report: every push funnels
-- through `recordTypeError` (`compiler/types/typecheck.mdk`), which also arms
-- `typeErrorsSticky` — the gate `hadTypeErrors` uses to ABORT `build`/`run` — and
-- bumps `errorsDetected`, the occurrence counter `erredDuring` polls to decide
-- whether gated `unify` calls run (issue 1146).  `recordTypeError` does both
-- UNCONDITIONALLY, without reading severity at all — so a severity-2 `TcDiag`
-- pushed here still ABORTS the build and still STEERS inference.  The side effects
-- are the reason this hardcode stands; the rendering is not.
--
-- ⚠️ Be precise about the rendering, because the imprecise version invites the wrong
-- fix.  Such a diagnostic does NOT print as severity 2 today — this arm binds the
-- severity field to `_`, so it prints severity 1, i.e. it does not even LOOK like the
-- warning its author intended.  And removing the hardcode would not rescue the idea:
-- it would only trade one wrong answer for another, printing severity 2 while
-- continuing to abort the build and steer inference.  Neither variant is a warning.
--
-- A typecheck-stage diagnostic that really is a WARNING belongs on the
-- `matchWarnings` channel instead — see `diagOfTypeWarning` below, which is
-- control-flow-free and carries the author's own `W-*` code end to end.
export
diagOfTypeError : TcDiag -> Diag
diagOfTypeError (TcDiag code _ loc msg help fix) =
  Diag SevError (Coded code) msg loc help (map fixOfLocRepl fix)

fixOfLocRepl : (Loc, String) -> Fix
fixOfLocRepl (l, r) = Fix l r

-- THE typecheck-stage WARNING channel.  Converts a `TcDiag` off `matchWarnings`
-- (whose `msg` is the full "Warning: …" string, carrying its captured loc and any
-- actionable-fix hint as `help`) to a `SevWarning` Diag.  #159: the hint rides in
-- the TcDiag's `help` field — no `matchWarningHelp` lookup.  The `W-*` code is the
-- one the TcDiag ALREADY CARRIES, authored at the push site.  Only the "Warning: "
-- prefix strip is computed from the message — that is presentation, not identity.
-- No machine `fix`: the hint has no single mechanical edit.
--
-- ⚠️ NEVER re-derive the code from the message text here.  This arm used to bind
-- the code field to `_`, throw it away, and recompute one via a `startsWith` prefix
-- match on the rendered message whose `otherwise` arm returned "W-NONEXHAUSTIVE".
-- That is diagnostic IDENTITY keyed on SPELLING — design law L2
-- (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §1: identity is resolved, never
-- re-derived from spelling) — and it was correct only by coincidence: there were
-- exactly two warnings on this channel and their messages happened to differ in
-- their first 30 characters.  A THIRD warning fell into the `otherwise` arm and was
-- silently relabelled a non-exhaustive-match warning: the "a new constructor is
-- swallowed by a `_` arm" shape, in the diagnostics layer.  `DIAGNOSTIC-CODES-DESIGN.md`
-- had already prescribed the right fix ("The two `setRef matchWarnings` sites
-- similarly gain `W-NONEXHAUSTIVE`.  *No chokepoint can infer these*"); this is that
-- design, restored.
--
-- This channel is also the ONLY correct home for a new typecheck warning: unlike
-- `typeErrors` (see `diagOfTypeError` above) `matchWarnings` has no sticky
-- build-abort gate and no occurrence counter behind it, so pushing to it reports
-- without steering `build`/`run` exit status or inference control flow.
--
-- ⚠️ "No control coupling" is NOT "no consumer" — `matchWarnings` has one, and a new
-- warning inherits it.  `hadMatchWarnings` (`compiler/types/typecheck.mdk`) reports
-- whether the last pass pushed ANY warning, and `compiler/tools/snapshot.mdk` reads
-- it to decide whether a rendered `# TYPES` section is `--bless`-able.  So adding a
-- warning that fires on existing corpus code can make snapshots that bless today
-- stop blessing.
--
-- ⚠️ THE FIRST DEMOTION HAS LANDED: F-3d (#614/#311) pushes `W-INCOMPARABLE-IMPLS`
-- here, so the sentence that stood here — "Nothing here pushes a new warning, so
-- nothing changes now" — is retired.  Measured over all 2395 in-tree `.mdk`: it
-- fires on 5 fixture files, none of them in a snapshot corpus, and every compiler
-- module already had `hadMatchWarnings` True, so no snapshot's blessability moved.
-- ⚠️ AND THE SECOND HALF OF THE HAZARD IS NOT THE SNAPSHOT ONE.  A warning here is
-- rendered by whatever surface each CLI verb happens to have, and they were NOT
-- equal: `medaka run` passed only its own main-shape warnings to
-- `emitLocatedWarnings` and `medaka build` had no warning surface at all, so a
-- diagnostic demoted onto this channel became INVISIBLE on both — turning a
-- loud reject into a silent accept on exactly the two verbs that execute
-- code.  F-3d threads them (`finishRunEval`'s `tcWarns`, the typecheck-gate
-- `Ok` payload, `compiler/driver/medaka_cli.mdk`).  A future demotion should re-check that all
-- three verbs still surface it rather than assume this stays fixed.
diagOfTypeWarning : TcDiag -> Diag
diagOfTypeWarning (TcDiag code _ loc w help _) =
  Diag SevWarning (Coded code) (stripWarnPrefix w) loc help None

-- THE JSON `kind`, from the code AND the severity together.  Use this, not bare
-- `diagIdKind`, wherever the severity is not already a literal.
--
-- `diagIdKind` reads only the code, so a demoted error that kept its `T-*` code
-- (a warning authored on the `matchWarnings` channel, see `diagOfTypeWarning`)
-- would render `"kind":"type"` beside `"severity":2`, and a consumer filtering
-- the per-stage taxonomy would read it as a type error.  So a `SevWarning`
-- diagnostic never renders a per-stage kind: it is `warning`.
--
-- That is not "severity 2 implies kind `warning`": `lint` is a real severity-2
-- kind (`medaka lint --json` ships `{"kind":"lint","severity":2}` through this
-- envelope), so lint stays `lint`.  The code text itself is passed through
-- unchanged.
export
diagKind : Severity -> DiagId -> String
diagKind SevError code = diagIdKind code
diagKind SevWarning code
  | diagIdKind code == "lint" = "lint"
  | otherwise = "warning"

export
ppSeverity : Severity -> String
ppSeverity SevError = "error"
ppSeverity SevWarning = "warning"

-- Render a diagnostic as "severity: message" (loc-free, diffable against
-- the location-stripped oracle — the loc is consumed by the LSP, not this text
-- form, so the diff gate stays byte-identical).
export
ppDiag : Diag -> String
ppDiag (Diag sev _ msg _ _ _) = "\{ppSeverity sev}: \{msg}"

-- Plain-text CLI renderer (Stage-A positioned output, Stage-C carat block).
-- line is 1-based (matches the oracle's plain-text convention); col is 0-based.
-- With a loc this reproduces the OCaml oracle's carat diagnostic byte-for-byte
-- (bin/main.ml `show_snippet` :14-24):
--
--     file:line:col: message
--       |
--     N | <source line>
--       | <col spaces>^
--
-- None loc → loc-free "severity: message" (resolve errors with no node span,
-- whole-doc range).  `src` is the target file's source text (to echo the
-- offending line); when the source line can't be read the carat block is
-- omitted (mirrors `show_snippet`'s `None -> ()`), leaving just the header.
export
ppDiagCli : String -> Diag -> String
ppDiagCli file diag = ppDiagCliSrc "" file diag

-- Stage-C: carat-aware renderer.  `src` carries the file's source text.
-- #1500: the header now leads with "<severity>: " so a human reading stderr
-- (or an agent grepping it as text, not `--json`) can tell a fatal error from
-- an advisory warning without tracking the exit code.
export
ppDiagCliSrc : String -> String -> Diag -> String
ppDiagCliSrc src file diag = ppDiagCliLines (srcLinesArr src) file diag

-- #2044: the same renderer, taking the file's lines ALREADY SPLIT.  Rendering
-- one file's N diagnostics through `ppDiagCliSrc` re-walked the whole source
-- from byte 0 (a fresh `stringToChars src`) once per diagnostic — Θ(N·|src|),
-- quadratic for a file whose size scales with its diagnostic count.  Callers
-- that map a renderer over one file's diagnostics hoist `srcLinesArr` OUT of
-- the map and call this; `ppDiagCliSrc` stays as the thin single-diagnostic
-- wrapper.  Output is byte-identical by construction — this IS the old body,
-- with `nthLine src sl` replaced by an index into the pre-split array.
--
-- 🚨 #2400 F2b: THIS is the one place a human-channel path becomes display text,
-- so `displayPath` is applied HERE and nowhere else.  Normalising at the four
-- individual multi-module call sites (as F2b first did) fixed only the arms that
-- happened to be listed: `medaka check main.mdk` agreed afterwards, but `medaka
-- check ./main.mdk` then diverged the OTHER way — the module-graph arm stripped
-- the prefix while the single-file arm, which echoes `target` exactly as typed,
-- kept it.  One renderer, one normalisation, and no call site can be missed.
export
ppDiagCliLines : Array String -> String -> Diag -> String
ppDiagCliLines srcLines file (Diag sev _ msg (Some (Loc _ sl sc _ _)) _ _) =
  let header =
    "\{ppSeverity sev}: \{displayPath file}:\{intToString sl}:\{intToString sc}: \{msg}"
  match nthLineArr srcLines sl
    None => header
    Some lineText =>
      "\{header}\n  |\n\{intToString sl} | \{lineText}\n  | \{spaces sc}^"
-- #2400 F3: an unlocated diagnostic keeps `<unknown location>` in the POSITION
-- a `file:L:C:` would occupy, but takes the severity prefix like every other
-- human diagnostic — so `grep -E '^(error|warning):'` over stderr finds ALL of
-- them, not just the located ones.  This does NOT invent a location: a resolve
-- duplicate-definition error genuinely has none (`resolve.dupErr` hard-codes
-- `None` because `dataRecordNames`/`ctorNames` return bare `List String` and the
-- `Decl` carries no `Loc` at all), and `--json` still reports `"range":null`.
ppDiagCliLines _ _ (Diag sev _ msg None _ _) =
  "\{ppSeverity sev}: <unknown location>: \{msg}"

-- #2544 (M4): render the residual an elaboration returned — the `run`/`build`
-- verbs and the emit driver's #2089 gate print these where they would otherwise print a
-- deflection or nothing.  Same face `check` renders through (`ppDiagCliLines`).  A
-- `Loc` carries no file on the elaborate path, so each entry arrives tagged with its
-- MODULE id and `pathMap` (the loader's modId → path map) names the file; a module
-- the map does not know (the emit driver has no paths) renders under its id with no
-- source snippet, and a diagnostic with no location renders as the `<unknown
-- location>` line that renderer already has.
export
renderTcDiags : List (String, String) ->
  List (String, TcDiag) ->
  <IO> List String
renderTcDiags pathMap ds = renderTcDiagsGo pathMap ds []

renderTcDiagsGo : List (String, String) ->
  List (String, TcDiag) ->
  List (String, Array String) ->
  <IO> List String
renderTcDiagsGo _ [] _ = []
renderTcDiagsGo pathMap ((mid, d) :: rest) cache = match lookupAssoc mid pathMap
  Some file =>
    let (lines, cache2) = srcLinesCached file cache
    ppDiagCliLines lines file (diagOfTypeError d)
      :: renderTcDiagsGo pathMap rest cache2
  -- no path for this module id (the prelude, or a caller that passed no map):
  -- the id stands in for the file, marked so it is not read as one
  None =>
    ppDiagCliLines (arrayFromList []) "(module \{mid})" (diagOfTypeError d)
      :: renderTcDiagsGo pathMap rest cache

-- one read per file, however many diagnostics land in it
srcLinesCached : String ->
  List (String, Array String) ->
  <IO> (Array String, List (String, Array String))
srcLinesCached file cache = match lookupAssoc file cache
  Some ls => (ls, cache)
  None =>
    let ls = srcLinesArr (readFileSafe file)
    (ls, (file, ls) :: cache)

-- ── ONE FACE for the module-graph resolve channel (#2400 F2) ────────────────
--
-- `frontend.resolve` must not render its own multi-module human output by hand
-- (`ppResErrorLocatedF`, deleted): `file:L:C: msg`, no `error: ` prefix, no
-- caret — that makes the SAME resolve error print one way single-file and another
-- way through an import.  Every located resolve error lands here and goes
-- through `ppDiagCliLines`, the renderer the single-file arm has always used.
--
-- Rendering could not stay in `resolve.mdk`: a caret block needs the module's
-- SOURCE TEXT, resolve is pure, and the loader drops module source after
-- parsing.  This module already imports `frontend.resolve` (the dependency only
-- runs one way), so the render boundary is the right place to acquire it.
--
-- ⚠️ THE SOURCE READ IS GUARDED BY THE EMPTY-ERROR ARM ON PURPOSE.  Every module
-- in the graph appears in `pairs`, errors or not; without the `[]` arm a clean
-- multi-module `check` would `readFile` the whole graph on the success path, for
-- output nobody ever prints.  `srcLinesArr` is hoisted out of the per-error
-- `map` for the #2044 reason: one file's N errors split its source ONCE.
--
-- `readFileSafe` degrades to `""`, which `ppDiagCliLines` already renders as
-- header-only (no caret) — the same graceful arm it takes for an out-of-range
-- line, not a new failure mode.
-- `hintResErrors` over the per-file resolve errors of a module graph, with one
-- `exportsFor` call for the names unbound anywhere in it.
export
hintResErrorPairs : (List String -> <e> List (String, List String)) ->
  List (String, List ResError) ->
  <e> List (String, List ResError)
hintResErrorPairs exportsFor pairs =
  match hintableUnboundNames (flatMap snd pairs)
    [] => pairs
    names =>
      let exports = exportsFor names
      map ((file, errs) => (file, withStdlibExports exports errs)) pairs

export
ppResolveErrorsByFile : List (String, List ResError) -> <IO> String
ppResolveErrorsByFile pairs = ppDiagBuckets (map resolveBucket pairs)

-- Each file's diagnostics rendered located against that file as it is on disk,
-- the files in bucket order; a file with none is not read.
export
ppDiagBuckets : List (String, List Diag) -> <IO> String
ppDiagBuckets buckets = joinNl (ppDiagBucketLines buckets)

ppDiagBucketLines : List (String, List Diag) -> <IO> List String
ppDiagBucketLines [] = []
ppDiagBucketLines ((_, []) :: rest) = ppDiagBucketLines rest
ppDiagBucketLines ((file, diags) :: rest) =
  let srcLines = srcLinesArr (readFileSafe file)
  map (ppDiagCliLines srcLines file) diags ++ ppDiagBucketLines rest

-- #2400 F2b: one file, two spellings, in one tool.  The loader mints a module's
-- path by joining its search root with the module id (`loader.fileOfModuleId`),
-- and the root for an entry named with no directory part is `"."` — so `medaka
-- check main.mdk` attributed its OWN entry as `./main.mdk`, while the
-- single-file arm, which echoes the target exactly as typed, printed
-- `main.mdk`.  Measured on both entry forms at the sprint base: `main.mdk` →
-- `./main.mdk:1:10:`, `proj/main.mdk` → `proj/main.mdk:1:10:` (already right),
-- absolute → absolute (already right).  Only the empty-dirname case diverged.
--
-- The convention is STRIPPED, and it must be applied to BOTH arms or it just
-- moves the divergence: a user who types `./main.mdk` gets that spelling back
-- verbatim from the single-file arm, so stripping only the module-graph arm
-- makes THAT invocation disagree instead.  Sole call site is `ppDiagCliLines`.
--
-- 🚨 NORMALIZED HERE, AT THE RENDER BOUNDARY — NOT IN `fileOfModuleId`.  That
-- string is also a real path handed to `fileExists`/`readFile`, AND the prefix
-- `loader.relUnderRoots`/`canonicalModId` match module ids against; rewriting it
-- there would change module IDENTITY, not presentation.  `locatedProjectDiags`
-- likewise relies on the loader-normalised form to identify the entry triple
-- POSITIONALLY, which this leaves untouched.
--
-- Residual, NOT fixed here: `--json` still emits `"file":"./main.mdk"` (its
-- paths come straight off the loader's own list, not through any renderer), as
-- does eval's runtime-panic attribution.  Human channel only — see #2400.
export
displayPath : String -> String
displayPath path
  | startsWith "./" path = stringSlice 2 (stringLength path) path
  | otherwise = path

-- `spaces n` = a string of n space characters (the oracle's `String.make col ' '`).
-- One allocation, not n of them (the old `" " ++ spaces (n-1)` was O(col²) per
-- rendered diagnostic — #2044's second rider).
spaces : Int -> String
spaces n
  | n <= 0 = ""
  | otherwise = stringFromChars (arrayMake n ' ')

-- `src` split on `\n`, by index.  ONE `stringToChars` + one linear pass; each
-- line is carved out of the char array directly (not accumulated with
-- `acc ++ charToStr c`, which was O(L²) in line length — #2044's third rider).
--
-- Line/index contract, preserved EXACTLY from the retired `nthLine`: lines are
-- 1-based, and the trailing fragment after the last `\n` always counts as a
-- line (so `""` has one line, `"a\n"` has two: "a" and ""), which is what makes
-- `ppDiagCli`'s empty-`src` path render as it always did.
export
srcLinesArr : String -> Array String
srcLinesArr src =
  let cs = stringToChars src
  arrayFromList (srcLinesGo cs 0 0 (arrayLength cs))

srcLinesGo : Array Char -> Int -> Int -> Int -> List String
srcLinesGo cs start i n
  | i >= n = [charSlice cs start n]
  | arrayGetUnsafe i cs == '\n' =
    charSlice cs start i :: srcLinesGo cs (i + 1) (i + 1) n
  | otherwise = srcLinesGo cs start (i + 1) n

-- `cs[lo, hi)` as a String.
charSlice : Array Char -> Int -> Int -> String
charSlice cs lo hi =
  stringFromChars (arrayMakeWith (hi - lo) (j => arrayGetUnsafe (lo + j) cs))

-- 1-based Nth line, or None if out of range.
nthLineArr : Array String -> Int -> Option String
nthLineArr srcLines n
  | n < 1 || n > arrayLength srcLines = None
  | otherwise = Some (arrayGetUnsafe (n - 1) srcLines)

-- ── single-file analysis ───────────────────────────────────────────────────
--
-- `analyze`: runs parse → desugar → resolve →
-- guard-exhaustiveness → typecheck, accumulating all stages' diagnostics.
-- Does NOT stop on the first error (errors accumulate).
--
-- Arguments: runtimeSrc (runtime.mdk source), coreSrc (core.mdk source),
-- progSrc (target source).

export
analyze : String -> String -> String -> List Diag
analyze runtimeSrc coreSrc progSrc =
  analyzeFrom noStdlibExports "" runtimeSrc coreSrc (parse progSrc)

-- B.10.2b: the target is parsed with `parseLocated`, so the ELoc wrappers carry
-- REAL line/col spans (the pure `parse` carries placeholder locs).  Type-error
-- Diags then surface the true expr-level span; runtime/core stay on `parse`
-- (their locs are never reported).  Unguarded for internal-only externs.
export
analyzeLocated : (List String -> <e> List (String, List String)) ->
  String ->
  String ->
  String ->
  <e> List Diag
analyzeLocated exportsFor runtimeSrc coreSrc progSrc =
  analyzeFrom exportsFor "" runtimeSrc coreSrc (parseLocated progSrc)

-- The raw-tree half of a single file's front end, plus the derived trees its
-- drive consumes.  `surfaceDiags` holds the first groups of the file's fixed
-- result order (derives, guard exhaustiveness, prelude-standalone shadows,
-- import shadows, resolve); the drive's half follows them (a value `main`'s
-- auto-print obligation is already inside it).  `resolveClean` is False when
-- `resolveProgramG2` reported, and no caller may typecheck a program resolve
-- rejected.
data SurfaceAnalysis = SurfaceAnalysis {
  surfaceDiags : List Diag,
  resolveClean : Bool,
  surfaceDesugared : List Decl,
  surfaceRuntimeP : List Decl,
  surfaceCoreP : List Decl,
  surfacePreludeKey : Option (Int, Int),
}

-- One file's diagnostics, unguarded, parameterised over the already-parsed
-- target program (so `analyze` can pass placeholder-loc `parse` decls and
-- `analyzeLocated` real-loc `parseLocated` decls).  `modName` names THIS module
-- in module-scoped diagnostic text (#1499's `W-PRELUDE-METHOD-SHADOW`).
-- "" = the caller has no module id in hand (the LSP live buffer, the
-- playground, an inline `source`), and the text falls back to "this module".
export
analyzeFrom : (List String -> <e> List (String, List String)) ->
  String ->
  String ->
  String ->
  List Decl ->
  <e> List Diag
analyzeFrom exportsFor modName runtimeSrc coreSrc raw =
  flatMap snd (fileFront exportsFor modName True runtimeSrc coreSrc raw).foDiags

-- One file through `frontEnd` and the check drive, with nothing kept beside the
-- drive's report: the faces that render only diagnostics (the LSP's
-- single-document path, the playground, `check --json`'s inline source).
-- `allowInternal` lifts the internal-extern guard.  No loader saw the file, so
-- no module is stdlib-owned; the profile is the one the process selected.
export
fileFront : (List String -> <e> List (String, List String)) ->
  String ->
  Bool ->
  String ->
  String ->
  List Decl ->
  <e> FrontOutput Unit
fileFront exportsFor modName allowInternal runtimeSrc coreSrc raw =
  frontEnd
    exportsFor
    (d => unkept (checkReportOf NoSteps "" d))
    FrontInput {
      fiInputs = driveInputsFor !selectedProfile False [],
      fiAllowInternal = allowInternal,
      fiTrusted = [],
      fiRuntimeSrc = runtimeSrc,
      fiCoreSrc = coreSrc,
      fiPolicy = NeverDriveRejected,
      fiProgram = FrontFile (modName, "", raw),
    }

-- What a check drive leaves for the target verdict, taken straight off it so no
-- second elaboration is needed: the entry's own schemes and the prelude's
-- (separate, so the caller picks the lookup order), the outputs of THAT drive
-- (its invocation view, its `main` shape), the desugared graph it read
-- (the entry last), and each module's file as the loader named it (`[]` for a
-- single-file drive, whose one module is the entry file).
public export data CheckDrive = CheckDrive {
  cdEntrySchemes : List (String, Scheme),
  cdCoreSchemes : List (String, Scheme),
  cdOutputs : DriveOutputs,
  cdMods : List (String, List Decl),
  cdPaths : List (String, String),
}

-- The single-file drive's report lines and its `CheckDrive`.
public export data CheckDump = CheckDump {
  cdLines : List String,
  cdDrive : CheckDrive,
}

-- The drive of a multi-module check, taken from the report that drive returned:
-- `modPairs` is the desugared graph it read and `paths` the loader's
-- module-to-file map.
export
graphCheckDrive : TcReport ->
  DriveOutputs ->
  List (String, List Decl) ->
  List (String, String) ->
  CheckDrive
graphCheckDrive r outputs modPairs paths = CheckDrive {
  cdEntrySchemes =
    pubSchemes (publishedEntrySchemes (map modOwnSchemes r.trDiagnostics)),
  cdCoreSchemes = pubSchemes r.trPartial.paCore,
  cdOutputs = outputs,
  cdMods = modPairs,
  cdPaths = paths,
}

modOwnSchemes : ModDiags -> (String, List (String, PubScheme))
modOwnSchemes (mid, (schemes, _, _)) = (mid, schemes)

-- The check drive's report beside its outputs: a single file's entry drive, or a
-- graph's keyed drive under `chainKey` (`checkChainReport`).
export
checkReportOf : ChainSteps -> String -> FrontDriveIn -> (TcReport, DriveOutputs)
checkReportOf steps chainKey original =
  let d =
    if original.fdInputs.diProfileName == "" then
      original
    else
      { original |
        fdInputs =
          executedMainInputs
            original.fdInputs
            EntryKey { moduleId = "async", binding = "runAsyncMain" }
            original.fdPairs,
      }
  match (d.fdMods, d.fdPairs)
    ([], [up]) => checkModulesEntryFullReportK
      d.fdInputs
      (valueMainCandidate d.fdCore [up])
      d.fdPreludeKey
      d.fdRuntime
      d.fdCore
      [up]
    (mods, pairs) =>
      checkChainReport
        steps
        d.fdInputs
        (valueMainCandidate d.fdCore pairs)
        d.fdPreludeKey
        chainKey
        d.fdRuntime
        d.fdCore
        mods
        pairs

-- The check drive with its `CheckDrive`, taken off the report before anything
-- else can drive.
export
checkDriveReport : String ->
  FrontDriveIn ->
  (CheckDrive, TcReport, DriveOutputs)
checkDriveReport chainKey d =
  let (r, outputs) = checkReportOf NoSteps chainKey d
  let drive = match (d.fdMods, d.fdPairs)
    ([], [_]) =>
      let (coreSchemes, schemes, _, _) = entrySplit r
      CheckDrive {
        cdEntrySchemes = pubSchemes schemes,
        cdCoreSchemes = pubSchemes coreSchemes,
        cdOutputs = outputs,
        cdMods = d.fdPairs,
        cdPaths = [],
      }
    (mods, pairs) => graphCheckDrive r outputs pairs (map modIdToPath mods)
  (drive, r, outputs)

-- `check`'s drive, the arm `frontEnd` runs for it.  A single file's renders the
-- entry's `name : scheme` lines inside the drive, before any later elaboration:
-- a scheme rendered after another drive can name its type variables differently
-- (#4053).  A graph's report is rendered later from its `trDiagnostics`, so its
-- `cdLines` are empty.  `target` and `roots` make the drive's chain key.
export
checkFrontDrive : String ->
  List String ->
  FrontDriveIn ->
  (CheckDump, TcReport, DriveOutputs)
checkFrontDrive target roots d =
  let (drive, r, outputs) = checkDriveReport (chainKeyOf target roots) d
  let lines = match (d.fdMods, d.fdPairs)
    ([], [_]) =>
      let (_, schemes, _, tcWarns) = entrySplit r
      schemeLines schemes ++ map tcMsg tcWarns
    _ => []
  (CheckDump { cdLines = lines, cdDrive = drive }, r, outputs)

-- `frontEnd`'s raw-tree passes over a single file: everything but the drive.
analyzeSurface : (List String -> <e> List (String, List String)) ->
  String ->
  String ->
  String ->
  List Decl ->
  List String ->
  <e> SurfaceAnalysis
analyzeSurface exportsFor modName runtimeSrc coreSrc raw internalGuard =
  let desugared = desugar raw
  let runtimeP = desugaredPrelude runtimeSrc
  let coreP = desugaredPrelude coreSrc
  -- the identity of those two trees, for the typechecker's prelude interface cache
  -- (`checkCoreMemoized`, types/typecheck.mdk): the prelude is typechecked once
  -- per process, not once per call.
  let preludeKey = Some (preludeGeneration runtimeSrc coreSrc)
  -- Oracle superset = target + prelude (runtime + core) so exhaustiveness of a
  -- multi-clause function over a prelude ADT (Result/Option/…) isn't false-flagged.
  let guardWarns = checkGuardExhaustivenessWith (raw ++ runtimeP ++ coreP) raw
  -- #1375 clause (b) / #1499: an interface method of THIS module whose name is a
  -- prelude standalone.  Unlike the guard-exhaustiveness pass above, this predicate
  -- has no surface-sugar dependency, so it reads the DESUGARED decls — a defaulted
  -- `IfaceMethod` is two RAW nodes (signature + default body) that `mergeIfaceDefaults`
  -- (desugar.mdk) folds into one; reading `raw` here double-fires the warning (F2).
  -- This is the FLAT half; `foldModuleTc` carries the per-module half.
  let shadowWarns = preludeStandaloneShadows (runtimeP ++ coreP) desugared
  -- #2738's importer peer.  The flat path analyses exactly ONE module, so it can
  -- name no dependency's decls: every `DUse` misses the (empty) graph and the walk
  -- yields `[]`.  Wired anyway, beside its sibling, so the two directions stay one
  -- SET here as they are at their detection sites — and so the multi-module half
  -- below is not the only place a reader can find this warning's wiring.  The
  -- interface-row index is passed empty: the one the typechecker holds here is a
  -- previous drive's, and this file's drive has not run.
  let importShadowWarns = importedStandaloneShadowsIn omEmpty [] desugared
  -- Derives live only on the RAW tree (`desugar` clears the field), so this reads
  -- `raw`, not `desugared`.
  let deriveDiags = map deriveErrToDiag (checkDerives raw)
  let resErrs =
    hintResErrors
      exportsFor
      (resolveProgramG2 internalGuard runtimeP coreP desugared)
  let resDiags = map diagOfResError resErrs
  let guardDiags = map guardWarnToDiag guardWarns
  let shadowDiags = map (preludeShadowWarnToDiag modName) shadowWarns
  let importShadowDiags = map (importShadowWarnToDiag modName) importShadowWarns
  let clean = match resErrs
    [] => True
    _ => False
  SurfaceAnalysis {
    surfaceDiags =
      deriveDiags ++ guardDiags ++ shadowDiags ++ importShadowDiags ++ resDiags,
    resolveClean = clean,
    surfaceDesugared = desugared,
    surfaceRuntimeP = runtimeP,
    surfaceCoreP = coreP,
    surfacePreludeKey = preludeKey,
  }

-- The errors among `analyzeSurface`'s diagnostics, in its order, without its
-- warning passes (guard exhaustiveness and the two shadow checks), which a
-- caller that renders warnings from a later typecheck would otherwise run twice.
-- `desugared` is the tree resolve reads: `raw` desugared by the caller.
export
surfaceErrors : (List String -> <e> List (String, List String)) ->
  List Decl ->
  List Decl ->
  List Decl ->
  List Decl ->
  List String ->
  <e> List Diag
surfaceErrors exportsFor runtimeP coreP raw desugared internalGuard =
  map deriveErrToDiag (checkDerives raw)
    ++ map
      diagOfResError
      (hintResErrors
        exportsFor
        (resolveProgramG2 internalGuard runtimeP coreP desugared))

-- A drive's per-module `(errs, warns)` as a single file's typecheck half: the
-- `diagOfTypeError`/`diagOfTypeWarning` conversion, errors before warnings,
-- which is the order the entry driver's half is built in.  A value `main`'s
-- auto-print `Display` obligation is already in it: the drive poses it
-- (`autoPrintWanted`, types/typecheck.mdk).  A graph buckets the same payload
-- per file through `typecheckDiagsFold` instead.
tcHalfOfPerModule : List (String, (List TcDiag, List TcDiag)) -> List Diag
tcHalfOfPerModule perMod =
  map diagOfTypeError (flatMap perModuleErrs perMod)
    ++ map diagOfTypeWarning (flatMap perModuleWarns perMod)

perModuleErrs : (String, (List TcDiag, List TcDiag)) -> List TcDiag
perModuleErrs (_, (errs, _)) = errs

perModuleWarns : (String, (List TcDiag, List TcDiag)) -> List TcDiag
perModuleWarns (_, (_, warns)) = warns

-- ── the front end ──────────────────────────────────────────────────────────
--
-- `frontEnd` runs a loaded program's raw-tree passes (derives, guard
-- exhaustiveness, the two prelude-shadow checks, resolve under the
-- internal-extern guard) and its one typecheck drive, which the verb supplies:
-- `check` passes `checkFrontDrive`, `run`, `check-policy` and `build`'s
-- emitter child their elaboration of the trees they go on to use, the LSP and
-- `check --json` the check drive (`checkReportOf`).  A program resolve rejects
-- is not driven by the verb's drive.

-- The program as the loader returned it, `(modId, path, decls)` per module.  A
-- single module is analysed from its raw, real-span decls and driven as
-- `__user__`; a graph comes with its desugared pairs, in the same dependency
-- order, the entry last.
public export data FrontProgram =
  | FrontFile (String, String, List Decl)
  | FrontGraph (List (String, String, List Decl)) (List (String, List Decl))

-- How a graph's resolve verdict is reached and what a rejection drives; a
-- single file resolve rejects is never driven, under any policy.
-- `NeverDriveRejected`: one unmemoised resolve of the whole graph, and a graph
-- it rejects is not driven (`check`, `run`, `check-policy`, `manifest`).
-- `DriveUnblocked chainKey`: per-module resolve through the pass caches keyed by
-- `chainKey` (`passCacheRef`), and a rejected graph's modules the rejection does not
-- block (`resolveBlockedMods`) get a check drive of their own, whose report the
-- LSP's hover reads (the LSP, `check --json`, `build --json`).
-- `ResolvedByGate`: no resolve here; `build`'s gate (`driver/front_gate.frontGate`)
-- resolved the graph before handing it over, or the emitter run is an ungated
-- one, which resolves nothing.
public export data FrontPolicy =
  | NeverDriveRejected
  | DriveUnblocked String ChainSteps
  | ResolvedByGate

-- Whether a check drive of a graph passes its modules' source keys, so it serves
-- unchanged modules from their recorded interfaces and records the ones it checks
-- (`types/module_interface.mdk`).  A session (the LSP, the playground) analyzes the
-- graph again and serves from them; a process that checks a graph once would only
-- pay a drain and a frozen interface per module for interfaces nothing reads.
public export data ChainSteps = RecordSteps | NoSteps

-- `fiInputs` is what every drive of the run is given: the verb's profile and the
-- stdlib ownership its loader computed.  `fiAllowInternal`/`fiTrusted` lift the
-- internal-extern guard: off for every module under `--allow-internal`, else off
-- for the modules named.
public export data FrontInput = FrontInput {
  fiInputs : DriveInputs,
  fiAllowInternal : Bool,
  fiTrusted : List String,
  fiRuntimeSrc : String,
  fiCoreSrc : String,
  fiPolicy : FrontPolicy,
  fiProgram : FrontProgram,
}

-- What the verb's drive is handed: the run's drive inputs, the preludes resolve
-- read, their memo key, and the desugared program.  `fdMods` is `[]` for a single
-- file, whose one pair is named `__user__` and has no file.
public export data FrontDriveIn = FrontDriveIn {
  fdInputs : DriveInputs,
  fdPreludeKey : Option (Int, Int),
  fdRuntime : List Decl,
  fdCore : List Decl,
  fdPairs : List (String, List Decl),
  fdMods : List (String, String, List Decl),
}

-- `foDiags` holds one bucket per loaded file, keyed by the loader's path, each
-- in rendered order: a single file's surface half then its typecheck half, a
-- graph's as `typecheckDiagsFold` buckets it, a rejected graph's resolve errors
-- alone, or under `DriveUnblocked` followed by what the unblocked modules'
-- check drive reported.  `foDriven` is what the verb's drive kept beside its
-- report, `None` exactly when resolve rejected the program; `foReport` is then
-- the unblocked modules' check drive's report, or a report of nothing.
-- `foReport.trChecked` is `None` whenever any diagnostic in `foDiags` is an
-- error, including the ones the raw-tree passes add outside the drive
-- (`R-CANNOT-DERIVE`).  `foOutputs` are the outputs of the drive that produced
-- `foReport` (`emptyDriveOutputs` where none ran).
public export data FrontOutput a = FrontOutput {
  foDiags : List (String, List Diag),
  foReport : TcReport,
  foOutputs : DriveOutputs,
  foDriven : Option a,
}

-- A drive that keeps nothing beside its report and outputs.
unkept : (TcReport, DriveOutputs) -> (Unit, TcReport, DriveOutputs)
unkept (r, o) = ((), r, o)

export
frontEnd : (List String -> <e> List (String, List String)) ->
  (FrontDriveIn -> <e> (a, TcReport, DriveOutputs)) ->
  FrontInput ->
  <e> FrontOutput a
frontEnd exportsFor drive fi = match fi.fiProgram
  FrontFile (mid, path, raw) =>
    let s =
      analyzeSurface
        exportsFor
        mid
        fi.fiRuntimeSrc
        fi.fiCoreSrc
        raw
        (internalGuardFor (fi.fiAllowInternal || contains mid fi.fiTrusted))
    match s.resolveClean
      False => undrivenOutput [(path, s.surfaceDiags)]
      True =>
        let (kept, r, outputs) = drive FrontDriveIn {
          fdInputs = fi.fiInputs,
          fdPreludeKey = s.surfacePreludeKey,
          fdRuntime = s.surfaceRuntimeP,
          fdCore = s.surfaceCoreP,
          fdPairs = [("__user__", s.surfaceDesugared)],
          fdMods = [],
        }
        let tcHalf = tcHalfOfPerModule (map dropModSchemes r.trDiagnostics)
        drivenOutput [(path, s.surfaceDiags ++ tcHalf)] r outputs kept
  FrontGraph mods pairs =>
    let rt = desugaredPrelude fi.fiRuntimeSrc
    let core = desugaredPrelude fi.fiCoreSrc
    let preludeKey = Some (preludeGeneration fi.fiRuntimeSrc fi.fiCoreSrc)
    let driveIn = FrontDriveIn {
      fdInputs = fi.fiInputs,
      fdPreludeKey = preludeKey,
      fdRuntime = rt,
      fdCore = core,
      fdPairs = pairs,
      fdMods = mods,
    }
    match fi.fiPolicy
      NeverDriveRejected =>
        let resolved =
          hintResErrorPairs
            exportsFor
            (resolveModulesErrorsByFile
              (map modIdToPath mods)
              fi.fiAllowInternal
              fi.fiTrusted
              preludeKey
              rt
              core
              pairs)
        match anyList (p => not (isEmpty (snd p))) resolved
          True => undrivenOutput (map resolveBucket resolved)
          False =>
            drivenGraph drive None driveIn (seedAll (map midPath mods) [])
      DriveUnblocked chainKey steps =>
        let buckets =
          resolvedBuckets
            exportsFor
            fi.fiAllowInternal
            fi.fiTrusted
            preludeKey
            chainKey
            rt
            core
            mods
            pairs
        match bucketsResolveRejected buckets
          True =>
            let (r, outputs, results) =
              typecheckPassReport
                steps
                fi.fiInputs
                rt
                core
                preludeKey
                chainKey
                mods
                pairs
                buckets
            FrontOutput {
              foDiags = results,
              foReport = r,
              foOutputs = outputs,
              foDriven = None,
            }
          False =>
            drivenGraph
              drive
              (foldServeKey steps preludeKey chainKey)
              driveIn
              buckets
      ResolvedByGate =>
        drivenGraph drive None driveIn (seedAll (map midPath mods) [])

-- The verb's drive of a graph resolve admitted, its per-module diagnostics
-- folded into `buckets`, which hold every loaded file.
drivenGraph : (FrontDriveIn -> <e> (a, TcReport, DriveOutputs)) ->
  Option String ->
  FrontDriveIn ->
  List (String, List Diag) ->
  <e> FrontOutput a
drivenGraph drive served d buckets =
  let (kept, r, outputs) = drive d
  let folded =
    typecheckDiagsFold
      outputs
      served
      d.fdRuntime
      d.fdCore
      d.fdMods
      d.fdPairs
      (map dropModSchemes r.trDiagnostics)
      buckets
  drivenOutput folded r outputs kept

resolveBucket : (String, List ResError) -> (String, List Diag)
resolveBucket (file, errs) = (file, map diagOfResError errs)

undrivenOutput : List (String, List Diag) -> FrontOutput a
undrivenOutput buckets = FrontOutput {
  foDiags = buckets,
  foReport = undrivenReport,
  foOutputs = emptyDriveOutputs (),
  foDriven = None,
}

drivenOutput : List (String, List Diag) ->
  TcReport ->
  DriveOutputs ->
  a ->
  FrontOutput a
drivenOutput buckets r outputs kept = FrontOutput {
  foDiags = buckets,
  foReport = if anyList cjHasErrD buckets then { r | trChecked = None } else r,
  foOutputs = outputs,
  foDriven = Some kept,
}
-- The report of a program no drive checked.
undrivenReport : TcReport
undrivenReport = TcReport {
  trPartial = partialAnalysis [] [] noEntryTables,
  trDiagnostics = [],
  trResidual = [],
  trChecked = None,
  trEvidenceFaults = [],
}

-- resolve over runtime + core (prelude) + target

-- resolve has no per-error loc in the compiler pipeline → None.

-- Only run typecheck when resolve found no errors (same gate as diagnostics.ml).

-- each tcErr is (msg, Option Loc): carry the captured span (B.10.2b).

-- Strip the leading "Warning: " prefix that exhaust/typecheck include in their
-- warning strings, so ppDiag emits "warning: <msg>" not "warning: Warning: <msg>".
-- Convert an exhaustiveness warning (message + optional per-group loc) to a Diag,
-- keying the stable code off the message shape: a constructor-coverage warning on
-- a multi-clause function is `W-NONEXHAUSTIVE-CLAUSES`; a guard gap stays
-- `W-GUARD-INEXHAUSTIVE`.
-- #421: an unknown `deriving (…)` name.  An ERROR, not a warning: the clause
-- silently generated NOTHING, so the program is already broken — it just fails
-- later and elsewhere ("No impl of Banana for X" at the first use site), or never,
-- if that impl is only needed on a rare path.  Naming it where it is written is
-- the whole point.
deriveErrToDiag : (String, Option Loc) -> Diag
deriveErrToDiag (msg, loc) = mkDiag SevError RCannotDerive msg loc

guardWarnToDiag : (DiagCode, String, Option Loc) -> Diag
guardWarnToDiag (code, msg, loc) =
  mkDiag SevWarning code (stripWarnPrefix msg) loc

-- #1375 clause (b) / #1499.  An interface method whose name equals a PRELUDE
-- standalone shadows it: under the adopted clause (a) the bare name denotes the
-- INTERFACE METHOD, so the prelude function is no longer reachable by its bare
-- name anywhere in this module.  Located on the method NAME's own span
-- (`IfaceMethod`'s 4th field, ast.mdk).
--
-- NO machine-applicable `fix`, deliberately: a `Fix` is a SINGLE-SPAN
-- replacement, and the repair (renaming the method) is a multi-site edit — a
-- one-span fix would rewrite the declaration and leave every call site broken.
--
-- The help text names the shim recovery only.  `import core as C` and
-- `import core.{n as pn}` are measured BROKEN today, so naming them would bake a
-- fact that rots the moment prelude aliasing lands; the negative list lives in
-- docs/spec/SHADOW-SEMANTICS.md.
preludeShadowWarnToDiag : String -> (String, String, Option Loc) -> Diag
preludeShadowWarnToDiag modName (_, mname, loc) =
  Diag
    SevWarning
    (Coded WPreludeMethodShadow)
    (stringConcat [
      "interface method `",
      mname,
      "` shadows the prelude function `",
      mname,
      "`, which is no longer reachable by its bare name in ",
      moduleScopeText modName,
    ])
    loc
    (Some (stringConcat ["rename the interface method `", mname, "`"]))
    None

-- #2738 / `SHADOW-SEMANTICS.md` S1-PRELUDE (b)'s register, one direction over:
-- a name the module explicitly and selectively IMPORTED is also an interface method
-- nameable here, and the two carry DIFFERENT schemes, so at any receiver with an impl
-- the occurrence means the method rather than the function the import names.  S1/S2
-- make that resolution conformant (§2 row 17); silence about it is what is not.
--
-- Both bindings are named with their types, because the whole defect is that the two
-- differ and only one of them is written in this file.
--
-- NO machine-applicable `fix`, for the same reason `W-PRELUDE-METHOD-SHADOW` ships
-- none: a `Fix` is a single-span replacement and the repair (aliasing the import, or
-- renaming one side) is multi-site — a one-span edit would rewrite the import line and
-- leave every call site meaning the other binding, silently.
importShadowWarnToDiag : String -> (String, String, Option Ty, Ty, Loc) -> Diag
importShadowWarnToDiag modName (name, iface, sty, mty, loc) =
  Diag
    SevWarning
    (Coded WImportMethodShadow)
    (stringConcat [
      "imported `",
      name,
      " : ",
      importedSchemeText sty,
      "` is shadowed in ",
      moduleScopeText modName,
      " by interface method `",
      iface,
      ".",
      name,
      " : ",
      ppTy mty,
      "`; at a receiver with an impl of `",
      iface,
      "` the name means the method",
    ])
    (Some loc)
    (Some
      (stringConcat [
        "import it under another name, `import m.{", name, " as ", name, "2}`"
      ]))
    None

-- The displaced import's own signature, or the reason there is none to show: a
-- module that declares the function WITHOUT a signature offers no scheme to compare,
-- and an unreadable scheme cannot be shown harmless — so it counts as differing and
-- says so here rather than printing a guess.
importedSchemeText : Option Ty -> String
importedSchemeText (Some t) = ppTy t
importedSchemeText None = "no declared signature"

-- "module 'main'" when the caller knows the module id; "this module" when it
-- does not (an inline source, the LSP live buffer) — never "module ''".
moduleScopeText : String -> String
moduleScopeText "" = "this module"
moduleScopeText m = stringConcat ["module `", m, "`"]

stripWarnPrefix : String -> String
stripWarnPrefix s =
  if stringSlice 0 9 s == "Warning: " then
    stringSlice 9 (stringLength s) s
  else
    s

-- ── text entry point (for diff gate) ──────────────────────────────────────

export
analyzeToLines : String -> String -> String -> String
analyzeToLines runtimeSrc coreSrc progSrc =
  joinNl (map ppDiag (analyze runtimeSrc coreSrc progSrc))

-- ── helpers ────────────────────────────────────────────────────────────────

-- ── multi-file / project-wide analysis (B.10.5) ─────────────────────────────
--
-- `analyzeProject`: load a root file's
-- transitive import graph with an unsaved-buffer override, then run desugar /
-- resolve / typecheck per module, BUCKETING every diagnostic by its file so the
-- LSP can publish one set of squiggles per file.  Clean files publish `[]` (their
-- bucket is seeded empty), and a bad file does NOT sink the batch — the
-- Result-returning loader + the per-module resolve/typecheck threading make
-- "continue past a broken file" natural (no try/catch needed).
--
-- Selfhost deviations from the OCaml model, all faithful where it matters:
--   * Buckets / the last-good cache are ASSOCIATION LISTS (`List (file, …)`), not
--     a Hashtbl/Map — the established compiler idiom (cf. lsp.mdk's `Docs`); a
--     project opens a handful of files so linear scan is fine, and `Map` is not in
--     the implicit prelude (it lives in stdlib/map.mdk, unreachable from the
--     single-root compiler tree).
--   * Per-module TYPECHECK threads the shared prelude (core) + runtime externs
--     through the exported multi-module `checkModulesDiagsChain`, which runs each
--     module ISOLATED via `checkModuleFull` (only earlier modules' PUBLIC
--     schemes/data are seeded) and harvests that module's own diagnostics by
--     snapshotting the typeErrors/matchWarnings refs after its check (each module
--     starts with a fresh `ModuleCtx`).  This keeps a private same-named helper in one
--     module from colliding with a different-typed one in another — the
--     per-module-frame property the OCaml `typecheck_module` has.  Resolve uses
--     the exported per-module `resolveModule` directly (it threads exports).

-- A per-file bucket of diagnostics, in dependency order.  Newest pushed last.
-- file → reversed-or-forward diag list; we keep forward order by appending.

-- Look a file's bucket up in the assoc list (None = not seeded yet).
lookupBucket : String -> List (String, List Diag) -> Option (List Diag)
lookupBucket _ [] = None
lookupBucket f ((k, v) :: rest)
  | k == f = Some v
  | otherwise = lookupBucket f rest

-- Replace (or insert) a file's bucket.  Preserves order: an existing key keeps
-- its position; a new key is appended at the end (so files appear in load order).
putBucket : String ->
  List Diag ->
  List (String, List Diag) ->
  List (String, List Diag)
putBucket f v [] = [(f, v)]
putBucket f v ((k, old) :: rest)
  | k == f = (f, v) :: rest
  | otherwise = (k, old) :: putBucket f v rest

-- Append one diagnostic to a file's bucket (seeding the bucket if absent).
pushDiag : String ->
  Diag ->
  List (String, List Diag) ->
  List (String, List Diag)
pushDiag f d buckets = match lookupBucket f buckets
  None => putBucket f [d] buckets
  Some ds => putBucket f (ds ++ [d]) buckets

-- Seed an empty bucket for a file (no-op if already present) so a clean file
-- still appears in the result with `[]` (mirror the empty-bucket seeding).
seedBucket : String -> List (String, List Diag) -> List (String, List Diag)
seedBucket f buckets = match lookupBucket f buckets
  None => putBucket f [] buckets
  Some _ => buckets

-- Append a whole list of diagnostics to one file's bucket.
-- #1019: folding `pushDiag` once per element re-did `existing ++ [d]` for
-- EVERY diag (each `++` O(len existing so far)) — O(n^2) over an n-diag
-- batch. One bulk `existing ++ ds` is a single O(len existing) traversal,
-- same resulting order (existing diags, then the batch, in original order).
pushDiags : String ->
  List Diag ->
  List (String, List Diag) ->
  List (String, List Diag)
pushDiags _ [] buckets = buckets
pushDiags f ds buckets = match lookupBucket f buckets
  None => putBucket f ds buckets
  Some existing => putBucket f (existing ++ ds) buckets

-- ── last-good-source cache + wrapped read (mirror wrapped_read) ─────────────
--
-- The cache is a `Ref (List (file, lastSourceThatParsed))`.  `wrappedRead` is the
-- callback handed to the loader: it consults the user's `read` (open buffers),
-- and when the current buffer FAILS to parse it (a) records the real parse-error
-- diagnostic in `staleRef` (so the user still sees the squiggle) and (b) returns
-- the last source that parsed (so one broken file doesn't blank the whole
-- project's downstream analysis).  A buffer that parses updates the cache.

cachePut : String -> String -> List (String, String) -> List (String, String)
cachePut f v xs = (f, v) :: cacheRemove f xs

cacheRemove : String -> List (String, String) -> List (String, String)
cacheRemove _ [] = []
cacheRemove f ((k, v) :: rest)
  | k == f = cacheRemove f rest
  | otherwise = (k, v) :: cacheRemove f rest

-- The wrapped read callback.  `cacheRef` persists last-good sources across
-- analyses (threaded by the caller); `staleRef` collects this round's parse
-- errors (file → Diag) to append after the graph analysis.
wrappedRead : Ref (List (String, String)) ->
  Ref (List (String, Diag)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  Option String
wrappedRead cacheRef staleRef parseCacheRef read path = match read path
  None => None
  Some src => match parseCachedLocated parseCacheRef src
    Ok _ =>
      cacheRef := cachePut path src !cacheRef
      Some src
    Err e =>
      staleRef := (path, parseErrDiag path e) :: !staleRef
      match lookupAssoc path !cacheRef
        Some good => Some good
        None => Some src  -- no cached version → use the broken one
-- fall back to the last source that parsed

export
parseErrDiag : String -> ParseError -> Diag
parseErrDiag path e = parseDiagnosticToDiag path (parseErrorDiagnostic e)

-- ── project analysis ────────────────────────────────────────────────────────
--
-- runtimeSrc / coreSrc seed the extern + prelude scope (as in `analyze`); `read`
-- supplies open-buffer overrides; entry + roots drive the loader.  Returns one
-- (file, List Diag) per file in the graph (clean files → []).
--
-- LSP latency (parse-cache): the LSP runs this on EVERY didChange.  `parseCacheRef`
-- is a session-lived source→decls memo threaded by the caller; the import graph is
-- loaded via loadProgramFilesLocatedCached so an UNCHANGED dependency module skips
-- re-parsing (only the edited entry buffer's new source misses).  The runtime/core
-- prelude desugar goes through the process-wide content-keyed `desugaredPrelude`
-- memo (frontend/desugar_cache.mdk) — the SAME memo a single file's front end
-- fills — so the two arms share one prelude artifact, and a caller that passes a
-- fresh `Ref []` per call (the playground's multi-module arm) still pays the
-- prelude parse+desugar once per process, not once per call.

-- Memoized prelude desugar, by source string.  One memo for every arm: a hit here
-- is a hit for `frontEnd` and for the emit drivers that read `desugaredPrelude`
-- after analysis, and vice versa.
preludeDesugared : String -> List Decl
preludeDesugared src = desugaredPrelude src

-- `allowInternal`/`trustedMods` gate the internal-extern guard on the RESOLVE
-- pass exactly as `resolveModulesErrorsPairsG` (the human `check`/`run`/`build`
-- multi-module gate) already does: a module is trusted (no internalExterns
-- restriction) when `allowInternal` is set OR its modId is in `trustedMods`
-- (the stdlib-owned modules, per the loader's owning-root) — see `resolvePass`
-- below.  #1362: previously `analyzeProject` always called the unguarded
-- `resolveModule` (implicit `internalGuard = []`), so `check --json`/MCP
-- silently accepted an internal-extern violation a multi-module project's
-- human `check` correctly rejected via the guarded path.
export
analyzeProject : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO | e> List (String, List Diag)
analyzeProject exportsFor allowInternal trustedMods cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let (_, results) =
    analyzeProjectFull
      exportsFor
      allowInternal
      trustedMods
      cacheRef
      parseCacheRef
      read
      entry
      roots
      runtimeSrc
      coreSrc
  results

-- `analyzeProject` also handing back the per-module `(schemes, errs, warns)` the
-- graph driver produced — see `typecheckPassFull`.  A load failure never reaches a
-- typecheck, so its per-module list is empty and only the diagnostics it attributes
-- to the entry file carry any verdict.
export
analyzeProjectFull : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO | e> (List ModDiags, List (String, List Diag))
analyzeProjectFull exportsFor allowInternal trustedMods cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let (report, results) =
    analyzeProjectReport
      exportsFor
      allowInternal
      trustedMods
      cacheRef
      parseCacheRef
      read
      entry
      roots
      runtimeSrc
      coreSrc
  match report
    Some r => (r.trDiagnostics, results)
    None => ([], results)

-- `analyzeProjectFull` handing back the typecheck drive's whole report (`None`
-- on a load failure, which reaches no typecheck).
export
analyzeProjectReport : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO | e> (Option TcReport, List (String, List Diag))
analyzeProjectReport exportsFor allowInternal trustedMods cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let (keyed, results) =
    analyzeProjectKeyed
      exportsFor
      allowInternal
      trustedMods
      cacheRef
      parseCacheRef
      read
      entry
      roots
      runtimeSrc
      coreSrc
  (map (k => fst (fst k)) keyed, results)

-- A loaded graph's identity: the entry's module id, and `moduleStepKey` of every
-- module in load order.  Two loads with equal ids read the same modules from
-- the same paths with the same sources.  A `None` step means the loader kept no
-- source record for that module, so the graph cannot be identified.
public export data GraphId = GraphId {
  giEntry : String,
  giSteps : List (Option String),
}

export
graphIdOf : List (String, String, List Decl) -> GraphId
graphIdOf mods = GraphId {
  giEntry = lastModId mods,
  giSteps = map moduleStepKey mods,
}

lastModId : List (String, String, List Decl) -> String
lastModId mods = match last mods
  Some (mid, _, _) => mid
  None => ""

export
graphIdSame : GraphId -> GraphId -> Bool
graphIdSame a b =
  a.giEntry == b.giEntry && allList isSome a.giSteps && a.giSteps == b.giSteps

-- `analyzeProjectReport` handing back, beside the report, the outputs of its
-- drive and the identity of the graph its load read.
export
analyzeProjectKeyed : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO | e> (Option ((TcReport, DriveOutputs), GraphId), List (String, List Diag))
analyzeProjectKeyed exportsFor allowInternal trustedMods cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let staleRef = newStale ()
  let wread = p => wrappedRead cacheRef staleRef parseCacheRef read p
  projectKeyedFromLoad
    exportsFor
    allowInternal
    trustedMods
    entry
    roots
    runtimeSrc
    coreSrc
    staleRef
    (loadProgramFilesLocatedCachedE parseCacheRef wread entry roots)

export
analyzeProjectKeyedSources : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO | e> (Option ((TcReport, DriveOutputs), GraphId), List (String, List Diag), OrdMap String)
analyzeProjectKeyedSources exportsFor allowInternal trustedMods cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let staleRef = newStale ()
  let wread = p => wrappedRead cacheRef staleRef parseCacheRef read p
  let (loaded, sources) =
    loadProgramFilesLocatedCachedSourcesE parseCacheRef wread entry roots
  let (keyed, diags) =
    projectKeyedFromLoad
      exportsFor
      allowInternal
      trustedMods
      entry
      roots
      runtimeSrc
      coreSrc
      staleRef
      loaded
  (keyed, diags, sources)

projectKeyedFromLoad : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  String ->
  List String ->
  String ->
  String ->
  Ref (List (String, Diag)) ->
  Result LoadError (List (String, String, List Decl)) ->
  <IO | e> (Option ((TcReport, DriveOutputs), GraphId), List (String, List Diag))
-- Dependency errors keep the destination file and the exact located parser error.
projectKeyedFromLoad exportsFor allowInternal trustedMods entry roots runtimeSrc coreSrc staleRef (Err (LoadParseFailed mpath _ pe)) =
  (None, appendStale staleRef [(mpath, [parseErrDiag mpath pe])])
projectKeyedFromLoad exportsFor allowInternal trustedMods entry roots runtimeSrc coreSrc staleRef (Err (LoadMsg e)) = (
  None,
  appendStale staleRef [(entry, [mkDiag SevError RModuleLoad e None])],
)
-- A located cycle belongs to the importing module that closes it.
projectKeyedFromLoad exportsFor allowInternal trustedMods entry roots runtimeSrc coreSrc staleRef (Err (LoadCycle e cpath (Some (_, loc)))) = (
  None,
  appendStale staleRef [(cpath, [mkDiag SevError RModuleLoad e (Some loc)])],
)
projectKeyedFromLoad exportsFor allowInternal trustedMods entry roots runtimeSrc coreSrc staleRef (Err (LoadCycle e _ None)) = (
  None,
  appendStale staleRef [(entry, [mkDiag SevError RModuleLoad e None])],
)
projectKeyedFromLoad exportsFor allowInternal trustedMods entry roots runtimeSrc coreSrc staleRef (Ok mods) =
  let chainKey = chainKeyOf entry roots
  let front =
    frontEnd
      exportsFor
      (d => unkept (checkReportOf RecordSteps chainKey d))
      FrontInput {
        fiInputs = driveInputsFor !selectedProfile False [],
        fiAllowInternal = allowInternal,
        fiTrusted = trustedMods,
        fiRuntimeSrc = runtimeSrc,
        fiCoreSrc = coreSrc,
        fiPolicy = DriveUnblocked chainKey RecordSteps,
        fiProgram = FrontGraph mods (desugaredModPairs mods),
      }
  (
    Some ((front.foReport, front.foOutputs), graphIdOf mods),
    appendStale staleRef front.foDiags,
  )

-- Whether resolve rejected any module of a bucketed graph.
bucketsResolveRejected : List (String, List Diag) -> Bool
bucketsResolveRejected buckets = anyList (b => resolveRejected (snd b)) buckets

-- `analyzeProject` minus the load: resolve, then typecheck, then bucket — over a
-- graph the caller has already loaded.  `medaka test` loads once and calls this,
-- rather than handing `analyzeProject` an entry it would load a second time.
export
projectDiagsLoaded : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  List Decl ->
  List Decl ->
  Option (Int, Int) ->
  String ->
  List (String, String, List Decl) ->
  <e> List (String, List Diag)
projectDiagsLoaded exportsFor allowInternal trustedMods runtimeP coreP preludeKey chainKey mods =
  snd
    (projectDiagsLoadedFull
      exportsFor
      allowInternal
      trustedMods
      runtimeP
      coreP
      preludeKey
      chainKey
      mods
      (desugaredModPairs mods))

-- `projectDiagsLoaded` also handing back the per-module `(schemes, errs, warns)` --
-- see `typecheckPassFull`.  `modPairs` is the caller's `desugaredModPairs mods`:
-- the resolve half and the typecheck half read the same trees.
projectDiagsLoadedFull : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  List Decl ->
  List Decl ->
  Option (Int, Int) ->
  String ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  <e> (List ModDiags, List (String, List Diag))
projectDiagsLoadedFull exportsFor allowInternal trustedMods runtimeP coreP preludeKey chainKey mods modPairs =
  typecheckPassFull
    (driveInputsFor !selectedProfile False [])
    runtimeP
    coreP
    preludeKey
    chainKey
    mods
    modPairs
    (resolvedBuckets
      exportsFor
      allowInternal
      trustedMods
      preludeKey
      chainKey
      runtimeP
      coreP
      mods
      modPairs)
-- A load error (cycle / unknown module / unreadable file) is attributed to the
-- entry file (the compiler loader returns a single Err string without a per-file
-- split, unlike the OCaml attribute_load_error; entry is the conservative
-- fallback there too for cycle/ambiguous).

-- Load the graph rooted at `entry` (the same loader + cache + read disk-fallback
-- analyzeProject uses) and return the ENTRY module's own top-level schemes, taken
-- from `projectEntryAnalysis`'s `PartialAnalysis`; the rest of that analysis (the
-- prelude's schemes, the entry's locals and seed) is dropped.  None on a load
-- error (a buffer with an unresolved import).
export
projectEntrySchemes : Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO> Option (List (String, PubScheme))
projectEntrySchemes cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  map
    (pa => publishedEntrySchemes pa.paSchemes)
    (projectEntryAnalysis
      cacheRef
      parseCacheRef
      read
      entry
      roots
      runtimeSrc
      coreSrc)

-- `projectEntrySchemes` handing back its drive's `PartialAnalysis`: every
-- module's schemes, the prelude's, and the last-checked module's locals and seed.
export
projectEntryAnalysis : Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO> Option PartialAnalysis
projectEntryAnalysis cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  projectEntryAnalysisOr
    (_ => None)
    cacheRef
    parseCacheRef
    read
    entry
    roots
    runtimeSrc
    coreSrc

-- `projectEntryAnalysis` that first asks `kept` for an analysis of the graph it
-- loaded, and drives only when `kept` has none.
export
projectEntryAnalysisOr : (GraphId -> Option PartialAnalysis) ->
  Ref (List (String, String)) ->
  Ref (OrdMap (List Decl)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO> Option PartialAnalysis
projectEntryAnalysisOr kept cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let staleRef = newStale ()
  let wread = p => wrappedRead cacheRef staleRef parseCacheRef read p
  let runtimeP = preludeDesugared runtimeSrc
  let coreP = preludeDesugared coreSrc
  -- #2719 (a1): the SAME prelude key `analyzeProject` mints, so hover/completion
  -- shares the process-wide prelude interface instead of re-typechecking and
  -- re-solving runtime + core on every request.
  let preludeKey = Some (preludeGeneration runtimeSrc coreSrc)
  match loadProgramFilesLocatedCached parseCacheRef wread entry roots
    Err _ => None
    Ok mods => match kept (graphIdOf mods)
      Some pa => Some pa
      None =>
        Some
          (checkModulesPartialK
            (driveInputsFor !selectedProfile False [])
            preludeKey
            runtimeP
            coreP
            (desugarGraph mods))

-- resolve per module (threading exports), bucketing by file.

-- typecheck per module via prefix-diff, bucketing by file.

-- finally fold in the stale parse-error diagnostics (and seed their files).

-- newStale: a fresh per-call stale-collection Ref.
newStale : Unit -> Ref (List (String, Diag))
newStale _ = Ref []

-- (modId, path, decls) → path (the bucket key) and the desugared decls helper.
export
midPath : (String, String, List Decl) -> String
midPath (_, p, _) = p

export
seedAll : List String -> List (String, List Diag) -> List (String, List Diag)
seedAll [] buckets = buckets
seedAll (f :: fs) buckets = seedAll fs (seedBucket f buckets)

-- Append the collected stale parse-error diagnostics into their files' buckets
-- (seeding the bucket first so the file appears even if it produced nothing else).
appendStale : Ref (List (String, Diag)) ->
  List (String, List Diag) ->
  List (String, List Diag)
appendStale staleRef buckets = foldStale !staleRef buckets

foldStale : List (String, Diag) ->
  List (String, List Diag) ->
  List (String, List Diag)
foldStale [] buckets = buckets
foldStale ((path, d) :: rest) buckets =
  foldStale rest (pushDiag path d (seedBucket path buckets))

-- ── resolve pass (per module, threading exports) ────────────────────────────
-- Mirror analyze_project's resolve loop: resolveModuleG per module in dependency
-- order, accumulating ModuleExports, bucketing each module's errors by its file.
-- #1362: guarded via `allowInternal`/`trustedMods` exactly like
-- `resolveModulesErrorsPairsG` (the human check/run/build multi-module gate) —
-- previously always called the unguarded `resolveModule` (implicit
-- `internalGuard = []`), so this pass never rejected an internal-extern
-- violation regardless of caller intent.
-- Resolve errors have no per-error loc in the compiler pipeline → None.
-- #926: `known` is now a Map keyed by module id (mirrors resolve.mdk's driver),
-- so each module's imports resolve via an O(log n) `findExports` lookup instead of a
-- linear scan of a growing `List ModuleExports`.  Threaded byte-identically:
-- `omInsert exp.modId exp known` replaces the `exp :: known` prepend.
--
-- `mods`' decls are already DESUGARED (the caller shares one `desugarModule` per
-- module with the typecheck half).  [served] is the chain key of an analyze that
-- serves each module's verdict from `passCacheRef`, `None` for one that resolves
-- every module afresh; [ids] holds the resolve identities of the modules before.
resolvePass : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  Option String ->
  OrdMap ModuleExports ->
  OrdMap Int ->
  List (String, String, List Decl) ->
  List (String, List Diag) ->
  <e> List (String, List Diag)
resolvePass _ _ _ _ _ _ _ _ _ [] buckets = buckets
resolvePass exportsFor allowInternal trustedMods preludeKey rt core served known ids ((m@(mid, path, desugared)) :: rest) buckets =
  let trusted = allowInternal || contains mid trustedMods
  -- A module's verdict reads, beside its own decls and its imports' exports, its
  -- trust (#1362) and whether any module came before it: a missing import is
  -- `UnknownModule` after the first module and a stub in the first.
  let graph =
    map (k => joinNl [k, boolKey trusted, boolKey (omSize known == 0)]) served
  let (diags, exp, ident) = servedPass ResolveKind graph ids m (_ =>
    let (exp, errs) =
      resolveModuleG
        (internalGuardFor trusted)
        preludeKey
        rt
        core
        known
        mid
        desugared
    (map diagOfResError (hintResErrors exportsFor errs), exp))
  resolvePass
    exportsFor
    allowInternal
    trustedMods
    preludeKey
    rt
    core
    served
    (omInsert exp.modId exp known)
    (withIdentity mid ident ids)
    rest
    (pushDiags path diags buckets)

-- [ids] with [mid]'s identity, when its pass handed one out.
withIdentity : String -> Option Int -> OrdMap Int -> OrdMap Int
withIdentity mid ident ids = option ids (i => omInsert mid i ids) ident

boolKey : Bool -> String
boolKey True = "T"
boolKey False = "F"

-- ── typecheck pass (per module, ISOLATED) ───────────────────────────────────
-- Run the shared multi-module typecheck (`checkModulesDiagsChain`): core + runtime are
-- seeded ONCE and each module is checked in its OWN frame via `checkModuleFull`
-- (only earlier modules' PUBLIC schemes/data carry forward), harvesting that
-- module's own diagnostics from the typeErrors/matchWarnings refs.  This gives the
-- per-module isolation OCaml's `typecheck_module` has, so a private helper named
-- the same across two modules but with different types never collides.
-- Guard-exhaustiveness warnings still come from the RAW (pre-desugar) module decls
-- (checkGuardExhaustiveness needs the surface `EGuards` shape, gone after desugar),
-- bucketed per file alongside the module's type diagnostics.
-- It hands back the per-module `(schemes, errs, warns)` the driver produced
-- beside the bucketed diagnostics; `medaka test`'s gate takes `snd`.
-- `typecheckDiagsFold` keeps consuming exactly `(errs, warns)`: the schemes are
-- a projection beside the fold, never an input to it.  `modPairs` is the
-- caller's, so the graph is desugared once per analyze.
typecheckPassFull : DriveInputs ->
  List Decl ->
  List Decl ->
  Option (Int, Int) ->
  String ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  List (String, List Diag) ->
  (List ModDiags, List (String, List Diag))
typecheckPassFull inputs runtimeP coreP preludeKey chainKey mods modPairs buckets =
  let (r, _, results) =
    typecheckPassReport
      NoSteps
      inputs
      runtimeP
      coreP
      preludeKey
      chainKey
      mods
      modPairs
      buckets
  (r.trDiagnostics, results)

-- `typecheckPassFull` returning the drive's whole report and outputs, whose
-- `trDiagnostics` is the per-module list.  `frontEnd` runs it over a graph
-- resolve rejected under `DriveUnblocked`.
typecheckPassReport : ChainSteps ->
  DriveInputs ->
  List Decl ->
  List Decl ->
  Option (Int, Int) ->
  String ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  List (String, List Diag) ->
  (TcReport, DriveOutputs, List (String, List Diag))
typecheckPassReport steps inputs runtimeP coreP preludeKey chainKey mods modPairs buckets =
  -- The graph analogue of a single file's `resolveClean` gate, per module: a
  -- module resolve rejected, or one importing such a module, is not typechecked
  -- (a bare method name resolve left unbound would panic in `inferMethodAt`).
  -- The blocked set is closed under importers, so what remains is closed under
  -- imports and still checks in dependency order.
  -- A rejected graph still records the interfaces and pass entries of the modules
  -- it checks, and a later accepted graph serves them.  That is sound because a
  -- served module's key carries the graph part: the subset's `chainGraphKey`
  -- equals the full graph's only when the blocked modules declare no impl, no
  -- constrained signature and no interface, which are the only things they could add
  -- to what a checked module reads (the key's interface prefix rows are the third).
  let blocked = resolveBlockedMods buckets omEmpty mods
  let checkedMods = filterList ((mid, _, _) => not (omHasKey mid blocked)) mods
  let checkedPairs =
    filterList ((mid, _) => not (omHasKey mid blocked)) modPairs
  -- A value `main`'s auto-print obligation is posed by this drive, unless some
  -- module is resolve-rejected: the entry is then not the graph's last checked
  -- module.
  let rejected = bucketsResolveRejected buckets
  let valueMain = not rejected && valueMainCandidate coreP modPairs
  let (driven, outputs) =
    checkChainReport
      steps
      inputs
      valueMain
      preludeKey
      chainKey
      runtimeP
      coreP
      checkedMods
      checkedPairs
  -- The drive covers only the modules resolve let through, so on a rejected graph
  -- its report checks a program that is not the one loaded.
  let report = if rejected then { driven | trChecked = None } else driven
  (
    report,
    outputs,
    typecheckDiagsFold
      outputs
      (foldServeKey steps preludeKey chainKey)
      runtimeP
      coreP
      mods
      modPairs
      (map dropModSchemes report.trDiagnostics)
      buckets,
  )

-- `check`'s drive of a graph, keyed under `chainKey`: with `RecordSteps` a module
-- whose source and import closure are unchanged since its interface was recorded is
-- served from it, so only the modules an edit reaches are re-checked
-- (types/typecheck.mdk, `diagsServe`).  `mods` are the loaded triples `pairs`
-- desugars.
checkChainReport : ChainSteps ->
  DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  String ->
  List Decl ->
  List Decl ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  (TcReport, DriveOutputs)
checkChainReport steps inputs valueMain preludeKey chainKey runtimeP coreP mods pairs =
  narrowInterfaces steps mods
  checkModulesChainReportFor
    inputs
    valueMain
    preludeKey
    chainKey
    (stepKeysFor steps mods)
    runtimeP
    coreP
    pairs

-- A recording drive keeps the interfaces of its own graph's modules and no others.
narrowInterfaces : ChainSteps -> List (String, String, List Decl) -> Unit
narrowInterfaces RecordSteps mods = retainModuleInterfaces (map modIdOf mods)
narrowInterfaces NoSteps _ = ()

modIdOf : (String, String, List Decl) -> String
modIdOf (mid, _, _) = mid

-- With no step keys the drive's fold records nothing.
stepKeysFor : ChainSteps ->
  List (String, String, List Decl) ->
  List (Option String)
stepKeysFor RecordSteps mods = map moduleStepKey mods
stepKeysFor NoSteps _ = []

-- The non-typecheck half of `typecheckPassFull`, over per-module `(errs, warns)` a
-- driver already produced: fold in each module's guard-exhaustiveness, `deriving`
-- and prelude-standalone-shadow diagnostics and bucket the lot by file path.
-- `frontEnd` reaches it with whatever the verb's drive returned (for `run`,
-- `check-policy`, `build` and `medaka test`'s gate, the elaboration), so the
-- graph is rendered from ONE typecheck rather than from a second, check-only one.
-- Both drivers' diagnostics must bucket, filter and order identically, which is
-- why there is one fold.
-- `modPairs` is passed in rather than re-derived: the keyed drive's source keys
-- need it, so the graph is desugared once.  [served] is the chain key of a caller
-- whose analyze serves each module's raw-tree diagnostics from `passCacheRef`
-- (`foldServeKey`), `None` for one that folds every module afresh.
typecheckDiagsFold : DriveOutputs ->
  Option String ->
  List Decl ->
  List Decl ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  List (String, (List TcDiag, List TcDiag)) ->
  List (String, List Diag) ->
  List (String, List Diag)
typecheckDiagsFold outputs served runtimeP coreP mods modPairs tcByMid buckets =
  let preludeDecls = runtimeP ++ coreP
  let desugaredPool = omFromPairs (reverseL modPairs) omEmpty
  let passes = RawPasses {
    rpCoreExports = coreExports coreP,
    rpPool = omFromPairs (map rawPairOf mods) omEmpty,
    rpPrelude = preludeDecls,
    -- #1499: the prelude-standalone operand is the prelude alone, not the
    -- oracle's decls, which fold in other modules' declarations and would turn
    -- this into a different (cross-module standalone) rule.
    rpShadowPool = preludeStandaloneSet preludeDecls,
    -- #2738's operand: every module whose decls this compile has, keyed the way a
    -- `DUse`'s `useModId` spells it, with the prelude under the same
    -- `"core"` key `meIfaceExports` (`DeclEnvs.deMethods`) uses.  The detector
    -- reads a DEPENDENCY's decls (the displaced function's own signature lives
    -- there, not here), which is exactly the operand the flat path cannot have.
    rpShadowGraph = ("core", preludeDecls) :: modPairs,
    rpOutputs = outputs,
    rpDesugared = desugaredPool,
    rpTc = omFromPairs (reverseL tcByMid) omEmpty,
  }
  foldModuleTc
    passes
    (option
      None
      (k => foldGraphPart k outputs mods (listLen modPairs) desugaredPool)
      served)
    omEmpty
    omEmpty
    mods
    buckets

-- What every module's raw-tree passes share: the prelude's exports and decls, the
-- graph's raw decls by module id (the constructor declarations a module's imports
-- bind are found there), the prelude-standalone set, the desugared graph the
-- import-shadow detector reads, the desugared decls by module id, the drive's
-- outputs, and the typechecker's (errs, warns) by module id.
data RawPasses = RawPasses {
  rpCoreExports : ModuleExports,
  rpPool : OrdMap (List Decl),
  rpPrelude : List Decl,
  rpShadowPool : OrdMap Unit,
  rpShadowGraph : List (String, List Decl),
  rpOutputs : DriveOutputs,
  rpDesugared : OrdMap (List Decl),
  rpTc : OrdMap (List TcDiag, List TcDiag),
}

-- The chain key under which a caller's analyze serves the bucketing fold's
-- per-module diagnostics: a session's (`RecordSteps`) with a keyed prelude.
foldServeKey : ChainSteps -> Option (Int, Int) -> String -> Option String
foldServeKey RecordSteps (Some (rk, ck)) chainKey =
  Some (chainFullKey rk ck chainKey)
foldServeKey _ _ _ = None

-- Resolve a graph the caller has already loaded, bucketing each module's errors
-- by its file.  The shared prefix of `projectDiagsLoaded` and `frontEnd`'s
-- `DriveUnblocked` arm, which differ only in where the typecheck half comes
-- from.  They resolve identically so their verdicts agree on a channel that has
-- nothing to do with typing.
resolvedBuckets : (List String -> <e> List (String, List String)) ->
  Bool ->
  List String ->
  Option (Int, Int) ->
  String ->
  List Decl ->
  List Decl ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  <e> List (String, List Diag)
resolvedBuckets exportsFor allowInternal trustedMods preludeKey chainKey runtimeP coreP mods modPairs =
  -- A keyed prelude serves each module's verdict from `passCacheRef`; unkeyed,
  -- nothing is served or recorded, and no key is built.  The caches keep this
  -- graph's modules and no others.
  if isSome preludeKey then retainPassEntries (map modIdOf mods)
  resolvePass
    exportsFor
    allowInternal
    trustedMods
    preludeKey
    runtimeP
    coreP
    (map ((rk, ck) => chainFullKey rk ck chainKey) preludeKey)
    omEmpty
    omEmpty
    (desugaredTriples mods modPairs)
    (seedAll (map midPath mods) [])

-- (modId, path, DESUGARED decls), pairing each module with the tree
-- `desugarModule` already memoized for the typecheck half.  `resolvePass` must not
-- run its own raw `desugar prog` over the whole graph and throw the trees away,
-- which desugars twice per analyze; resolve reads no route cell, so sharing
-- the one tree is byte-identical.
desugaredTriples : List (String, String, List Decl) ->
  List (String, List Decl) ->
  List (String, String, List Decl)
desugaredTriples ((mid, path, _) :: ms) ((_, decls) :: ps) =
  (mid, path, decls) :: desugaredTriples ms ps
desugaredTriples _ _ = []

-- The desugared `(modId, decls)` pairs a graph's analyze buckets against, for a
-- caller that must hand the SAME trees to a graph driver.  Shares
-- `desugarModule`'s path-and-source-keyed memo with the check path.
export
desugaredModPairs : List (String, String, List Decl) -> List (String, List Decl)
desugaredModPairs mods = desugarGraph mods

rawPairOf : (String, String, List Decl) -> (String, List Decl)
rawPairOf (mid, _, prog) = (mid, prog)

-- (mid, path, rawDecls) → (mid, desugared decls) for checkModulesDiagsChain.
export
midToDesugaredPair : (String, String, List Decl) -> (String, List Decl)
midToDesugaredPair (mid, path, prog) = (mid, desugarModule path prog)

-- The chain-level memo key: the entry and its roots fix how the loader resolves
-- and rewrites every module in the graph.
export
chainKeyOf : String -> List String -> String
chainKeyOf entry roots = joinNl (entry :: roots)

-- One step key per module: id + path + the EXACT source the loader parsed for
-- that path (`loadedSourceOf`); None when the loader has no record, which
-- simply keeps that module (and those after it) out of the memo.
moduleStepKey : (String, String, List Decl) -> Option String
moduleStepKey (mid, path, _) =
  map (src => joinNl [mid, path, src]) (loadedSourceOf path)

-- `desugar prog`, memoized by the module's PATH and loaded source: the desugared
-- tree is what the typechecker stamps and checks (and what the resolve half reads),
-- and re-deriving it per call was the other per-import cost besides the check
-- itself.  The key carries the path because `prog` is not a function of the source
-- alone: the loader rewrites each `import` target for the package that OWNS the
-- path (`rewriteDecls`), so two byte-identical sources in two packages are two
-- different trees, and a source-only key hands the second module the first one's
-- imports.  Falls back to a plain desugar when the loader has no source record for
-- the path.
desugarModule : String -> List Decl -> List Decl
desugarModule path prog = match loadedSourceOf path
  None => desugar prog
  Some src =>
    let key = joinNl [path, src]
    match omLookup key !moduleDesugarCacheRef
      Some decls => decls
      None =>
        let decls = desugar prog
        moduleDesugarCacheRef := omInsert key decls !moduleDesugarCacheRef
        decls

-- `midToDesugaredPair` over a whole loaded graph, then the memo narrows to the
-- graph's entries: it is bounded by the graph, and no graph size evicts a
-- module another module of the same graph still needs.
desugarGraph : List (String, String, List Decl) -> List (String, List Decl)
desugarGraph mods =
  let pairs = map midToDesugaredPair mods
  let old = !moduleDesugarCacheRef
  moduleDesugarCacheRef := omFromPairs (keptDesugared old mods) omEmpty
  pairs

keptDesugared : OrdMap (List Decl) ->
  List (String, String, List Decl) ->
  List (String, List Decl)
keptDesugared _ [] = []
keptDesugared old ((_, path, _) :: rest) = match loadedSourceOf path
  None => keptDesugared old rest
  Some src =>
    let key = joinNl [path, src]
    match omLookup key old
      Some decls => (key, decls) :: keptDesugared old rest
      None => keptDesugared old rest

moduleDesugarCacheRef : Ref (OrdMap (List Decl))
moduleDesugarCacheRef = Ref omEmpty

diagCode : Diag -> DiagId
diagCode (Diag _ code _ _ _ _) = code

-- The multi-module twin of `SurfaceAnalysis.resolveClean`: a module whose own
-- bucket holds a resolve error gets no typecheck diagnostics.  Whatever
-- typecheck reports about such a module follows from a name resolve could not
-- bind (`T-UNBOUND` beside `R-UNBOUND`, `T-NO-IMPL` beside
-- `R-UNKNOWN-INTERFACE`), and only the resolve diagnostic names the fault.
-- On the analyze path such a module is not typechecked at all
-- (`resolveBlockedMods`); a caller that already typechecked has its report gated.
resolveRejected : List Diag -> Bool
resolveRejected =
  anyList (d => diagIsError d && diagIdKind (diagCode d) == "resolve")

-- The modules a resolve rejection withholds from typecheck: each module whose
-- own bucket is `resolveRejected`, and each module importing a blocked one,
-- transitively, since the schemes it would check against were never built.
-- `mods` is dependency-first, so one forward pass sees every import's verdict
-- before its importer.
resolveBlockedMods : List (String, List Diag) ->
  OrdMap Unit ->
  List (String, String, List Decl) ->
  OrdMap Unit
resolveBlockedMods _ blocked [] = blocked
resolveBlockedMods buckets blocked ((mid, path, prog) :: rest) =
  let rejected = match lookupBucket path buckets
    Some ds => resolveRejected ds
    None => False
  let blocks = rejected || anyList (m => omHasKey m blocked) (useModuleIds prog)
  resolveBlockedMods
    buckets
    (if blocks then omInsert mid () blocked else blocked)
    rest

-- For each (mid, path, rawProg): its raw-tree diagnostics (`rawTreeDiags`, or the
-- served ones), then its harvested (errs, warns) as Diags (preserving each type
-- error's Option Loc) unless resolve rejected it, bucketed by path.  [known] is
-- the exports of the modules before it, [ids] their fold identities.
foldModuleTc : RawPasses ->
  Option String ->
  OrdMap ModuleExports ->
  OrdMap Int ->
  List (String, String, List Decl) ->
  List (String, List Diag) ->
  List (String, List Diag)
foldModuleTc _ _ _ _ [] buckets = buckets
foldModuleTc passes graph known ids ((mid, path, prog) :: rest) buckets =
  let (rawDiags, exp, ident) =
    servedPass
      FoldKind
      graph
      ids
      (mid, path, prog)
      (_ => rawTreeDiags passes known (mid, path, prog))
  let (tcErrs, tcWarns) = optionOr ([], []) (omLookup mid passes.rpTc)
  let tcReported = match lookupBucket path buckets
    Some existing => not (resolveRejected existing)
    None => True
  let errDiags = if tcReported then map diagOfTypeError tcErrs else []
  let warnDiags = if tcReported then map diagOfTypeWarning tcWarns else []
  foldModuleTc
    passes
    graph
    (omInsert exp.modId exp known)
    (withIdentity mid ident ids)
    rest
    (pushDiags path (rawDiags ++ errDiags ++ warnDiags) buckets)

-- One module's derive, guard-exhaustiveness and two shadow diagnostics, and its
-- exports for the modules after it.
rawTreeDiags : RawPasses ->
  OrdMap ModuleExports ->
  (String, String, List Decl) ->
  (List Diag, ModuleExports)
rawTreeDiags passes known (mid, _, prog) =
  let desugared = optionOr [] (omLookup mid passes.rpDesugared)
  -- The clause-exhaustiveness oracle is the module's own decls, the decls
  -- declaring a constructor its imports bind, and the prelude: never every
  -- loaded module, where an unrelated module's same-spelled constructor
  -- answers for a pattern that names another (#1185).
  let (imported, exp) = importedCtorDeclsStep
    passes.rpCoreExports
    passes.rpPool
    known
    (mid, desugared)
  let guardWarns =
    checkGuardExhaustivenessWith (imported ++ passes.rpPrelude) prog
  -- #1375 clause (b) / #1499, per module: this module's own interface methods
  -- against the prelude standalones, named by its own module id.  Reads the
  -- DESUGARED decls, not raw — see the FLAT-half comment in `analyzeSurface`
  -- for why a defaulted `IfaceMethod` double-fires over the raw tree (F2).
  let shadowDiags =
    map
      (preludeShadowWarnToDiag mid)
      (preludeStandaloneShadowsWith passes.rpShadowPool desugared)
  -- #2738, the importer direction: this module's own selective imports against the
  -- interfaces it can name, named by its own module id.
  let importShadowDiags =
    map
      (importShadowWarnToDiag mid)
      (importedStandaloneShadows
        passes.rpOutputs
        passes.rpShadowGraph
        desugared)
  (
    map deriveErrToDiag (checkDerives prog)
      ++ map guardWarnToDiag guardWarns
      ++ shadowDiags
      ++ importShadowDiags,
    exp,
  )

-- ── the per-module pass caches ──────────────────────────────────────────────
-- An analyze under a keyed prelude serves a module's resolve verdict from the
-- analyze that last computed it, and records on a miss, whichever verb drives it
-- (the LSP, the playground, `check --json`, `build --json`, `medaka test`, MCP).
-- The raw-tree diagnostics' entries are served and recorded only by a drive that
-- records steps (`RecordSteps`: the LSP and the playground).  Each entry carries
-- the exports the modules after it read, and is served when nothing it read has
-- changed: the module's own
-- decls (its path and the exact source the loader parsed), its imports' exports
-- and constructor declarations through re-export chains, and what the pass reads of
-- the whole graph (the key's graph part: `resolvePass`, `foldGraphPart`).  A key's
-- imports are the identities of the modules its decls import, and a module's
-- identity is new whenever its pass computes it afresh, so a change anywhere in the
-- import closure reaches the module.  Each pass keeps one entry per module id, the
-- newest, for the modules of the graph last resolved: a keyed resolve drops the
-- entries of every other module.  An entry holds strings, string lists and maps of them
-- (`ModuleExports`, `Diag`): no `Decl`, no `Ref`, no `Scheme`, so it lies outside
-- the admissibility rule of `types/module_interface.mdk`.
data PassKey = PassKey {
  pkGraph : String,
  pkPath : String,
  pkSource : String,
  pkImports : List (Option Int),
} deriving (Eq)

data PassEntry = PassEntry {
  peKey : PassKey,
  peIdentity : Int,
  peDiags : List Diag,
  peExports : ModuleExports,
}

-- [pcSerial] is the last identity handed out.
data PassCaches = PassCaches {
  pcResolve : OrdMap PassEntry,
  pcFold : OrdMap PassEntry,
  pcSerial : Int,
}

passCacheRef : Ref PassCaches
passCacheRef = Ref (emptyPassCaches ())

emptyPassCaches : Unit -> PassCaches
emptyPassCaches _ =
  PassCaches { pcResolve = omEmpty, pcFold = omEmpty, pcSerial = 0 }

data PassKind = ResolveKind | FoldKind

passEntries : PassKind -> PassCaches -> OrdMap PassEntry
passEntries ResolveKind c = c.pcResolve
passEntries FoldKind c = c.pcFold

retainPassEntries : List String -> Unit
retainPassEntries mids =
  let c = passCacheRef.value
  passCacheRef := { c |
    pcResolve = omRestrict mids c.pcResolve,
    pcFold = omRestrict mids c.pcFold,
  }

export
clearProjectPassEntries : Unit -> Unit
clearProjectPassEntries () = retainPassEntries []

keepPassEntry : PassKind -> String -> PassEntry -> Unit
keepPassEntry kind mid entry =
  let c = passCacheRef.value
  passCacheRef := match kind
    ResolveKind => { c | pcResolve = omInsert mid entry c.pcResolve }
    FoldKind => { c | pcFold = omInsert mid entry c.pcFold }

-- An identity no earlier call returned.
freshPassIdentity : Unit -> Int
freshPassIdentity _ =
  let c = passCacheRef.value
  let next = c.pcSerial + 1
  passCacheRef := { c | pcSerial = next }
  next

-- The identity of the entry the bucketing fold's cache holds for module [mid]:
-- unchanged across analyzes that serve the module, new whenever one folds it.
export
foldCachedIdentity : String -> Option Int
foldCachedIdentity mid =
  map (e => e.peIdentity) (omLookup mid passCacheRef.value.pcFold)

-- The same for the resolve pass's cache.
export
resolveCachedIdentity : String -> Option Int
resolveCachedIdentity mid =
  map (e => e.peIdentity) (omLookup mid passCacheRef.value.pcResolve)

-- [compute] of one module with its identity in [kind]'s pass: served when [graph]
-- is `Some` and the module's entry was recorded under the same graph part, path,
-- source and import identities; otherwise computed, and under `Some` recorded with
-- a fresh identity.
servedPass : PassKind ->
  Option String ->
  OrdMap Int ->
  (String, String, List Decl) ->
  (Unit -> <e> (List Diag, ModuleExports)) ->
  <e> (List Diag, ModuleExports, Option Int)
servedPass _ None _ _ compute =
  let (diags, exp) = compute ()
  (diags, exp, None)
servedPass kind (Some g) ids (mid, path, prog) compute =
  match loadedSourceOf path
    None =>
      let (diags, exp) = compute ()
      (diags, exp, Some (freshPassIdentity ()))
    Some src =>
      let key = PassKey {
        pkGraph = g,
        pkPath = path,
        pkSource = src,
        pkImports = map (i => omLookup i ids) (useModuleIds prog),
      }
      let hit = match omLookup mid (passEntries kind passCacheRef.value)
        Some e => if e.peKey == key then Some e else None
        None => None
      match hit
        Some e => (e.peDiags, e.peExports, Some e.peIdentity)
        None =>
          let (diags, exp) = compute ()
          let ident = freshPassIdentity ()
          keepPassEntry kind mid PassEntry {
            peKey = key,
            peIdentity = ident,
            peDiags = diags,
            peExports = exp,
          }
          (diags, exp, Some ident)

-- What every module's raw-tree diagnostics read of the whole graph, beside the
-- chain key [chainFull] (the prelude generation, the entry and the roots the
-- loader rewrote each module's imports under): the module count (the import-shadow
-- detector's bound on a re-export chain), the drive's interface-row index, and
-- the path and source of every module that declares an interface, since the
-- import-shadow detector takes an interface's method signature from the first
-- loaded module declaring an interface of that bare name, imported or not.  `None`
-- when a module declaring an interface has no source record: nothing is served.
-- [count] is the number of modules and [pool] their desugared decls by id.
foldGraphPart : String ->
  DriveOutputs ->
  List (String, String, List Decl) ->
  Int ->
  OrdMap (List Decl) ->
  Option String
foldGraphPart chainFull outputs mods count pool =
  let declarers =
    filterList
      ((mid, _, _) =>
        anyList declaresInterface (optionOr [] (omLookup mid pool)))
      mods
  let rows =
    map
      ((_, path, _) =>
        map (src => "\{lenKey path}\{lenKey src}") (loadedSourceOf path))
      declarers
  if allList isSome rows then
    Some
      (joinNl
        ([
            lenKey chainFull,
            lenKey (intToString count),
            lenKey (ifaceIndexText outputs.doIfaceExports),
          ]
          ++ map (optionOr "") rows))
  else
    None

declaresInterface : Decl -> Bool
declaresInterface (DInterface {  }) = True
declaresInterface (DAttrib _ d) = declaresInterface d
declaresInterface _ = False

ifaceIndexText : OrdMap (List (String, List String)) -> String
ifaceIndexText idx =
  joinNl (map (mid => ifaceRowsText mid (omLookup mid idx)) (omKeys idx))

ifaceRowsText : String -> Option (List (String, List String)) -> String
ifaceRowsText mid rows =
  stringConcat
    (lenKey mid
      :: map
        (row => "\{lenKey (fst row)}\{lenKey (joinNl (snd row))}")
        (optionOr [] rows))

-- ── project text entry point (diff gate) ────────────────────────────────────
-- Render the per-file buckets as one block per file:
--   "## FILE <path>"  followed by each diag's "severity: message" line.
-- The harness splits on the marker and sorts each file's lines, diffing against
-- the OCaml analyze_project's per-file buckets.
-- #1362: this diff-gate probe has no `--allow-internal`/trusted-root concept of
-- its own (it is a raw multi-file diagnostics dump, not a `check` route) — kept
-- unguarded (`allowInternal = True`, `trustedMods = []`) to preserve its prior
-- byte-identical behavior; it is not exercising the internal-extern boundary.
export
analyzeProjectToLines : Ref (List (String, String)) ->
  (String -> Option String) ->
  String ->
  List String ->
  String ->
  String ->
  <IO> String
analyzeProjectToLines cacheRef read entry roots runtimeSrc coreSrc =
  let parseCacheRef = Ref omEmpty
  joinNl
    (projectLines
      (analyzeProject
        noStdlibExports
        True
        []
        cacheRef
        parseCacheRef
        read
        entry
        roots
        runtimeSrc
        coreSrc))

projectLines : List (String, List Diag) -> List String
projectLines [] = []
projectLines ((file, ds) :: rest) =
  "## FILE " ++ file :: map ppDiagLoc ds ++ projectLines rest

-- Render a diagnostic for the project gate WITH its start position, so the diff
-- can assert positions (the loc is otherwise consumed only by the LSP JSON).
--   "<severity>@<line>:<col>: <message>"   (0-based LSP line/col, mirror
--   range_of_loc: line = startLine-1, character = startCol)
--   "<severity>: <message>"                when the diag carries no loc (None →
--   whole-document range in the LSP; positionless here).
ppDiagLoc : Diag -> String
ppDiagLoc (Diag sev _ msg None _ _) = "\{ppSeverity sev}: \{msg}"
ppDiagLoc (Diag sev _ msg (Some (Loc _ sl sc _ _)) _ _) =
  "\{ppSeverity sev}@\{intToString (sl - 1)}:\{intToString sc}: \{msg}"

-- ── check --json JSON shaping ────────────────────────────────────────────────
-- Shared by medaka_cli.mdk (`medaka check --json`) and playground_main.mdk
-- (wasm playground). Field/key ordering matches OCaml/Yojson alphabetical
-- insertion so the JSON is byte-identical to `medaka check --json`:
--   file entry:   file, diagnostics
--   diagnostic:   message, range, severity, source
--   range:        end, start
--   position:     character, line

-- Build a 0-based LSP Position JSON: { "character": ch, "line": line }
-- (alphabetical: character < line)
export
cjPosition : Int -> Int -> Json
cjPosition line ch = jObject [("character", JInt ch), ("line", JInt line)]

-- Build an LSP Range JSON: { "end": ..., "start": ... }
-- (alphabetical: end < start)
export
cjRange : Int -> Int -> Int -> Int -> Json
cjRange sl sc el ec =
  jObject [("end", cjPosition el ec), ("start", cjPosition sl sc)]

-- Map an Option Loc to a range JSON (mirror of rangeOfLoc in lsp.mdk).
-- A `None` loc (a genuinely unlocated diagnostic — e.g. R-MODULE-LOAD, or any
-- span-less resolve / build-phase error) renders `null`, NOT a fabricated {0,0}
-- range: {0,0} is a real position on source line 1 that a reader/editor would
-- trust, so consumers must be able to tell "unlocated" from a diagnostic that
-- genuinely sits at 0,0. This mirrors the human path's `<unknown location>`.
-- The key is present with a null value (not omitted) so consumers distinguish
-- "unlocated" from "field missing". See the Diag JSON contract in
-- compiler/DIAGNOSTIC-CODES-DESIGN.md.
export
cjRangeOfLoc : String -> Option Loc -> Json
cjRangeOfLoc "" (Some (Loc _ sl sc el ec)) = cjRange (sl - 1) sc (el - 1) ec
cjRangeOfLoc src (Some (Loc _ sl sc el ec)) =
  let index = indexSource src
  let positions = do
    start <- sourcePositionToOffset index sl sc
    end <- sourcePositionToOffset index el ec
    (a, b) <- offsetToUtf16Position index start
    (c, d) <- offsetToUtf16Position index end
    Some (cjRange a b c d)
  optionOr JNull positions
cjRangeOfLoc src None = JNull

-- Severity code: Error=1, Warning=2.
cjSevCode : Severity -> Int
cjSevCode SevError = 1
cjSevCode _ = 2

-- Build one diagnostic JSON object with alphabetical field order:
-- { "code": ..., "kind": ..., "message": ..., "range": ..., "severity": ...,
--   "source": "medaka" }.  Stage 1 (DIAGNOSTIC-CODES-DESIGN): every diagnostic
-- (error OR warning) now carries its stable `code` + derived `kind`, a bare
-- `message`, and its REAL loc-derived range.  Warnings are rendered exactly like
-- errors — the old oracle-compat special arm (which baked "path:L:C: Warning:"
-- into the message and emitted a {0,0} dummy range) is gone, so a non-exhaustive
-- match warning now reports a real span.  `path` is unused (kept for the caller's
-- uniform call shape).
-- Stage 2: a single optional JSON field — `[]` when absent so the key is omitted
-- entirely (keeps every non-suggestion diagnostic's JSON byte-identical to Stage 1).
export
optField : String -> Option Json -> List (String, Json)
optField k (Some v) = [(k, v)]
optField _ None = []

-- Render a machine-applicable Fix as { "range": {...}, "replacement": "..." },
-- the range covering exactly the span to overwrite (mirrors the LSP text edit).
export
cjFixJson : Fix -> Json
cjFixJson = cjFixJsonWithSource ""

cjFixJsonWithSource : String -> Fix -> Json
cjFixJsonWithSource src (Fix loc repl) = jObject [
  ("range", cjRangeOfLoc src (Some loc)),
  ("replacement", JString repl),
]
cjFixJsonWithSource src (FixEdits applicability edits) =
  fixEditsJson (loc => cjRangeOfLoc src (Some loc)) applicability edits

-- The `{applicability, edits}` object of a span-edit fix, each edit's range
-- rendered by `rangeOf`: the CLI and the language server differ only there.
export
fixEditsJson : (Loc -> Json) -> String -> List (Loc, String) -> Json
fixEditsJson rangeOf applicability edits = jObject [
  ("applicability", JString applicability),
  (
    "edits",
    JArray
      (arrayFromList
        (map
          ((loc, repl) => jObject [
            ("range", rangeOf loc),
            ("replacement", JString repl),
          ])
          edits)),
  ),
]

export
cjDiagnostic : String -> String -> Diag -> Json
cjDiagnostic _ src (Diag sev code msg loc help fix) =
  jObject
    ([("code", JString (diagIdText code))]
      ++ optField "fix" (map (cjFixJsonWithSource src) fix)
      ++ optField "help" (map JString help)
      ++ [
        ("kind", JString (diagKind sev code)),
        ("message", JString msg),
        ("range", cjRangeOfLoc src loc),
        ("severity", JInt (cjSevCode sev)),
        ("source", JString "medaka"),
      ])

-- Build the per-file entry: { "file": path, "diagnostics": [...] }.
-- `diags` is the List Diag from analyzeProject.
export
cjFileEntry : String -> String -> List Diag -> Json
cjFileEntry path src diags = jObject [
  ("file", JString path),
  ("diagnostics", JArray (arrayFromList (map (cjDiagnostic path src) diags))),
]

cjTriple : (String, String, List Diag) -> Json
cjTriple (path, src, diags) = cjFileEntry path src diags

-- Serialize the analyzeProject result as the top-level JSON object:
-- { "files": [ { "file": ..., "diagnostics": [...] }, ... ] }
export
cjAllToJson : List (String, String, List Diag) -> String
cjAllToJson triples = cjAllToJsonWith [] triples

-- `cjAllToJson` plus caller-supplied top-level fields, appended AFTER "files"
-- so the schema every existing consumer reads is unchanged and the extras are
-- purely additive.  C4 (docs/ops/CLI-CONFORMANCE.md §4): `medaka run --json`'s
-- machine channel is STDERR (its stdout belongs to the user program), which it
-- shares with two human-readable writers — `MEDAKA_PERF=1`'s `[perf]` lines and
-- the `[B-STDERR]` staleness warning.  Those writers are ROUTED INTO this
-- envelope, never silenced: suppressing the staleness warning under `--json`
-- would make a stale binary invisible to every machine consumer, which is a
-- severity INCREASE ([W-QUIETER]), not a fix.  Same shape as `attachStaleness`
-- (compiler/tools/mcp.mdk), which already splices a `staleBinary` field onto an
-- MCP tool result rather than inventing a second channel.
export
cjAllToJsonWith : List (String, Json) ->
  List (String, String, List Diag) ->
  String
cjAllToJsonWith extra triples =
  stringify
    (jObject
      ([("files", JArray (arrayFromList (map cjTriple triples)))] ++ extra))

-- ── run --json envelope notices ─────────────────────────────────────────────
-- Staged here rather than in eval.mdk (which owns `pendingRunDiags`) because
-- BOTH envelope emitters must see them and only one of them is in eval.mdk:
-- the clean-exit flush lives in medaka_cli.mdk (`flushPendingRunDiags`) and the
-- runtime-panic one in eval.mdk (`runtimePanic`).  driver.diagnostics is the
-- module both already import, and putting them here adds no top-level binding
-- to a LEG-A-golden module.
--
-- Both are set ONLY on the `run --json` path; every other verb and every
-- non-JSON `run` leaves them empty and its output byte-identical.

-- The `[B-STALENESS]` verdict, deferred so it lands INSIDE the envelope instead
-- of ahead of it as prose.  `None` = fresh binary (or not `run --json`).
export
pendingStaleNotice : Ref (Option String)
pendingStaleNotice = Ref None

-- The stale lines `run` prints for the prelude's shipped files (`core.mdke`,
-- `core.mdkd`), deferred the same way: each is the envelope field it lands in
-- and the line, in the order they were staged.
export
pendingPreludeNotices : Ref (List (String, String))
pendingPreludeNotices = Ref []

-- The extra top-level envelope fields the deferred notices amount to: the
-- staleness verdicts staged above, plus whatever `MEDAKA_PERF=1` buffered into
-- `support.timer`'s sink (verbatim `[perf]` lines — the identical strings the
-- consumer would have seen on stderr, just inside the document).  Empty when
-- neither fired ⇒ the envelope is byte-identical to today's.
export
runEnvelopeFields : Unit -> <e> List (String, Json)
runEnvelopeFields _ =
  let staleF = match !pendingStaleNotice
    None => []
    Some msg => [("staleBinary", JString msg)]
  let preludeF =
    map ((field, msg) => (field, JString msg)) !pendingPreludeNotices
  let perfF = match takePerfSink ()
    [] => []
    ls => [("perf", JArray (arrayFromList (map (l => JString l) ls)))]
  staleF ++ preludeF ++ perfF

-- Emit the ONE `run --json` envelope on stderr — or nothing at all when there
-- is nothing to say (no diagnostics AND no notices), which keeps a clean run on
-- a fresh binary byte-identical to before this convention landed.
export
flushRunEnvelope : List (String, String, List Diag) -> <Stderr | e> Unit
flushRunEnvelope triples = match (triples, runEnvelopeFields ())
  ([], []) => ()
  (ts, extra) => ePutStrLn (cjAllToJsonWith extra ts)

-- Read each file's source for rendering.  A file with no diagnostics renders
-- nothing, so it costs no read (its source is `""`; the JSON envelope ignores
-- `src`, so a diagnostic folded in later by `cjFoldIntoFile` still serializes).
-- Otherwise the loader's own copy of the source is preferred (the bytes it
-- parsed), and the disk is read when the loader's bounded table has evicted the
-- entry or never noted the path.  On read error, use "" so diagnostics still
-- serialize (the error itself is in the diag list).
export
readDiagSrc : (String, List Diag) -> <IO> (String, String, List Diag)
readDiagSrc (path, []) = (path, "", [])
readDiagSrc (path, diags) = match loadedSourceOf path
  Some src => (path, src, diags)
  None => match readFile path
    Ok src => (path, src, diags)
    Err _ => (path, "", diags)

export
cohWarnsOfTriple : (String, String, List Diag) -> (String, String, List Diag)
cohWarnsOfTriple (path, src, diags) = (path, src, filter isCoherenceWarn diags)

export
joinedOrNone : List String -> Option String
joinedOrNone [] = None
joinedOrNone ls = Some (joinNl ls)

-- #2044: split the source ONCE, not once per diagnostic — and, per the strictness
-- trap the strictness note on `locatedProjectDiags` (medaka_cli.mdk) spells out, not at all
-- when there is nothing to render.  `map f xs` with `f = ppDiagCliLines
-- (srcLinesArr src) path` builds that partial application from ALREADY-EVALUATED
-- arguments, so a strict language splits the whole file before `map` ever looks at
-- whether `xs` is empty — which made a clean multi-module project pay a full
-- per-file `Array String` split on EVERY file for output that does not exist.
-- The `[]` arm is what keeps the split off the zero-diagnostic path; keep it.
--
-- #2400 F2b: `path` here is the LOADER-NORMALISED form (`./main.mdk` for an
-- entry named with no directory part), where the single-file arm passes the
-- CLI's `target` verbatim — the same tool printed `./main.mdk` for a
-- multi-module TYPE error and `main.mdk` for a single-file one.  `displayPath`
-- reconciles the two INSIDE `ppDiagCliLines`, for DISPLAY only, so the triples
-- reaching here keep the loader's spelling and `locatedProjectDiags` can go on
-- identifying the entry triple positionally (it works BECAUSE these paths do
-- not compare equal to `target`).
export
renderTripleErrors : (String, String, List Diag) -> List String
renderTripleErrors (path, src, diags) =
  let errs = filter diagIsError diags
  match errs
    [] => []
    _ => map (ppDiagCliLines (srcLinesArr src) path) errs

export
renderTripleWarnings : (String, String, List Diag) -> List String
renderTripleWarnings (path, src, diags) =
  let ws = filter diagIsWarn diags
  match ws
    [] => []
    _ => map (ppDiagCliLines (srcLinesArr src) path) ws

-- For the run/build multi-module gates, whose SOUNDNESS predicate stays the
-- looser `hadTypeErrors`: once that gate has already fired, render the residual —
-- the graph-end drain's own diagnostics, which the per-module lists do not carry
-- (they close before the drain runs) — falling back to the generic deflection only
-- if the residual carries nothing (never leaves the user with exit 1 and no text).
--
-- #1813: the None arm must NOT send the user to `medaka check`.  It fires EXACTLY
-- when the per-module diagnostics this elaboration produced were empty while the
-- same elaboration armed `hadTypeErrors` — i.e. precisely the #1812 divergence,
-- where `medaka check` on this program exits 0 and reports success.  Text reading
-- "Run `medaka check` for details" names the one command guaranteed to
-- confirm the wrong thing.  #2544 (M4): the residual IS reachable — `elaborateModules`
-- returns every diagnostic the elaboration left standing, each with its own `Loc` —
-- so this renders it located, through the same face `check` uses.
--
-- The `analyzeProject` re-run this used to prefer over the residual is gone with the
-- second typecheck it belonged to: the per-module errors the caller already rendered
-- ARE that pass's output, and they were empty on every path that reaches here.
export
residualOrGeneric : List (String, String) ->
  String ->
  List (String, TcDiag) ->
  <IO> String
residualOrGeneric pathMap target residual = match renderTcDiags pathMap residual
  [] =>
    "error: type error in "
      ++ target
      ++ " detected during elaboration; no located diagnostic is available for it"
  rendered => joinNl rendered

export
diagIsWarn : Diag -> Bool
diagIsWarn d = not (diagIsError d)

-- ── the ONE typecheck warning `run`/`build` surface (F-3d, #614/#311) ───────
-- READ THIS BEFORE WIDENING IT TO `diagIsWarn`.  That was tried, on the reasoning
-- that `run`/`build` "should show the same warnings `check` does", and it is wrong on
-- three counts, each measured:
--
--  (1) IT IS NOT THE ACCEPTANCE CRITERION.  F-3d's criterion is "nothing that was
--      LOUD goes silent".  The only diagnostic that was loud on `run`/`build` before
--      F-3d is the coherence reject F-3d demoted.  Every other warning on the
--      `matchWarnings` channel was ALREADY invisible on those verbs and stays exactly
--      as it was — not a regression, and not this change's to fix.
--  (2) SPEW.  The channel is populated over the whole module graph.  The
--      exhaustiveness oracle reads the constructors each module can name (#1185), and
--      on the compiler's own graph (`check --json compiler/driver/medaka_cli.mdk`) the
--      channel carries 8 `W-NONEXHAUSTIVE-CLAUSES` and 2 `W-NONEXHAUSTIVE`, each
--      hand-graded genuine.  Surfacing them on every `build` is a decision about those
--      findings, not a cleanup, and this allowlist stays as it is until one is made.
--  (3) PERF.  Surfacing the channel means RENDERING it, and rendering a located
--      diagnostic materialises the containing file's lines (`ppDiagCliSrc` →
--      `srcLinesArr`) — a cost paid per file whose channel is non-empty.
--      Interleaved A/B on a quiet box: multi-module `check` 16.0–17.1 s → 38.9–40.6 s
--      with byte-identical stdout.  Narrowing to one code removes the render, which
--      fixes that at its cause rather than optimising around it.
--
-- So: exactly the demoted code, nothing else.  Widening this predicate is a decision
-- about which verb is the diagnostic one, not a cleanup.
export
coherenceWarnCode : DiagCode
coherenceWarnCode = WIncomparableImpls

-- These three warning codes are on the allowlist because they satisfy three
-- measurements: (1) oracle properties and false-positive rates are bounded,
-- (2) occurrence frequency is bounded (not graph-wide), and (3) render cost
-- is bounded by collision/site count, not module-graph size. This list is
-- not a place to park codes; every addition owes the same three measurements.
-- The single-file and single-module arms of `run` and `build` bypass this
-- allowlist entirely via `allWarnTriples`, matching the single-file arm's
-- behavior in `checkRoute`. This split is deliberate: the three measurement
-- properties above are properties of the module graph and do not reach a
-- single-file program.
export
runBuildWarnCodes : List DiagCode
runBuildWarnCodes = [
  coherenceWarnCode,
  WPreludeMethodShadow,
  WImportMethodShadow,
]

export
isCoherenceWarn : Diag -> Bool
isCoherenceWarn (Diag SevWarning (Coded c) _ _ _ _) = elem c runBuildWarnCodes
isCoherenceWarn _ = False

-- The exit code the emit driver uses when what it wrote to stderr is a LOCATED
-- DIAGNOSTIC rather than a backend failure.  `medaka build`'s parent forwards
-- that stderr verbatim instead of wrapping it in "emitter failed compiling …",
-- so a type error reads exactly as `medaka check` prints it; every other
-- non-zero code keeps the preamble, which is what names the emitter for a real
-- backend crash.  Never reaches a user: the parent reports 1 either way, per
-- docs/ops/CLI-CONFORMANCE.md's two-code rule.
export
emitDiagExitCode : Int
emitDiagExitCode = 3

-- The Wasm emitter's physical-symbol defects (backend/wasm_symbols.mdk) as
-- diagnostics, each at the binding whose emission found it.  The code leads the
-- message because the text renderers print none.  [file] names the program for
-- an origin parsed without a file name.
export
renderSymbolDefects : String -> List SymbolDefect -> List String
renderSymbolDefects file ds =
  map
    (d =>
      let (at, diag) = symbolDefectDiag file d
      ppDiagCliLines (arrayFromList []) at diag)
    ds

-- the file a defect is reported in, and its diagnostic
symbolDefectDiag : String -> SymbolDefect -> (String, Diag)
symbolDefectDiag file d =
  physicalDiag file (defectOrigin d) (defectCode d) (defectMessage d)

-- [code] and [message] at [origin], in [file] when the origin names no file:
-- the file reported in, and the diagnostic
physicalDiag : String -> SymbolOrigin -> DiagCode -> String -> (String, Diag)
physicalDiag file origin code message =
  let (f, line, col) = originPosition origin
  let at = if f == "" then file else f
  let loc =
    if line > 0 && at /= "" then Some (Loc at line col line col) else None
  (at, mkDiag SevError code "[\{code}] \{message}" loc)

-- The emit driver's refusal of a module with physical-symbol defects: their
-- diagnostics on stderr, each with its source line, under the code that tells
-- `medaka build` they are diagnostics rather than a backend crash.  No module
-- text is written.
export
refuseSymbolDefects : String -> List SymbolDefect -> <IO> Unit
refuseSymbolDefects file ds = refusePhysical (map (symbolDefectDiag file) ds)

refusePhysical : List (String, Diag) -> <IO> Unit
refusePhysical diags =
  let _ =
    map
      ((at, diag) =>
        ePutStrLn (ppDiagCliLines (srcLinesArr (readFileSafe at)) at diag))
      diags
  stageExit emitDiagExitCode

-- The LLVM emitter's physical-symbol defects (backend/llvm_symbols.mdk), refused
-- as the Wasm emitter's are above.
export
refuseLlvmSymbolDefects : String -> List LlvmSymbols.SymbolDefect -> <IO> Unit
refuseLlvmSymbolDefects file ds =
  refusePhysical (map (llvmSymbolDefectDiag file) ds)

llvmSymbolDefectDiag : String -> LlvmSymbols.SymbolDefect -> (String, Diag)
llvmSymbolDefectDiag file d =
  physicalDiag
    file
    (LlvmSymbols.defectOrigin d)
    (LlvmSymbols.defectCode d)
    (LlvmSymbols.defectMessage d)

-- The emit driver's whole diagnostic face (ARCH §E), over the per-file buckets
-- `frontEnd` folded from ONE elaboration: the located per-file error lines and
-- the warning lines `build` prints, rendered exactly as `check` renders them.
-- `medaka build`'s parent process runs no typecheck of its own, so this is where
-- every post-resolve diagnostic of a build comes from.
--
-- The single/multi split is `runBuildWarnCodes`' (see its note): one module ⇒
-- the FULL warning set, a graph ⇒ the coherence allowlist, because the #1185
-- phantom is a property of the graph oracle and cannot reach one module.
-- The main-shape warning rides last, the order the CLI's two arms both used.
export
emitGateDiags : List (String, String, List Decl) ->
  List (String, List Diag) ->
  <IO> (List String, List String)
emitGateDiags modsWithPath buckets =
  let triples = map readDiagSrc buckets
  let warnSrc = match modsWithPath
    [_] => triples
    _ => map cohWarnsOfTriple triples
  (
    flatMap renderTripleErrors triples,
    flatMap renderTripleWarnings (warnSrc ++ mainShapeTriple modsWithPath),
  )

-- `main`'s shape warning as a renderable triple against the ENTRY module's own
-- file.  `mainShapeWarnings` reads `mainSchemeRef`, so the caller's elaboration
-- must already have run over this graph.
mainShapeTriple : List (String, String, List Decl) ->
  <IO> List (String, String, List Diag)
mainShapeTriple mods = match lastModTriple mods
  None => []
  Some (_, path, decls) => match mainShapeWarnings [] [] [] decls
    [] => []
    ws => [readDiagSrc (path, ws)]

lastModTriple : List (String, String, List Decl) ->
  Option (String, String, List Decl)
lastModTriple [] = None
lastModTriple [m] = Some m
lastModTriple (_ :: rest) = lastModTriple rest

-- Normalize an emitted diagnostic `file` path to project-root-relative (#298).
-- Target + project imports resolve relative to cwd and stay relative, but a
-- stdlib dependency resolves through the absolute stdlibDir root and would
-- otherwise be echoed verbatim — leaking the private worktree layout and making
-- the response internally inconsistent + goldens non-portable.  Stripping the
-- project-root prefix turns `<root>/stdlib/list.mdk` into `stdlib/list.mdk`,
-- matching the already-relative target + project imports (we run from the root,
-- so root == cwd).  A path without the prefix (already relative) passes through.
export
relDiagPath : String -> String -> String
relDiagPath root path =
  let pre = root ++ "/"
  if startsWith pre path then
    stringSlice (stringLength pre) (stringLength path) path
  else
    path

relDiagTriple : String ->
  (String, String, List Diag) ->
  (String, String, List Diag)
relDiagTriple root (path, src, diags) = (relDiagPath root path, src, diags)

-- Fold [extra] into the ONE (path, src, diags) triple whose path matches
-- [path] (the entry always has a bucket, even a clean one — `seedAll`), so an
-- extra diagnostic lands INSIDE the entry file's existing `diagnostics`
-- array instead of manufacturing a second, duplicate `{"file": ...}` entry for
-- the same path.  A no-match ([] extra, or a path `analyzeProject` never
-- bucketed) leaves the list untouched.  It folds the main-shape warning below
-- and the target refusal; `build --json`'s build-stage notes (#2243) are
-- folded the same way into the envelope the emitter child wrote
-- (`driver/front_gate.envelopeWithNotes`).
export
cjFoldIntoFile : String ->
  List Diag ->
  List (String, String, List Diag) ->
  List (String, String, List Diag)
cjFoldIntoFile _ [] triples = triples
cjFoldIntoFile _ _ [] = []
cjFoldIntoFile path extra ((p, s, ds) :: rest)
  | p == path = (p, s, ds ++ extra) :: rest
  | otherwise = (p, s, ds) :: cjFoldIntoFile path extra rest

-- ── main shape (0.1.0 audit #3; #1236; #2413) ──────────────────────────────
-- Every verb forces a zero-arg `main`; none applies one.  A zero-arg VALUE
-- `main` of a non-Unit type is printed through its `Display` impl
-- (driver/main_autoprint.mdk), so the only shape left to diagnose is a
-- FUNCTION `main` (`main () = …` / `main x = …`), visible on the raw
-- (pre-desugar) Decl as a non-empty param list with no type info needed:
--   * `check` reports it as a `W-MAIN-SHAPE` warning (`mainShapeWarnings`);
--   * `run` and `build` refuse it, and a program with no `main` at all, with
--     one error before anything is forced (`mainEntryError`).  `check` says
--     nothing about a missing `main`: a library module has none.
-- All of these are ordinary LOCATED Diags, so every caller (human CLI,
-- `check --json`, `run --json`, `medaka mcp`) renders/serializes them through
-- the same pipeline as every other diagnostic.

-- Find a top-level `main` DFunDef among a module's raw decls (skipping @attr
-- wrappers).  Returns its param list + body so callers can inspect arity and
-- locate the body's first ELoc span.
export
findMainFunDef : List Decl -> Option (List Pat, Expr)
-- This is the canonical copy; the twin is entries/playground_main.mdk's, which
-- keeps its own so the playground entry's module graph stays small enough to
-- compile to wasm (that file's header states the constraint and suppresses the
-- rule file-wide). Removing this one is not the fix — the entry's copy is.
-- lint-disable-next-line rule-duplicate-body
findMainFunDef [] = None
findMainFunDef ((DAttrib _ d) :: rest) = findMainFunDef (d :: rest)
findMainFunDef ((DFunDef _ "main" ps body _ _) :: _) = Some (ps, body)
findMainFunDef (_ :: rest) = findMainFunDef rest

-- Best-effort location: the first ELoc span walking the outermost expr spine
-- (mirrors frontend/desugar.mdk's private `exprLoc`, duplicated here so this
-- stays self-contained).  #1236: `exprLoc`/the old copy of this function only
-- descended through `EApp`, so a binop/unary/postfix-headed body (`main = 1 +
-- 2`, `main = -x`, `main = r.field`) fell through to `<unknown location>` even
-- though the wrapped leaf operand carries a real span two hops down — descend
-- through the same "binop/app/unary/postfix levels stay unwrapped" shapes the
-- parser documents (`parseAtom`'s comment, compiler/frontend/parser.mdk).
export
mainBodyLoc : Expr -> Option Loc
mainBodyLoc (ELoc l _) = Some l
mainBodyLoc (EApp f _) = mainBodyLoc f
mainBodyLoc (EBinOp _ a _ _) = mainBodyLoc a
mainBodyLoc (EUnOp _ a _) = mainBodyLoc a
mainBodyLoc (EFieldAccess a _ _) = mainBodyLoc a
mainBodyLoc (EIndex a _) = mainBodyLoc a
mainBodyLoc (ESlice a _ _ _) = mainBodyLoc a
mainBodyLoc _ = None

export
mainArityMsg : String
mainArityMsg =
  "`main` must be a value, not a function; write `main = ...`, not `main () = ...`"

export
mainMissingMsg : String
mainMissingMsg = "no `main` in this file; add `main = ...`"

-- The function shape (`main () = …` / `main x = …`) needs no type info, so it
-- is safe to call before (or without) any typecheck.
export
mainArityWarning : List Decl -> Option Diag
mainArityWarning decls = match findMainFunDef decls
  Some (_ :: _, body) =>
    Some (mkDiag SevWarning WMainShape mainArityMsg (mainBodyLoc body))
  _ => None

-- `check`'s main-shape report for the entry module.  The three leading
-- arguments are ignored: the check reads the raw entry decls alone.
export
mainShapeWarnings : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List Decl ->
  List Diag
mainShapeWarnings _ _ _ entryDecls = match mainArityWarning entryDecls
  Some d => [d]
  None => []

-- What `run` and `build` refuse before forcing anything: a function-shaped
-- `main` (forcing it would only build a closure) or no `main` at all.  The
-- codes are the ones the playground's pre-emit guard reports for the same two
-- programs (entries/playground_main.mdk, `mainShapeError`).
export
mainEntryError : List Decl -> Option Diag
mainEntryError decls = match findMainFunDef decls
  Some (_ :: _, body) =>
    Some (mkDiag SevError WMainShape mainArityMsg (mainBodyLoc body))
  Some ([], _) => None
  None => Some (missingMainDiag decls)

-- The program's `main` is the entry file's own top-level binding, so a `main`
-- the entry only imports is refused with a message that says so, located at the
-- import member.  Only the explicit member form (`import m.{main}`,
-- `import m.{f as main}`) is visible in the entry's decls; a wildcard import
-- that happens to bring a `main` gets the generic `mainMissingMsg`.
export
missingMainDiag : List Decl -> Diag
missingMainDiag decls = match importedMainMember decls
  Some (modName, m) =>
    mkDiag
      SevError
      WMainMissing
      (mainImportedMsg modName m)
      (Some (useMemberLoc m))
  None => mkDiag SevError WMainMissing mainMissingMsg None

mainImportedMsg : String -> UseMember -> String
mainImportedMsg modName (UseMember origin _ _ alias) =
  let written = match alias
    Some a => "\{origin} as \{a}"
    None => origin
  "`main` must be defined in the entry file, not imported by `import \{modName}.{\{written}}`; add `main = ...` to this file"

importedMainMember : List Decl -> Option (String, UseMember)
importedMainMember [] = None
importedMainMember ((DAttrib _ d) :: rest) = importedMainMember (d :: rest)
importedMainMember ((DUse _ (UseGroup ns members) _) :: rest) =
  match filterList (m => useMemberLocal m == "main") members
    m :: _ => Some (joinDot ns, m)
    [] => importedMainMember rest
importedMainMember (_ :: rest) = importedMainMember rest

useMemberLoc : UseMember -> Loc
useMemberLoc (UseMember _ _ l _) = l

-- The human face of `mainEntryError` for [file] with source [src].  A missing
-- `main` has no position to point at, so the file itself fills the slot a
-- `file:L:C:` would occupy rather than `<unknown location>`.
export
ppMainEntryError : String -> String -> Diag -> String
ppMainEntryError _ file (Diag sev _ msg None _ _) =
  "\{ppSeverity sev}: \{displayPath file}: \{msg}"
ppMainEntryError src file d = ppDiagCliSrc src file d

-- ── check → structured-diagnostics JSON ─────────────────────────────────────
--
-- Shared by `medaka check --json` (runCheckJsonCmd in medaka_cli) and the
-- `medaka mcp` medaka_check tool.  Both return (jsonString, hasError): the
-- {"files":[...]} JSON `medaka check --json` emits, plus whether any diagnostic
-- is a hard error (severity 1).  The caller decides what to do — the CLI prints +
-- `exit 1`; MCP wraps the string in a tool result and sets `isError` — so the
-- serializer + routing live in ONE place, byte-for-byte.

-- True iff the diagnostic is a hard error (severity 1), not a warning.
export
diagIsError : Diag -> Bool
diagIsError (Diag SevError _ _ _ _ _) = True
diagIsError _ = False

cjHasErrD : (String, List Diag) -> Bool
cjHasErrD (_, diags) = anyList diagIsError diags

-- readFile that yields "" on error (any real read failure surfaces as a diag).
-- Shared with medaka_cli's driver code (which imports it) so the two don't
-- diverge — the one canonical "read a target, tolerate a missing file" helper.
-- The stdin entry has no file: its text is the one the loader parsed.
export
readFileSafe : String -> <IO> String
readFileSafe path =
  match if path == stdinEntry then loadedSourceOf path else None
    Some src => src
    None => resultOr "" (readFile path)

-- The single located parse-error diagnostic, as the {"files":[...]} JSON string.
-- Uses the same serializer as other diagnostics, including typed edits.
export
cjParseErrJson : String -> String -> ParseError -> String
cjParseErrJson target src e =
  cjAllToJson [(target, src, [parseErrDiag target e])]

-- Single-module check → JSON.  Parse errors are detected FIRST; otherwise the
-- single-file located pipeline runs and its diags serialize via cjAllToJson.
-- Pure — NO import resolution — so it is exactly right for inline `source` (no
-- file on disk to resolve imports against) and for a no-import file.  `target` is
-- the value that lands in each diagnostic's `file` field (cjRangeOfLoc ignores the
-- filename inside each Loc), so an inline check can pass a stable synthetic name.
--
-- A `check --json` envelope, before it is serialized.  Nearly every shape is
-- the ordinary (file, source, diagnostics) triples `cjAllToJson` renders, and
-- `CjParts` also carries the ENTRY's path key — the value a caller needs to
-- fold diagnostics of its own into the right file's bucket, since the
-- multi-module arm relativizes paths.  The located parse-error envelope is
-- rendered as a complete envelope and always travels with
-- `hasErr = True`, which is why no caller has to fold into it.
public export data CheckJson =
  | CjRendered String
  | CjParts String (List (String, String, List Diag))

export
ppCheckJson : CheckJson -> String
ppCheckJson (CjRendered json) = json
ppCheckJson (CjParts _ triples) = cjAllToJson triples

export
checkJsonSingle : (List String -> <e> List (String, List String)) ->
  String ->
  Bool ->
  String ->
  String ->
  String ->
  String ->
  <e> (String, Bool)
checkJsonSingle exportsFor modName allowInternal rsrc csrc target src =
  let (cj, hasErr) =
    checkJsonSingleParts exportsFor modName allowInternal rsrc csrc target src
  (ppCheckJson cj, hasErr)

export
checkJsonSingleParts : (List String -> <e> List (String, List String)) ->
  String ->
  Bool ->
  String ->
  String ->
  String ->
  String ->
  <e> (CheckJson, Bool)
checkJsonSingleParts exportsFor modName allowInternal rsrc csrc target src =
  match parseResult src
    Err e => (CjRendered (cjParseErrJson target src e), True)
    Ok _ =>
      let front =
        fileFront exportsFor modName allowInternal rsrc csrc (parseLocated src)
      let diags = flatMap snd front.foDiags
      let hasErr = anyList diagIsError diags
      -- #1236: fold the main-shape warning (`main () = …` / `main = 1 + 2`) into
      -- the SAME envelope `check --json` already builds, instead of leaving it
      -- entirely absent from this channel. Only on a clean program (no type
      -- error already reported) — mirrors `checkRoute`'s human-CLI gating, and keeps
      -- the warning from contradicting the errors already reported for an ill-typed
      -- program.  (`mainShapeWarnings` itself is now free: it reads the `mainSchemeRef`
      -- the drive above already populated, rather than re-elaborating.)
      let mainWarns =
        if hasErr then
          []
        else
          let entryRaw = parseLocated src
          mainShapeWarnings [] [] [] entryRaw
      (CjParts target [(target, src, diags ++ mainWarns)], hasErr)

-- The single-module envelope over a module's whole diagnostic list: the
-- main-shape warning joins it only on a clean program, as in
-- `checkJsonSingleParts`.  `decls` are the entry's located decls, read after
-- the drive that judged `main`.
export
cjSingleParts : String -> String -> List Decl -> List Diag -> (CheckJson, Bool)
cjSingleParts target src decls diags =
  let hasErr = anyList diagIsError diags
  let mainWarns = if hasErr then [] else mainShapeWarnings [] [] [] decls
  (CjParts target [(target, src, diags ++ mainWarns)], hasErr)

-- File check → JSON.  Reads `target`, loads its graph once, then routes exactly
-- like runCheckJsonCmd: load failure → the entry's parse error if it has one, else
-- the loader's diag (bad import → R-MODULE-LOAD with the import span +
-- available-modules hint); otherwise one `frontEnd` run over the loaded program
-- (honouring the owning-root trust signal), enveloped per module count.
-- `stdlibDir` is the <root>/stdlib dir; roots are derived from the target's
-- directory + stdlibDir.
export
checkJsonFile : Bool ->
  String ->
  String ->
  String ->
  String ->
  <IO> (String, Bool)
checkJsonFile allowInternal rsrc csrc target stdlibDir =
  let (cj, hasErr, _) =
    checkJsonFileParts allowInternal rsrc csrc target stdlibDir
  (ppCheckJson cj, hasErr)

-- The same check, one step before serialization — see `CheckJson`.  `medaka
-- check --json` runs this rather than `checkJsonFile` so it can fold the
-- target refusal into the SAME `{"files":[…]}` envelope, judged from the drive
-- it hands back.
export
checkJsonFileParts : Bool ->
  String ->
  String ->
  String ->
  String ->
  <IO> (CheckJson, Bool, Option CheckDrive)
checkJsonFileParts allowInternal rsrc csrc target stdlibDir =
  let src = readFileSafe target
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  match loadProgramFilesLocatedE (_ => None) target roots
    Err le => (cjLoadFailure target src stdlibDir le, True, None)
    Ok modsWithPath =>
      let mods = map dropPathTriple modsWithPath
      -- #1362: one trust set guards every module count, as on human `check`.
      let trusted = projectTrustedMods target roots stdlibDir mods
      -- #2072: the FFI-stamp discriminator (stdlib-root ownership, NO
      -- `allow-internal` opt-out) — see `stdlibOwnedMods` in loader.mdk for
      -- why it is not `trusted` above.
      let (flatStdlib, ownedStdlib) =
        stdlibOwnership target roots stdlibDir mods
      let program = match modsWithPath
        [m] => FrontFile m
        _ => FrontGraph modsWithPath (desugaredModPairs modsWithPath)
      let chainKey = chainKeyOf target roots
      let front = frontEnd (stdlibExportsReader stdlibDir) (checkDriveReport
        chainKey) FrontInput {
        fiInputs = driveInputsFor !selectedProfile flatStdlib ownedStdlib,
        fiAllowInternal = allowInternal,
        fiTrusted = trusted,
        fiRuntimeSrc = rsrc,
        fiCoreSrc = csrc,
        fiPolicy = DriveUnblocked chainKey NoSteps,
        fiProgram = program,
      }
      let (cj, hasErr) = match modsWithPath
        [(_, _, decls)] =>
          cjSingleParts target src decls (flatMap snd front.foDiags)
        _ => cjGraphParts target stdlibDir mods front.foDiags
      (cj, hasErr, front.foDriven)

-- An entry the loader could not load: its own parse error if it has one, else
-- the loader's error.  An unparsable entry is reported against the spelling the
-- caller gave, not the path the loader minted, so the entry's own parse is
-- checked first.
export
cjLoadFailure : String -> String -> String -> LoadError -> <IO> CheckJson
cjLoadFailure target src stdlibDir le = match parseResult src
  Err e => CjRendered (cjParseErrJson target src e)
  Ok _ => fst (checkJsonLoadErr target src stdlibDir le)

-- The multi-module envelope over the per-file diagnostic buckets of a loaded
-- graph, its paths relative to the install root.  #1236: the main-shape warning
-- joins it only on a clean project, read off the entry (the last loaded
-- module), whose located decls give it the `Loc` every other diagnostic on that
-- file carries; the drive that produced `results` must have run.
export
cjGraphParts : String ->
  String ->
  List (String, List Decl) ->
  List (String, List Diag) ->
  <IO> (CheckJson, Bool)
cjGraphParts target stdlibDir mods results =
  let hasErr = anyList cjHasErrD results
  let mainWarns = match (hasErr, lastDecls mods)
    (False, Some edecls) => mainShapeWarnings [] [] [] edecls
    _ => []
  let triples = map readDiagSrc results
  let root = dirOf stdlibDir
  let relTriples = map (relDiagTriple root) triples
  let entryKey = relDiagPath root target
  (CjParts entryKey (cjFoldIntoFile entryKey mainWarns relTriples), hasErr)

-- The entry of a loaded graph is its last module.
lastDecls : List (String, List Decl) -> Option (List Decl)
lastDecls [] = None
lastDecls [(_, ds)] = Some ds
lastDecls (_ :: rest) = lastDecls rest

-- The loader's `Err` rendered as a `check --json` envelope, for an entry whose
-- own parse was already found clean.  #100: a parse/lex error in an IMPORTED
-- module serializes exactly like one in the entry — same `P-*`/`L-*` code, same
-- real range — only attributed to the MODULE's file and rendered against the
-- module's OWN source.
checkJsonLoadErr : String ->
  String ->
  String ->
  LoadError ->
  <IO> (CheckJson, Bool)
checkJsonLoadErr _ _ _ (LoadParseFailed mpath msrc pe) =
  (CjRendered (cjParseErrJson mpath msrc pe), True)
checkJsonLoadErr target src _ (LoadCycle cmsg cpath csite) = match csite
  Some (csrc, cloc) => (
    CjParts target [
      (
        cpath,
        csrc,
        [Diag SevError (Coded RModuleLoad) cmsg (Some cloc) None None],
      ),
    ],
    True,
  )
  None => (
    CjParts target [
      (target, src, [Diag SevError (Coded RModuleLoad) cmsg None None None]),
    ],
    True,
  )
checkJsonLoadErr target src stdlibDir (LoadMsg lmsg) =
  let mloc = match unknownModuleIdOf lmsg
    None => None
    Some mid => findImportLoc mid (parseLocated src)
  let mhelp = match unknownModuleIdOf lmsg
    None => None
    Some _ => match availableModulesText stdlibDir
      "" => None
      txt => Some txt
  let jmsg =
    lmsg
      ++ (match unknownModuleIdOf lmsg
        None => ""
        Some _ => availableModulesHint stdlibDir)
  (
    CjParts target [
      (target, src, [Diag SevError (Coded RModuleLoad) jmsg mloc mhelp None]),
    ],
    True,
  )
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "executedMainInputs" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "Ty" false) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorDiagnostic" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "checkDerives" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "ResError" false) (mem "resolveProgram" false) (mem "resolveProgramG2" false) (mem "internalGuardFor" false) (mem "ppResError" false) (mem "resErrorLoc" false) (mem "resErrorCode" false) (mem "resErrorDidYouMean" false) (mem "resErrorIsPrivateName" false) (mem "resolveModuleG" false) (mem "resolveModulesErrorsByFile" false) (mem "importedCtorDeclsStep" false) (mem "withStdlibExports" false) (mem "hintableUnboundNames" false) (mem "exportedValueNames" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" false) (mem "coreExports" false) (mem "useModuleIds" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omKeys" false) (mem "omSize" false) (mem "omRestrict" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "checkGuardExhaustivenessWith" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "preludeStandaloneShadows" false) (mem "preludeStandaloneSet" false) (mem "preludeStandaloneShadowsWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "pubSchemes" false) (mem "TcReport" true) (mem "PartialAnalysis" true) (mem "partialAnalysis" false) (mem "noEntryTables" false) (mem "publishedEntrySchemes" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" true) (mem "chainFullKey" false) (mem "checkModulesChainReportFor" false) (mem "checkModulesEntryFullReportK" false) (mem "checkModulesPartialK" false) (mem "driveInputsFor" false) (mem "dropModSchemes" false) (mem "entrySplit" false) (mem "ModDiags" false) (mem "schemeLines" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "DriveOutputs" true) (mem "emptyDriveOutputs" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "retainModuleInterfaces" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "loadProgramFilesLocatedCached" false) (mem "loadProgramFilesLocatedCachedE" false) (mem "loadProgramFilesLocatedCachedSourcesE" false) (mem "loadedSourceOf" false) (mem "stdinEntry" false) (mem "parseCachedLocated" false) (mem "loadProgramFilesLocatedE" false) (mem "dropPathTriple" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false) (mem "entrySearchRoots" false) (mem "findImportLoc" false) (mem "unknownModuleIdOf" false) (mem "availableModulesText" false) (mem "availableModulesHint" false) (mem "availableModuleIds" false) (mem "fileOfModuleId" false) (mem "modIdToPath" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "valueMainCandidate" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "contains" false) (mem "joinDot" false) (mem "isSome" false) (mem "lenKey" false) (mem "reverseL" false))))
(DUse false (UseGroup ("support" "timer") ((mem "takePerfSink" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "SymbolDefect" false) (mem "defectCode" false) (mem "defectMessage" false) (mem "defectOrigin" false))))
(DUse false (UseAlias ("backend" "llvm_symbols") "LlvmSymbols"))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" false) (mem "originPosition" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "importedStandaloneShadows" false) (mem "importedStandaloneShadowsIn" false))))
(DUse true (UseGroup ("driver" "diagnostic_value") ((mem "Severity" true) (mem "Fix" true) (mem "Diag" true) (mem "DiagId" true) (mem "mkDiag" false) (mem "diagIdText" false) (mem "diagIdKind" false) (mem "diagIdIsSyntax" false))))
(DTypeSig false "didYouMeanFix" (TyFun (TyCon "ResError") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "didYouMeanFix" ((PVar "e") (PVar "bad") (PVar "sug") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EBinOp "&&" (EApp (EVar "resErrorIsPrivateName") (EVar "e")) (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "sl")) (EBinOp "==" (EVar "ec") (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))) (EVar "sug")))))
(DTypeSig true "resErrorHelpFix" (TyFun (TyCon "ResError") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "resErrorHelpFix" ((PVar "e")) (EMatch (EApp (EVar "resErrorDidYouMean") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "bad") (PVar "sug"))) () (EBlock (DoLet false false (PVar "help") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean `")) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "`?"))))) (DoLet false false (PVar "fix") (EMatch (EApp (EVar "resErrorLoc") (EVar "e")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EApp (EApp (EVar "didYouMeanFix") (EVar "e")) (EVar "bad")) (EVar "sug")) (EVar "l"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))))
(DTypeSig true "diagOfResError" (TyFun (TyCon "ResError") (TyCon "Diag")))
(DFunDef false "diagOfResError" ((PVar "e")) (EBlock (DoLet false false (PTuple (PVar "help") (PVar "fix")) (EApp (EVar "resErrorHelpFix") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EApp (EVar "resErrorCode") (EVar "e")))) (EApp (EVar "ppResError") (EVar "e"))) (EApp (EVar "resErrorLoc") (EVar "e"))) (EVar "help")) (EVar "fix")))))
(DTypeSig true "hintResErrors" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "hintResErrors" ((PVar "exportsFor") (PVar "errs")) (EMatch (EApp (EVar "hintableUnboundNames") (EVar "errs")) (arm (PList) () (EVar "errs")) (arm (PVar "names") () (EApp (EApp (EVar "withStdlibExports") (EApp (EVar "exportsFor") (EVar "names"))) (EVar "errs")))))
(DTypeSig true "noStdlibExports" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "noStdlibExports" (PWild) (EListLit))
(DTypeSig true "stdlibExportsReader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "stdlibExportsReader" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "exportsAmong") (EVar "names")) (EApp (EApp (EApp (EVar "sourcesMentioning") (EVar "stdlibDir")) (EApp (EVar "availableModuleIds") (EVar "stdlibDir"))) (EVar "names"))))
(DTypeSig true "sourcesMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "sourcesMentioning" (PWild PWild (PList)) (EListLit))
(DFunDef false "sourcesMentioning" ((PVar "root") (PVar "ids") (PVar "names")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "sourceMentioning") (EVar "root")) (EVar "names"))) (EVar "ids")))
(DTypeSig false "sourceMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "sourceMentioning" ((PVar "root") (PVar "names") (PVar "mid")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "fileOfModuleId") (EVar "root")) (EVar "mid"))) (arm (PCon "Ok" (PVar "src")) () (EIf (EApp (EApp (EVar "any") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "n")) (EVar "src"))))) (EVar "names")) (EListLit (ETuple (EVar "mid") (EVar "src"))) (EListLit))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig true "exportsAmong" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "exportsAmong" ((PVar "names") (PVar "srcs")) (EApp (EApp (EVar "flatMap") (EApp (EVar "moduleExportsAmong") (EVar "names"))) (EVar "srcs")))
(DTypeSig false "moduleExportsAmong" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "moduleExportsAmong" ((PVar "names") (PTuple (PVar "mid") (PVar "src"))) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "names")))) (EApp (EVar "exportedValueNames") (EVar "decls"))) (arm (PList) () (EListLit)) (arm (PVar "found") () (EListLit (ETuple (EVar "mid") (EVar "found"))))))))
(DTypeSig true "diagOfTypeError" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeError" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "code"))) (EVar "msg")) (EVar "loc")) (EVar "help")) (EApp (EApp (EVar "map") (EVar "fixOfLocRepl")) (EVar "fix"))))
(DTypeSig false "fixOfLocRepl" (TyFun (TyTuple (TyCon "Loc") (TyCon "String")) (TyCon "Fix")))
(DFunDef false "fixOfLocRepl" ((PTuple (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Fix") (EVar "l")) (EVar "r")))
(DTypeSig false "diagOfTypeWarning" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeWarning" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "w") (PVar "help") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "code"))) (EApp (EVar "stripWarnPrefix") (EVar "w"))) (EVar "loc")) (EVar "help")) (EVar "None")))
(DTypeSig true "diagKind" (TyFun (TyCon "Severity") (TyFun (TyCon "DiagId") (TyCon "String"))))
(DFunDef false "diagKind" ((PCon "SevError") (PVar "code")) (EApp (EVar "diagIdKind") (EVar "code")))
(DFunDef false "diagKind" ((PCon "SevWarning") (PVar "code")) (EIf (EBinOp "==" (EApp (EVar "diagIdKind") (EVar "code")) (ELit (LString "lint"))) (ELit (LString "lint")) (EIf (EVar "otherwise") (ELit (LString "warning")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ppSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "ppSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "ppSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig true "ppDiag" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiag" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "ppDiagCli" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "ppDiagCli" ((PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliSrc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliSrc" ((PVar "src") (PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliLines" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliLines" ((PVar "srcLines") (PVar "file") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "displayPath") (EVar "file")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "nthLineArr") (EVar "srcLines")) (EVar "sl")) (arm (PCon "None") () (EVar "header")) (arm (PCon "Some" (PVar "lineText")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "header"))) (ELit (LString "\n  |\n"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "lineText"))) (ELit (LString "\n  | "))) (EApp (EVar "display") (EApp (EVar "spaces") (EVar "sc")))) (ELit (LString "^"))))))))
(DFunDef false "ppDiagCliLines" (PWild PWild (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": <unknown location>: "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "renderTcDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renderTcDiags" ((PVar "pathMap") (PVar "ds")) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "ds")) (EListLit)))
(DTypeSig false "renderTcDiagsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "renderTcDiagsGo" (PWild (PList) PWild) (EListLit))
(DFunDef false "renderTcDiagsGo" ((PVar "pathMap") (PCons (PTuple (PVar "mid") (PVar "d")) (PVar "rest")) (PVar "cache")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "pathMap")) (arm (PCon "Some" (PVar "file")) () (EBlock (DoLet false false (PTuple (PVar "lines") (PVar "cache2")) (EApp (EApp (EVar "srcLinesCached") (EVar "file")) (EVar "cache"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "file")) (EApp (EVar "diagOfTypeError") (EVar "d"))) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "rest")) (EVar "cache2")))))) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "++" (EBinOp "++" (ELit (LString "(module ")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString ")")))) (EApp (EVar "diagOfTypeError") (EVar "d"))) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "rest")) (EVar "cache"))))))
(DTypeSig false "srcLinesCached" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))))))))
(DFunDef false "srcLinesCached" ((PVar "file") (PVar "cache")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "file")) (EVar "cache")) (arm (PCon "Some" (PVar "ls")) () (ETuple (EVar "ls") (EVar "cache"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ls") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (ETuple (EVar "ls") (EBinOp "::" (ETuple (EVar "file") (EVar "ls")) (EVar "cache"))))))))
(DTypeSig true "hintResErrorPairs" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "hintResErrorPairs" ((PVar "exportsFor") (PVar "pairs")) (EMatch (EApp (EVar "hintableUnboundNames") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "pairs"))) (arm (PList) () (EVar "pairs")) (arm (PVar "names") () (EBlock (DoLet false false (PVar "exports") (EApp (EVar "exportsFor") (EVar "names"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "file") (PVar "errs"))) (ETuple (EVar "file") (EApp (EApp (EVar "withStdlibExports") (EVar "exports")) (EVar "errs"))))) (EVar "pairs")))))))
(DTypeSig true "ppResolveErrorsByFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ppResolveErrorsByFile" ((PVar "pairs")) (EApp (EVar "ppDiagBuckets") (EApp (EApp (EVar "map") (EVar "resolveBucket")) (EVar "pairs"))))
(DTypeSig true "ppDiagBuckets" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ppDiagBuckets" ((PVar "buckets")) (EApp (EVar "joinNl") (EApp (EVar "ppDiagBucketLines") (EVar "buckets"))))
(DTypeSig false "ppDiagBucketLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ppDiagBucketLines" ((PList)) (EListLit))
(DFunDef false "ppDiagBucketLines" ((PCons (PTuple PWild (PList)) (PVar "rest"))) (EApp (EVar "ppDiagBucketLines") (EVar "rest")))
(DFunDef false "ppDiagBucketLines" ((PCons (PTuple (PVar "file") (PVar "diags")) (PVar "rest"))) (EBlock (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "file"))) (EVar "diags")) (EApp (EVar "ppDiagBucketLines") (EVar "rest"))))))
(DTypeSig true "displayPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "displayPath" ((PVar "path")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EIf (EVar "otherwise") (EVar "path") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LChar " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "srcLinesArr" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "String"))))
(DFunDef false "srcLinesArr" ((PVar "src")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs")))))))
(DTypeSig false "srcLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "srcLinesGo" ((PVar "cs") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "charSlice") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "charSlice") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charSlice" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "j"))) (EVar "cs"))))))
(DTypeSig false "nthLineArr" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nthLineArr" ((PVar "srcLines") (PVar "n")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 1))) (EBinOp ">" (EVar "n") (EApp (EVar "arrayLength") (EVar "srcLines")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "srcLines"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "analyze" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyze" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "noStdlibExports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parse") (EVar "progSrc"))))
(DTypeSig true "analyzeLocated" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "analyzeLocated" ((PVar "exportsFor") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exportsFor")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))))
(DData Private "SurfaceAnalysis" () ((variant "SurfaceAnalysis" (ConNamed (field "surfaceDiags" (TyApp (TyCon "List") (TyCon "Diag"))) (field "resolveClean" (TyCon "Bool")) (field "surfaceDesugared" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfaceRuntimeP" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfaceCoreP" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfacePreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))) ())
(DTypeSig true "analyzeFrom" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "analyzeFrom" ((PVar "exportsFor") (PVar "modName") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EVar "exportsFor")) (EVar "modName")) (EVar "True")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "raw")) "foDiags")))
(DTypeSig true "fileFront" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyCon "Unit"))))))))))
(DFunDef false "fileFront" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw")) (EApp (EApp (EApp (EVar "frontEnd") (EVar "exportsFor")) (ELam ((PVar "d")) (EApp (EVar "unkept") (EApp (EApp (EApp (EVar "checkReportOf") (EVar "NoSteps")) (ELit (LString ""))) (EVar "d"))))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EListLit)) (fa "fiRuntimeSrc" (EVar "runtimeSrc")) (fa "fiCoreSrc" (EVar "coreSrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EApp (EVar "FrontFile") (ETuple (EVar "modName") (ELit (LString "")) (EVar "raw"))))))))
(DData Public "CheckDrive" () ((variant "CheckDrive" (ConNamed (field "cdEntrySchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "cdCoreSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "cdOutputs" (TyCon "DriveOutputs")) (field "cdMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "cdPaths" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "CheckDump" () ((variant "CheckDump" (ConNamed (field "cdLines" (TyApp (TyCon "List") (TyCon "String"))) (field "cdDrive" (TyCon "CheckDrive"))))) ())
(DTypeSig true "graphCheckDrive" (TyFun (TyCon "TcReport") (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "CheckDrive"))))))
(DFunDef false "graphCheckDrive" ((PVar "r") (PVar "outputs") (PVar "modPairs") (PVar "paths")) (ERecordCreate "CheckDrive" ((fa "cdEntrySchemes" (EApp (EVar "pubSchemes") (EApp (EVar "publishedEntrySchemes") (EApp (EApp (EVar "map") (EVar "modOwnSchemes")) (EFieldAccess (EVar "r") "trDiagnostics"))))) (fa "cdCoreSchemes" (EApp (EVar "pubSchemes") (EFieldAccess (EFieldAccess (EVar "r") "trPartial") "paCore"))) (fa "cdOutputs" (EVar "outputs")) (fa "cdMods" (EVar "modPairs")) (fa "cdPaths" (EVar "paths")))))
(DTypeSig false "modOwnSchemes" (TyFun (TyCon "ModDiags") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "modOwnSchemes" ((PTuple (PVar "mid") (PTuple (PVar "schemes") PWild PWild))) (ETuple (EVar "mid") (EVar "schemes")))
(DTypeSig true "checkReportOf" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "String") (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs"))))))
(DFunDef false "checkReportOf" ((PVar "steps") (PVar "chainKey") (PVar "original")) (EBlock (DoLet false false (PVar "d") (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "original") "fdInputs") "diProfileName") (ELit (LString ""))) (EVar "original") (ERecordUpdate (EVar "original") ((fa "fdInputs" (EApp (EApp (EApp (EVar "executedMainInputs") (EFieldAccess (EVar "original") "fdInputs")) (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (ELit (LString "runAsyncMain")))))) (EFieldAccess (EVar "original") "fdPairs"))))))) (DoExpr (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList (PVar "up"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EFieldAccess (EVar "d") "fdCore")) (EListLit (EVar "up")))) (EFieldAccess (EVar "d") "fdPreludeKey")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EListLit (EVar "up")))) (arm (PTuple (PVar "mods") (PVar "pairs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkChainReport") (EVar "steps")) (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EFieldAccess (EVar "d") "fdCore")) (EVar "pairs"))) (EFieldAccess (EVar "d") "fdPreludeKey")) (EVar "chainKey")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EVar "mods")) (EVar "pairs")))))))
(DTypeSig true "checkDriveReport" (TyFun (TyCon "String") (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "CheckDrive") (TyCon "TcReport") (TyCon "DriveOutputs")))))
(DFunDef false "checkDriveReport" ((PVar "chainKey") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "r") (PVar "outputs")) (EApp (EApp (EApp (EVar "checkReportOf") (EVar "NoSteps")) (EVar "chainKey")) (EVar "d"))) (DoLet false false (PVar "drive") (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList PWild)) () (EBlock (DoLet false false (PTuple (PVar "coreSchemes") (PVar "schemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (ERecordCreate "CheckDrive" ((fa "cdEntrySchemes" (EApp (EVar "pubSchemes") (EVar "schemes"))) (fa "cdCoreSchemes" (EApp (EVar "pubSchemes") (EVar "coreSchemes"))) (fa "cdOutputs" (EVar "outputs")) (fa "cdMods" (EFieldAccess (EVar "d") "fdPairs")) (fa "cdPaths" (EListLit))))))) (arm (PTuple (PVar "mods") (PVar "pairs")) () (EApp (EApp (EApp (EApp (EVar "graphCheckDrive") (EVar "r")) (EVar "outputs")) (EVar "pairs")) (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "mods")))))) (DoExpr (ETuple (EVar "drive") (EVar "r") (EVar "outputs")))))
(DTypeSig true "checkFrontDrive" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "CheckDump") (TyCon "TcReport") (TyCon "DriveOutputs"))))))
(DFunDef false "checkFrontDrive" ((PVar "target") (PVar "roots") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "drive") (PVar "r") (PVar "outputs")) (EApp (EApp (EVar "checkDriveReport") (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "d"))) (DoLet false false (PVar "lines") (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList PWild)) () (EBlock (DoLet false false (PTuple PWild (PVar "schemes") PWild (PVar "tcWarns")) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "tcWarns")))))) (arm PWild () (EListLit)))) (DoExpr (ETuple (ERecordCreate "CheckDump" ((fa "cdLines" (EVar "lines")) (fa "cdDrive" (EVar "drive")))) (EVar "r") (EVar "outputs")))))
(DTypeSig false "analyzeSurface" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyCon "SurfaceAnalysis")))))))))
(DFunDef false "analyzeSurface" ((PVar "exportsFor") (PVar "modName") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "shadowWarns") (EApp (EApp (EVar "preludeStandaloneShadows") (EBinOp "++" (EVar "runtimeP") (EVar "coreP"))) (EVar "desugared"))) (DoLet false false (PVar "importShadowWarns") (EApp (EApp (EApp (EVar "importedStandaloneShadowsIn") (EVar "omEmpty")) (EListLit)) (EVar "desugared"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EVar "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw")))) (DoLet false false (PVar "resErrs") (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared")))) (DoLet false false (PVar "resDiags") (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EVar "resErrs"))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EVar "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoLet false false (PVar "shadowDiags") (EApp (EApp (EVar "map") (EApp (EVar "preludeShadowWarnToDiag") (EVar "modName"))) (EVar "shadowWarns"))) (DoLet false false (PVar "importShadowDiags") (EApp (EApp (EVar "map") (EApp (EVar "importShadowWarnToDiag") (EVar "modName"))) (EVar "importShadowWarns"))) (DoLet false false (PVar "clean") (EMatch (EVar "resErrs") (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (DoExpr (ERecordCreate "SurfaceAnalysis" ((fa "surfaceDiags" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "shadowDiags")) (EVar "importShadowDiags")) (EVar "resDiags"))) (fa "resolveClean" (EVar "clean")) (fa "surfaceDesugared" (EVar "desugared")) (fa "surfaceRuntimeP" (EVar "runtimeP")) (fa "surfaceCoreP" (EVar "coreP")) (fa "surfacePreludeKey" (EVar "preludeKey")))))))
(DTypeSig true "surfaceErrors" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "surfaceErrors" ((PVar "exportsFor") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared") (PVar "internalGuard")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw"))) (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))))))
(DTypeSig false "tcHalfOfPerModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "tcHalfOfPerModule" ((PVar "perMod")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "diagOfTypeError")) (EApp (EApp (EVar "flatMap") (EVar "perModuleErrs")) (EVar "perMod"))) (EApp (EApp (EVar "map") (EVar "diagOfTypeWarning")) (EApp (EApp (EVar "flatMap") (EVar "perModuleWarns")) (EVar "perMod")))))
(DTypeSig false "perModuleErrs" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "perModuleErrs" ((PTuple PWild (PTuple (PVar "errs") PWild))) (EVar "errs"))
(DTypeSig false "perModuleWarns" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "perModuleWarns" ((PTuple PWild (PTuple PWild (PVar "warns")))) (EVar "warns"))
(DData Public "FrontProgram" () ((variant "FrontFile" (ConPos (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (variant "FrontGraph" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))) ())
(DData Public "FrontPolicy" () ((variant "NeverDriveRejected" (ConPos)) (variant "DriveUnblocked" (ConPos (TyCon "String") (TyCon "ChainSteps"))) (variant "ResolvedByGate" (ConPos))) ())
(DData Public "ChainSteps" () ((variant "RecordSteps" (ConPos)) (variant "NoSteps" (ConPos))) ())
(DData Public "FrontInput" () ((variant "FrontInput" (ConNamed (field "fiInputs" (TyCon "DriveInputs")) (field "fiAllowInternal" (TyCon "Bool")) (field "fiTrusted" (TyApp (TyCon "List") (TyCon "String"))) (field "fiRuntimeSrc" (TyCon "String")) (field "fiCoreSrc" (TyCon "String")) (field "fiPolicy" (TyCon "FrontPolicy")) (field "fiProgram" (TyCon "FrontProgram"))))) ())
(DData Public "FrontDriveIn" () ((variant "FrontDriveIn" (ConNamed (field "fdInputs" (TyCon "DriveInputs")) (field "fdPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "fdRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fdPairs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "fdMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "FrontOutput" ("a") ((variant "FrontOutput" (ConNamed (field "foDiags" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))) (field "foReport" (TyCon "TcReport")) (field "foOutputs" (TyCon "DriveOutputs")) (field "foDriven" (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DTypeSig false "unkept" (TyFun (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyTuple (TyCon "Unit") (TyCon "TcReport") (TyCon "DriveOutputs"))))
(DFunDef false "unkept" ((PTuple (PVar "r") (PVar "o"))) (ETuple (ELit LUnit) (EVar "r") (EVar "o")))
(DTypeSig true "frontEnd" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "FrontDriveIn") (TyEffect () (Some "e") (TyTuple (TyVar "a") (TyCon "TcReport") (TyCon "DriveOutputs")))) (TyFun (TyCon "FrontInput") (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyVar "a")))))))
(DFunDef false "frontEnd" ((PVar "exportsFor") (PVar "drive") (PVar "fi")) (EMatch (EFieldAccess (EVar "fi") "fiProgram") (arm (PCon "FrontFile" (PTuple (PVar "mid") (PVar "path") (PVar "raw"))) () (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeSurface") (EVar "exportsFor")) (EVar "mid")) (EFieldAccess (EVar "fi") "fiRuntimeSrc")) (EFieldAccess (EVar "fi") "fiCoreSrc")) (EVar "raw")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EFieldAccess (EVar "fi") "fiAllowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EFieldAccess (EVar "fi") "fiTrusted")))))) (DoExpr (EMatch (EFieldAccess (EVar "s") "resolveClean") (arm (PCon "False") () (EApp (EVar "undrivenOutput") (EListLit (ETuple (EVar "path") (EFieldAccess (EVar "s") "surfaceDiags"))))) (arm (PCon "True") () (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "r") (PVar "outputs")) (EApp (EVar "drive") (ERecordCreate "FrontDriveIn" ((fa "fdInputs" (EFieldAccess (EVar "fi") "fiInputs")) (fa "fdPreludeKey" (EFieldAccess (EVar "s") "surfacePreludeKey")) (fa "fdRuntime" (EFieldAccess (EVar "s") "surfaceRuntimeP")) (fa "fdCore" (EFieldAccess (EVar "s") "surfaceCoreP")) (fa "fdPairs" (EListLit (ETuple (ELit (LString "__user__")) (EFieldAccess (EVar "s") "surfaceDesugared")))) (fa "fdMods" (EListLit)))))) (DoLet false false (PVar "tcHalf") (EApp (EVar "tcHalfOfPerModule") (EApp (EApp (EVar "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "r") "trDiagnostics")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "drivenOutput") (EListLit (ETuple (EVar "path") (EBinOp "++" (EFieldAccess (EVar "s") "surfaceDiags") (EVar "tcHalf"))))) (EVar "r")) (EVar "outputs")) (EVar "kept"))))))))) (arm (PCon "FrontGraph" (PVar "mods") (PVar "pairs")) () (EBlock (DoLet false false (PVar "rt") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "fi") "fiRuntimeSrc"))) (DoLet false false (PVar "core") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "fi") "fiCoreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EFieldAccess (EVar "fi") "fiRuntimeSrc")) (EFieldAccess (EVar "fi") "fiCoreSrc")))) (DoLet false false (PVar "driveIn") (ERecordCreate "FrontDriveIn" ((fa "fdInputs" (EFieldAccess (EVar "fi") "fiInputs")) (fa "fdPreludeKey" (EVar "preludeKey")) (fa "fdRuntime" (EVar "rt")) (fa "fdCore" (EVar "core")) (fa "fdPairs" (EVar "pairs")) (fa "fdMods" (EVar "mods"))))) (DoExpr (EMatch (EFieldAccess (EVar "fi") "fiPolicy") (arm (PCon "NeverDriveRejected") () (EBlock (DoLet false false (PVar "resolved") (EApp (EApp (EVar "hintResErrorPairs") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "mods"))) (EFieldAccess (EVar "fi") "fiAllowInternal")) (EFieldAccess (EVar "fi") "fiTrusted")) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "pairs")))) (DoExpr (EMatch (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isEmpty") (EApp (EVar "snd") (EVar "p")))))) (EVar "resolved")) (arm (PCon "True") () (EApp (EVar "undrivenOutput") (EApp (EApp (EVar "map") (EVar "resolveBucket")) (EVar "resolved")))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EVar "None")) (EVar "driveIn")) (EApp (EApp (EVar "seedAll") (EApp (EApp (EVar "map") (EVar "midPath")) (EVar "mods"))) (EListLit)))))))) (arm (PCon "DriveUnblocked" (PVar "chainKey") (PVar "steps")) () (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvedBuckets") (EVar "exportsFor")) (EFieldAccess (EVar "fi") "fiAllowInternal")) (EFieldAccess (EVar "fi") "fiTrusted")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "rt")) (EVar "core")) (EVar "mods")) (EVar "pairs"))) (DoExpr (EMatch (EApp (EVar "bucketsResolveRejected") (EVar "buckets")) (arm (PCon "True") () (EBlock (DoLet false false (PTuple (PVar "r") (PVar "outputs") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassReport") (EVar "steps")) (EFieldAccess (EVar "fi") "fiInputs")) (EVar "rt")) (EVar "core")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "pairs")) (EVar "buckets"))) (DoExpr (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "results")) (fa "foReport" (EVar "r")) (fa "foOutputs" (EVar "outputs")) (fa "foDriven" (EVar "None"))))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EApp (EApp (EApp (EVar "foldServeKey") (EVar "steps")) (EVar "preludeKey")) (EVar "chainKey"))) (EVar "driveIn")) (EVar "buckets"))))))) (arm (PCon "ResolvedByGate") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EVar "None")) (EVar "driveIn")) (EApp (EApp (EVar "seedAll") (EApp (EApp (EVar "map") (EVar "midPath")) (EVar "mods"))) (EListLit))))))))))
(DTypeSig false "drivenGraph" (TyFun (TyFun (TyCon "FrontDriveIn") (TyEffect () (Some "e") (TyTuple (TyVar "a") (TyCon "TcReport") (TyCon "DriveOutputs")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "FrontDriveIn") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyVar "a"))))))))
(DFunDef false "drivenGraph" ((PVar "drive") (PVar "served") (PVar "d") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "r") (PVar "outputs")) (EApp (EVar "drive") (EVar "d"))) (DoLet false false (PVar "folded") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "outputs")) (EVar "served")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EFieldAccess (EVar "d") "fdMods")) (EFieldAccess (EVar "d") "fdPairs")) (EApp (EApp (EVar "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "r") "trDiagnostics"))) (EVar "buckets"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "drivenOutput") (EVar "folded")) (EVar "r")) (EVar "outputs")) (EVar "kept")))))
(DTypeSig false "resolveBucket" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "resolveBucket" ((PTuple (PVar "file") (PVar "errs"))) (ETuple (EVar "file") (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EVar "errs"))))
(DTypeSig false "undrivenOutput" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "FrontOutput") (TyVar "a"))))
(DFunDef false "undrivenOutput" ((PVar "buckets")) (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "buckets")) (fa "foReport" (EVar "undrivenReport")) (fa "foOutputs" (EApp (EVar "emptyDriveOutputs") (ELit LUnit))) (fa "foDriven" (EVar "None")))))
(DTypeSig false "drivenOutput" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyCon "TcReport") (TyFun (TyCon "DriveOutputs") (TyFun (TyVar "a") (TyApp (TyCon "FrontOutput") (TyVar "a")))))))
(DFunDef false "drivenOutput" ((PVar "buckets") (PVar "r") (PVar "outputs") (PVar "kept")) (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "buckets")) (fa "foReport" (EIf (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "buckets")) (ERecordUpdate (EVar "r") ((fa "trChecked" (EVar "None")))) (EVar "r"))) (fa "foOutputs" (EVar "outputs")) (fa "foDriven" (EApp (EVar "Some") (EVar "kept"))))))
(DTypeSig false "undrivenReport" (TyCon "TcReport"))
(DFunDef false "undrivenReport" () (ERecordCreate "TcReport" ((fa "trPartial" (EApp (EApp (EApp (EVar "partialAnalysis") (EListLit)) (EListLit)) (EVar "noEntryTables"))) (fa "trDiagnostics" (EListLit)) (fa "trResidual" (EListLit)) (fa "trChecked" (EVar "None")) (fa "trEvidenceFaults" (EListLit)))))
(DTypeSig false "deriveErrToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "deriveErrToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RCannotDerive")) (EVar "msg")) (EVar "loc")))
(DTypeSig false "guardWarnToDiag" (TyFun (TyTuple (TyCon "DiagCode") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "guardWarnToDiag" ((PTuple (PVar "code") (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EVar "code")) (EApp (EVar "stripWarnPrefix") (EVar "msg"))) (EVar "loc")))
(DTypeSig false "preludeShadowWarnToDiag" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag"))))
(DFunDef false "preludeShadowWarnToDiag" ((PVar "modName") (PTuple PWild (PVar "mname") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "WPreludeMethodShadow"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "interface method `")) (EVar "mname") (ELit (LString "` shadows the prelude function `")) (EVar "mname") (ELit (LString "`, which is no longer reachable by its bare name in ")) (EApp (EVar "moduleScopeText") (EVar "modName"))))) (EVar "loc")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "rename the interface method `")) (EVar "mname") (ELit (LString "`")))))) (EVar "None")))
(DTypeSig false "importShadowWarnToDiag" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")) (TyCon "Diag"))))
(DFunDef false "importShadowWarnToDiag" ((PVar "modName") (PTuple (PVar "name") (PVar "iface") (PVar "sty") (PVar "mty") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "WImportMethodShadow"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "imported `")) (EVar "name") (ELit (LString " : ")) (EApp (EVar "importedSchemeText") (EVar "sty")) (ELit (LString "` is shadowed in ")) (EApp (EVar "moduleScopeText") (EVar "modName")) (ELit (LString " by interface method `")) (EVar "iface") (ELit (LString ".")) (EVar "name") (ELit (LString " : ")) (EApp (EVar "ppTy") (EVar "mty")) (ELit (LString "`; at a receiver with an impl of `")) (EVar "iface") (ELit (LString "` the name means the method"))))) (EApp (EVar "Some") (EVar "loc"))) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "import it under another name, `import m.{")) (EVar "name") (ELit (LString " as ")) (EVar "name") (ELit (LString "2}`")))))) (EVar "None")))
(DTypeSig false "importedSchemeText" (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))
(DFunDef false "importedSchemeText" ((PCon "Some" (PVar "t"))) (EApp (EVar "ppTy") (EVar "t")))
(DFunDef false "importedSchemeText" ((PCon "None")) (ELit (LString "no declared signature")))
(DTypeSig false "moduleScopeText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "moduleScopeText" ((PLit (LString ""))) (ELit (LString "this module")))
(DFunDef false "moduleScopeText" ((PVar "m")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "module `")) (EVar "m") (ELit (LString "`")))))
(DTypeSig false "stripWarnPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarnPrefix" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "Warning: "))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "analyzeToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "analyzeToLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppDiag")) (EApp (EApp (EApp (EVar "analyze") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "progSrc")))))
(DTypeSig false "lookupBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "lookupBucket" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBucket" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "putBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PList)) (EListLit (ETuple (EVar "f") (EVar "v"))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PCons (PTuple (PVar "k") (PVar "old")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "old")) (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "v")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pushDiag" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiag" ((PVar "f") (PVar "d") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit (EVar "d"))) (EVar "buckets"))) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "buckets")))))
(DTypeSig false "seedBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedBucket" ((PVar "f") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit)) (EVar "buckets"))) (arm (PCon "Some" PWild) () (EVar "buckets"))))
(DTypeSig false "pushDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiags" (PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "pushDiags" ((PVar "f") (PVar "ds") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "ds")) (EVar "buckets"))) (arm (PCon "Some" (PVar "existing")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "existing") (EVar "ds"))) (EVar "buckets")))))
(DTypeSig false "cachePut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "cachePut" ((PVar "f") (PVar "v") (PVar "xs")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "xs"))))
(DTypeSig false "cacheRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "cacheRemove" (PWild (PList)) (EListLit))
(DFunDef false "cacheRemove" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wrappedRead" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "wrappedRead" ((PVar "cacheRef") (PVar "staleRef") (PVar "parseCacheRef") (PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EVar "parseCachedLocated") (EVar "parseCacheRef")) (EVar "src")) (arm (PCon "Ok" PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EApp (EVar "cachePut") (EVar "path")) (EVar "src")) (EUnOp "!" (EVar "cacheRef"))))) (DoExpr (EApp (EVar "Some") (EVar "src"))))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "staleRef")) (EBinOp "::" (ETuple (EVar "path") (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EUnOp "!" (EVar "staleRef"))))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "path")) (EUnOp "!" (EVar "cacheRef"))) (arm (PCon "Some" (PVar "good")) () (EApp (EVar "Some") (EVar "good"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "src")))))))))))
(DTypeSig true "parseErrDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Diag"))))
(DFunDef false "parseErrDiag" ((PVar "path") (PVar "e")) (EApp (EApp (EVar "parseDiagnosticToDiag") (EVar "path")) (EApp (EVar "parseErrorDiagnostic") (EVar "e"))))
(DTypeSig false "preludeDesugared" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "preludeDesugared" ((PVar "src")) (EApp (EVar "desugaredPrelude") (EVar "src")))
(DTypeSig true "analyzeProject" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "analyzeProject" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectFull") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EVar "results"))))
(DTypeSig true "analyzeProjectFull" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectFull" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectReport") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EVar "report") (arm (PCon "Some" (PVar "r")) () (ETuple (EFieldAccess (EVar "r") "trDiagnostics") (EVar "results"))) (arm (PCon "None") () (ETuple (EListLit) (EVar "results")))))))
(DTypeSig true "analyzeProjectReport" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyCon "TcReport")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectReport" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple (PVar "keyed") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectKeyed") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EApp (EVar "fst") (EApp (EVar "fst") (EVar "k"))))) (EVar "keyed")) (EVar "results")))))
(DData Public "GraphId" () ((variant "GraphId" (ConNamed (field "giEntry" (TyCon "String")) (field "giSteps" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))) ())
(DTypeSig true "graphIdOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "GraphId")))
(DFunDef false "graphIdOf" ((PVar "mods")) (ERecordCreate "GraphId" ((fa "giEntry" (EApp (EVar "lastModId") (EVar "mods"))) (fa "giSteps" (EApp (EApp (EVar "map") (EVar "moduleStepKey")) (EVar "mods"))))))
(DTypeSig false "lastModId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "lastModId" ((PVar "mods")) (EMatch (EApp (EVar "last") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "mid") PWild PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "graphIdSame" (TyFun (TyCon "GraphId") (TyFun (TyCon "GraphId") (TyCon "Bool"))))
(DFunDef false "graphIdSame" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "giEntry") (EFieldAccess (EVar "b") "giEntry")) (EApp (EApp (EVar "allList") (EVar "isSome")) (EFieldAccess (EVar "a") "giSteps"))) (EBinOp "==" (EFieldAccess (EVar "a") "giSteps") (EFieldAccess (EVar "b") "giSteps"))))
(DTypeSig true "analyzeProjectKeyed" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectKeyed" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectKeyedFromLoad") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "staleRef")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots"))))))
(DTypeSig true "analyzeProjectKeyedSources" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "OrdMap") (TyCon "String")))))))))))))))
(DFunDef false "analyzeProjectKeyedSources" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PTuple (PVar "loaded") (PVar "sources")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedSourcesE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots"))) (DoLet false false (PTuple (PVar "keyed") (PVar "diags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectKeyedFromLoad") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "staleRef")) (EVar "loaded"))) (DoExpr (ETuple (EVar "keyed") (EVar "diags") (EVar "sources")))))
(DTypeSig false "projectKeyedFromLoad" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadMsg" (PVar "e")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EVar "None"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadCycle" (PVar "e") (PVar "cpath") (PCon "Some" (PTuple PWild (PVar "loc")))))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "cpath") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EApp (EVar "Some") (EVar "loc")))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadCycle" (PVar "e") PWild (PCon "None")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EVar "None"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Ok" (PVar "mods"))) (EBlock (DoLet false false (PVar "chainKey") (EApp (EApp (EVar "chainKeyOf") (EVar "entry")) (EVar "roots"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "exportsFor")) (ELam ((PVar "d")) (EApp (EVar "unkept") (EApp (EApp (EApp (EVar "checkReportOf") (EVar "RecordSteps")) (EVar "chainKey")) (EVar "d"))))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trustedMods")) (fa "fiRuntimeSrc" (EVar "runtimeSrc")) (fa "fiCoreSrc" (EVar "coreSrc")) (fa "fiPolicy" (EApp (EApp (EVar "DriveUnblocked") (EVar "chainKey")) (EVar "RecordSteps"))) (fa "fiProgram" (EApp (EApp (EVar "FrontGraph") (EVar "mods")) (EApp (EVar "desugaredModPairs") (EVar "mods")))))))) (DoExpr (ETuple (EApp (EVar "Some") (ETuple (ETuple (EFieldAccess (EVar "front") "foReport") (EFieldAccess (EVar "front") "foOutputs")) (EApp (EVar "graphIdOf") (EVar "mods")))) (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EFieldAccess (EVar "front") "foDiags"))))))
(DTypeSig false "bucketsResolveRejected" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "bucketsResolveRejected" ((PVar "buckets")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EApp (EVar "resolveRejected") (EApp (EVar "snd") (EVar "b"))))) (EVar "buckets")))
(DTypeSig true "projectDiagsLoaded" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))
(DFunDef false "projectDiagsLoaded" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods")) (EApp (EVar "snd") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoadedFull") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EApp (EVar "desugaredModPairs") (EVar "mods")))))
(DTypeSig false "projectDiagsLoadedFull" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "projectDiagsLoadedFull" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassFull") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "modPairs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvedBuckets") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "runtimeP")) (EVar "coreP")) (EVar "mods")) (EVar "modPairs"))))
(DTypeSig true "projectEntrySchemes" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))))))))
(DFunDef false "projectEntrySchemes" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EVar "map") (ELam ((PVar "pa")) (EApp (EVar "publishedEntrySchemes") (EFieldAccess (EVar "pa") "paSchemes")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysis") (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))))
(DTypeSig true "projectEntryAnalysis" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "PartialAnalysis")))))))))))
(DFunDef false "projectEntryAnalysis" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysisOr") (ELam (PWild) (EVar "None"))) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig true "projectEntryAnalysisOr" (TyFun (TyFun (TyCon "GraphId") (TyApp (TyCon "Option") (TyCon "PartialAnalysis"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "PartialAnalysis"))))))))))))
(DFunDef false "projectEntryAnalysisOr" ((PVar "kept") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EVar "preludeDesugared") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "preludeDesugared") (EVar "coreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EApp (EVar "kept") (EApp (EVar "graphIdOf") (EVar "mods"))) (arm (PCon "Some" (PVar "pa")) () (EApp (EVar "Some") (EVar "pa"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPartialK") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "preludeKey")) (EVar "runtimeP")) (EVar "coreP")) (EApp (EVar "desugarGraph") (EVar "mods")))))))))))
(DTypeSig false "newStale" (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))))))
(DFunDef false "newStale" (PWild) (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "midPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "midPath" ((PTuple PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig true "seedAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedAll" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "seedAll" ((PCons (PVar "f") (PVar "fs")) (PVar "buckets")) (EApp (EApp (EVar "seedAll") (EVar "fs")) (EApp (EApp (EVar "seedBucket") (EVar "f")) (EVar "buckets"))))
(DTypeSig false "appendStale" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendStale" ((PVar "staleRef") (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EUnOp "!" (EVar "staleRef"))) (EVar "buckets")))
(DTypeSig false "foldStale" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "foldStale" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldStale" ((PCons (PTuple (PVar "path") (PVar "d")) (PVar "rest")) (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "path")) (EVar "d")) (EApp (EApp (EVar "seedBucket") (EVar "path")) (EVar "buckets")))))
(DTypeSig false "resolvePass" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "resolvePass" (PWild PWild PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "resolvePass" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "preludeKey") (PVar "rt") (PVar "core") (PVar "served") (PVar "known") (PVar "ids") (PCons (PAs "m" (PTuple (PVar "mid") (PVar "path") (PVar "desugared"))) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PVar "trusted") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods")))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EApp (EVar "joinNl") (EListLit (EVar "k") (EApp (EVar "boolKey") (EVar "trusted")) (EApp (EVar "boolKey") (EBinOp "==" (EApp (EVar "omSize") (EVar "known")) (ELit (LInt 0)))))))) (EVar "served"))) (DoLet false false (PTuple (PVar "diags") (PVar "exp") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "servedPass") (EVar "ResolveKind")) (EVar "graph")) (EVar "ids")) (EVar "m")) (ELam (PWild) (EBlock (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EApp (EVar "internalGuardFor") (EVar "trusted"))) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "known")) (EVar "mid")) (EVar "desugared"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EVar "errs"))) (EVar "exp"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "served")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EApp (EApp (EApp (EVar "withIdentity") (EVar "mid")) (EVar "ident")) (EVar "ids"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EVar "diags")) (EVar "buckets"))))))
(DTypeSig false "withIdentity" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "withIdentity" ((PVar "mid") (PVar "ident") (PVar "ids")) (EApp (EApp (EApp (EVar "option") (EVar "ids")) (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "i")) (EVar "ids")))) (EVar "ident")))
(DTypeSig false "boolKey" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolKey" ((PCon "True")) (ELit (LString "T")))
(DFunDef false "boolKey" ((PCon "False")) (ELit (LString "F")))
(DTypeSig false "typecheckPassFull" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))
(DFunDef false "typecheckPassFull" ((PVar "inputs") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "r") PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassReport") (EVar "NoSteps")) (EVar "inputs")) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "modPairs")) (EVar "buckets"))) (DoExpr (ETuple (EFieldAccess (EVar "r") "trDiagnostics") (EVar "results")))))
(DTypeSig false "typecheckPassReport" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))
(DFunDef false "typecheckPassReport" ((PVar "steps") (PVar "inputs") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs") (PVar "buckets")) (EBlock (DoLet false false (PVar "blocked") (EApp (EApp (EApp (EVar "resolveBlockedMods") (EVar "buckets")) (EVar "omEmpty")) (EVar "mods"))) (DoLet false false (PVar "checkedMods") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "blocked"))))) (EVar "mods"))) (DoLet false false (PVar "checkedPairs") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "blocked"))))) (EVar "modPairs"))) (DoLet false false (PVar "rejected") (EApp (EVar "bucketsResolveRejected") (EVar "buckets"))) (DoLet false false (PVar "valueMain") (EBinOp "&&" (EApp (EVar "not") (EVar "rejected")) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreP")) (EVar "modPairs")))) (DoLet false false (PTuple (PVar "driven") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkChainReport") (EVar "steps")) (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "runtimeP")) (EVar "coreP")) (EVar "checkedMods")) (EVar "checkedPairs"))) (DoLet false false (PVar "report") (EIf (EVar "rejected") (ERecordUpdate (EVar "driven") ((fa "trChecked" (EVar "None")))) (EVar "driven"))) (DoExpr (ETuple (EVar "report") (EVar "outputs") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "outputs")) (EApp (EApp (EApp (EVar "foldServeKey") (EVar "steps")) (EVar "preludeKey")) (EVar "chainKey"))) (EVar "runtimeP")) (EVar "coreP")) (EVar "mods")) (EVar "modPairs")) (EApp (EApp (EVar "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "report") "trDiagnostics"))) (EVar "buckets"))))))
(DTypeSig false "checkChainReport" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs"))))))))))))
(DFunDef false "checkChainReport" ((PVar "steps") (PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "pairs")) (EBlock (DoExpr (EApp (EApp (EVar "narrowInterfaces") (EVar "steps")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesChainReportFor") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EApp (EApp (EVar "stepKeysFor") (EVar "steps")) (EVar "mods"))) (EVar "runtimeP")) (EVar "coreP")) (EVar "pairs")))))
(DTypeSig false "narrowInterfaces" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "narrowInterfaces" ((PCon "RecordSteps") (PVar "mods")) (EApp (EVar "retainModuleInterfaces") (EApp (EApp (EVar "map") (EVar "modIdOf")) (EVar "mods"))))
(DFunDef false "narrowInterfaces" ((PCon "NoSteps") PWild) (ELit LUnit))
(DTypeSig false "modIdOf" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "modIdOf" ((PTuple (PVar "mid") PWild PWild)) (EVar "mid"))
(DTypeSig false "stepKeysFor" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stepKeysFor" ((PCon "RecordSteps") (PVar "mods")) (EApp (EApp (EVar "map") (EVar "moduleStepKey")) (EVar "mods")))
(DFunDef false "stepKeysFor" ((PCon "NoSteps") PWild) (EListLit))
(DTypeSig false "typecheckDiagsFold" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "typecheckDiagsFold" ((PVar "outputs") (PVar "served") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "modPairs") (PVar "tcByMid") (PVar "buckets")) (EBlock (DoLet false false (PVar "preludeDecls") (EBinOp "++" (EVar "runtimeP") (EVar "coreP"))) (DoLet false false (PVar "desugaredPool") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "modPairs"))) (EVar "omEmpty"))) (DoLet false false (PVar "passes") (ERecordCreate "RawPasses" ((fa "rpCoreExports" (EApp (EVar "coreExports") (EVar "coreP"))) (fa "rpPool" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "rawPairOf")) (EVar "mods"))) (EVar "omEmpty"))) (fa "rpPrelude" (EVar "preludeDecls")) (fa "rpShadowPool" (EApp (EVar "preludeStandaloneSet") (EVar "preludeDecls"))) (fa "rpShadowGraph" (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "preludeDecls")) (EVar "modPairs"))) (fa "rpOutputs" (EVar "outputs")) (fa "rpDesugared" (EVar "desugaredPool")) (fa "rpTc" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "tcByMid"))) (EVar "omEmpty")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "passes")) (EApp (EApp (EApp (EVar "option") (EVar "None")) (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "foldGraphPart") (EVar "k")) (EVar "outputs")) (EVar "mods")) (EApp (EVar "listLen") (EVar "modPairs"))) (EVar "desugaredPool")))) (EVar "served"))) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "mods")) (EVar "buckets")))))
(DData Private "RawPasses" () ((variant "RawPasses" (ConNamed (field "rpCoreExports" (TyCon "ModuleExports")) (field "rpPool" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (field "rpPrelude" (TyApp (TyCon "List") (TyCon "Decl"))) (field "rpShadowPool" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "rpShadowGraph" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "rpOutputs" (TyCon "DriveOutputs")) (field "rpDesugared" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (field "rpTc" (TyApp (TyCon "OrdMap") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))) ())
(DTypeSig false "foldServeKey" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "foldServeKey" ((PCon "RecordSteps") (PCon "Some" (PTuple (PVar "rk") (PVar "ck"))) (PVar "chainKey")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey"))))
(DFunDef false "foldServeKey" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "resolvedBuckets" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))
(DFunDef false "resolvedBuckets" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "preludeKey") (PVar "chainKey") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "modPairs")) (EBlock (DoExpr (EIf (EApp (EVar "isSome") (EVar "preludeKey")) (EApp (EVar "retainPassEntries") (EApp (EApp (EVar "map") (EVar "modIdOf")) (EVar "mods"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "runtimeP")) (EVar "coreP")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "rk") (PVar "ck"))) (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")))) (EVar "preludeKey"))) (EVar "omEmpty")) (EVar "omEmpty")) (EApp (EApp (EVar "desugaredTriples") (EVar "mods")) (EVar "modPairs"))) (EApp (EApp (EVar "seedAll") (EApp (EApp (EVar "map") (EVar "midPath")) (EVar "mods"))) (EListLit))))))
(DTypeSig false "desugaredTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "desugaredTriples" ((PCons (PTuple (PVar "mid") (PVar "path") PWild) (PVar "ms")) (PCons (PTuple PWild (PVar "decls")) (PVar "ps"))) (EBinOp "::" (ETuple (EVar "mid") (EVar "path") (EVar "decls")) (EApp (EApp (EVar "desugaredTriples") (EVar "ms")) (EVar "ps"))))
(DFunDef false "desugaredTriples" (PWild PWild) (EListLit))
(DTypeSig true "desugaredModPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugaredModPairs" ((PVar "mods")) (EApp (EVar "desugarGraph") (EVar "mods")))
(DTypeSig false "rawPairOf" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rawPairOf" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig true "midToDesugaredPair" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "midToDesugaredPair" ((PTuple (PVar "mid") (PVar "path") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarModule") (EVar "path")) (EVar "prog"))))
(DTypeSig true "chainKeyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "chainKeyOf" ((PVar "entry") (PVar "roots")) (EApp (EVar "joinNl") (EBinOp "::" (EVar "entry") (EVar "roots"))))
(DTypeSig false "moduleStepKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "moduleStepKey" ((PTuple (PVar "mid") (PVar "path") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "src")) (EApp (EVar "joinNl") (EListLit (EVar "mid") (EVar "path") (EVar "src"))))) (EApp (EVar "loadedSourceOf") (EVar "path"))))
(DTypeSig false "desugarModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarModule" ((PVar "path") (PVar "prog")) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EApp (EVar "desugar") (EVar "prog"))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (EApp (EVar "joinNl") (EListLit (EVar "path") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "moduleDesugarCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleDesugarCacheRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "decls")) (EUnOp "!" (EVar "moduleDesugarCacheRef"))))) (DoExpr (EVar "decls"))))))))))
(DTypeSig false "desugarGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugarGraph" ((PVar "mods")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "midToDesugaredPair")) (EVar "mods"))) (DoLet false false (PVar "old") (EUnOp "!" (EVar "moduleDesugarCacheRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleDesugarCacheRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "mods"))) (EVar "omEmpty")))) (DoExpr (EVar "pairs"))))
(DTypeSig false "keptDesugared" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "keptDesugared" (PWild (PList)) (EListLit))
(DFunDef false "keptDesugared" ((PVar "old") (PCons (PTuple PWild (PVar "path") PWild) (PVar "rest"))) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest"))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (EApp (EVar "joinNl") (EListLit (EVar "path") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "old")) (arm (PCon "Some" (PVar "decls")) () (EBinOp "::" (ETuple (EVar "key") (EVar "decls")) (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest")))))))))
(DTypeSig false "moduleDesugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "moduleDesugarCacheRef" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "diagCode" (TyFun (TyCon "Diag") (TyCon "DiagId")))
(DFunDef false "diagCode" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "resolveRejected" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "resolveRejected" () (EApp (EVar "anyList") (ELam ((PVar "d")) (EBinOp "&&" (EApp (EVar "diagIsError") (EVar "d")) (EBinOp "==" (EApp (EVar "diagIdKind") (EApp (EVar "diagCode") (EVar "d"))) (ELit (LString "resolve")))))))
(DTypeSig false "resolveBlockedMods" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "resolveBlockedMods" (PWild (PVar "blocked") (PList)) (EVar "blocked"))
(DFunDef false "resolveBlockedMods" ((PVar "buckets") (PVar "blocked") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "rejected") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "ds")) () (EApp (EVar "resolveRejected") (EVar "ds"))) (arm (PCon "None") () (EVar "False")))) (DoLet false false (PVar "blocks") (EBinOp "||" (EVar "rejected") (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "blocked")))) (EApp (EVar "useModuleIds") (EVar "prog"))))) (DoExpr (EApp (EApp (EApp (EVar "resolveBlockedMods") (EVar "buckets")) (EIf (EVar "blocks") (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EVar "blocked")) (EVar "blocked"))) (EVar "rest")))))
(DTypeSig false "foldModuleTc" (TyFun (TyCon "RawPasses") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))
(DFunDef false "foldModuleTc" (PWild PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldModuleTc" ((PVar "passes") (PVar "graph") (PVar "known") (PVar "ids") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "rawDiags") (PVar "exp") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "servedPass") (EVar "FoldKind")) (EVar "graph")) (EVar "ids")) (ETuple (EVar "mid") (EVar "path") (EVar "prog"))) (ELam (PWild) (EApp (EApp (EApp (EVar "rawTreeDiags") (EVar "passes")) (EVar "known")) (ETuple (EVar "mid") (EVar "path") (EVar "prog")))))) (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EVar "optionOr") (ETuple (EListLit) (EListLit))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "passes") "rpTc")))) (DoLet false false (PVar "tcReported") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "existing")) () (EApp (EVar "not") (EApp (EVar "resolveRejected") (EVar "existing")))) (arm (PCon "None") () (EVar "True")))) (DoLet false false (PVar "errDiags") (EIf (EVar "tcReported") (EApp (EApp (EVar "map") (EVar "diagOfTypeError")) (EVar "tcErrs")) (EListLit))) (DoLet false false (PVar "warnDiags") (EIf (EVar "tcReported") (EApp (EApp (EVar "map") (EVar "diagOfTypeWarning")) (EVar "tcWarns")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "passes")) (EVar "graph")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EApp (EApp (EApp (EVar "withIdentity") (EVar "mid")) (EVar "ident")) (EVar "ids"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EBinOp "++" (EBinOp "++" (EVar "rawDiags") (EVar "errDiags")) (EVar "warnDiags"))) (EVar "buckets"))))))
(DTypeSig false "rawTreeDiags" (TyFun (TyCon "RawPasses") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports"))))))
(DFunDef false "rawTreeDiags" ((PVar "passes") (PVar "known") (PTuple (PVar "mid") PWild (PVar "prog"))) (EBlock (DoLet false false (PVar "desugared") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "passes") "rpDesugared")))) (DoLet false false (PTuple (PVar "imported") (PVar "exp")) (EApp (EApp (EApp (EApp (EVar "importedCtorDeclsStep") (EFieldAccess (EVar "passes") "rpCoreExports")) (EFieldAccess (EVar "passes") "rpPool")) (EVar "known")) (ETuple (EVar "mid") (EVar "desugared")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EVar "imported") (EFieldAccess (EVar "passes") "rpPrelude"))) (EVar "prog"))) (DoLet false false (PVar "shadowDiags") (EApp (EApp (EVar "map") (EApp (EVar "preludeShadowWarnToDiag") (EVar "mid"))) (EApp (EApp (EVar "preludeStandaloneShadowsWith") (EFieldAccess (EVar "passes") "rpShadowPool")) (EVar "desugared")))) (DoLet false false (PVar "importShadowDiags") (EApp (EApp (EVar "map") (EApp (EVar "importShadowWarnToDiag") (EVar "mid"))) (EApp (EApp (EApp (EVar "importedStandaloneShadows") (EFieldAccess (EVar "passes") "rpOutputs")) (EFieldAccess (EVar "passes") "rpShadowGraph")) (EVar "desugared")))) (DoExpr (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "prog"))) (EApp (EApp (EVar "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (EVar "shadowDiags")) (EVar "importShadowDiags")) (EVar "exp")))))
(DData Private "PassKey" () ((variant "PassKey" (ConNamed (field "pkGraph" (TyCon "String")) (field "pkPath" (TyCon "String")) (field "pkSource" (TyCon "String")) (field "pkImports" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))) ())
(DImpl true "Eq" ((TyCon "PassKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "PassKey" ((rf "pkGraph" (PVar "__a0")) (rf "pkPath" (PVar "__a1")) (rf "pkSource" (PVar "__a2")) (rf "pkImports" (PVar "__a3"))) false) (PRec "PassKey" ((rf "pkGraph" (PVar "__b0")) (rf "pkPath" (PVar "__b1")) (rf "pkSource" (PVar "__b2")) (rf "pkImports" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DData Private "PassEntry" () ((variant "PassEntry" (ConNamed (field "peKey" (TyCon "PassKey")) (field "peIdentity" (TyCon "Int")) (field "peDiags" (TyApp (TyCon "List") (TyCon "Diag"))) (field "peExports" (TyCon "ModuleExports"))))) ())
(DData Private "PassCaches" () ((variant "PassCaches" (ConNamed (field "pcResolve" (TyApp (TyCon "OrdMap") (TyCon "PassEntry"))) (field "pcFold" (TyApp (TyCon "OrdMap") (TyCon "PassEntry"))) (field "pcSerial" (TyCon "Int"))))) ())
(DTypeSig false "passCacheRef" (TyApp (TyCon "Ref") (TyCon "PassCaches")))
(DFunDef false "passCacheRef" () (EApp (EVar "Ref") (EApp (EVar "emptyPassCaches") (ELit LUnit))))
(DTypeSig false "emptyPassCaches" (TyFun (TyCon "Unit") (TyCon "PassCaches")))
(DFunDef false "emptyPassCaches" (PWild) (ERecordCreate "PassCaches" ((fa "pcResolve" (EVar "omEmpty")) (fa "pcFold" (EVar "omEmpty")) (fa "pcSerial" (ELit (LInt 0))))))
(DData Private "PassKind" () ((variant "ResolveKind" (ConPos)) (variant "FoldKind" (ConPos))) ())
(DTypeSig false "passEntries" (TyFun (TyCon "PassKind") (TyFun (TyCon "PassCaches") (TyApp (TyCon "OrdMap") (TyCon "PassEntry")))))
(DFunDef false "passEntries" ((PCon "ResolveKind") (PVar "c")) (EFieldAccess (EVar "c") "pcResolve"))
(DFunDef false "passEntries" ((PCon "FoldKind") (PVar "c")) (EFieldAccess (EVar "c") "pcFold"))
(DTypeSig false "retainPassEntries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "retainPassEntries" ((PVar "mids")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (ERecordUpdate (EVar "c") ((fa "pcResolve" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "c") "pcResolve"))) (fa "pcFold" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "c") "pcFold")))))))))
(DTypeSig true "clearProjectPassEntries" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "clearProjectPassEntries" ((PLit LUnit)) (EApp (EVar "retainPassEntries") (EListLit)))
(DTypeSig false "keepPassEntry" (TyFun (TyCon "PassKind") (TyFun (TyCon "String") (TyFun (TyCon "PassEntry") (TyCon "Unit")))))
(DFunDef false "keepPassEntry" ((PVar "kind") (PVar "mid") (PVar "entry")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (EMatch (EVar "kind") (arm (PCon "ResolveKind") () (ERecordUpdate (EVar "c") ((fa "pcResolve" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "entry")) (EFieldAccess (EVar "c") "pcResolve")))))) (arm (PCon "FoldKind") () (ERecordUpdate (EVar "c") ((fa "pcFold" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "entry")) (EFieldAccess (EVar "c") "pcFold")))))))))))
(DTypeSig false "freshPassIdentity" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "freshPassIdentity" (PWild) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoLet false false (PVar "next") (EBinOp "+" (EFieldAccess (EVar "c") "pcSerial") (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (ERecordUpdate (EVar "c") ((fa "pcSerial" (EVar "next")))))) (DoExpr (EVar "next"))))
(DTypeSig true "foldCachedIdentity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "foldCachedIdentity" ((PVar "mid")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EFieldAccess (EVar "e") "peIdentity"))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "passCacheRef") "value") "pcFold"))))
(DTypeSig true "resolveCachedIdentity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "resolveCachedIdentity" ((PVar "mid")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EFieldAccess (EVar "e") "peIdentity"))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "passCacheRef") "value") "pcResolve"))))
(DTypeSig false "servedPass" (TyFun (TyCon "PassKind") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "servedPass" (PWild (PCon "None") PWild PWild (PVar "compute")) (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EVar "None")))))
(DFunDef false "servedPass" ((PVar "kind") (PCon "Some" (PVar "g")) (PVar "ids") (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "compute")) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EApp (EVar "Some") (EApp (EVar "freshPassIdentity") (ELit LUnit))))))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (ERecordCreate "PassKey" ((fa "pkGraph" (EVar "g")) (fa "pkPath" (EVar "path")) (fa "pkSource" (EVar "src")) (fa "pkImports" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "omLookup") (EVar "i")) (EVar "ids")))) (EApp (EVar "useModuleIds") (EVar "prog"))))))) (DoLet false false (PVar "hit") (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "passEntries") (EVar "kind")) (EFieldAccess (EVar "passCacheRef") "value"))) (arm (PCon "Some" (PVar "e")) () (EIf (EBinOp "==" (EFieldAccess (EVar "e") "peKey") (EVar "key")) (EApp (EVar "Some") (EVar "e")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EMatch (EVar "hit") (arm (PCon "Some" (PVar "e")) () (ETuple (EFieldAccess (EVar "e") "peDiags") (EFieldAccess (EVar "e") "peExports") (EApp (EVar "Some") (EFieldAccess (EVar "e") "peIdentity")))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoLet false false (PVar "ident") (EApp (EVar "freshPassIdentity") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "keepPassEntry") (EVar "kind")) (EVar "mid")) (ERecordCreate "PassEntry" ((fa "peKey" (EVar "key")) (fa "peIdentity" (EVar "ident")) (fa "peDiags" (EVar "diags")) (fa "peExports" (EVar "exp")))))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EApp (EVar "Some") (EVar "ident"))))))))))))
(DTypeSig false "foldGraphPart" (TyFun (TyCon "String") (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "foldGraphPart" ((PVar "chainFull") (PVar "outputs") (PVar "mods") (PVar "count") (PVar "pool")) (EBlock (DoLet false false (PVar "declarers") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "declaresInterface")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "pool")))))) (EVar "mods"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "path") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "src")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "path")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "src")))) (ELit (LString ""))))) (EApp (EVar "loadedSourceOf") (EVar "path"))))) (EVar "declarers"))) (DoExpr (EIf (EApp (EApp (EVar "allList") (EVar "isSome")) (EVar "rows")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EVar "chainFull")) (EApp (EVar "lenKey") (EApp (EVar "intToString") (EVar "count"))) (EApp (EVar "lenKey") (EApp (EVar "ifaceIndexText") (EFieldAccess (EVar "outputs") "doIfaceExports")))) (EApp (EApp (EVar "map") (EApp (EVar "optionOr") (ELit (LString "")))) (EVar "rows"))))) (EVar "None")))))
(DTypeSig false "declaresInterface" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declaresInterface" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "declaresInterface" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declaresInterface") (EVar "d")))
(DFunDef false "declaresInterface" (PWild) (EVar "False"))
(DTypeSig false "ifaceIndexText" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyCon "String")))
(DFunDef false "ifaceIndexText" ((PVar "idx")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "mid")) (EApp (EApp (EVar "ifaceRowsText") (EVar "mid")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "idx"))))) (EApp (EVar "omKeys") (EVar "idx")))))
(DTypeSig false "ifaceRowsText" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyCon "String"))))
(DFunDef false "ifaceRowsText" ((PVar "mid") (PVar "rows")) (EApp (EVar "stringConcat") (EBinOp "::" (EApp (EVar "lenKey") (EVar "mid")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "row"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "joinNl") (EApp (EVar "snd") (EVar "row")))))) (ELit (LString ""))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "rows"))))))
(DTypeSig true "analyzeProjectToLines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "analyzeProjectToLines" ((PVar "cacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EVar "projectLines") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))))))
(DTypeSig false "projectLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectLines" ((PList)) (EListLit))
(DFunDef false "projectLines" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## FILE ")) (EVar "file")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ppDiagLoc")) (EVar "ds")) (EApp (EVar "projectLines") (EVar "rest")))))
(DTypeSig false "ppDiagLoc" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "cjPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "cjPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))))))
(DTypeSig true "cjRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "cjRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "end")) (EApp (EApp (EVar "cjPosition") (EVar "el")) (EVar "ec"))) (ETuple (ELit (LString "start")) (EApp (EApp (EVar "cjPosition") (EVar "sl")) (EVar "sc"))))))
(DTypeSig true "cjRangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "cjRangeOfLoc" ((PLit (LString "")) (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "positions") (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "sl")) (EVar "sc"))) (ELam ((PVar "start")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "end")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "start"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "c") (PVar "d")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))))))))))))))) (DoExpr (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EVar "positions")))))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "None")) (EVar "JNull"))
(DTypeSig false "cjSevCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "cjSevCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "cjSevCode" (PWild) (ELit (LInt 2)))
(DTypeSig true "optField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "optField" ((PVar "k") (PCon "Some" (PVar "v"))) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "optField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "cjFixJson" (TyFun (TyCon "Fix") (TyCon "Json")))
(DFunDef false "cjFixJson" () (EApp (EVar "cjFixJsonWithSource") (ELit (LString ""))))
(DTypeSig false "cjFixJsonWithSource" (TyFun (TyCon "String") (TyFun (TyCon "Fix") (TyCon "Json"))))
(DFunDef false "cjFixJsonWithSource" ((PVar "src") (PCon "Fix" (PVar "loc") (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EApp (EVar "Some") (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))
(DFunDef false "cjFixJsonWithSource" ((PVar "src") (PCon "FixEdits" (PVar "applicability") (PVar "edits"))) (EApp (EApp (EApp (EVar "fixEditsJson") (ELam ((PVar "loc")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EApp (EVar "Some") (EVar "loc"))))) (EVar "applicability")) (EVar "edits")))
(DTypeSig true "fixEditsJson" (TyFun (TyFun (TyCon "Loc") (TyCon "Json")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyCon "Json")))))
(DFunDef false "fixEditsJson" ((PVar "rangeOf") (PVar "applicability") (PVar "edits")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "applicability")) (EApp (EVar "JString") (EVar "applicability"))) (ETuple (ELit (LString "edits")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "loc") (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "rangeOf") (EVar "loc"))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))) (EVar "edits"))))))))
(DTypeSig true "cjDiagnostic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "cjDiagnostic" (PWild (PVar "src") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "diagIdText") (EVar "code"))))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EVar "map") (EApp (EVar "cjFixJsonWithSource") (EVar "src"))) (EVar "fix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EVar "map") (EVar "JString")) (EVar "help")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EApp (EVar "diagKind") (EVar "sev")) (EVar "code")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EVar "loc"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "cjSevCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))))
(DTypeSig true "cjFileEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Json")))))
(DFunDef false "cjFileEntry" ((PVar "path") (PVar "src") (PVar "diags")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "path")) (EVar "src"))) (EVar "diags"))))))))
(DTypeSig false "cjTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "cjTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig true "cjAllToJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String")))
(DFunDef false "cjAllToJson" ((PVar "triples")) (EApp (EApp (EVar "cjAllToJsonWith") (EListLit)) (EVar "triples")))
(DTypeSig true "cjAllToJsonWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String"))))
(DFunDef false "cjAllToJsonWith" ((PVar "extra") (PVar "triples")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "cjTriple")) (EVar "triples")))))) (EVar "extra")))))
(DTypeSig true "pendingStaleNotice" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pendingStaleNotice" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "pendingPreludeNotices" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "pendingPreludeNotices" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "runEnvelopeFields" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "runEnvelopeFields" (PWild) (EBlock (DoLet false false (PVar "staleF") (EMatch (EUnOp "!" (EVar "pendingStaleNotice")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "msg")) () (EListLit (ETuple (ELit (LString "staleBinary")) (EApp (EVar "JString") (EVar "msg"))))))) (DoLet false false (PVar "preludeF") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "field") (PVar "msg"))) (ETuple (EVar "field") (EApp (EVar "JString") (EVar "msg"))))) (EUnOp "!" (EVar "pendingPreludeNotices")))) (DoLet false false (PVar "perfF") (EMatch (EApp (EVar "takePerfSink") (ELit LUnit)) (arm (PList) () (EListLit)) (arm (PVar "ls") () (EListLit (ETuple (ELit (LString "perf")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EApp (EVar "JString") (EVar "l")))) (EVar "ls"))))))))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "staleF") (EVar "preludeF")) (EVar "perfF")))))
(DTypeSig true "flushRunEnvelope" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("Stderr") (Some "e") (TyCon "Unit"))))
(DFunDef false "flushRunEnvelope" ((PVar "triples")) (EMatch (ETuple (EVar "triples") (EApp (EVar "runEnvelopeFields") (ELit LUnit))) (arm (PTuple (PList) (PList)) () (ELit LUnit)) (arm (PTuple (PVar "ts") (PVar "extra")) () (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "cjAllToJsonWith") (EVar "extra")) (EVar "ts"))))))
(DTypeSig true "readDiagSrc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PList))) (ETuple (EVar "path") (ELit (LString "")) (EListLit)))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PVar "diags"))) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "Some" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "Err" PWild) () (ETuple (EVar "path") (ELit (LString "")) (EVar "diags")))))))
(DTypeSig true "cohWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "cohWarnsOfTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EVar "path") (EVar "src") (EApp (EApp (EVar "filter") (EVar "isCoherenceWarn")) (EVar "diags"))))
(DTypeSig true "joinedOrNone" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "joinedOrNone" ((PList)) (EVar "None"))
(DFunDef false "joinedOrNone" ((PVar "ls")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig true "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "errs")))))))
(DTypeSig true "renderTripleWarnings" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleWarnings" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EVar "filter") (EVar "diagIsWarn")) (EVar "diags"))) (DoExpr (EMatch (EVar "ws") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "ws")))))))
(DTypeSig true "residualOrGeneric" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "residualOrGeneric" ((PVar "pathMap") (PVar "target") (PVar "residual")) (EMatch (EApp (EApp (EVar "renderTcDiags") (EVar "pathMap")) (EVar "residual")) (arm (PList) () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString " detected during elaboration; no located diagnostic is available for it")))) (arm (PVar "rendered") () (EApp (EVar "joinNl") (EVar "rendered")))))
(DTypeSig true "diagIsWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "diagIsError") (EVar "d"))))
(DTypeSig true "coherenceWarnCode" (TyCon "DiagCode"))
(DFunDef false "coherenceWarnCode" () (EVar "WIncomparableImpls"))
(DTypeSig true "runBuildWarnCodes" (TyApp (TyCon "List") (TyCon "DiagCode")))
(DFunDef false "runBuildWarnCodes" () (EListLit (EVar "coherenceWarnCode") (EVar "WPreludeMethodShadow") (EVar "WImportMethodShadow")))
(DTypeSig true "isCoherenceWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isCoherenceWarn" ((PCon "Diag" (PCon "SevWarning") (PCon "Coded" (PVar "c")) PWild PWild PWild PWild)) (EApp (EApp (EVar "elem") (EVar "c")) (EVar "runBuildWarnCodes")))
(DFunDef false "isCoherenceWarn" (PWild) (EVar "False"))
(DTypeSig true "emitDiagExitCode" (TyCon "Int"))
(DFunDef false "emitDiagExitCode" () (ELit (LInt 3)))
(DTypeSig true "renderSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EBlock (DoLet false false (PTuple (PVar "at") (PVar "diag")) (EApp (EApp (EVar "symbolDefectDiag") (EVar "file")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "arrayFromList") (EListLit))) (EVar "at")) (EVar "diag")))))) (EVar "ds")))
(DTypeSig false "symbolDefectDiag" (TyFun (TyCon "String") (TyFun (TyCon "SymbolDefect") (TyTuple (TyCon "String") (TyCon "Diag")))))
(DFunDef false "symbolDefectDiag" ((PVar "file") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "physicalDiag") (EVar "file")) (EApp (EVar "defectOrigin") (EVar "d"))) (EApp (EVar "defectCode") (EVar "d"))) (EApp (EVar "defectMessage") (EVar "d"))))
(DTypeSig false "physicalDiag" (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Diag")))))))
(DFunDef false "physicalDiag" ((PVar "file") (PVar "origin") (PVar "code") (PVar "message")) (EBlock (DoLet false false (PTuple (PVar "f") (PVar "line") (PVar "col")) (EApp (EVar "originPosition") (EVar "origin"))) (DoLet false false (PVar "at") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "file") (EVar "f"))) (DoLet false false (PVar "loc") (EIf (EBinOp "&&" (EBinOp ">" (EVar "line") (ELit (LInt 0))) (EBinOp "/=" (EVar "at") (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "at")) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col"))) (EVar "None"))) (DoExpr (ETuple (EVar "at") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "code")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EVar "code"))) (ELit (LString "] "))) (EApp (EVar "display") (EVar "message"))) (ELit (LString "")))) (EVar "loc"))))))
(DTypeSig true "refuseSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "map") (EApp (EVar "symbolDefectDiag") (EVar "file"))) (EVar "ds"))))
(DTypeSig false "refusePhysical" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "refusePhysical" ((PVar "diags")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "at")))) (EVar "at")) (EVar "diag"))))) (EVar "diags"))) (DoExpr (EApp (EVar "stageExit") (EVar "emitDiagExitCode")))))
(DTypeSig true "refuseLlvmSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LlvmSymbols.SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseLlvmSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EVar "map") (EApp (EVar "llvmSymbolDefectDiag") (EVar "file"))) (EVar "ds"))))
(DTypeSig false "llvmSymbolDefectDiag" (TyFun (TyCon "String") (TyFun (TyCon "LlvmSymbols.SymbolDefect") (TyTuple (TyCon "String") (TyCon "Diag")))))
(DFunDef false "llvmSymbolDefectDiag" ((PVar "file") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "physicalDiag") (EVar "file")) (EApp (EVar "LlvmSymbols.defectOrigin") (EVar "d"))) (EApp (EVar "LlvmSymbols.defectCode") (EVar "d"))) (EApp (EVar "LlvmSymbols.defectMessage") (EVar "d"))))
(DTypeSig true "emitGateDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "emitGateDiags" ((PVar "modsWithPath") (PVar "buckets")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "buckets"))) (DoLet false false (PVar "warnSrc") (EMatch (EVar "modsWithPath") (arm (PList PWild) () (EVar "triples")) (arm PWild () (EApp (EApp (EVar "map") (EVar "cohWarnsOfTriple")) (EVar "triples"))))) (DoExpr (ETuple (EApp (EApp (EVar "flatMap") (EVar "renderTripleErrors")) (EVar "triples")) (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EBinOp "++" (EVar "warnSrc") (EApp (EVar "mainShapeTriple") (EVar "modsWithPath"))))))))
(DTypeSig false "mainShapeTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mainShapeTriple" ((PVar "mods")) (EMatch (EApp (EVar "lastModTriple") (EVar "mods")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "path") (PVar "decls"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (EApp (EVar "readDiagSrc") (ETuple (EVar "path") (EVar "ws")))))))))
(DTypeSig false "lastModTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModTriple" ((PList)) (EVar "None"))
(DFunDef false "lastModTriple" ((PList (PVar "m"))) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "lastModTriple" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModTriple") (EVar "rest")))
(DTypeSig true "relDiagPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relDiagPath" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path")))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig true "cjFoldIntoFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "cjFoldIntoFile" (PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "cjFoldIntoFile" (PWild PWild (PList)) (EListLit))
(DFunDef false "cjFoldIntoFile" ((PVar "path") (PVar "extra") (PCons (PTuple (PVar "p") (PVar "s") (PVar "ds")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "path")) (EBinOp "::" (ETuple (EVar "p") (EVar "s") (EBinOp "++" (EVar "ds") (EVar "extra"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "p") (EVar "s") (EVar "ds")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "path")) (EVar "extra")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findMainFunDef" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "findMainFunDef" ((PList)) (EVar "None"))
(DFunDef false "findMainFunDef" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainFunDef") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainFunDef" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") (PVar "body") PWild PWild) PWild)) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "findMainFunDef" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainFunDef") (EVar "rest")))
(DTypeSig true "mainBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainBodyLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "mainBodyLoc") (EVar "f")))
(DFunDef false "mainBodyLoc" ((PCon "EBinOp" PWild (PVar "a") PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EFieldAccess" (PVar "a") PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EIndex" (PVar "a") PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "ESlice" (PVar "a") PWild PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" (PWild) (EVar "None"))
(DTypeSig true "mainArityMsg" (TyCon "String"))
(DFunDef false "mainArityMsg" () (ELit (LString "`main` must be a value, not a function; write `main = ...`, not `main () = ...`")))
(DTypeSig true "mainMissingMsg" (TyCon "String"))
(DFunDef false "mainMissingMsg" () (ELit (LString "no `main` in this file; add `main = ...`")))
(DTypeSig true "mainArityWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainArityWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EVar "WMainShape")) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mainShapeWarnings" (PWild PWild PWild (PVar "entryDecls")) (EMatch (EApp (EVar "mainArityWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "mainEntryError" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainEntryError" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainShape")) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm (PCon "Some" (PTuple (PList) PWild)) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "missingMainDiag") (EVar "decls"))))))
(DTypeSig true "missingMainDiag" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Diag")))
(DFunDef false "missingMainDiag" ((PVar "decls")) (EMatch (EApp (EVar "importedMainMember") (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "modName") (PVar "m"))) () (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainMissing")) (EApp (EApp (EVar "mainImportedMsg") (EVar "modName")) (EVar "m"))) (EApp (EVar "Some") (EApp (EVar "useMemberLoc") (EVar "m"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainMissing")) (EVar "mainMissingMsg")) (EVar "None")))))
(DTypeSig false "mainImportedMsg" (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyCon "String"))))
(DFunDef false "mainImportedMsg" ((PVar "modName") (PCon "UseMember" (PVar "origin") PWild PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "written") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "origin"))) (ELit (LString " as "))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "origin")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` must be defined in the entry file, not imported by `import ")) (EApp (EVar "display") (EVar "modName"))) (ELit (LString ".{"))) (EApp (EVar "display") (EVar "written"))) (ELit (LString "}`; add `main = ...` to this file"))))))
(DTypeSig false "importedMainMember" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "UseMember")))))
(DFunDef false "importedMainMember" ((PList)) (EVar "None"))
(DFunDef false "importedMainMember" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "importedMainMember") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "importedMainMember" ((PCons (PCon "DUse" PWild (PCon "UseGroup" (PVar "ns") (PVar "members")) PWild) (PVar "rest"))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "==" (EApp (EVar "useMemberLocal") (EVar "m")) (ELit (LString "main"))))) (EVar "members")) (arm (PCons (PVar "m") PWild) () (EApp (EVar "Some") (ETuple (EApp (EVar "joinDot") (EVar "ns")) (EVar "m")))) (arm (PList) () (EApp (EVar "importedMainMember") (EVar "rest")))))
(DFunDef false "importedMainMember" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedMainMember") (EVar "rest")))
(DTypeSig false "useMemberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "useMemberLoc" ((PCon "UseMember" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "ppMainEntryError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppMainEntryError" (PWild (PVar "file") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "displayPath") (EVar "file")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppMainEntryError" ((PVar "src") (PVar "file") (PVar "d")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EVar "d")))
(DTypeSig true "diagIsError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "diagIsError" (PWild) (EVar "False"))
(DTypeSig false "cjHasErrD" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErrD" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig true "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EIf (EBinOp "==" (EVar "path") (EVar "stdinEntry")) (EApp (EVar "loadedSourceOf") (EVar "path")) (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EVar "src")) (arm (PCon "None") () (EApp (EApp (EVar "resultOr") (ELit (LString ""))) (EApp (EVar "readFile") (EVar "path"))))))
(DTypeSig true "cjParseErrJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "cjParseErrJson" ((PVar "target") (PVar "src") (PVar "e")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e")))))))
(DData Public "CheckJson" () ((variant "CjRendered" (ConPos (TyCon "String"))) (variant "CjParts" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))) ())
(DTypeSig true "ppCheckJson" (TyFun (TyCon "CheckJson") (TyCon "String")))
(DFunDef false "ppCheckJson" ((PCon "CjRendered" (PVar "json"))) (EVar "json"))
(DFunDef false "ppCheckJson" ((PCon "CjParts" PWild (PVar "triples"))) (EApp (EVar "cjAllToJson") (EVar "triples")))
(DTypeSig true "checkJsonSingle" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyCon "Bool")))))))))))
(DFunDef false "checkJsonSingle" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingleParts") (EVar "exportsFor")) (EVar "modName")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "src"))) (DoExpr (ETuple (EApp (EVar "ppCheckJson") (EVar "cj")) (EVar "hasErr")))))
(DTypeSig true "checkJsonSingleParts" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyTuple (TyCon "CheckJson") (TyCon "Bool")))))))))))
(DFunDef false "checkJsonSingleParts" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e"))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "front") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EVar "exportsFor")) (EVar "modName")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "parseLocated") (EVar "src")))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))) (DoLet false false (PVar "mainWarns") (EIf (EVar "hasErr") (EListLit) (EBlock (DoLet false false (PVar "entryRaw") (EApp (EVar "parseLocated") (EVar "src"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "entryRaw")))))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EBinOp "++" (EVar "diags") (EVar "mainWarns"))))) (EVar "hasErr")))))))
(DTypeSig true "cjSingleParts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyTuple (TyCon "CheckJson") (TyCon "Bool")))))))
(DFunDef false "cjSingleParts" ((PVar "target") (PVar "src") (PVar "decls") (PVar "diags")) (EBlock (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))) (DoLet false false (PVar "mainWarns") (EIf (EVar "hasErr") (EListLit) (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls")))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EBinOp "++" (EVar "diags") (EVar "mainWarns"))))) (EVar "hasErr")))))
(DTypeSig true "checkJsonFile" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "Bool")))))))))
(DFunDef false "checkJsonFile" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr") PWild) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFileParts") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoExpr (ETuple (EApp (EVar "ppCheckJson") (EVar "cj")) (EVar "hasErr")))))
(DTypeSig true "checkJsonFileParts" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "CheckDrive"))))))))))
(DFunDef false "checkJsonFileParts" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EApp (EVar "cjLoadFailure") (EVar "target")) (EVar "src")) (EVar "stdlibDir")) (EVar "le")) (EVar "True") (EVar "None"))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "program") (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (EApp (EVar "FrontFile") (EVar "m"))) (arm PWild () (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EApp (EVar "desugaredModPairs") (EVar "modsWithPath")))))) (DoLet false false (PVar "chainKey") (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (EApp (EVar "checkDriveReport") (EVar "chainKey"))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib"))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EApp (EApp (EVar "DriveUnblocked") (EVar "chainKey")) (EVar "NoSteps"))) (fa "fiProgram" (EVar "program")))))) (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EMatch (EVar "modsWithPath") (arm (PList (PTuple PWild PWild (PVar "decls"))) () (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "target")) (EVar "src")) (EVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags")))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "target")) (EVar "stdlibDir")) (EVar "mods")) (EFieldAccess (EVar "front") "foDiags"))))) (DoExpr (ETuple (EVar "cj") (EVar "hasErr") (EFieldAccess (EVar "front") "foDriven")))))))))
(DTypeSig true "cjLoadFailure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "CheckJson")))))))
(DFunDef false "cjLoadFailure" ((PVar "target") (PVar "src") (PVar "stdlibDir") (PVar "le")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkJsonLoadErr") (EVar "target")) (EVar "src")) (EVar "stdlibDir")) (EVar "le"))))))
(DTypeSig true "cjGraphParts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool"))))))))
(DFunDef false "cjGraphParts" ((PVar "target") (PVar "stdlibDir") (PVar "mods") (PVar "results")) (EBlock (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "results"))) (DoLet false false (PVar "mainWarns") (EMatch (ETuple (EVar "hasErr") (EApp (EVar "lastDecls") (EVar "mods"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "edecls"))) (arm PWild () (EListLit)))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "root") (EApp (EVar "dirOf") (EVar "stdlibDir"))) (DoLet false false (PVar "relTriples") (EApp (EApp (EVar "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "triples"))) (DoLet false false (PVar "entryKey") (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "target"))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "entryKey")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "entryKey")) (EVar "mainWarns")) (EVar "relTriples"))) (EVar "hasErr")))))
(DTypeSig false "lastDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastDecls" ((PList)) (EVar "None"))
(DFunDef false "lastDecls" ((PList (PTuple PWild (PVar "ds")))) (EApp (EVar "Some") (EVar "ds")))
(DFunDef false "lastDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastDecls") (EVar "rest")))
(DTypeSig false "checkJsonLoadErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool"))))))))
(DFunDef false "checkJsonLoadErr" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "pe"))) (ETuple (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "mpath")) (EVar "msrc")) (EVar "pe"))) (EVar "True")))
(DFunDef false "checkJsonLoadErr" ((PVar "target") (PVar "src") PWild (PCon "LoadCycle" (PVar "cmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "cloc"))) () (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "cpath") (EVar "csrc") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "cmsg")) (EApp (EVar "Some") (EVar "cloc"))) (EVar "None")) (EVar "None")))))) (EVar "True"))) (arm (PCon "None") () (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "cmsg")) (EVar "None")) (EVar "None")) (EVar "None")))))) (EVar "True")))))
(DFunDef false "checkJsonLoadErr" ((PVar "target") (PVar "src") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (EVar "True")))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("driver" "parse_diag_adapter") ((mem "parseDiagnosticToDiag" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "executedMainInputs" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "Ty" false) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberLocal" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorDiagnostic" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "checkDerives" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "ResError" false) (mem "resolveProgram" false) (mem "resolveProgramG2" false) (mem "internalGuardFor" false) (mem "ppResError" false) (mem "resErrorLoc" false) (mem "resErrorCode" false) (mem "resErrorDidYouMean" false) (mem "resErrorIsPrivateName" false) (mem "resolveModuleG" false) (mem "resolveModulesErrorsByFile" false) (mem "importedCtorDeclsStep" false) (mem "withStdlibExports" false) (mem "hintableUnboundNames" false) (mem "exportedValueNames" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" false) (mem "coreExports" false) (mem "useModuleIds" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omKeys" false) (mem "omSize" false) (mem "omRestrict" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "checkGuardExhaustivenessWith" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "preludeStandaloneShadows" false) (mem "preludeStandaloneSet" false) (mem "preludeStandaloneShadowsWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "pubSchemes" false) (mem "TcReport" true) (mem "PartialAnalysis" true) (mem "partialAnalysis" false) (mem "noEntryTables" false) (mem "publishedEntrySchemes" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" true) (mem "chainFullKey" false) (mem "checkModulesChainReportFor" false) (mem "checkModulesEntryFullReportK" false) (mem "checkModulesPartialK" false) (mem "driveInputsFor" false) (mem "dropModSchemes" false) (mem "entrySplit" false) (mem "ModDiags" false) (mem "schemeLines" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "DriveOutputs" true) (mem "emptyDriveOutputs" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "selectedProfile" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "retainModuleInterfaces" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "ppTy" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "loadProgramFilesLocatedCached" false) (mem "loadProgramFilesLocatedCachedE" false) (mem "loadProgramFilesLocatedCachedSourcesE" false) (mem "loadedSourceOf" false) (mem "stdinEntry" false) (mem "parseCachedLocated" false) (mem "loadProgramFilesLocatedE" false) (mem "dropPathTriple" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false) (mem "entrySearchRoots" false) (mem "findImportLoc" false) (mem "unknownModuleIdOf" false) (mem "availableModulesText" false) (mem "availableModulesHint" false) (mem "availableModuleIds" false) (mem "fileOfModuleId" false) (mem "modIdToPath" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "valueMainCandidate" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "contains" false) (mem "joinDot" false) (mem "isSome" false) (mem "lenKey" false) (mem "reverseL" false))))
(DUse false (UseGroup ("support" "timer") ((mem "takePerfSink" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "SymbolDefect" false) (mem "defectCode" false) (mem "defectMessage" false) (mem "defectOrigin" false))))
(DUse false (UseAlias ("backend" "llvm_symbols") "LlvmSymbols"))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" false) (mem "originPosition" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "importedStandaloneShadows" false) (mem "importedStandaloneShadowsIn" false))))
(DUse true (UseGroup ("driver" "diagnostic_value") ((mem "Severity" true) (mem "Fix" true) (mem "Diag" true) (mem "DiagId" true) (mem "mkDiag" false) (mem "diagIdText" false) (mem "diagIdKind" false) (mem "diagIdIsSyntax" false))))
(DTypeSig false "didYouMeanFix" (TyFun (TyCon "ResError") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "didYouMeanFix" ((PVar "e") (PVar "bad") (PVar "sug") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EBinOp "&&" (EApp (EVar "resErrorIsPrivateName") (EVar "e")) (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "sl")) (EBinOp "==" (EVar "ec") (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))) (EVar "sug")))))
(DTypeSig true "resErrorHelpFix" (TyFun (TyCon "ResError") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "resErrorHelpFix" ((PVar "e")) (EMatch (EApp (EVar "resErrorDidYouMean") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "bad") (PVar "sug"))) () (EBlock (DoLet false false (PVar "help") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean `")) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "`?"))))) (DoLet false false (PVar "fix") (EMatch (EApp (EVar "resErrorLoc") (EVar "e")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EApp (EApp (EVar "didYouMeanFix") (EVar "e")) (EVar "bad")) (EVar "sug")) (EVar "l"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))))
(DTypeSig true "diagOfResError" (TyFun (TyCon "ResError") (TyCon "Diag")))
(DFunDef false "diagOfResError" ((PVar "e")) (EBlock (DoLet false false (PTuple (PVar "help") (PVar "fix")) (EApp (EVar "resErrorHelpFix") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EApp (EVar "resErrorCode") (EVar "e")))) (EApp (EVar "ppResError") (EVar "e"))) (EApp (EVar "resErrorLoc") (EVar "e"))) (EVar "help")) (EVar "fix")))))
(DTypeSig true "hintResErrors" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "hintResErrors" ((PVar "exportsFor") (PVar "errs")) (EMatch (EApp (EVar "hintableUnboundNames") (EVar "errs")) (arm (PList) () (EVar "errs")) (arm (PVar "names") () (EApp (EApp (EVar "withStdlibExports") (EApp (EVar "exportsFor") (EVar "names"))) (EVar "errs")))))
(DTypeSig true "noStdlibExports" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "noStdlibExports" (PWild) (EListLit))
(DTypeSig true "stdlibExportsReader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "stdlibExportsReader" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "exportsAmong") (EVar "names")) (EApp (EApp (EApp (EVar "sourcesMentioning") (EVar "stdlibDir")) (EApp (EVar "availableModuleIds") (EVar "stdlibDir"))) (EVar "names"))))
(DTypeSig true "sourcesMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "sourcesMentioning" (PWild PWild (PList)) (EListLit))
(DFunDef false "sourcesMentioning" ((PVar "root") (PVar "ids") (PVar "names")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "sourceMentioning") (EVar "root")) (EVar "names"))) (EVar "ids")))
(DTypeSig false "sourceMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "sourceMentioning" ((PVar "root") (PVar "names") (PVar "mid")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EVar "fileOfModuleId") (EVar "root")) (EVar "mid"))) (arm (PCon "Ok" (PVar "src")) () (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "n")) (EVar "src"))))) (EVar "names")) (EListLit (ETuple (EVar "mid") (EVar "src"))) (EListLit))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig true "exportsAmong" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "exportsAmong" ((PVar "names") (PVar "srcs")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "moduleExportsAmong") (EVar "names"))) (EVar "srcs")))
(DTypeSig false "moduleExportsAmong" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "moduleExportsAmong" ((PVar "names") (PTuple (PVar "mid") (PVar "src"))) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "names")))) (EApp (EVar "exportedValueNames") (EVar "decls"))) (arm (PList) () (EListLit)) (arm (PVar "found") () (EListLit (ETuple (EVar "mid") (EVar "found"))))))))
(DTypeSig true "diagOfTypeError" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeError" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "code"))) (EVar "msg")) (EVar "loc")) (EVar "help")) (EApp (EApp (EMethodRef "map") (EVar "fixOfLocRepl")) (EVar "fix"))))
(DTypeSig false "fixOfLocRepl" (TyFun (TyTuple (TyCon "Loc") (TyCon "String")) (TyCon "Fix")))
(DFunDef false "fixOfLocRepl" ((PTuple (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Fix") (EVar "l")) (EVar "r")))
(DTypeSig false "diagOfTypeWarning" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeWarning" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "w") (PVar "help") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "code"))) (EApp (EVar "stripWarnPrefix") (EVar "w"))) (EVar "loc")) (EVar "help")) (EVar "None")))
(DTypeSig true "diagKind" (TyFun (TyCon "Severity") (TyFun (TyCon "DiagId") (TyCon "String"))))
(DFunDef false "diagKind" ((PCon "SevError") (PVar "code")) (EApp (EVar "diagIdKind") (EVar "code")))
(DFunDef false "diagKind" ((PCon "SevWarning") (PVar "code")) (EIf (EBinOp "==" (EApp (EVar "diagIdKind") (EVar "code")) (ELit (LString "lint"))) (ELit (LString "lint")) (EIf (EVar "otherwise") (ELit (LString "warning")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ppSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "ppSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "ppSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig true "ppDiag" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiag" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "ppDiagCli" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "ppDiagCli" ((PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliSrc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliSrc" ((PVar "src") (PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliLines" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliLines" ((PVar "srcLines") (PVar "file") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "displayPath") (EVar "file")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "nthLineArr") (EVar "srcLines")) (EVar "sl")) (arm (PCon "None") () (EVar "header")) (arm (PCon "Some" (PVar "lineText")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString "\n  |\n"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "lineText"))) (ELit (LString "\n  | "))) (EApp (EMethodRef "display") (EApp (EVar "spaces") (EVar "sc")))) (ELit (LString "^"))))))))
(DFunDef false "ppDiagCliLines" (PWild PWild (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": <unknown location>: "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "renderTcDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renderTcDiags" ((PVar "pathMap") (PVar "ds")) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "ds")) (EListLit)))
(DTypeSig false "renderTcDiagsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "renderTcDiagsGo" (PWild (PList) PWild) (EListLit))
(DFunDef false "renderTcDiagsGo" ((PVar "pathMap") (PCons (PTuple (PVar "mid") (PVar "d")) (PVar "rest")) (PVar "cache")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "pathMap")) (arm (PCon "Some" (PVar "file")) () (EBlock (DoLet false false (PTuple (PVar "lines") (PVar "cache2")) (EApp (EApp (EVar "srcLinesCached") (EVar "file")) (EVar "cache"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "file")) (EApp (EVar "diagOfTypeError") (EVar "d"))) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "rest")) (EVar "cache2")))))) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "++" (EBinOp "++" (ELit (LString "(module ")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString ")")))) (EApp (EVar "diagOfTypeError") (EVar "d"))) (EApp (EApp (EApp (EVar "renderTcDiagsGo") (EVar "pathMap")) (EVar "rest")) (EVar "cache"))))))
(DTypeSig false "srcLinesCached" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Array") (TyCon "String")))))))))
(DFunDef false "srcLinesCached" ((PVar "file") (PVar "cache")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "file")) (EVar "cache")) (arm (PCon "Some" (PVar "ls")) () (ETuple (EVar "ls") (EVar "cache"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ls") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (ETuple (EVar "ls") (EBinOp "::" (ETuple (EVar "file") (EVar "ls")) (EVar "cache"))))))))
(DTypeSig true "hintResErrorPairs" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "hintResErrorPairs" ((PVar "exportsFor") (PVar "pairs")) (EMatch (EApp (EVar "hintableUnboundNames") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "pairs"))) (arm (PList) () (EVar "pairs")) (arm (PVar "names") () (EBlock (DoLet false false (PVar "exports") (EApp (EVar "exportsFor") (EVar "names"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "file") (PVar "errs"))) (ETuple (EVar "file") (EApp (EApp (EVar "withStdlibExports") (EVar "exports")) (EVar "errs"))))) (EVar "pairs")))))))
(DTypeSig true "ppResolveErrorsByFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ppResolveErrorsByFile" ((PVar "pairs")) (EApp (EVar "ppDiagBuckets") (EApp (EApp (EMethodRef "map") (EVar "resolveBucket")) (EVar "pairs"))))
(DTypeSig true "ppDiagBuckets" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "ppDiagBuckets" ((PVar "buckets")) (EApp (EVar "joinNl") (EApp (EVar "ppDiagBucketLines") (EVar "buckets"))))
(DTypeSig false "ppDiagBucketLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ppDiagBucketLines" ((PList)) (EListLit))
(DFunDef false "ppDiagBucketLines" ((PCons (PTuple PWild (PList)) (PVar "rest"))) (EApp (EVar "ppDiagBucketLines") (EVar "rest")))
(DFunDef false "ppDiagBucketLines" ((PCons (PTuple (PVar "file") (PVar "diags")) (PVar "rest"))) (EBlock (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "file")))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "file"))) (EVar "diags")) (EApp (EVar "ppDiagBucketLines") (EVar "rest"))))))
(DTypeSig true "displayPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "displayPath" ((PVar "path")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "./"))) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EIf (EVar "otherwise") (EVar "path") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LChar " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "srcLinesArr" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "String"))))
(DFunDef false "srcLinesArr" ((PVar "src")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs")))))))
(DTypeSig false "srcLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "srcLinesGo" ((PVar "cs") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "charSlice") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "charSlice") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "srcLinesGo") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charSlice" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "j"))) (EVar "cs"))))))
(DTypeSig false "nthLineArr" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nthLineArr" ((PVar "srcLines") (PVar "n")) (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (ELit (LInt 1))) (EBinOp ">" (EVar "n") (EApp (EVar "arrayLength") (EVar "srcLines")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "srcLines"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "analyze" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyze" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "noStdlibExports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parse") (EVar "progSrc"))))
(DTypeSig true "analyzeLocated" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "analyzeLocated" ((PVar "exportsFor") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exportsFor")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))))
(DData Private "SurfaceAnalysis" () ((variant "SurfaceAnalysis" (ConNamed (field "surfaceDiags" (TyApp (TyCon "List") (TyCon "Diag"))) (field "resolveClean" (TyCon "Bool")) (field "surfaceDesugared" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfaceRuntimeP" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfaceCoreP" (TyApp (TyCon "List") (TyCon "Decl"))) (field "surfacePreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))) ())
(DTypeSig true "analyzeFrom" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "analyzeFrom" ((PVar "exportsFor") (PVar "modName") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EVar "exportsFor")) (EVar "modName")) (EVar "True")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "raw")) "foDiags")))
(DTypeSig true "fileFront" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyCon "Unit"))))))))))
(DFunDef false "fileFront" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw")) (EApp (EApp (EApp (EVar "frontEnd") (EVar "exportsFor")) (ELam ((PVar "d")) (EApp (EVar "unkept") (EApp (EApp (EApp (EVar "checkReportOf") (EVar "NoSteps")) (ELit (LString ""))) (EVar "d"))))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EListLit)) (fa "fiRuntimeSrc" (EVar "runtimeSrc")) (fa "fiCoreSrc" (EVar "coreSrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EApp (EVar "FrontFile") (ETuple (EVar "modName") (ELit (LString "")) (EVar "raw"))))))))
(DData Public "CheckDrive" () ((variant "CheckDrive" (ConNamed (field "cdEntrySchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "cdCoreSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "cdOutputs" (TyCon "DriveOutputs")) (field "cdMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "cdPaths" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DData Public "CheckDump" () ((variant "CheckDump" (ConNamed (field "cdLines" (TyApp (TyCon "List") (TyCon "String"))) (field "cdDrive" (TyCon "CheckDrive"))))) ())
(DTypeSig true "graphCheckDrive" (TyFun (TyCon "TcReport") (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "CheckDrive"))))))
(DFunDef false "graphCheckDrive" ((PVar "r") (PVar "outputs") (PVar "modPairs") (PVar "paths")) (ERecordCreate "CheckDrive" ((fa "cdEntrySchemes" (EApp (EVar "pubSchemes") (EApp (EVar "publishedEntrySchemes") (EApp (EApp (EMethodRef "map") (EVar "modOwnSchemes")) (EFieldAccess (EVar "r") "trDiagnostics"))))) (fa "cdCoreSchemes" (EApp (EVar "pubSchemes") (EFieldAccess (EFieldAccess (EVar "r") "trPartial") "paCore"))) (fa "cdOutputs" (EVar "outputs")) (fa "cdMods" (EVar "modPairs")) (fa "cdPaths" (EVar "paths")))))
(DTypeSig false "modOwnSchemes" (TyFun (TyCon "ModDiags") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "modOwnSchemes" ((PTuple (PVar "mid") (PTuple (PVar "schemes") PWild PWild))) (ETuple (EVar "mid") (EVar "schemes")))
(DTypeSig true "checkReportOf" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "String") (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs"))))))
(DFunDef false "checkReportOf" ((PVar "steps") (PVar "chainKey") (PVar "original")) (EBlock (DoLet false false (PVar "d") (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "original") "fdInputs") "diProfileName") (ELit (LString ""))) (EVar "original") (ERecordUpdate (EVar "original") ((fa "fdInputs" (EApp (EApp (EApp (EVar "executedMainInputs") (EFieldAccess (EVar "original") "fdInputs")) (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (ELit (LString "runAsyncMain")))))) (EFieldAccess (EVar "original") "fdPairs"))))))) (DoExpr (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList (PVar "up"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EFieldAccess (EVar "d") "fdCore")) (EListLit (EVar "up")))) (EFieldAccess (EVar "d") "fdPreludeKey")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EListLit (EVar "up")))) (arm (PTuple (PVar "mods") (PVar "pairs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkChainReport") (EVar "steps")) (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EFieldAccess (EVar "d") "fdCore")) (EVar "pairs"))) (EFieldAccess (EVar "d") "fdPreludeKey")) (EVar "chainKey")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EVar "mods")) (EVar "pairs")))))))
(DTypeSig true "checkDriveReport" (TyFun (TyCon "String") (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "CheckDrive") (TyCon "TcReport") (TyCon "DriveOutputs")))))
(DFunDef false "checkDriveReport" ((PVar "chainKey") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "r") (PVar "outputs")) (EApp (EApp (EApp (EVar "checkReportOf") (EVar "NoSteps")) (EVar "chainKey")) (EVar "d"))) (DoLet false false (PVar "drive") (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList PWild)) () (EBlock (DoLet false false (PTuple (PVar "coreSchemes") (PVar "schemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (ERecordCreate "CheckDrive" ((fa "cdEntrySchemes" (EApp (EVar "pubSchemes") (EVar "schemes"))) (fa "cdCoreSchemes" (EApp (EVar "pubSchemes") (EVar "coreSchemes"))) (fa "cdOutputs" (EVar "outputs")) (fa "cdMods" (EFieldAccess (EVar "d") "fdPairs")) (fa "cdPaths" (EListLit))))))) (arm (PTuple (PVar "mods") (PVar "pairs")) () (EApp (EApp (EApp (EApp (EVar "graphCheckDrive") (EVar "r")) (EVar "outputs")) (EVar "pairs")) (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "mods")))))) (DoExpr (ETuple (EVar "drive") (EVar "r") (EVar "outputs")))))
(DTypeSig true "checkFrontDrive" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FrontDriveIn") (TyTuple (TyCon "CheckDump") (TyCon "TcReport") (TyCon "DriveOutputs"))))))
(DFunDef false "checkFrontDrive" ((PVar "target") (PVar "roots") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "drive") (PVar "r") (PVar "outputs")) (EApp (EApp (EVar "checkDriveReport") (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "d"))) (DoLet false false (PVar "lines") (EMatch (ETuple (EFieldAccess (EVar "d") "fdMods") (EFieldAccess (EVar "d") "fdPairs")) (arm (PTuple (PList) (PList PWild)) () (EBlock (DoLet false false (PTuple PWild (PVar "schemes") PWild (PVar "tcWarns")) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "tcWarns")))))) (arm PWild () (EListLit)))) (DoExpr (ETuple (ERecordCreate "CheckDump" ((fa "cdLines" (EVar "lines")) (fa "cdDrive" (EVar "drive")))) (EVar "r") (EVar "outputs")))))
(DTypeSig false "analyzeSurface" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyCon "SurfaceAnalysis")))))))))
(DFunDef false "analyzeSurface" ((PVar "exportsFor") (PVar "modName") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "shadowWarns") (EApp (EApp (EVar "preludeStandaloneShadows") (EBinOp "++" (EVar "runtimeP") (EVar "coreP"))) (EVar "desugared"))) (DoLet false false (PVar "importShadowWarns") (EApp (EApp (EApp (EVar "importedStandaloneShadowsIn") (EVar "omEmpty")) (EListLit)) (EVar "desugared"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EMethodRef "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw")))) (DoLet false false (PVar "resErrs") (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared")))) (DoLet false false (PVar "resDiags") (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EVar "resErrs"))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EMethodRef "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoLet false false (PVar "shadowDiags") (EApp (EApp (EMethodRef "map") (EApp (EVar "preludeShadowWarnToDiag") (EVar "modName"))) (EVar "shadowWarns"))) (DoLet false false (PVar "importShadowDiags") (EApp (EApp (EMethodRef "map") (EApp (EVar "importShadowWarnToDiag") (EVar "modName"))) (EVar "importShadowWarns"))) (DoLet false false (PVar "clean") (EMatch (EVar "resErrs") (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (DoExpr (ERecordCreate "SurfaceAnalysis" ((fa "surfaceDiags" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "shadowDiags")) (EVar "importShadowDiags")) (EVar "resDiags"))) (fa "resolveClean" (EVar "clean")) (fa "surfaceDesugared" (EVar "desugared")) (fa "surfaceRuntimeP" (EVar "runtimeP")) (fa "surfaceCoreP" (EVar "coreP")) (fa "surfacePreludeKey" (EVar "preludeKey")))))))
(DTypeSig true "surfaceErrors" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "surfaceErrors" ((PVar "exportsFor") (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared") (PVar "internalGuard")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw"))) (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))))))
(DTypeSig false "tcHalfOfPerModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "tcHalfOfPerModule" ((PVar "perMod")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeError")) (EApp (EApp (EDictApp "flatMap") (EVar "perModuleErrs")) (EVar "perMod"))) (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeWarning")) (EApp (EApp (EDictApp "flatMap") (EVar "perModuleWarns")) (EVar "perMod")))))
(DTypeSig false "perModuleErrs" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "perModuleErrs" ((PTuple PWild (PTuple (PVar "errs") PWild))) (EVar "errs"))
(DTypeSig false "perModuleWarns" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "perModuleWarns" ((PTuple PWild (PTuple PWild (PVar "warns")))) (EVar "warns"))
(DData Public "FrontProgram" () ((variant "FrontFile" (ConPos (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (variant "FrontGraph" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))) ())
(DData Public "FrontPolicy" () ((variant "NeverDriveRejected" (ConPos)) (variant "DriveUnblocked" (ConPos (TyCon "String") (TyCon "ChainSteps"))) (variant "ResolvedByGate" (ConPos))) ())
(DData Public "ChainSteps" () ((variant "RecordSteps" (ConPos)) (variant "NoSteps" (ConPos))) ())
(DData Public "FrontInput" () ((variant "FrontInput" (ConNamed (field "fiInputs" (TyCon "DriveInputs")) (field "fiAllowInternal" (TyCon "Bool")) (field "fiTrusted" (TyApp (TyCon "List") (TyCon "String"))) (field "fiRuntimeSrc" (TyCon "String")) (field "fiCoreSrc" (TyCon "String")) (field "fiPolicy" (TyCon "FrontPolicy")) (field "fiProgram" (TyCon "FrontProgram"))))) ())
(DData Public "FrontDriveIn" () ((variant "FrontDriveIn" (ConNamed (field "fdInputs" (TyCon "DriveInputs")) (field "fdPreludeKey" (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "fdRuntime" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fdCore" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fdPairs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "fdMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DData Public "FrontOutput" ("a") ((variant "FrontOutput" (ConNamed (field "foDiags" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))) (field "foReport" (TyCon "TcReport")) (field "foOutputs" (TyCon "DriveOutputs")) (field "foDriven" (TyApp (TyCon "Option") (TyVar "a")))))) ())
(DTypeSig false "unkept" (TyFun (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyTuple (TyCon "Unit") (TyCon "TcReport") (TyCon "DriveOutputs"))))
(DFunDef false "unkept" ((PTuple (PVar "r") (PVar "o"))) (ETuple (ELit LUnit) (EVar "r") (EVar "o")))
(DTypeSig true "frontEnd" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "FrontDriveIn") (TyEffect () (Some "e") (TyTuple (TyVar "a") (TyCon "TcReport") (TyCon "DriveOutputs")))) (TyFun (TyCon "FrontInput") (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyVar "a")))))))
(DFunDef false "frontEnd" ((PVar "exportsFor") (PVar "drive") (PVar "fi")) (EMatch (EFieldAccess (EVar "fi") "fiProgram") (arm (PCon "FrontFile" (PTuple (PVar "mid") (PVar "path") (PVar "raw"))) () (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeSurface") (EVar "exportsFor")) (EVar "mid")) (EFieldAccess (EVar "fi") "fiRuntimeSrc")) (EFieldAccess (EVar "fi") "fiCoreSrc")) (EVar "raw")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EFieldAccess (EVar "fi") "fiAllowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EFieldAccess (EVar "fi") "fiTrusted")))))) (DoExpr (EMatch (EFieldAccess (EVar "s") "resolveClean") (arm (PCon "False") () (EApp (EVar "undrivenOutput") (EListLit (ETuple (EVar "path") (EFieldAccess (EVar "s") "surfaceDiags"))))) (arm (PCon "True") () (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "r") (PVar "outputs")) (EApp (EVar "drive") (ERecordCreate "FrontDriveIn" ((fa "fdInputs" (EFieldAccess (EVar "fi") "fiInputs")) (fa "fdPreludeKey" (EFieldAccess (EVar "s") "surfacePreludeKey")) (fa "fdRuntime" (EFieldAccess (EVar "s") "surfaceRuntimeP")) (fa "fdCore" (EFieldAccess (EVar "s") "surfaceCoreP")) (fa "fdPairs" (EListLit (ETuple (ELit (LString "__user__")) (EFieldAccess (EVar "s") "surfaceDesugared")))) (fa "fdMods" (EListLit)))))) (DoLet false false (PVar "tcHalf") (EApp (EVar "tcHalfOfPerModule") (EApp (EApp (EMethodRef "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "r") "trDiagnostics")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "drivenOutput") (EListLit (ETuple (EVar "path") (EBinOp "++" (EFieldAccess (EVar "s") "surfaceDiags") (EVar "tcHalf"))))) (EVar "r")) (EVar "outputs")) (EVar "kept"))))))))) (arm (PCon "FrontGraph" (PVar "mods") (PVar "pairs")) () (EBlock (DoLet false false (PVar "rt") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "fi") "fiRuntimeSrc"))) (DoLet false false (PVar "core") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "fi") "fiCoreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EFieldAccess (EVar "fi") "fiRuntimeSrc")) (EFieldAccess (EVar "fi") "fiCoreSrc")))) (DoLet false false (PVar "driveIn") (ERecordCreate "FrontDriveIn" ((fa "fdInputs" (EFieldAccess (EVar "fi") "fiInputs")) (fa "fdPreludeKey" (EVar "preludeKey")) (fa "fdRuntime" (EVar "rt")) (fa "fdCore" (EVar "core")) (fa "fdPairs" (EVar "pairs")) (fa "fdMods" (EVar "mods"))))) (DoExpr (EMatch (EFieldAccess (EVar "fi") "fiPolicy") (arm (PCon "NeverDriveRejected") () (EBlock (DoLet false false (PVar "resolved") (EApp (EApp (EVar "hintResErrorPairs") (EVar "exportsFor")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "mods"))) (EFieldAccess (EVar "fi") "fiAllowInternal")) (EFieldAccess (EVar "fi") "fiTrusted")) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "pairs")))) (DoExpr (EMatch (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EApp (EVar "snd") (EVar "p")))))) (EVar "resolved")) (arm (PCon "True") () (EApp (EVar "undrivenOutput") (EApp (EApp (EMethodRef "map") (EVar "resolveBucket")) (EVar "resolved")))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EVar "None")) (EVar "driveIn")) (EApp (EApp (EVar "seedAll") (EApp (EApp (EMethodRef "map") (EVar "midPath")) (EVar "mods"))) (EListLit)))))))) (arm (PCon "DriveUnblocked" (PVar "chainKey") (PVar "steps")) () (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvedBuckets") (EVar "exportsFor")) (EFieldAccess (EVar "fi") "fiAllowInternal")) (EFieldAccess (EVar "fi") "fiTrusted")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "rt")) (EVar "core")) (EVar "mods")) (EVar "pairs"))) (DoExpr (EMatch (EApp (EVar "bucketsResolveRejected") (EVar "buckets")) (arm (PCon "True") () (EBlock (DoLet false false (PTuple (PVar "r") (PVar "outputs") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassReport") (EVar "steps")) (EFieldAccess (EVar "fi") "fiInputs")) (EVar "rt")) (EVar "core")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "pairs")) (EVar "buckets"))) (DoExpr (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "results")) (fa "foReport" (EVar "r")) (fa "foOutputs" (EVar "outputs")) (fa "foDriven" (EVar "None"))))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EApp (EApp (EApp (EVar "foldServeKey") (EVar "steps")) (EVar "preludeKey")) (EVar "chainKey"))) (EVar "driveIn")) (EVar "buckets"))))))) (arm (PCon "ResolvedByGate") () (EApp (EApp (EApp (EApp (EVar "drivenGraph") (EVar "drive")) (EVar "None")) (EVar "driveIn")) (EApp (EApp (EVar "seedAll") (EApp (EApp (EMethodRef "map") (EVar "midPath")) (EVar "mods"))) (EListLit))))))))))
(DTypeSig false "drivenGraph" (TyFun (TyFun (TyCon "FrontDriveIn") (TyEffect () (Some "e") (TyTuple (TyVar "a") (TyCon "TcReport") (TyCon "DriveOutputs")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "FrontDriveIn") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect () (Some "e") (TyApp (TyCon "FrontOutput") (TyVar "a"))))))))
(DFunDef false "drivenGraph" ((PVar "drive") (PVar "served") (PVar "d") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "r") (PVar "outputs")) (EApp (EVar "drive") (EVar "d"))) (DoLet false false (PVar "folded") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "outputs")) (EVar "served")) (EFieldAccess (EVar "d") "fdRuntime")) (EFieldAccess (EVar "d") "fdCore")) (EFieldAccess (EVar "d") "fdMods")) (EFieldAccess (EVar "d") "fdPairs")) (EApp (EApp (EMethodRef "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "r") "trDiagnostics"))) (EVar "buckets"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "drivenOutput") (EVar "folded")) (EVar "r")) (EVar "outputs")) (EVar "kept")))))
(DTypeSig false "resolveBucket" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "resolveBucket" ((PTuple (PVar "file") (PVar "errs"))) (ETuple (EVar "file") (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EVar "errs"))))
(DTypeSig false "undrivenOutput" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "FrontOutput") (TyVar "a"))))
(DFunDef false "undrivenOutput" ((PVar "buckets")) (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "buckets")) (fa "foReport" (EVar "undrivenReport")) (fa "foOutputs" (EApp (EVar "emptyDriveOutputs") (ELit LUnit))) (fa "foDriven" (EVar "None")))))
(DTypeSig false "drivenOutput" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyCon "TcReport") (TyFun (TyCon "DriveOutputs") (TyFun (TyVar "a") (TyApp (TyCon "FrontOutput") (TyVar "a")))))))
(DFunDef false "drivenOutput" ((PVar "buckets") (PVar "r") (PVar "outputs") (PVar "kept")) (ERecordCreate "FrontOutput" ((fa "foDiags" (EVar "buckets")) (fa "foReport" (EIf (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "buckets")) (ERecordUpdate (EVar "r") ((fa "trChecked" (EVar "None")))) (EVar "r"))) (fa "foOutputs" (EVar "outputs")) (fa "foDriven" (EApp (EVar "Some") (EVar "kept"))))))
(DTypeSig false "undrivenReport" (TyCon "TcReport"))
(DFunDef false "undrivenReport" () (ERecordCreate "TcReport" ((fa "trPartial" (EApp (EApp (EApp (EVar "partialAnalysis") (EListLit)) (EListLit)) (EVar "noEntryTables"))) (fa "trDiagnostics" (EListLit)) (fa "trResidual" (EListLit)) (fa "trChecked" (EVar "None")) (fa "trEvidenceFaults" (EListLit)))))
(DTypeSig false "deriveErrToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "deriveErrToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RCannotDerive")) (EVar "msg")) (EVar "loc")))
(DTypeSig false "guardWarnToDiag" (TyFun (TyTuple (TyCon "DiagCode") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "guardWarnToDiag" ((PTuple (PVar "code") (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EVar "code")) (EApp (EVar "stripWarnPrefix") (EVar "msg"))) (EVar "loc")))
(DTypeSig false "preludeShadowWarnToDiag" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag"))))
(DFunDef false "preludeShadowWarnToDiag" ((PVar "modName") (PTuple PWild (PVar "mname") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "WPreludeMethodShadow"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "interface method `")) (EVar "mname") (ELit (LString "` shadows the prelude function `")) (EVar "mname") (ELit (LString "`, which is no longer reachable by its bare name in ")) (EApp (EVar "moduleScopeText") (EVar "modName"))))) (EVar "loc")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "rename the interface method `")) (EVar "mname") (ELit (LString "`")))))) (EVar "None")))
(DTypeSig false "importShadowWarnToDiag" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")) (TyCon "Diag"))))
(DFunDef false "importShadowWarnToDiag" ((PVar "modName") (PTuple (PVar "name") (PVar "iface") (PVar "sty") (PVar "mty") (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "Coded") (EVar "WImportMethodShadow"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "imported `")) (EVar "name") (ELit (LString " : ")) (EApp (EVar "importedSchemeText") (EVar "sty")) (ELit (LString "` is shadowed in ")) (EApp (EVar "moduleScopeText") (EVar "modName")) (ELit (LString " by interface method `")) (EVar "iface") (ELit (LString ".")) (EVar "name") (ELit (LString " : ")) (EApp (EVar "ppTy") (EVar "mty")) (ELit (LString "`; at a receiver with an impl of `")) (EVar "iface") (ELit (LString "` the name means the method"))))) (EApp (EVar "Some") (EVar "loc"))) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "import it under another name, `import m.{")) (EVar "name") (ELit (LString " as ")) (EVar "name") (ELit (LString "2}`")))))) (EVar "None")))
(DTypeSig false "importedSchemeText" (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))
(DFunDef false "importedSchemeText" ((PCon "Some" (PVar "t"))) (EApp (EVar "ppTy") (EVar "t")))
(DFunDef false "importedSchemeText" ((PCon "None")) (ELit (LString "no declared signature")))
(DTypeSig false "moduleScopeText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "moduleScopeText" ((PLit (LString ""))) (ELit (LString "this module")))
(DFunDef false "moduleScopeText" ((PVar "m")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "module `")) (EVar "m") (ELit (LString "`")))))
(DTypeSig false "stripWarnPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarnPrefix" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "Warning: "))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "analyzeToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "analyzeToLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppDiag")) (EApp (EApp (EApp (EVar "analyze") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "progSrc")))))
(DTypeSig false "lookupBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "lookupBucket" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBucket" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "putBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PList)) (EListLit (ETuple (EVar "f") (EVar "v"))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PCons (PTuple (PVar "k") (PVar "old")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "old")) (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "v")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pushDiag" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiag" ((PVar "f") (PVar "d") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit (EVar "d"))) (EVar "buckets"))) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "buckets")))))
(DTypeSig false "seedBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedBucket" ((PVar "f") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit)) (EVar "buckets"))) (arm (PCon "Some" PWild) () (EVar "buckets"))))
(DTypeSig false "pushDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiags" (PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "pushDiags" ((PVar "f") (PVar "ds") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "ds")) (EVar "buckets"))) (arm (PCon "Some" (PVar "existing")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "existing") (EVar "ds"))) (EVar "buckets")))))
(DTypeSig false "cachePut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "cachePut" ((PVar "f") (PVar "v") (PVar "xs")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "xs"))))
(DTypeSig false "cacheRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "cacheRemove" (PWild (PList)) (EListLit))
(DFunDef false "cacheRemove" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wrappedRead" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "wrappedRead" ((PVar "cacheRef") (PVar "staleRef") (PVar "parseCacheRef") (PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EVar "parseCachedLocated") (EVar "parseCacheRef")) (EVar "src")) (arm (PCon "Ok" PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EApp (EVar "cachePut") (EVar "path")) (EVar "src")) (EUnOp "!" (EVar "cacheRef"))))) (DoExpr (EApp (EVar "Some") (EVar "src"))))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "staleRef")) (EBinOp "::" (ETuple (EVar "path") (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EUnOp "!" (EVar "staleRef"))))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "path")) (EUnOp "!" (EVar "cacheRef"))) (arm (PCon "Some" (PVar "good")) () (EApp (EVar "Some") (EVar "good"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "src")))))))))))
(DTypeSig true "parseErrDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Diag"))))
(DFunDef false "parseErrDiag" ((PVar "path") (PVar "e")) (EApp (EApp (EVar "parseDiagnosticToDiag") (EVar "path")) (EApp (EVar "parseErrorDiagnostic") (EVar "e"))))
(DTypeSig false "preludeDesugared" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "preludeDesugared" ((PVar "src")) (EApp (EVar "desugaredPrelude") (EVar "src")))
(DTypeSig true "analyzeProject" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "analyzeProject" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectFull") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EVar "results"))))
(DTypeSig true "analyzeProjectFull" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectFull" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectReport") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EVar "report") (arm (PCon "Some" (PVar "r")) () (ETuple (EFieldAccess (EVar "r") "trDiagnostics") (EVar "results"))) (arm (PCon "None") () (ETuple (EListLit) (EVar "results")))))))
(DTypeSig true "analyzeProjectReport" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyCon "TcReport")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectReport" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PTuple (PVar "keyed") (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProjectKeyed") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EApp (EVar "fst") (EApp (EVar "fst") (EVar "k"))))) (EVar "keyed")) (EVar "results")))))
(DData Public "GraphId" () ((variant "GraphId" (ConNamed (field "giEntry" (TyCon "String")) (field "giSteps" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))) ())
(DTypeSig true "graphIdOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "GraphId")))
(DFunDef false "graphIdOf" ((PVar "mods")) (ERecordCreate "GraphId" ((fa "giEntry" (EApp (EVar "lastModId") (EVar "mods"))) (fa "giSteps" (EApp (EApp (EMethodRef "map") (EVar "moduleStepKey")) (EVar "mods"))))))
(DTypeSig false "lastModId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "lastModId" ((PVar "mods")) (EMatch (EApp (EVar "last") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "mid") PWild PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "graphIdSame" (TyFun (TyCon "GraphId") (TyFun (TyCon "GraphId") (TyCon "Bool"))))
(DFunDef false "graphIdSame" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "a") "giEntry") (EFieldAccess (EVar "b") "giEntry")) (EApp (EApp (EVar "allList") (EVar "isSome")) (EFieldAccess (EVar "a") "giSteps"))) (EBinOp "==" (EFieldAccess (EVar "a") "giSteps") (EFieldAccess (EVar "b") "giSteps"))))
(DTypeSig true "analyzeProjectKeyed" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "analyzeProjectKeyed" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectKeyedFromLoad") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "staleRef")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots"))))))
(DTypeSig true "analyzeProjectKeyedSources" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "OrdMap") (TyCon "String")))))))))))))))
(DFunDef false "analyzeProjectKeyedSources" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PTuple (PVar "loaded") (PVar "sources")) (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedSourcesE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots"))) (DoLet false false (PTuple (PVar "keyed") (PVar "diags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectKeyedFromLoad") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "staleRef")) (EVar "loaded"))) (DoExpr (ETuple (EVar "keyed") (EVar "diags") (EVar "sources")))))
(DTypeSig false "projectKeyedFromLoad" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "LoadError")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyEffect ("IO") (Some "e") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphId"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadMsg" (PVar "e")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EVar "None"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadCycle" (PVar "e") (PVar "cpath") (PCon "Some" (PTuple PWild (PVar "loc")))))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "cpath") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EApp (EVar "Some") (EVar "loc")))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Err" (PCon "LoadCycle" (PVar "e") PWild (PCon "None")))) (ETuple (EVar "None") (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "RModuleLoad")) (EVar "e")) (EVar "None"))))))))
(DFunDef false "projectKeyedFromLoad" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "staleRef") (PCon "Ok" (PVar "mods"))) (EBlock (DoLet false false (PVar "chainKey") (EApp (EApp (EVar "chainKeyOf") (EVar "entry")) (EVar "roots"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "exportsFor")) (ELam ((PVar "d")) (EApp (EVar "unkept") (EApp (EApp (EApp (EVar "checkReportOf") (EVar "RecordSteps")) (EVar "chainKey")) (EVar "d"))))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trustedMods")) (fa "fiRuntimeSrc" (EVar "runtimeSrc")) (fa "fiCoreSrc" (EVar "coreSrc")) (fa "fiPolicy" (EApp (EApp (EVar "DriveUnblocked") (EVar "chainKey")) (EVar "RecordSteps"))) (fa "fiProgram" (EApp (EApp (EVar "FrontGraph") (EVar "mods")) (EApp (EVar "desugaredModPairs") (EVar "mods")))))))) (DoExpr (ETuple (EApp (EVar "Some") (ETuple (ETuple (EFieldAccess (EVar "front") "foReport") (EFieldAccess (EVar "front") "foOutputs")) (EApp (EVar "graphIdOf") (EVar "mods")))) (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EFieldAccess (EVar "front") "foDiags"))))))
(DTypeSig false "bucketsResolveRejected" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Bool")))
(DFunDef false "bucketsResolveRejected" ((PVar "buckets")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EApp (EVar "resolveRejected") (EApp (EVar "snd") (EVar "b"))))) (EVar "buckets")))
(DTypeSig true "projectDiagsLoaded" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))
(DFunDef false "projectDiagsLoaded" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods")) (EApp (EVar "snd") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoadedFull") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EApp (EVar "desugaredModPairs") (EVar "mods")))))
(DTypeSig false "projectDiagsLoadedFull" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))))
(DFunDef false "projectDiagsLoadedFull" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassFull") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "modPairs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvedBuckets") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "runtimeP")) (EVar "coreP")) (EVar "mods")) (EVar "modPairs"))))
(DTypeSig true "projectEntrySchemes" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))))))))
(DFunDef false "projectEntrySchemes" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "pa")) (EApp (EVar "publishedEntrySchemes") (EFieldAccess (EVar "pa") "paSchemes")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysis") (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc"))))
(DTypeSig true "projectEntryAnalysis" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "PartialAnalysis")))))))))))
(DFunDef false "projectEntryAnalysis" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntryAnalysisOr") (ELam (PWild) (EVar "None"))) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig true "projectEntryAnalysisOr" (TyFun (TyFun (TyCon "GraphId") (TyApp (TyCon "Option") (TyCon "PartialAnalysis"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "PartialAnalysis"))))))))))))
(DFunDef false "projectEntryAnalysisOr" ((PVar "kept") (PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EVar "preludeDesugared") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "preludeDesugared") (EVar "coreSrc"))) (DoLet false false (PVar "preludeKey") (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "runtimeSrc")) (EVar "coreSrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EApp (EVar "kept") (EApp (EVar "graphIdOf") (EVar "mods"))) (arm (PCon "Some" (PVar "pa")) () (EApp (EVar "Some") (EVar "pa"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPartialK") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit))) (EVar "preludeKey")) (EVar "runtimeP")) (EVar "coreP")) (EApp (EVar "desugarGraph") (EVar "mods")))))))))))
(DTypeSig false "newStale" (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))))))
(DFunDef false "newStale" (PWild) (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "midPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "midPath" ((PTuple PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig true "seedAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedAll" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "seedAll" ((PCons (PVar "f") (PVar "fs")) (PVar "buckets")) (EApp (EApp (EVar "seedAll") (EVar "fs")) (EApp (EApp (EVar "seedBucket") (EVar "f")) (EVar "buckets"))))
(DTypeSig false "appendStale" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendStale" ((PVar "staleRef") (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EUnOp "!" (EVar "staleRef"))) (EVar "buckets")))
(DTypeSig false "foldStale" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "foldStale" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldStale" ((PCons (PTuple (PVar "path") (PVar "d")) (PVar "rest")) (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "path")) (EVar "d")) (EApp (EApp (EVar "seedBucket") (EVar "path")) (EVar "buckets")))))
(DTypeSig false "resolvePass" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))))
(DFunDef false "resolvePass" (PWild PWild PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "resolvePass" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "preludeKey") (PVar "rt") (PVar "core") (PVar "served") (PVar "known") (PVar "ids") (PCons (PAs "m" (PTuple (PVar "mid") (PVar "path") (PVar "desugared"))) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PVar "trusted") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods")))) (DoLet false false (PVar "graph") (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EApp (EVar "joinNl") (EListLit (EVar "k") (EApp (EVar "boolKey") (EVar "trusted")) (EApp (EVar "boolKey") (EBinOp "==" (EApp (EVar "omSize") (EVar "known")) (ELit (LInt 0)))))))) (EVar "served"))) (DoLet false false (PTuple (PVar "diags") (PVar "exp") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "servedPass") (EVar "ResolveKind")) (EVar "graph")) (EVar "ids")) (EVar "m")) (ELam (PWild) (EBlock (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EApp (EVar "internalGuardFor") (EVar "trusted"))) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "known")) (EVar "mid")) (EVar "desugared"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EApp (EApp (EVar "hintResErrors") (EVar "exportsFor")) (EVar "errs"))) (EVar "exp"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "rt")) (EVar "core")) (EVar "served")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EApp (EApp (EApp (EVar "withIdentity") (EVar "mid")) (EVar "ident")) (EVar "ids"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EVar "diags")) (EVar "buckets"))))))
(DTypeSig false "withIdentity" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "withIdentity" ((PVar "mid") (PVar "ident") (PVar "ids")) (EApp (EApp (EApp (EVar "option") (EVar "ids")) (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "i")) (EVar "ids")))) (EVar "ident")))
(DTypeSig false "boolKey" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolKey" ((PCon "True")) (ELit (LString "T")))
(DFunDef false "boolKey" ((PCon "False")) (ELit (LString "F")))
(DTypeSig false "typecheckPassFull" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyTuple (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))))
(DFunDef false "typecheckPassFull" ((PVar "inputs") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "r") PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPassReport") (EVar "NoSteps")) (EVar "inputs")) (EVar "runtimeP")) (EVar "coreP")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "mods")) (EVar "modPairs")) (EVar "buckets"))) (DoExpr (ETuple (EFieldAccess (EVar "r") "trDiagnostics") (EVar "results")))))
(DTypeSig false "typecheckPassReport" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))
(DFunDef false "typecheckPassReport" ((PVar "steps") (PVar "inputs") (PVar "runtimeP") (PVar "coreP") (PVar "preludeKey") (PVar "chainKey") (PVar "mods") (PVar "modPairs") (PVar "buckets")) (EBlock (DoLet false false (PVar "blocked") (EApp (EApp (EApp (EVar "resolveBlockedMods") (EVar "buckets")) (EVar "omEmpty")) (EVar "mods"))) (DoLet false false (PVar "checkedMods") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "blocked"))))) (EVar "mods"))) (DoLet false false (PVar "checkedPairs") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "blocked"))))) (EVar "modPairs"))) (DoLet false false (PVar "rejected") (EApp (EVar "bucketsResolveRejected") (EVar "buckets"))) (DoLet false false (PVar "valueMain") (EBinOp "&&" (EApp (EVar "not") (EVar "rejected")) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreP")) (EVar "modPairs")))) (DoLet false false (PTuple (PVar "driven") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkChainReport") (EVar "steps")) (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "runtimeP")) (EVar "coreP")) (EVar "checkedMods")) (EVar "checkedPairs"))) (DoLet false false (PVar "report") (EIf (EVar "rejected") (ERecordUpdate (EVar "driven") ((fa "trChecked" (EVar "None")))) (EVar "driven"))) (DoExpr (ETuple (EVar "report") (EVar "outputs") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "outputs")) (EApp (EApp (EApp (EVar "foldServeKey") (EVar "steps")) (EVar "preludeKey")) (EVar "chainKey"))) (EVar "runtimeP")) (EVar "coreP")) (EVar "mods")) (EVar "modPairs")) (EApp (EApp (EMethodRef "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "report") "trDiagnostics"))) (EVar "buckets"))))))
(DTypeSig false "checkChainReport" (TyFun (TyCon "ChainSteps") (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs"))))))))))))
(DFunDef false "checkChainReport" ((PVar "steps") (PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "pairs")) (EBlock (DoExpr (EApp (EApp (EVar "narrowInterfaces") (EVar "steps")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesChainReportFor") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EApp (EApp (EVar "stepKeysFor") (EVar "steps")) (EVar "mods"))) (EVar "runtimeP")) (EVar "coreP")) (EVar "pairs")))))
(DTypeSig false "narrowInterfaces" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "narrowInterfaces" ((PCon "RecordSteps") (PVar "mods")) (EApp (EVar "retainModuleInterfaces") (EApp (EApp (EMethodRef "map") (EVar "modIdOf")) (EVar "mods"))))
(DFunDef false "narrowInterfaces" ((PCon "NoSteps") PWild) (ELit LUnit))
(DTypeSig false "modIdOf" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "modIdOf" ((PTuple (PVar "mid") PWild PWild)) (EVar "mid"))
(DTypeSig false "stepKeysFor" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "stepKeysFor" ((PCon "RecordSteps") (PVar "mods")) (EApp (EApp (EMethodRef "map") (EVar "moduleStepKey")) (EVar "mods")))
(DFunDef false "stepKeysFor" ((PCon "NoSteps") PWild) (EListLit))
(DTypeSig false "typecheckDiagsFold" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "typecheckDiagsFold" ((PVar "outputs") (PVar "served") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "modPairs") (PVar "tcByMid") (PVar "buckets")) (EBlock (DoLet false false (PVar "preludeDecls") (EBinOp "++" (EVar "runtimeP") (EVar "coreP"))) (DoLet false false (PVar "desugaredPool") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "modPairs"))) (EVar "omEmpty"))) (DoLet false false (PVar "passes") (ERecordCreate "RawPasses" ((fa "rpCoreExports" (EApp (EVar "coreExports") (EVar "coreP"))) (fa "rpPool" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "rawPairOf")) (EVar "mods"))) (EVar "omEmpty"))) (fa "rpPrelude" (EVar "preludeDecls")) (fa "rpShadowPool" (EApp (EVar "preludeStandaloneSet") (EVar "preludeDecls"))) (fa "rpShadowGraph" (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "preludeDecls")) (EVar "modPairs"))) (fa "rpOutputs" (EVar "outputs")) (fa "rpDesugared" (EVar "desugaredPool")) (fa "rpTc" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "tcByMid"))) (EVar "omEmpty")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "passes")) (EApp (EApp (EApp (EVar "option") (EVar "None")) (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "foldGraphPart") (EVar "k")) (EVar "outputs")) (EVar "mods")) (EApp (EVar "listLen") (EVar "modPairs"))) (EVar "desugaredPool")))) (EVar "served"))) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "mods")) (EVar "buckets")))))
(DData Private "RawPasses" () ((variant "RawPasses" (ConNamed (field "rpCoreExports" (TyCon "ModuleExports")) (field "rpPool" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (field "rpPrelude" (TyApp (TyCon "List") (TyCon "Decl"))) (field "rpShadowPool" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "rpShadowGraph" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "rpOutputs" (TyCon "DriveOutputs")) (field "rpDesugared" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))) (field "rpTc" (TyApp (TyCon "OrdMap") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))) ())
(DTypeSig false "foldServeKey" (TyFun (TyCon "ChainSteps") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "foldServeKey" ((PCon "RecordSteps") (PCon "Some" (PTuple (PVar "rk") (PVar "ck"))) (PVar "chainKey")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey"))))
(DFunDef false "foldServeKey" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "resolvedBuckets" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))))
(DFunDef false "resolvedBuckets" ((PVar "exportsFor") (PVar "allowInternal") (PVar "trustedMods") (PVar "preludeKey") (PVar "chainKey") (PVar "runtimeP") (PVar "coreP") (PVar "mods") (PVar "modPairs")) (EBlock (DoExpr (EIf (EApp (EVar "isSome") (EVar "preludeKey")) (EApp (EVar "retainPassEntries") (EApp (EApp (EMethodRef "map") (EVar "modIdOf")) (EVar "mods"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "exportsFor")) (EVar "allowInternal")) (EVar "trustedMods")) (EVar "preludeKey")) (EVar "runtimeP")) (EVar "coreP")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "rk") (PVar "ck"))) (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")))) (EVar "preludeKey"))) (EVar "omEmpty")) (EVar "omEmpty")) (EApp (EApp (EVar "desugaredTriples") (EVar "mods")) (EVar "modPairs"))) (EApp (EApp (EVar "seedAll") (EApp (EApp (EMethodRef "map") (EVar "midPath")) (EVar "mods"))) (EListLit))))))
(DTypeSig false "desugaredTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "desugaredTriples" ((PCons (PTuple (PVar "mid") (PVar "path") PWild) (PVar "ms")) (PCons (PTuple PWild (PVar "decls")) (PVar "ps"))) (EBinOp "::" (ETuple (EVar "mid") (EVar "path") (EVar "decls")) (EApp (EApp (EVar "desugaredTriples") (EVar "ms")) (EVar "ps"))))
(DFunDef false "desugaredTriples" (PWild PWild) (EListLit))
(DTypeSig true "desugaredModPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugaredModPairs" ((PVar "mods")) (EApp (EVar "desugarGraph") (EVar "mods")))
(DTypeSig false "rawPairOf" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rawPairOf" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig true "midToDesugaredPair" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "midToDesugaredPair" ((PTuple (PVar "mid") (PVar "path") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarModule") (EVar "path")) (EVar "prog"))))
(DTypeSig true "chainKeyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "chainKeyOf" ((PVar "entry") (PVar "roots")) (EApp (EVar "joinNl") (EBinOp "::" (EVar "entry") (EVar "roots"))))
(DTypeSig false "moduleStepKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "moduleStepKey" ((PTuple (PVar "mid") (PVar "path") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "src")) (EApp (EVar "joinNl") (EListLit (EVar "mid") (EVar "path") (EVar "src"))))) (EApp (EVar "loadedSourceOf") (EVar "path"))))
(DTypeSig false "desugarModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarModule" ((PVar "path") (PVar "prog")) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EApp (EVar "desugar") (EVar "prog"))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (EApp (EVar "joinNl") (EListLit (EVar "path") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "moduleDesugarCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleDesugarCacheRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "decls")) (EUnOp "!" (EVar "moduleDesugarCacheRef"))))) (DoExpr (EVar "decls"))))))))))
(DTypeSig false "desugarGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugarGraph" ((PVar "mods")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "midToDesugaredPair")) (EVar "mods"))) (DoLet false false (PVar "old") (EUnOp "!" (EVar "moduleDesugarCacheRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleDesugarCacheRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "mods"))) (EVar "omEmpty")))) (DoExpr (EVar "pairs"))))
(DTypeSig false "keptDesugared" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "keptDesugared" (PWild (PList)) (EListLit))
(DFunDef false "keptDesugared" ((PVar "old") (PCons (PTuple PWild (PVar "path") PWild) (PVar "rest"))) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest"))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (EApp (EVar "joinNl") (EListLit (EVar "path") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "old")) (arm (PCon "Some" (PVar "decls")) () (EBinOp "::" (ETuple (EVar "key") (EVar "decls")) (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "keptDesugared") (EVar "old")) (EVar "rest")))))))))
(DTypeSig false "moduleDesugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "moduleDesugarCacheRef" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "diagCode" (TyFun (TyCon "Diag") (TyCon "DiagId")))
(DFunDef false "diagCode" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "resolveRejected" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Bool")))
(DFunDef false "resolveRejected" () (EApp (EVar "anyList") (ELam ((PVar "d")) (EBinOp "&&" (EApp (EVar "diagIsError") (EVar "d")) (EBinOp "==" (EApp (EVar "diagIdKind") (EApp (EVar "diagCode") (EVar "d"))) (ELit (LString "resolve")))))))
(DTypeSig false "resolveBlockedMods" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "resolveBlockedMods" (PWild (PVar "blocked") (PList)) (EVar "blocked"))
(DFunDef false "resolveBlockedMods" ((PVar "buckets") (PVar "blocked") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "rejected") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "ds")) () (EApp (EVar "resolveRejected") (EVar "ds"))) (arm (PCon "None") () (EVar "False")))) (DoLet false false (PVar "blocks") (EBinOp "||" (EVar "rejected") (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "blocked")))) (EApp (EVar "useModuleIds") (EVar "prog"))))) (DoExpr (EApp (EApp (EApp (EVar "resolveBlockedMods") (EVar "buckets")) (EIf (EVar "blocks") (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EVar "blocked")) (EVar "blocked"))) (EVar "rest")))))
(DTypeSig false "foldModuleTc" (TyFun (TyCon "RawPasses") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))
(DFunDef false "foldModuleTc" (PWild PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldModuleTc" ((PVar "passes") (PVar "graph") (PVar "known") (PVar "ids") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "rawDiags") (PVar "exp") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "servedPass") (EVar "FoldKind")) (EVar "graph")) (EVar "ids")) (ETuple (EVar "mid") (EVar "path") (EVar "prog"))) (ELam (PWild) (EApp (EApp (EApp (EVar "rawTreeDiags") (EVar "passes")) (EVar "known")) (ETuple (EVar "mid") (EVar "path") (EVar "prog")))))) (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EVar "optionOr") (ETuple (EListLit) (EListLit))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "passes") "rpTc")))) (DoLet false false (PVar "tcReported") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "existing")) () (EApp (EVar "not") (EApp (EVar "resolveRejected") (EVar "existing")))) (arm (PCon "None") () (EVar "True")))) (DoLet false false (PVar "errDiags") (EIf (EVar "tcReported") (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeError")) (EVar "tcErrs")) (EListLit))) (DoLet false false (PVar "warnDiags") (EIf (EVar "tcReported") (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeWarning")) (EVar "tcWarns")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "passes")) (EVar "graph")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EApp (EApp (EApp (EVar "withIdentity") (EVar "mid")) (EVar "ident")) (EVar "ids"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EBinOp "++" (EBinOp "++" (EVar "rawDiags") (EVar "errDiags")) (EVar "warnDiags"))) (EVar "buckets"))))))
(DTypeSig false "rawTreeDiags" (TyFun (TyCon "RawPasses") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports"))))))
(DFunDef false "rawTreeDiags" ((PVar "passes") (PVar "known") (PTuple (PVar "mid") PWild (PVar "prog"))) (EBlock (DoLet false false (PVar "desugared") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "passes") "rpDesugared")))) (DoLet false false (PTuple (PVar "imported") (PVar "exp")) (EApp (EApp (EApp (EApp (EVar "importedCtorDeclsStep") (EFieldAccess (EVar "passes") "rpCoreExports")) (EFieldAccess (EVar "passes") "rpPool")) (EVar "known")) (ETuple (EVar "mid") (EVar "desugared")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EVar "imported") (EFieldAccess (EVar "passes") "rpPrelude"))) (EVar "prog"))) (DoLet false false (PVar "shadowDiags") (EApp (EApp (EMethodRef "map") (EApp (EVar "preludeShadowWarnToDiag") (EVar "mid"))) (EApp (EApp (EVar "preludeStandaloneShadowsWith") (EFieldAccess (EVar "passes") "rpShadowPool")) (EVar "desugared")))) (DoLet false false (PVar "importShadowDiags") (EApp (EApp (EMethodRef "map") (EApp (EVar "importShadowWarnToDiag") (EVar "mid"))) (EApp (EApp (EApp (EVar "importedStandaloneShadows") (EFieldAccess (EVar "passes") "rpOutputs")) (EFieldAccess (EVar "passes") "rpShadowGraph")) (EVar "desugared")))) (DoExpr (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "prog"))) (EApp (EApp (EMethodRef "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (EVar "shadowDiags")) (EVar "importShadowDiags")) (EVar "exp")))))
(DData Private "PassKey" () ((variant "PassKey" (ConNamed (field "pkGraph" (TyCon "String")) (field "pkPath" (TyCon "String")) (field "pkSource" (TyCon "String")) (field "pkImports" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))) ())
(DImpl true "Eq" ((TyCon "PassKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "PassKey" ((rf "pkGraph" (PVar "__a0")) (rf "pkPath" (PVar "__a1")) (rf "pkSource" (PVar "__a2")) (rf "pkImports" (PVar "__a3"))) false) (PRec "PassKey" ((rf "pkGraph" (PVar "__b0")) (rf "pkPath" (PVar "__b1")) (rf "pkSource" (PVar "__b2")) (rf "pkImports" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DData Private "PassEntry" () ((variant "PassEntry" (ConNamed (field "peKey" (TyCon "PassKey")) (field "peIdentity" (TyCon "Int")) (field "peDiags" (TyApp (TyCon "List") (TyCon "Diag"))) (field "peExports" (TyCon "ModuleExports"))))) ())
(DData Private "PassCaches" () ((variant "PassCaches" (ConNamed (field "pcResolve" (TyApp (TyCon "OrdMap") (TyCon "PassEntry"))) (field "pcFold" (TyApp (TyCon "OrdMap") (TyCon "PassEntry"))) (field "pcSerial" (TyCon "Int"))))) ())
(DTypeSig false "passCacheRef" (TyApp (TyCon "Ref") (TyCon "PassCaches")))
(DFunDef false "passCacheRef" () (EApp (EVar "Ref") (EApp (EVar "emptyPassCaches") (ELit LUnit))))
(DTypeSig false "emptyPassCaches" (TyFun (TyCon "Unit") (TyCon "PassCaches")))
(DFunDef false "emptyPassCaches" (PWild) (ERecordCreate "PassCaches" ((fa "pcResolve" (EVar "omEmpty")) (fa "pcFold" (EVar "omEmpty")) (fa "pcSerial" (ELit (LInt 0))))))
(DData Private "PassKind" () ((variant "ResolveKind" (ConPos)) (variant "FoldKind" (ConPos))) ())
(DTypeSig false "passEntries" (TyFun (TyCon "PassKind") (TyFun (TyCon "PassCaches") (TyApp (TyCon "OrdMap") (TyCon "PassEntry")))))
(DFunDef false "passEntries" ((PCon "ResolveKind") (PVar "c")) (EFieldAccess (EVar "c") "pcResolve"))
(DFunDef false "passEntries" ((PCon "FoldKind") (PVar "c")) (EFieldAccess (EVar "c") "pcFold"))
(DTypeSig false "retainPassEntries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "retainPassEntries" ((PVar "mids")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (ERecordUpdate (EVar "c") ((fa "pcResolve" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "c") "pcResolve"))) (fa "pcFold" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "c") "pcFold")))))))))
(DTypeSig true "clearProjectPassEntries" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "clearProjectPassEntries" ((PLit LUnit)) (EApp (EVar "retainPassEntries") (EListLit)))
(DTypeSig false "keepPassEntry" (TyFun (TyCon "PassKind") (TyFun (TyCon "String") (TyFun (TyCon "PassEntry") (TyCon "Unit")))))
(DFunDef false "keepPassEntry" ((PVar "kind") (PVar "mid") (PVar "entry")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (EMatch (EVar "kind") (arm (PCon "ResolveKind") () (ERecordUpdate (EVar "c") ((fa "pcResolve" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "entry")) (EFieldAccess (EVar "c") "pcResolve")))))) (arm (PCon "FoldKind") () (ERecordUpdate (EVar "c") ((fa "pcFold" (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "entry")) (EFieldAccess (EVar "c") "pcFold")))))))))))
(DTypeSig false "freshPassIdentity" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "freshPassIdentity" (PWild) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "passCacheRef") "value")) (DoLet false false (PVar "next") (EBinOp "+" (EFieldAccess (EVar "c") "pcSerial") (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "passCacheRef")) (ERecordUpdate (EVar "c") ((fa "pcSerial" (EVar "next")))))) (DoExpr (EVar "next"))))
(DTypeSig true "foldCachedIdentity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "foldCachedIdentity" ((PVar "mid")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EFieldAccess (EVar "e") "peIdentity"))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "passCacheRef") "value") "pcFold"))))
(DTypeSig true "resolveCachedIdentity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "resolveCachedIdentity" ((PVar "mid")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EFieldAccess (EVar "e") "peIdentity"))) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "passCacheRef") "value") "pcResolve"))))
(DTypeSig false "servedPass" (TyFun (TyCon "PassKind") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "servedPass" (PWild (PCon "None") PWild PWild (PVar "compute")) (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EVar "None")))))
(DFunDef false "servedPass" ((PVar "kind") (PCon "Some" (PVar "g")) (PVar "ids") (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "compute")) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EApp (EVar "Some") (EApp (EVar "freshPassIdentity") (ELit LUnit))))))) (arm (PCon "Some" (PVar "src")) () (EBlock (DoLet false false (PVar "key") (ERecordCreate "PassKey" ((fa "pkGraph" (EVar "g")) (fa "pkPath" (EVar "path")) (fa "pkSource" (EVar "src")) (fa "pkImports" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "omLookup") (EVar "i")) (EVar "ids")))) (EApp (EVar "useModuleIds") (EVar "prog"))))))) (DoLet false false (PVar "hit") (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "passEntries") (EVar "kind")) (EFieldAccess (EVar "passCacheRef") "value"))) (arm (PCon "Some" (PVar "e")) () (EIf (EBinOp "==" (EFieldAccess (EVar "e") "peKey") (EVar "key")) (EApp (EVar "Some") (EVar "e")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EMatch (EVar "hit") (arm (PCon "Some" (PVar "e")) () (ETuple (EFieldAccess (EVar "e") "peDiags") (EFieldAccess (EVar "e") "peExports") (EApp (EVar "Some") (EFieldAccess (EVar "e") "peIdentity")))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "diags") (PVar "exp")) (EApp (EVar "compute") (ELit LUnit))) (DoLet false false (PVar "ident") (EApp (EVar "freshPassIdentity") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "keepPassEntry") (EVar "kind")) (EVar "mid")) (ERecordCreate "PassEntry" ((fa "peKey" (EVar "key")) (fa "peIdentity" (EVar "ident")) (fa "peDiags" (EVar "diags")) (fa "peExports" (EVar "exp")))))) (DoExpr (ETuple (EVar "diags") (EVar "exp") (EApp (EVar "Some") (EVar "ident"))))))))))))
(DTypeSig false "foldGraphPart" (TyFun (TyCon "String") (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "foldGraphPart" ((PVar "chainFull") (PVar "outputs") (PVar "mods") (PVar "count") (PVar "pool")) (EBlock (DoLet false false (PVar "declarers") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "mid") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "declaresInterface")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "pool")))))) (EVar "mods"))) (DoLet false false (PVar "rows") (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "path") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "src")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "path")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "src")))) (ELit (LString ""))))) (EApp (EVar "loadedSourceOf") (EVar "path"))))) (EVar "declarers"))) (DoExpr (EIf (EApp (EApp (EVar "allList") (EVar "isSome")) (EVar "rows")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EVar "chainFull")) (EApp (EVar "lenKey") (EApp (EVar "intToString") (EDictApp "count"))) (EApp (EVar "lenKey") (EApp (EVar "ifaceIndexText") (EFieldAccess (EVar "outputs") "doIfaceExports")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "optionOr") (ELit (LString "")))) (EVar "rows"))))) (EVar "None")))))
(DTypeSig false "declaresInterface" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declaresInterface" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "declaresInterface" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declaresInterface") (EVar "d")))
(DFunDef false "declaresInterface" (PWild) (EVar "False"))
(DTypeSig false "ifaceIndexText" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyCon "String")))
(DFunDef false "ifaceIndexText" ((PVar "idx")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "mid")) (EApp (EApp (EVar "ifaceRowsText") (EVar "mid")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "idx"))))) (EApp (EVar "omKeys") (EVar "idx")))))
(DTypeSig false "ifaceRowsText" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyCon "String"))))
(DFunDef false "ifaceRowsText" ((PVar "mid") (PVar "rows")) (EApp (EVar "stringConcat") (EBinOp "::" (EApp (EVar "lenKey") (EVar "mid")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "row"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "joinNl") (EApp (EVar "snd") (EVar "row")))))) (ELit (LString ""))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "rows"))))))
(DTypeSig true "analyzeProjectToLines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "analyzeProjectToLines" ((PVar "cacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EVar "projectLines") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))))))
(DTypeSig false "projectLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectLines" ((PList)) (EListLit))
(DFunDef false "projectLines" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## FILE ")) (EVar "file")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ppDiagLoc")) (EVar "ds")) (EApp (EVar "projectLines") (EVar "rest")))))
(DTypeSig false "ppDiagLoc" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "cjPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "cjPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))))))
(DTypeSig true "cjRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "cjRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "end")) (EApp (EApp (EVar "cjPosition") (EVar "el")) (EVar "ec"))) (ETuple (ELit (LString "start")) (EApp (EApp (EVar "cjPosition") (EVar "sl")) (EVar "sc"))))))
(DTypeSig true "cjRangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "cjRangeOfLoc" ((PLit (LString "")) (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "positions") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "sl")) (EVar "sc"))) (ELam ((PVar "start")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "end")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "start"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "c") (PVar "d")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))))))))))))))) (DoExpr (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EVar "positions")))))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "None")) (EVar "JNull"))
(DTypeSig false "cjSevCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "cjSevCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "cjSevCode" (PWild) (ELit (LInt 2)))
(DTypeSig true "optField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "optField" ((PVar "k") (PCon "Some" (PVar "v"))) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "optField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "cjFixJson" (TyFun (TyCon "Fix") (TyCon "Json")))
(DFunDef false "cjFixJson" () (EApp (EVar "cjFixJsonWithSource") (ELit (LString ""))))
(DTypeSig false "cjFixJsonWithSource" (TyFun (TyCon "String") (TyFun (TyCon "Fix") (TyCon "Json"))))
(DFunDef false "cjFixJsonWithSource" ((PVar "src") (PCon "Fix" (PVar "loc") (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EApp (EVar "Some") (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))
(DFunDef false "cjFixJsonWithSource" ((PVar "src") (PCon "FixEdits" (PVar "applicability") (PVar "edits"))) (EApp (EApp (EApp (EVar "fixEditsJson") (ELam ((PVar "loc")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EApp (EVar "Some") (EVar "loc"))))) (EVar "applicability")) (EVar "edits")))
(DTypeSig true "fixEditsJson" (TyFun (TyFun (TyCon "Loc") (TyCon "Json")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyCon "Json")))))
(DFunDef false "fixEditsJson" ((PVar "rangeOf") (PVar "applicability") (PVar "edits")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "applicability")) (EApp (EVar "JString") (EVar "applicability"))) (ETuple (ELit (LString "edits")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "loc") (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "rangeOf") (EVar "loc"))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))) (EVar "edits"))))))))
(DTypeSig true "cjDiagnostic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "cjDiagnostic" (PWild (PVar "src") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "diagIdText") (EVar "code"))))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cjFixJsonWithSource") (EVar "src"))) (EVar "fix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "help")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EApp (EVar "diagKind") (EVar "sev")) (EVar "code")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EVar "loc"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "cjSevCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))))
(DTypeSig true "cjFileEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Json")))))
(DFunDef false "cjFileEntry" ((PVar "path") (PVar "src") (PVar "diags")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "path")) (EVar "src"))) (EVar "diags"))))))))
(DTypeSig false "cjTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "cjTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig true "cjAllToJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String")))
(DFunDef false "cjAllToJson" ((PVar "triples")) (EApp (EApp (EVar "cjAllToJsonWith") (EListLit)) (EVar "triples")))
(DTypeSig true "cjAllToJsonWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String"))))
(DFunDef false "cjAllToJsonWith" ((PVar "extra") (PVar "triples")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "cjTriple")) (EVar "triples")))))) (EVar "extra")))))
(DTypeSig true "pendingStaleNotice" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pendingStaleNotice" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "pendingPreludeNotices" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "pendingPreludeNotices" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "runEnvelopeFields" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "runEnvelopeFields" (PWild) (EBlock (DoLet false false (PVar "staleF") (EMatch (EUnOp "!" (EVar "pendingStaleNotice")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "msg")) () (EListLit (ETuple (ELit (LString "staleBinary")) (EApp (EVar "JString") (EVar "msg"))))))) (DoLet false false (PVar "preludeF") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "field") (PVar "msg"))) (ETuple (EVar "field") (EApp (EVar "JString") (EVar "msg"))))) (EUnOp "!" (EVar "pendingPreludeNotices")))) (DoLet false false (PVar "perfF") (EMatch (EApp (EVar "takePerfSink") (ELit LUnit)) (arm (PList) () (EListLit)) (arm (PVar "ls") () (EListLit (ETuple (ELit (LString "perf")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EApp (EVar "JString") (EVar "l")))) (EVar "ls"))))))))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "staleF") (EVar "preludeF")) (EVar "perfF")))))
(DTypeSig true "flushRunEnvelope" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("Stderr") (Some "e") (TyCon "Unit"))))
(DFunDef false "flushRunEnvelope" ((PVar "triples")) (EMatch (ETuple (EVar "triples") (EApp (EVar "runEnvelopeFields") (ELit LUnit))) (arm (PTuple (PList) (PList)) () (ELit LUnit)) (arm (PTuple (PVar "ts") (PVar "extra")) () (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "cjAllToJsonWith") (EVar "extra")) (EVar "ts"))))))
(DTypeSig true "readDiagSrc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PList))) (ETuple (EVar "path") (ELit (LString "")) (EListLit)))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PVar "diags"))) (EMatch (EApp (EVar "loadedSourceOf") (EVar "path")) (arm (PCon "Some" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "Err" PWild) () (ETuple (EVar "path") (ELit (LString "")) (EVar "diags")))))))
(DTypeSig true "cohWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "cohWarnsOfTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EVar "path") (EVar "src") (EApp (EApp (EMethodRef "filter") (EVar "isCoherenceWarn")) (EVar "diags"))))
(DTypeSig true "joinedOrNone" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "joinedOrNone" ((PList)) (EVar "None"))
(DFunDef false "joinedOrNone" ((PVar "ls")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig true "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "errs")))))))
(DTypeSig true "renderTripleWarnings" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleWarnings" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EMethodRef "filter") (EVar "diagIsWarn")) (EVar "diags"))) (DoExpr (EMatch (EVar "ws") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "ws")))))))
(DTypeSig true "residualOrGeneric" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "residualOrGeneric" ((PVar "pathMap") (PVar "target") (PVar "residual")) (EMatch (EApp (EApp (EVar "renderTcDiags") (EVar "pathMap")) (EVar "residual")) (arm (PList) () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString " detected during elaboration; no located diagnostic is available for it")))) (arm (PVar "rendered") () (EApp (EVar "joinNl") (EVar "rendered")))))
(DTypeSig true "diagIsWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "diagIsError") (EVar "d"))))
(DTypeSig true "coherenceWarnCode" (TyCon "DiagCode"))
(DFunDef false "coherenceWarnCode" () (EVar "WIncomparableImpls"))
(DTypeSig true "runBuildWarnCodes" (TyApp (TyCon "List") (TyCon "DiagCode")))
(DFunDef false "runBuildWarnCodes" () (EListLit (EVar "coherenceWarnCode") (EVar "WPreludeMethodShadow") (EVar "WImportMethodShadow")))
(DTypeSig true "isCoherenceWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isCoherenceWarn" ((PCon "Diag" (PCon "SevWarning") (PCon "Coded" (PVar "c")) PWild PWild PWild PWild)) (EApp (EApp (EDictApp "elem") (EVar "c")) (EVar "runBuildWarnCodes")))
(DFunDef false "isCoherenceWarn" (PWild) (EVar "False"))
(DTypeSig true "emitDiagExitCode" (TyCon "Int"))
(DFunDef false "emitDiagExitCode" () (ELit (LInt 3)))
(DTypeSig true "renderSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EBlock (DoLet false false (PTuple (PVar "at") (PVar "diag")) (EApp (EApp (EVar "symbolDefectDiag") (EVar "file")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "arrayFromList") (EListLit))) (EVar "at")) (EVar "diag")))))) (EVar "ds")))
(DTypeSig false "symbolDefectDiag" (TyFun (TyCon "String") (TyFun (TyCon "SymbolDefect") (TyTuple (TyCon "String") (TyCon "Diag")))))
(DFunDef false "symbolDefectDiag" ((PVar "file") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "physicalDiag") (EVar "file")) (EApp (EVar "defectOrigin") (EVar "d"))) (EApp (EVar "defectCode") (EVar "d"))) (EApp (EVar "defectMessage") (EVar "d"))))
(DTypeSig false "physicalDiag" (TyFun (TyCon "String") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Diag")))))))
(DFunDef false "physicalDiag" ((PVar "file") (PVar "origin") (PVar "code") (PVar "message")) (EBlock (DoLet false false (PTuple (PVar "f") (PVar "line") (PVar "col")) (EApp (EVar "originPosition") (EVar "origin"))) (DoLet false false (PVar "at") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "file") (EVar "f"))) (DoLet false false (PVar "loc") (EIf (EBinOp "&&" (EBinOp ">" (EVar "line") (ELit (LInt 0))) (EBinOp "/=" (EVar "at") (ELit (LString "")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "at")) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col"))) (EVar "None"))) (DoExpr (ETuple (EVar "at") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "code")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EVar "code"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString "")))) (EVar "loc"))))))
(DTypeSig true "refuseSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EMethodRef "map") (EApp (EVar "symbolDefectDiag") (EVar "file"))) (EVar "ds"))))
(DTypeSig false "refusePhysical" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "refusePhysical" ((PVar "diags")) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "at") (PVar "diag"))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EApp (EVar "readFileSafe") (EVar "at")))) (EVar "at")) (EVar "diag"))))) (EVar "diags"))) (DoExpr (EApp (EVar "stageExit") (EVar "emitDiagExitCode")))))
(DTypeSig true "refuseLlvmSymbolDefects" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "LlvmSymbols.SymbolDefect")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "refuseLlvmSymbolDefects" ((PVar "file") (PVar "ds")) (EApp (EVar "refusePhysical") (EApp (EApp (EMethodRef "map") (EApp (EVar "llvmSymbolDefectDiag") (EVar "file"))) (EVar "ds"))))
(DTypeSig false "llvmSymbolDefectDiag" (TyFun (TyCon "String") (TyFun (TyCon "LlvmSymbols.SymbolDefect") (TyTuple (TyCon "String") (TyCon "Diag")))))
(DFunDef false "llvmSymbolDefectDiag" ((PVar "file") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "physicalDiag") (EVar "file")) (EApp (EVar "LlvmSymbols.defectOrigin") (EVar "d"))) (EApp (EVar "LlvmSymbols.defectCode") (EVar "d"))) (EApp (EVar "LlvmSymbols.defectMessage") (EVar "d"))))
(DTypeSig true "emitGateDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "emitGateDiags" ((PVar "modsWithPath") (PVar "buckets")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "buckets"))) (DoLet false false (PVar "warnSrc") (EMatch (EVar "modsWithPath") (arm (PList PWild) () (EVar "triples")) (arm PWild () (EApp (EApp (EMethodRef "map") (EVar "cohWarnsOfTriple")) (EVar "triples"))))) (DoExpr (ETuple (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleErrors")) (EVar "triples")) (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EBinOp "++" (EVar "warnSrc") (EApp (EVar "mainShapeTriple") (EVar "modsWithPath"))))))))
(DTypeSig false "mainShapeTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mainShapeTriple" ((PVar "mods")) (EMatch (EApp (EVar "lastModTriple") (EVar "mods")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "path") (PVar "decls"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (EApp (EVar "readDiagSrc") (ETuple (EVar "path") (EVar "ws")))))))))
(DTypeSig false "lastModTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModTriple" ((PList)) (EVar "None"))
(DFunDef false "lastModTriple" ((PList (PVar "m"))) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "lastModTriple" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModTriple") (EVar "rest")))
(DTypeSig true "relDiagPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relDiagPath" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path")))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig true "cjFoldIntoFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "cjFoldIntoFile" (PWild (PList) (PVar "triples")) (EVar "triples"))
(DFunDef false "cjFoldIntoFile" (PWild PWild (PList)) (EListLit))
(DFunDef false "cjFoldIntoFile" ((PVar "path") (PVar "extra") (PCons (PTuple (PVar "p") (PVar "s") (PVar "ds")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "path")) (EBinOp "::" (ETuple (EVar "p") (EVar "s") (EBinOp "++" (EVar "ds") (EVar "extra"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "p") (EVar "s") (EVar "ds")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "path")) (EVar "extra")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findMainFunDef" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "findMainFunDef" ((PList)) (EVar "None"))
(DFunDef false "findMainFunDef" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainFunDef") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainFunDef" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") (PVar "body") PWild PWild) PWild)) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "findMainFunDef" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainFunDef") (EVar "rest")))
(DTypeSig true "mainBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainBodyLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "mainBodyLoc") (EVar "f")))
(DFunDef false "mainBodyLoc" ((PCon "EBinOp" PWild (PVar "a") PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EFieldAccess" (PVar "a") PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "EIndex" (PVar "a") PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" ((PCon "ESlice" (PVar "a") PWild PWild PWild)) (EApp (EVar "mainBodyLoc") (EVar "a")))
(DFunDef false "mainBodyLoc" (PWild) (EVar "None"))
(DTypeSig true "mainArityMsg" (TyCon "String"))
(DFunDef false "mainArityMsg" () (ELit (LString "`main` must be a value, not a function; write `main = ...`, not `main () = ...`")))
(DTypeSig true "mainMissingMsg" (TyCon "String"))
(DFunDef false "mainMissingMsg" () (ELit (LString "no `main` in this file; add `main = ...`")))
(DTypeSig true "mainArityWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainArityWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EVar "WMainShape")) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "mainShapeWarnings" (PWild PWild PWild (PVar "entryDecls")) (EMatch (EApp (EVar "mainArityWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "mainEntryError" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainEntryError" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainShape")) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm (PCon "Some" (PTuple (PList) PWild)) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EVar "missingMainDiag") (EVar "decls"))))))
(DTypeSig true "missingMainDiag" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Diag")))
(DFunDef false "missingMainDiag" ((PVar "decls")) (EMatch (EApp (EVar "importedMainMember") (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "modName") (PVar "m"))) () (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainMissing")) (EApp (EApp (EVar "mainImportedMsg") (EVar "modName")) (EVar "m"))) (EApp (EVar "Some") (EApp (EVar "useMemberLoc") (EVar "m"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "WMainMissing")) (EVar "mainMissingMsg")) (EVar "None")))))
(DTypeSig false "mainImportedMsg" (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyCon "String"))))
(DFunDef false "mainImportedMsg" ((PVar "modName") (PCon "UseMember" (PVar "origin") PWild PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "written") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString " as "))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (arm (PCon "None") () (EVar "origin")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`main` must be defined in the entry file, not imported by `import ")) (EApp (EMethodRef "display") (EVar "modName"))) (ELit (LString ".{"))) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "}`; add `main = ...` to this file"))))))
(DTypeSig false "importedMainMember" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "UseMember")))))
(DFunDef false "importedMainMember" ((PList)) (EVar "None"))
(DFunDef false "importedMainMember" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "importedMainMember") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "importedMainMember" ((PCons (PCon "DUse" PWild (PCon "UseGroup" (PVar "ns") (PVar "members")) PWild) (PVar "rest"))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "==" (EApp (EVar "useMemberLocal") (EVar "m")) (ELit (LString "main"))))) (EVar "members")) (arm (PCons (PVar "m") PWild) () (EApp (EVar "Some") (ETuple (EApp (EVar "joinDot") (EVar "ns")) (EVar "m")))) (arm (PList) () (EApp (EVar "importedMainMember") (EVar "rest")))))
(DFunDef false "importedMainMember" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedMainMember") (EVar "rest")))
(DTypeSig false "useMemberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "useMemberLoc" ((PCon "UseMember" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "ppMainEntryError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppMainEntryError" (PWild (PVar "file") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "displayPath") (EVar "file")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppMainEntryError" ((PVar "src") (PVar "file") (PVar "d")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EVar "d")))
(DTypeSig true "diagIsError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "diagIsError" (PWild) (EVar "False"))
(DTypeSig false "cjHasErrD" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErrD" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig true "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EIf (EBinOp "==" (EVar "path") (EVar "stdinEntry")) (EApp (EVar "loadedSourceOf") (EVar "path")) (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EVar "src")) (arm (PCon "None") () (EApp (EApp (EVar "resultOr") (ELit (LString ""))) (EApp (EVar "readFile") (EVar "path"))))))
(DTypeSig true "cjParseErrJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "cjParseErrJson" ((PVar "target") (PVar "src") (PVar "e")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e")))))))
(DData Public "CheckJson" () ((variant "CjRendered" (ConPos (TyCon "String"))) (variant "CjParts" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))) ())
(DTypeSig true "ppCheckJson" (TyFun (TyCon "CheckJson") (TyCon "String")))
(DFunDef false "ppCheckJson" ((PCon "CjRendered" (PVar "json"))) (EVar "json"))
(DFunDef false "ppCheckJson" ((PCon "CjParts" PWild (PVar "triples"))) (EApp (EVar "cjAllToJson") (EVar "triples")))
(DTypeSig true "checkJsonSingle" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyCon "Bool")))))))))))
(DFunDef false "checkJsonSingle" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingleParts") (EVar "exportsFor")) (EVar "modName")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "src"))) (DoExpr (ETuple (EApp (EVar "ppCheckJson") (EVar "cj")) (EVar "hasErr")))))
(DTypeSig true "checkJsonSingleParts" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect () (Some "e") (TyTuple (TyCon "CheckJson") (TyCon "Bool")))))))))))
(DFunDef false "checkJsonSingleParts" ((PVar "exportsFor") (PVar "modName") (PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e"))) (EVar "True"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "front") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileFront") (EVar "exportsFor")) (EVar "modName")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "parseLocated") (EVar "src")))) (DoLet false false (PVar "diags") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))) (DoLet false false (PVar "mainWarns") (EIf (EVar "hasErr") (EListLit) (EBlock (DoLet false false (PVar "entryRaw") (EApp (EVar "parseLocated") (EVar "src"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "entryRaw")))))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EBinOp "++" (EVar "diags") (EVar "mainWarns"))))) (EVar "hasErr")))))))
(DTypeSig true "cjSingleParts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyTuple (TyCon "CheckJson") (TyCon "Bool")))))))
(DFunDef false "cjSingleParts" ((PVar "target") (PVar "src") (PVar "decls") (PVar "diags")) (EBlock (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))) (DoLet false false (PVar "mainWarns") (EIf (EVar "hasErr") (EListLit) (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls")))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EBinOp "++" (EVar "diags") (EVar "mainWarns"))))) (EVar "hasErr")))))
(DTypeSig true "checkJsonFile" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "Bool")))))))))
(DFunDef false "checkJsonFile" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr") PWild) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFileParts") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoExpr (ETuple (EApp (EVar "ppCheckJson") (EVar "cj")) (EVar "hasErr")))))
(DTypeSig true "checkJsonFileParts" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "CheckDrive"))))))))))
(DFunDef false "checkJsonFileParts" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EApp (EVar "cjLoadFailure") (EVar "target")) (EVar "src")) (EVar "stdlibDir")) (EVar "le")) (EVar "True") (EVar "None"))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "program") (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (EApp (EVar "FrontFile") (EVar "m"))) (arm PWild () (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EApp (EVar "desugaredModPairs") (EVar "modsWithPath")))))) (DoLet false false (PVar "chainKey") (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (EApp (EVar "checkDriveReport") (EVar "chainKey"))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib"))) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EApp (EApp (EVar "DriveUnblocked") (EVar "chainKey")) (EVar "NoSteps"))) (fa "fiProgram" (EVar "program")))))) (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EMatch (EVar "modsWithPath") (arm (PList (PTuple PWild PWild (PVar "decls"))) () (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "target")) (EVar "src")) (EVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags")))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "target")) (EVar "stdlibDir")) (EVar "mods")) (EFieldAccess (EVar "front") "foDiags"))))) (DoExpr (ETuple (EVar "cj") (EVar "hasErr") (EFieldAccess (EVar "front") "foDriven")))))))))
(DTypeSig true "cjLoadFailure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "CheckJson")))))))
(DFunDef false "cjLoadFailure" ((PVar "target") (PVar "src") (PVar "stdlibDir") (PVar "le")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkJsonLoadErr") (EVar "target")) (EVar "src")) (EVar "stdlibDir")) (EVar "le"))))))
(DTypeSig true "cjGraphParts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool"))))))))
(DFunDef false "cjGraphParts" ((PVar "target") (PVar "stdlibDir") (PVar "mods") (PVar "results")) (EBlock (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "results"))) (DoLet false false (PVar "mainWarns") (EMatch (ETuple (EVar "hasErr") (EApp (EVar "lastDecls") (EVar "mods"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "edecls"))) (arm PWild () (EListLit)))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "root") (EApp (EVar "dirOf") (EVar "stdlibDir"))) (DoLet false false (PVar "relTriples") (EApp (EApp (EMethodRef "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "triples"))) (DoLet false false (PVar "entryKey") (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "target"))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "entryKey")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "entryKey")) (EVar "mainWarns")) (EVar "relTriples"))) (EVar "hasErr")))))
(DTypeSig false "lastDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastDecls" ((PList)) (EVar "None"))
(DFunDef false "lastDecls" ((PList (PTuple PWild (PVar "ds")))) (EApp (EVar "Some") (EVar "ds")))
(DFunDef false "lastDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastDecls") (EVar "rest")))
(DTypeSig false "checkJsonLoadErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyTuple (TyCon "CheckJson") (TyCon "Bool"))))))))
(DFunDef false "checkJsonLoadErr" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "pe"))) (ETuple (EApp (EVar "CjRendered") (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "mpath")) (EVar "msrc")) (EVar "pe"))) (EVar "True")))
(DFunDef false "checkJsonLoadErr" ((PVar "target") (PVar "src") PWild (PCon "LoadCycle" (PVar "cmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "cloc"))) () (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "cpath") (EVar "csrc") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "cmsg")) (EApp (EVar "Some") (EVar "cloc"))) (EVar "None")) (EVar "None")))))) (EVar "True"))) (arm (PCon "None") () (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "cmsg")) (EVar "None")) (EVar "None")) (EVar "None")))))) (EVar "True")))))
(DFunDef false "checkJsonLoadErr" ((PVar "target") (PVar "src") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoExpr (ETuple (EApp (EApp (EVar "CjParts") (EVar "target")) (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RModuleLoad"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (EVar "True")))))
