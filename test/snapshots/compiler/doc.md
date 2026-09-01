# META
source_lines=679
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/doc.mdk — the native `medaka doc` documentation extractor.
--
-- A faithful port of lib/doc.ml (the OCaml oracle), byte-identical output.
-- Harvests doc comments from the lexer's side-channel (collectComments),
-- matches them to top-level PUBLIC declarations by source position, looks up
-- inferred types from the typechecker (checkOneScheme, the Module-arm
-- single-module analogue of the single-file path lsp.mdk still uses), and
-- renders Markdown.
--
-- Mirrors lib/doc.ml exactly:
--   • comment_body / expand_comment / build_comment_tbl / find_doc_for_line
--   • value_sig / pp_data_variant / pp_record_fields / pp_requires / render_sig
--   • all_letgroup_entries / extract_entries / render_markdown
-- and the pre-desugar `pp_ty_prec` (lib/ast.ml) used for AST-rendered sigs —
-- compiler's types/typecheck.ppTy DROPS effect rows, so doc carries its own
-- precise ppTyP that renders <eff> like OCaml's pp_ty_prec.

import frontend.lexer.{Comment, collectComments, commentLine, commentText}
import frontend.parser.{
  parseWithPositions,
  Positions,
  DeclPos,
  positionsDecls,
  declPosLine,
}
import frontend.ast.{
  Decl(..),
  Ty(..),
  Constraint(..),
  DataVis(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  IfaceMethod(..),
  Require(..),
  LetBind(..),
}
import types.typecheck.{Scheme(..), ppScheme}
import support.util.{
  joinWith,
  reverseL,
  escStr,
  stringTrim,
  splitNl,
  startsWith,
}
import support.path.{baseOf, chopExt}
import driver.diagnostics.{projectEntrySchemes}
import json.{Json, JString, jObject, jArray}
import string.{toLower}

-- ── doc_entry ──────────────────────────────────────────────────────────────
-- de_name / de_sig (never empty) / de_doc (stripped doc prose, may be "").
data DocEntry = DocEntry String String String

-- ── small string helpers (builtins; mirror doctest's local wrappers) ────────
dlen : String -> Int
dlen s = stringLength s

-- stringSlice a b = chars [a, b)
dsub : Int -> Int -> String -> String
dsub a b s = stringSlice a b s

-- ── pre-desugar type rendering (mirror lib/ast.ml pp_ty_prec) ───────────────
-- NOTE: types/typecheck.ppTy drops `TyEffect` rows; OCaml pp_ty_prec renders
-- them, and interface method types carry effect rows.  So we mirror pp_ty_prec
-- here directly, precedence-passing.

ppTyP : Int -> Ty -> String
ppTyP _ (TyCon { tyConName = s }) = s
ppTyP _ (TyVar s) = s
ppTyP _ (TyTuple ts) = "(" ++ joinWith ", " (map (ppTyP 0) ts) ++ ")"
ppTyP p (TyApp f x) =
  let s = "\{ppTyP 1 f} \{ppTyP 2 x}"
  if p >= 2 then "(" ++ s ++ ")" else s
ppTyP p (TyFun a b) =
  let s = "\{ppTyP 1 a} -> \{ppTyP 0 b}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyP p (TyEffect effs tail t) =
  let s = "<\{ppEffInsideDoc effs tail}> \{ppTyP 0 t}"
  if p >= 1 then "(" ++ s ++ ")" else s
-- A bare row atom (#997) is already atomic (no wrapped type), so — unlike
-- `TyEffect` above — it never needs precedence-parens at any `p`.
ppTyP _ (TyRow effs tail _) = "<\{ppEffInsideDoc effs tail}>"
ppTyP _ (TyConstrained cs t) =
  let csStr = match cs
    [c] => ppConstrDoc c
    _ => "(" ++ joinWith ", " (map ppConstrDoc cs) ++ ")"
  "\{csStr} => \{ppTyP 0 t}"

-- shared `<...>` row-body renderer for `TyEffect`/`TyRow` (factored out of
-- `TyEffect`'s arm above so `TyRow` doesn't duplicate it — lint's
-- rule-duplicate-body would flag an inlined copy).
ppEffInsideDoc : List (String, Option String) -> Option String -> String
ppEffInsideDoc effs tail =
  let labs = map ppEffAtomDoc effs
  match tail
    None => joinWith ", " labs
    Some v => match effs
      [] => v
      _ => "\{joinWith ", " labs} | \{v}"

-- effect atom: `l` | `l _` (inferred hole) | `l "dom"` (domain-carrying).
-- Mirror pp_atom in pp_ty_prec: None=>l, Some "_" => l ++ " _", Some s => l ++ " " ++ %S
ppEffAtomDoc : (String, Option String) -> String
ppEffAtomDoc (l, None) = l
-- Intentional cross-file duplicate of the same helper in typecheck.mdk AND eval.mdk's ppEffAtomK; not consolidating (tiny helper / divergent-by-design backend trio).
-- lint-disable-next-line rule-duplicate-body
ppEffAtomDoc (l, Some s) = if s == "_" then l ++ " _" else "\{l} \{escStr s}"

-- a constraint `Iface arg…` (mirror pp_c inside TyConstrained / pp_requires).
ppConstrDoc : Constraint -> String
ppConstrDoc (Constraint { constraintHead = iface, constraintArgs = args }) = match args
  [] => iface
  _ => "\{iface} \{joinWith " " (map (ppTyP 2) args)}"

ppTyDoc : Ty -> String
ppTyDoc t = ppTyP 0 t

-- ── Comment-text extraction (mirror lib/doc.ml) ─────────────────────────────

-- Strip the `-- ` prefix from a line-comment text, returning the bare prose.
--   "--"            -> ""
--   "-- foo"        -> "foo"   (3-char `-- ` prefix)
--   "--foo"         -> "foo"   (len>2, drop first 2)
commentBody : String -> String
commentBody t =
  if t == "--" then
    ""
  else if dlen t >= 3 && dsub 0 3 t == "-- " then
    dsub 3 (dlen t) t
  else if dlen t > 2 then
    dsub 2 (dlen t) t
  else
    ""

-- Expand a comment into (line, text) pairs.  Block comments expand to one entry
-- per inner line (bare trimmed, like lib/doc.ml expand_comment — NOT the
-- doctest `-- ` reshape).  Line comments → [(line, commentBody text)].
expandComment : Comment -> List (Int, String)
expandComment c =
  let t = commentText c
  if dlen t >= 2 && dsub 0 2 t == "{-" then
    let n = dlen t
    -- OCaml String.sub t 2 (n-4): start 2, LENGTH n-4 → end index n-2.
    -- stringSlice takes (start, end), so end = n-2 (drops the 2-char `-}`).
    let inner = if n >= 4 then dsub 2 (n - 2) t else ""
    expandBlockLines (commentLine c) 0 (splitNl inner)
  else
    [(commentLine c, commentBody t)]

expandBlockLines : Int -> Int -> List String -> List (Int, String)
expandBlockLines _ _ [] = []
expandBlockLines baseLine i (line::rest) =
  (baseLine + i, stringTrim line) :: expandBlockLines baseLine (i + 1) rest

-- splitNl → support/util.mdk (imported above; #242 dedup of the splitNl cluster).

-- ── comment table: line -> text (assoc list; later entries win, like
-- Hashtbl.replace which keeps the last inserted for a key) ──────────────────
-- We build an assoc list, then look up by line.  build_comment_tbl iterates
-- comments in order, replacing per line; for lookup we want the LAST text set
-- for a line.  We keep insertion order and `lookupLast` returns the last match.

buildCommentTbl : List Comment -> List (Int, String)
buildCommentTbl comments = concatMapDoc expandComment comments

concatMapDoc : (a -> List b) -> List a -> List b
concatMapDoc _ [] = []
concatMapDoc f (x::xs) = f x ++ concatMapDoc f xs

-- Find the LAST (line,text) pair whose line matches (mirrors Hashtbl.replace
-- semantics: the last insertion for a key wins).
lookupLineLast : List (Int, String) -> Int -> Option String
lookupLineLast tbl line = lookupLineLastGo tbl line None

lookupLineLastGo : List (Int, String) -> Int -> Option String -> Option String
lookupLineLastGo [] _ acc = acc
lookupLineLastGo ((l, t)::rest) line acc =
  if l == line then
    lookupLineLastGo rest line (Some t)
  else
    lookupLineLastGo rest line acc

-- Return doc prose for the decl at [startLine]: the maximal consecutive block
-- of comments immediately above it (no line gap).  Newline-joined + trimmed.
findDocForLine : List (Int, String) -> Int -> String
findDocForLine tbl startLine =
  stringTrim (joinWith "\n" (collectDocLines tbl (startLine - 1) []))

-- Collect backwards; accumulator ends up in ascending line order.
collectDocLines : List (Int, String) -> Int -> List String -> List String
collectDocLines tbl line acc = match lookupLineLast tbl line
  None => acc
  Some text => collectDocLines tbl (line - 1) (text::acc)

-- ── signature rendering (mirror lib/doc.ml) ─────────────────────────────────

ppDataVariant : Variant -> String
ppDataVariant (Variant name (ConPos [])) = name
ppDataVariant (Variant name (ConPos tys)) =
  "\{name} \{joinWith " " (map (ppTyP 2) tys)}"
ppDataVariant (Variant name (ConNamed fs _)) =
  "\{name} { \{joinWith ", " (map ppFieldDoc fs)} }"

ppFieldDoc : Field -> String
ppFieldDoc (Field fn ft) = "\{fn} : \{ppTyDoc ft}"

ppRequiresDoc : List Require -> String
ppRequiresDoc [] = ""
ppRequiresDoc rs = " requires " ++ joinWith ", " (map ppRequireOne rs)

ppRequireOne : Require -> String
ppRequireOne (Require { requireHead = iface, requireArgs = tys }) = match tys
  [] => iface
  _ => "\{iface} \{joinWith " " (map (ppTyP 2) tys)}"

-- Look up the inferred scheme for [name]; fall back to the AST annotation when
-- typecheck produced no scheme (partial results).  Mirror value_sig.
valueSig : String -> List (String, Scheme) -> Option Ty -> String
valueSig name schemes fallbackTy = match lookupScheme name schemes
  Some s => "\{name} : \{ppScheme s}"
  None => match fallbackTy
    Some ty => "\{name} : \{ppTyDoc ty}"
    None => name

-- Last match wins: checkProgramSeeded returns globalS ++ topSchemes, so the
-- user's top-level binding appears LAST (after any same-named interface method
-- scheme from the prelude).  OCaml check_program_impl returns results first
-- and uses List.assoc_opt (first match on a user-first list), so the two
-- are equivalent.  A last-match here mirrors OCaml's user-binding preference.
lookupScheme : String -> List (String, Scheme) -> Option Scheme
lookupScheme name schemes = lookupSchemeGo name schemes None

lookupSchemeGo : String -> List (String, Scheme) -> Option Scheme -> Option Scheme
lookupSchemeGo _ [] acc = acc
lookupSchemeGo name ((n, s)::rest) acc =
  if name == n then
    lookupSchemeGo name rest (Some s)
  else
    lookupSchemeGo name rest acc

-- A rendered interface method line: `  name : ty`.
ppIfaceMethod : IfaceMethod -> String
ppIfaceMethod (IfaceMethod mname mty _ _) = "  \{mname} : \{ppTyDoc mty}"

-- Compute (name, sig) for a public decl, or None to skip it.  Mirror render_sig.
renderSig : Decl -> List (String, Scheme) -> Option (String, String)
renderSig (DTypeSig True name ty) schemes =
  Some (name, valueSig name schemes (Some ty))
renderSig (DFunDef True name _ _) schemes =
  Some (name, valueSig name schemes None)
renderSig (DExtern True name ty) schemes =
  Some (name, valueSig name schemes (Some ty))
renderSig (DLetGroup True bindings) schemes = match bindings
  (LetBind name _)::_ => Some (name, valueSig name schemes None)
  [] => None
renderSig (DData { dataVis = vis, dataName = name, dataParams = params, dataCtors = variants }) _
  | not (dataVisPrivate vis) =
    let head = joinWith " " (name::params)
    let body = match variants
      [] => ""
      _ => "\n  = " ++ joinWith "\n  | " (map ppDataVariant variants)
    Some (name, "data \{head}\{body}")
renderSig (DInterface { pub = True, name, typarams, methods }) _ =
  let head = joinWith " " (name::typarams)
  let ms = map ppIfaceMethod methods
  let body = match ms
    [] => ""
    _ => "\n" ++ joinWith "\n" ms
  Some (name, "interface \{head}\{body}")
renderSig (DTypeAlias { tyAliasPub = True, tyAliasName = name, tyAliasParams = params, tyAliasRhs = ty }) _ =
  let head = joinWith " " (name::params)
  Some (name, "type \{head} = \{ppTyDoc ty}")
renderSig (DNewtype { newtypePub = True, newtypeName = name, newtypeParams = params, newtypeCtor = ctor, newtypeFieldTy = ty }) _ =
  let head = joinWith " " (name::params)
  Some (name, "newtype \{head} = \{ctor} \{ppTyP 2 ty}")
renderSig (DImpl { pub = True, iface, tys, reqs }) _ =
  let args = match tys
    [] => ""
    _ => " " ++ joinWith " " (map (ppTyP 2) tys)
  Some (iface ++ args, "impl \{iface}\{args}\{ppRequiresDoc reqs}")
renderSig _ _ = None

dataVisPrivate : DataVis -> Bool
dataVisPrivate VisPrivate = True
dataVisPrivate _ = False

-- ── entry extraction (mirror lib/doc.ml) ────────────────────────────────────

-- Expand a public DLetGroup into one (name, DocEntry) per binding.
allLetgroupEntries : Bool -> List LetBind -> Int -> List (String, Scheme) -> List (Int, String) -> List (String, DocEntry)
allLetgroupEntries False _ _ _ _ = []
allLetgroupEntries True bindings line schemes tbl =
  let doc = findDocForLine tbl line
  letgroupEntriesGo bindings schemes doc

letgroupEntriesGo : List LetBind -> List (String, Scheme) -> String -> List (String, DocEntry)
letgroupEntriesGo [] _ _ = []
letgroupEntriesGo ((LetBind name _)::rest) schemes doc =
  let sigStr = valueSig name schemes None
  (name, DocEntry name sigStr doc) :: letgroupEntriesGo rest schemes doc

-- The driver: zip decls with their positions, fold collecting entries, dedup by
-- name (first wins), emit in source order.  Mirror extract_entries.
extractEntries : List Decl -> List DeclPos -> List (String, Scheme) -> List Comment -> List DocEntry
extractEntries decls positions schemes comments =
  let tbl = buildCommentTbl comments
  let pairs = zipDoc decls positions
  let result = extractFold pairs schemes tbl [] []
  reverseL (fst result)

-- Fold over (decl, pos) pairs.  State: (revEntries, seenNames).  Returns it.
extractFold : List (Decl, DeclPos) -> List (String, Scheme) -> List (Int, String) -> List DocEntry -> List String -> (List DocEntry, List String)
extractFold [] _ _ revEntries seen = (revEntries, seen)
extractFold ((decl, dp)::rest) schemes tbl revEntries seen =
  let line = declPosLine dp
  match letgroupOf decl
    Some (isPub, bindings) =>
      let extras = allLetgroupEntries isPub bindings line schemes tbl
      let acc = foldExtras extras revEntries seen
      extractFold rest schemes tbl (fst acc) (snd acc)
    None => match renderSig decl schemes
      None => extractFold rest schemes tbl revEntries seen
      Some (name, sigStr) => if memberStr name seen then extractFold rest schemes tbl revEntries seen
      else
        let doc = findDocForLine tbl line
        extractFold
          rest
          schemes
          tbl
          (DocEntry name sigStr doc :: revEntries)
          (name::seen)

-- Add each letgroup extra if its name is unseen (first wins).
foldExtras : List (String, DocEntry) -> List DocEntry -> List String -> (List DocEntry, List String)
foldExtras [] revEntries seen = (revEntries, seen)
foldExtras ((name, e)::rest) revEntries seen =
  if memberStr name seen then
    foldExtras rest revEntries seen
  else
    foldExtras rest (e::revEntries) (name::seen)

-- Match a DLetGroup, returning (is_pub, bindings) or None.
letgroupOf : Decl -> Option (Bool, List LetBind)
letgroupOf (DLetGroup isPub bindings) = Some (isPub, bindings)
letgroupOf _ = None

memberStr : String -> List String -> Bool
memberStr _ [] = False
memberStr x (y::ys)
  | x == y = True
  | otherwise = memberStr x ys

zipDoc : List a -> List b -> List (a, b)
zipDoc [] _ = []
zipDoc _ [] = []
zipDoc (x::xs) (y::ys) = (x, y) :: zipDoc xs ys

-- ── Markdown rendering (mirror render_markdown) ─────────────────────────────
--
-- S-doc-library-mode rendering fixes (contract §4 E): the extracted doc prose
-- can (1) start with a literal `| ` Haddock marker (`{- | ... -}` / `-- | ...`
-- — the block/line-comment convention that flags a comment as attached doc
-- prose rather than a stray note) which must be stripped, not rendered, and
-- (2) contain a doctest example (`> expr` + its expected-output lines up to
-- the next blank line/EOF, doctest.mdk's own `-- > ` convention after
-- `commentBody` strips the leading `-- `) which must render as a fenced code
-- block, not a Markdown blockquote.  `renderDocProse` is the single place
-- both fixes apply, so every consumer (per-entry docs, the module header lead
-- paragraph) gets clean Markdown.

-- Strip a leading `| ` (or bare `|`) marker from a prose line. Normally only
-- the very first line of a marked comment carries it (`{- | ... -}` marks
-- once at the top; a continuation `--   line two` never repeats it) — BUT a
-- decorative, unmarked section-separator comment (`-- ── Duration ──`,
-- `stdlib/time.mdk`) can sit directly above a `-- | ...`-marked one with no
-- blank line between, and `findDocForLine`'s proximity rule merges both into
-- one doc block, putting the marker on an interior line. So this strips `| `
-- from EVERY prose line, not just the first — applied only in `ModeProse`
-- below, never inside a doctest example block, where a leading `|` would be
-- real (if unlikely) expected output, not a marker.
stripPipePrefix : String -> String
stripPipePrefix line =
  if dlen line >= 2 && dsub 0 2 line == "| " then
    dsub 2 (dlen line) line
  else if line == "|" then
    ""
  else
    line

-- A run of extracted doc-prose lines is either plain prose or a doctest
-- example block (starts at a `> ` line, extends through following non-blank
-- lines — its expected-output lines — up to the next blank line or EOF).
data DocSegment = ProseSeg (List String) | ExampleSeg (List String)
data SegMode = ModeProse | ModeExample

isExampleStart : String -> Bool
isExampleStart line = dlen line >= 2 && dsub 0 2 line == "> "

allBlankLines : List String -> Bool
allBlankLines [] = True
allBlankLines (x::xs) = x == "" && allBlankLines xs

-- Flush the current accumulator (source order) as a segment, dropping an
-- all-blank prose run (keeps paragraph gaps from becoming empty segments).
pushSeg : SegMode -> List String -> List DocSegment -> List DocSegment
pushSeg _ [] segs = segs
pushSeg ModeProse acc segs =
  let ls = reverseL acc
  if allBlankLines ls then segs else ProseSeg ls :: segs
pushSeg ModeExample acc segs = ExampleSeg (reverseL acc) :: segs

docSegGo : List String -> SegMode -> List String -> List DocSegment -> List DocSegment
docSegGo [] mode acc segs = reverseL (pushSeg mode acc segs)
docSegGo (line::rest) ModeProse acc segs =
  if isExampleStart line then
    docSegGo rest ModeExample [line] (pushSeg ModeProse acc segs)
  else
    docSegGo rest ModeProse (stripPipePrefix line :: acc) segs
docSegGo (line::rest) ModeExample acc segs =
  if line == "" then
    docSegGo rest ModeProse [] (pushSeg ModeExample acc segs)
  else
    docSegGo rest ModeExample (line::acc) segs

docSegments : List String -> List DocSegment
docSegments lines = docSegGo lines ModeProse [] []

renderDocSegment : DocSegment -> String
renderDocSegment (ProseSeg ls) = joinWith "\n" ls
renderDocSegment (ExampleSeg ls) = "```medaka\n" ++ joinWith "\n" ls ++ "\n```"

-- Render extracted doc prose (an entry's own doc, or a module's header
-- comment) as valid Markdown: marker stripped, doctest examples fenced.
renderDocProse : String -> String
renderDocProse doc =
  if doc == "" then ""
  else
    let segs = docSegments (splitNl doc)
    joinWith "\n\n" (map renderDocSegment segs)

-- The module's own header: the comment block starting at the FIRST comment
-- in the file (contiguous by line — stops at the first line with no comment),
-- independent of whether it is adjacent to the first decl (it usually isn't —
-- this file's own header, lines 1-16, is followed by a blank line before the
-- first `import`).  `tbl` is the same (line, text) assoc list `findDocForLine`
-- reads; comments arrive from `collectComments` in ascending source order.
moduleHeaderFrom : List (Int, String) -> String
moduleHeaderFrom [] = ""
moduleHeaderFrom ((startLine, text)::rest) =
  stringTrim (joinWith
    "\n"
    (collectHeaderLines ((startLine, text)::rest) startLine))

collectHeaderLines : List (Int, String) -> Int -> List String
collectHeaderLines tbl line = match lookupLineLast tbl line
  None => []
  Some text => text :: collectHeaderLines tbl (line + 1)

renderMarkdown : String -> String -> List DocEntry -> String
renderMarkdown moduleName header entries =
  let titleBlock = "# " ++ moduleName ++ "\n\n"
  let headerProse = renderDocProse header
  let headerBlock = if headerProse == "" then "" else headerProse ++ "\n\n"
  stringConcat (titleBlock :: headerBlock :: map renderEntry entries)

renderEntry : DocEntry -> String
renderEntry (DocEntry name sig doc) =
  let header = "## `" ++ name ++ "`\n\n"
  let sigBlock = "```\n" ++ sig ++ "\n```\n"
  let rendered = renderDocProse doc
  let docBlock = if rendered == "" then "" else "\n" ++ rendered ++ "\n"
  "\{header}\{sigBlock}\{docBlock}\n"

-- ── top-level driver ────────────────────────────────────────────────────────
-- Mirror bin/main.ml's `doc` arm: parse (capturing positions + comments),
-- typecheck a desugared copy for schemes ([] on type error), extract entries
-- from the RAW (pre-desugar) program + positions, render Markdown.
--
-- runtimeSrc / coreSrc are the prelude sources (runtime.mdk + core.mdk), read
-- by the caller from MEDAKA_ROOT; src is the target file; filename gives the
-- module-name basename; roots are the import search roots (mirrors `check`'s
-- `entrySearchRoots (dirOf2 target) ++ [stdlibDir]`, medaka_cli.mdk:583) so an
-- import-bearing target resolves its siblings before inferring schemes.
export
runDoc : String -> String -> String -> String -> List String -> <IO> String
runDoc runtimeSrc coreSrc src filename roots = match computeModuleDoc runtimeSrc coreSrc src filename roots
  ModuleDoc name header entries => renderMarkdown name header entries

-- ── library mode (S-doc-library-mode) ───────────────────────────────────────
-- A module's full extracted doc: name (page/index title, page filename minus
-- `.md`), header (lead paragraph, from `moduleHeaderFrom`), and entries.
-- Abstract export: `medaka_cli.mdk`'s library-mode driver reads it only
-- through the accessors + `renderModulePage`/`renderIndex`/
-- `libraryInventoryJson` below, never by constructing/pattern-matching it
-- itself.
export data ModuleDoc = ModuleDoc String String (List DocEntry)

export
mdName : ModuleDoc -> String
mdName (ModuleDoc n _ _) = n

export
mdEntries : ModuleDoc -> List DocEntry
mdEntries (ModuleDoc _ _ es) = es

-- Shared by `runDoc` (single-file) and library mode: parse, infer schemes,
-- extract entries + the module header, in one place so both modes see
-- identical resolution behavior (S-doc-multimodule's per-module scheme fix
-- included).
export
computeModuleDoc : String -> String -> String -> String -> List String -> <IO> ModuleDoc
computeModuleDoc runtimeSrc coreSrc src filename roots =
  let parsed = parseWithPositions src
  let rawDecls = fst parsed
  let positions = positionsDecls (snd parsed)
  let comments = collectComments src
  let schemes = docSchemesFor runtimeSrc coreSrc filename roots rawDecls
  let moduleName = chopExt (baseOf filename)
  let tbl = buildCommentTbl comments
  let header = moduleHeaderFrom tbl
  let entries = extractEntries rawDecls positions schemes comments
  ModuleDoc moduleName (dedupHeader header entries) entries

-- When the header comment sits directly above the FIRST decl with no gap
-- (no blank line — e.g. `test/doc_fixtures/multiline.mdk`), `findDocForLine`
-- (unchanged extraction logic) legitimately attaches that SAME comment block
-- to that decl's own doc too — so the naive header would render identical
-- text twice, once as the lead paragraph and once as the first entry's own
-- doc.  Drop the header in that one case; keep it whenever it differs (the
-- usual case, a gap before the first decl — `stdlib/list.mdk`, this file).
dedupHeader : String -> List DocEntry -> String
dedupHeader header entries =
  if header /= "" && header == firstEntryDoc entries then
    ""
  else
    header

firstEntryDoc : List DocEntry -> String
firstEntryDoc [] = ""
firstEntryDoc ((DocEntry _ _ doc)::_) = doc

export
renderModulePage : ModuleDoc -> String
renderModulePage (ModuleDoc name header entries) =
  renderMarkdown name header entries

-- `async` is excluded from library mode BY CONSTRUCTION: the rule keys on the
-- module's own derived NAME (post `chopExt`/`baseOf`, the same value that
-- becomes the page's `# name` heading and filename), not on the literal path
-- `stdlib/async.mdk` — so a fixture module also named `async` (anywhere) is
-- excluded too, not just the real stdlib one.  Async's design is locked
-- (ASYNC-DESIGN.md) but excluded from the public docs per the 0.1.0 epic
-- decision (project_0_1_0_epic_rederivation memory: "async EXCLUDED from
-- docs").  A single named check, not a growable list, is the rule this slice
-- is licensed to add — widening it needs a fresh decision, not a bigger list.
export
excludedLibraryModule : String -> Bool
excludedLibraryModule moduleName = moduleName == "async"

-- GitHub's auto-anchor slug for a `## \`name\`` header: lowercase, run of
-- non `[a-z0-9_-]` chars collapses to one `-`, leading/trailing `-` trimmed.
-- Exact enough for the plain identifiers most entries render as; an impl
-- entry's compound name (`Debug (Array a)`) still gets a stable (if not
-- necessarily GitHub-exact) anchor — same-page linking never depended on
-- exactness, only on the entry's OWN header and the index's link agreeing,
-- which `slugifyAnchor` guarantees by construction (both read from the same
-- function).
export
slugifyAnchor : String -> String
slugifyAnchor name =
  let lowered = toLower name
  let chars = stringToChars lowered
  let n = arrayLength chars
  stringTrimDashes (slugCharsGo chars 0 n)

-- Walk char-by-char (`arrayGetUnsafe`/`arrayLength` — both globals, no
-- `array` module import needed), mapping a non slug-char to `-` and
-- collapsing adjacent `-` as we go (so we never materialize the
-- un-collapsed string).
slugCharsGo : Array Char -> Int -> Int -> String
slugCharsGo chars i n =
  if i >= n then ""
  else
    let c = arrayGetUnsafe i chars
    let rest = slugCharsGo chars (i + 1) n
    if isSlugChar c then
      charToStr c ++ rest
    else if dlen rest > 0 && dsub 0 1 rest == "-" then
      rest
    else
      "-" ++ rest

isSlugChar : Char -> Bool
isSlugChar c = c >= 'a' && c <= 'z'
  || c >= '0' && c <= '9'
  || c == '_'
  || c == '-'

stringTrimDashes : String -> String
stringTrimDashes s = stringTrimDashEnd (stringTrimDashStart s)

stringTrimDashStart : String -> String
stringTrimDashStart s =
  if dlen s >= 1 && dsub 0 1 s == "-" then
    stringTrimDashStart (dsub 1 (dlen s) s)
  else
    s

stringTrimDashEnd : String -> String
stringTrimDashEnd s =
  if dlen s >= 1 && dsub (dlen s - 1) (dlen s) s == "-" then
    stringTrimDashEnd (dsub 0 (dlen s - 1) s)
  else
    s

-- Machine-readable inventory (#2306 step 1's artifact): every documented
-- name -> module -> signature, across the library.
export
libraryInventoryJson : List ModuleDoc -> Json
libraryInventoryJson mds = jArray (concatMapDoc inventoryEntriesFor mds)

inventoryEntriesFor : ModuleDoc -> List Json
inventoryEntriesFor (ModuleDoc moduleName _ entries) =
  map (inventoryEntryJson moduleName) entries

inventoryEntryJson : String -> DocEntry -> Json
inventoryEntryJson moduleName (DocEntry name sig _) = jObject
  [
    ("module", JString moduleName),
    ("name", JString name),
    ("signature", JString sig),
  ]

-- Index page: one section per module, linking every entry to its own page's
-- anchor.
export
renderIndex : List ModuleDoc -> String
renderIndex mds =
  stringConcat ("# Library Index\n\n" :: map renderIndexModule mds)

renderIndexModule : ModuleDoc -> String
renderIndexModule (ModuleDoc name _ entries) =
  let count = intToString2 (listLenDoc entries)
  let head = "## `\{name}` (\{count} entries)\n\n"
  let links = joinWith "\n" (map (renderIndexLink name) entries)
  "\{head}\{links}\n\n"

renderIndexLink : String -> DocEntry -> String
renderIndexLink moduleName (DocEntry name _ _) =
  "- [`\{name}`](\{moduleName}.md#\{slugifyAnchor name})"

listLenDoc : List a -> Int
listLenDoc [] = 0
listLenDoc (_::xs) = 1 + listLenDoc xs

intToString2 : Int -> String
intToString2 n = intToString n

-- Inferred schemes via the SAME multi-module loader path `check`/`run`/LSP
-- project-hover use (`projectEntrySchemes`, driver.diagnostics) — loads the
-- import graph rooted at `filename`, typechecks it, and returns the entry
-- module's own top-level schemes with siblings resolved.  #213: the prior
-- single-module `checkOneScheme runtimeDecls coreDecls ("__user__", rawUser)`
-- left any name imported from a non-core sibling unbound during the check, so
-- an inferred (no `DTypeSig`) entry whose signature depended on an import
-- rendered wrong or missing.  A fresh `Ref []` cache/parseCache per call is
-- correct here — `doc` is a single CLI invocation, no cross-call reuse.
-- `projectEntrySchemes` returns `None` only on a LOAD error (missing/cyclic
-- import), never on a type error; a no-import file cannot hit a load error,
-- so falling back to `[]` on `None` changes nothing for the no-import case.
-- Unlike lsp.mdk's completion consumer, this call site only ever looks up
-- schemes BY NAME for names the caller already knows it declared
-- (extractEntries/renderSig, never a full-environment enumeration).
docSchemesFor : String -> String -> String -> List String -> List Decl -> <IO> List (String, Scheme)
docSchemesFor runtimeSrc coreSrc filename roots rawUser = match projectEntrySchemes (Ref []) (Ref []) (_ => None) filename roots runtimeSrc coreSrc
  None => []
  Some schemes => schemes
# DESUGAR
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false) (mem "splitNl" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "dlen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dlen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "dsub" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dsub" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "ppTyP" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyP" (PWild (PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInsideDoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideDoc" ((PVar "effs") (PVar "tail")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EVar "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm (PCon "Some" (PVar "v")) () (EMatch (EVar "effs") (arm (PList) () (EVar "v")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentBody") (EVar "t"))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line"))) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (EVar "t"))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (EVar "text") (EVar "acc"))))))
(DTypeSig false "ppDataVariant" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PList)))) (EVar "name"))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fs") PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppFieldDoc")) (EVar "fs"))))) (ELit (LString " }"))))
(DTypeSig false "ppFieldDoc" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "ppFieldDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ft")))) (ELit (LString ""))))
(DTypeSig false "ppRequiresDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "String")))
(DFunDef false "ppRequiresDoc" ((PList)) (ELit (LString "")))
(DFunDef false "ppRequiresDoc" ((PVar "rs")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppRequireOne")) (EVar "rs")))))
(DTypeSig false "ppRequireOne" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "ppRequireOne" ((PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "tys"))) false)) (EMatch (EVar "tys") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))))
(DTypeSig false "valueSig" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PVar "fallbackTy")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EVar "fallbackTy") (arm (PCon "Some" (PVar "ty")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderSig" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PCon "DExtern" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataCtors" (PVar "variants"))) false) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EVar "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" ((PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "typarams")))) (DoLet false false (PVar "ms") (EApp (EApp (EVar "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasRhs" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeCtor" (PVar "ctor")) (rf "newtypeFieldTy" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "args"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc"))) (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc"))))))
(DTypeSig false "extractEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))
(DFunDef false "extractEntries" ((PVar "decls") (PVar "positions") (PVar "schemes") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "pairs")) (EVar "schemes")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "extractFold" ((PList) PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EBlock (DoLet false false (PVar "extras") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "renderSig") (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "foldExtras" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldExtras" ((PList) (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "foldExtras" ((PCons (PTuple (PVar "name") (PVar "e")) (PVar "rest")) (PVar "revEntries") (PVar "seen")) (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EVar "revEntries")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))
(DTypeSig false "letgroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "letgroupOf" ((PCon "DLetGroup" (PVar "isPub") (PVar "bindings"))) (EApp (EVar "Some") (ETuple (EVar "isPub") (EVar "bindings"))))
(DFunDef false "letgroupOf" (PWild) (EVar "None"))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "zipDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipDoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDoc" (PWild (PList)) (EListLit))
(DFunDef false "zipDoc" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zipDoc") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "stripPipePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripPipePrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EIf (EBinOp "==" (EVar "line") (ELit (LString "|"))) (ELit (LString "")) (EVar "line"))))
(DData Private "DocSegment" () ((variant "ProseSeg" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "ExampleSeg" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Private "SegMode" () ((variant "ModeProse" (ConPos)) (variant "ModeExample" (ConPos))) ())
(DTypeSig false "isExampleStart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExampleStart" ((PVar "line")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "> ")))))
(DTypeSig false "allBlankLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allBlankLines" ((PList)) (EVar "True"))
(DFunDef false "allBlankLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "allBlankLines") (EVar "xs"))))
(DTypeSig false "pushSeg" (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))
(DFunDef false "pushSeg" (PWild (PList) (PVar "segs")) (EVar "segs"))
(DFunDef false "pushSeg" ((PCon "ModeProse") (PVar "acc") (PVar "segs")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "reverseL") (EVar "acc"))) (DoExpr (EIf (EApp (EVar "allBlankLines") (EVar "ls")) (EVar "segs") (EBinOp "::" (EApp (EVar "ProseSeg") (EVar "ls")) (EVar "segs"))))))
(DFunDef false "pushSeg" ((PCon "ModeExample") (PVar "acc") (PVar "segs")) (EBinOp "::" (EApp (EVar "ExampleSeg") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "segs")))
(DTypeSig false "docSegGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment")))))))
(DFunDef false "docSegGo" ((PList) (PVar "mode") (PVar "acc") (PVar "segs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "pushSeg") (EVar "mode")) (EVar "acc")) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeProse") (PVar "acc") (PVar "segs")) (EIf (EApp (EVar "isExampleStart") (EVar "line")) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EListLit (EVar "line"))) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeProse")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EBinOp "::" (EApp (EVar "stripPipePrefix") (EVar "line")) (EVar "acc"))) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeExample") (PVar "acc") (PVar "segs")) (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EListLit)) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeExample")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EBinOp "::" (EVar "line") (EVar "acc"))) (EVar "segs"))))
(DTypeSig false "docSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DocSegment"))))
(DFunDef false "docSegments" ((PVar "lines")) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "lines")) (EVar "ModeProse")) (EListLit)) (EListLit)))
(DTypeSig false "renderDocSegment" (TyFun (TyCon "DocSegment") (TyCon "String")))
(DFunDef false "renderDocSegment" ((PCon "ProseSeg" (PVar "ls"))) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls")))
(DFunDef false "renderDocSegment" ((PCon "ExampleSeg" (PVar "ls"))) (EBinOp "++" (EBinOp "++" (ELit (LString "```medaka\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls"))) (ELit (LString "\n```"))))
(DTypeSig false "renderDocProse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderDocProse" ((PVar "doc")) (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "segs") (EApp (EVar "docSegments") (EApp (EVar "splitNl") (EVar "doc")))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\n\n"))) (EApp (EApp (EVar "map") (EVar "renderDocSegment")) (EVar "segs")))))))
(DTypeSig false "moduleHeaderFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "String")))
(DFunDef false "moduleHeaderFrom" ((PList)) (ELit (LString "")))
(DFunDef false "moduleHeaderFrom" ((PCons (PTuple (PVar "startLine") (PVar "text")) (PVar "rest"))) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "collectHeaderLines") (EBinOp "::" (ETuple (EVar "startLine") (EVar "text")) (EVar "rest"))) (EVar "startLine")))))
(DTypeSig false "collectHeaderLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectHeaderLines" ((PVar "tbl") (PVar "line")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "text")) () (EBinOp "::" (EVar "text") (EApp (EApp (EVar "collectHeaderLines") (EVar "tbl")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "header") (PVar "entries")) (EBlock (DoLet false false (PVar "titleBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n")))) (DoLet false false (PVar "headerProse") (EApp (EVar "renderDocProse") (EVar "header"))) (DoLet false false (PVar "headerBlock") (EIf (EBinOp "==" (EVar "headerProse") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "headerProse") (ELit (LString "\n\n"))))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "::" (EVar "titleBlock") (EBinOp "::" (EVar "headerBlock") (EApp (EApp (EVar "map") (EVar "renderEntry")) (EVar "entries"))))))))
(DTypeSig false "renderEntry" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc"))) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EVar "name")) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "rendered") (EApp (EVar "renderDocProse") (EVar "doc"))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "rendered") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "rendered")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "header"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "docBlock"))) (ELit (LString "\n"))))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EVar "filename")) (EVar "roots")) (arm (PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries")) () (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))))
(DData Abstract "ModuleDoc" () ((variant "ModuleDoc" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "DocEntry"))))) ())
(DTypeSig true "mdName" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "mdName" ((PCon "ModuleDoc" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "mdEntries" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyCon "DocEntry"))))
(DFunDef false "mdEntries" ((PCon "ModuleDoc" PWild PWild (PVar "es"))) (EVar "es"))
(DTypeSig true "computeModuleDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "ModuleDoc"))))))))
(DFunDef false "computeModuleDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filename")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "header") (EApp (EVar "moduleHeaderFrom") (EVar "tbl"))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "comments"))) (DoExpr (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "moduleName")) (EApp (EApp (EVar "dedupHeader") (EVar "header")) (EVar "entries"))) (EVar "entries")))))
(DTypeSig false "dedupHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "dedupHeader" ((PVar "header") (PVar "entries")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "header") (ELit (LString ""))) (EBinOp "==" (EVar "header") (EApp (EVar "firstEntryDoc") (EVar "entries")))) (ELit (LString "")) (EVar "header")))
(DTypeSig false "firstEntryDoc" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "firstEntryDoc" ((PList)) (ELit (LString "")))
(DFunDef false "firstEntryDoc" ((PCons (PCon "DocEntry" PWild PWild (PVar "doc")) PWild)) (EVar "doc"))
(DTypeSig true "renderModulePage" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderModulePage" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries"))) (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))
(DTypeSig true "excludedLibraryModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "excludedLibraryModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "async"))))
(DTypeSig true "slugifyAnchor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "slugifyAnchor" ((PVar "name")) (EBlock (DoLet false false (PVar "lowered") (EApp (EVar "toLower") (EVar "name"))) (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "lowered"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EVar "stringTrimDashes") (EApp (EApp (EApp (EVar "slugCharsGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "slugCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "slugCharsGo" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "slugCharsGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "isSlugChar") (EVar "c")) (EBinOp "++" (EApp (EVar "charToStr") (EVar "c")) (EVar "rest")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "dlen") (EVar "rest")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rest")) (ELit (LString "-")))) (EVar "rest") (EBinOp "++" (ELit (LString "-")) (EVar "rest"))))))))
(DTypeSig false "isSlugChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSlugChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9"))))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))))
(DTypeSig false "stringTrimDashes" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashes" ((PVar "s")) (EApp (EVar "stringTrimDashEnd") (EApp (EVar "stringTrimDashStart") (EVar "s"))))
(DTypeSig false "stringTrimDashStart" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashStart" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))) (EApp (EVar "stringTrimDashStart") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 1))) (EApp (EVar "dlen") (EVar "s"))) (EVar "s"))) (EVar "s")))
(DTypeSig false "stringTrimDashEnd" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashEnd" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (EBinOp "-" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1)))) (EApp (EVar "dlen") (EVar "s"))) (EVar "s")) (ELit (LString "-")))) (EApp (EVar "stringTrimDashEnd") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1)))) (EVar "s"))) (EVar "s")))
(DTypeSig true "libraryInventoryJson" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "Json")))
(DFunDef false "libraryInventoryJson" ((PVar "mds")) (EApp (EVar "jArray") (EApp (EApp (EVar "concatMapDoc") (EVar "inventoryEntriesFor")) (EVar "mds"))))
(DTypeSig false "inventoryEntriesFor" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "inventoryEntriesFor" ((PCon "ModuleDoc" (PVar "moduleName") PWild (PVar "entries"))) (EApp (EApp (EVar "map") (EApp (EVar "inventoryEntryJson") (EVar "moduleName"))) (EVar "entries")))
(DTypeSig false "inventoryEntryJson" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Json"))))
(DFunDef false "inventoryEntryJson" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") (PVar "sig") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "module")) (EApp (EVar "JString") (EVar "moduleName"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "signature")) (EApp (EVar "JString") (EVar "sig"))))))
(DTypeSig true "renderIndex" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "String")))
(DFunDef false "renderIndex" ((PVar "mds")) (EApp (EVar "stringConcat") (EBinOp "::" (ELit (LString "# Library Index\n\n")) (EApp (EApp (EVar "map") (EVar "renderIndexModule")) (EVar "mds")))))
(DTypeSig false "renderIndexModule" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderIndexModule" ((PCon "ModuleDoc" (PVar "name") PWild (PVar "entries"))) (EBlock (DoLet false false (PVar "count") (EApp (EVar "intToString2") (EApp (EVar "listLenDoc") (EVar "entries")))) (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` ("))) (EApp (EVar "display") (EVar "count"))) (ELit (LString " entries)\n\n")))) (DoLet false false (PVar "links") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EApp (EVar "renderIndexLink") (EVar "name"))) (EVar "entries")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "links"))) (ELit (LString "\n\n"))))))
(DTypeSig false "renderIndexLink" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "String"))))
(DFunDef false "renderIndexLink" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- [`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EVar "display") (EVar "moduleName"))) (ELit (LString ".md#"))) (EApp (EVar "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "listLenDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLenDoc" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLenDoc" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLenDoc") (EVar "xs"))))
(DTypeSig false "intToString2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "intToString2" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filename") (PVar "roots") (PVar "rawUser")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "filename")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "schemes")) () (EVar "schemes"))))
# MARK
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false) (mem "splitNl" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "dlen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dlen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "dsub" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dsub" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "ppTyP" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyP" (PWild (PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInsideDoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideDoc" ((PVar "effs") (PVar "tail")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EMethodRef "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm (PCon "Some" (PVar "v")) () (EMatch (EVar "effs") (arm (PList) () (EVar "v")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentBody") (EVar "t"))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line"))) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (EVar "t"))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (EVar "text") (EVar "acc"))))))
(DTypeSig false "ppDataVariant" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PList)))) (EVar "name"))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fs") PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppFieldDoc")) (EVar "fs"))))) (ELit (LString " }"))))
(DTypeSig false "ppFieldDoc" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "ppFieldDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ft")))) (ELit (LString ""))))
(DTypeSig false "ppRequiresDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "String")))
(DFunDef false "ppRequiresDoc" ((PList)) (ELit (LString "")))
(DFunDef false "ppRequiresDoc" ((PVar "rs")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppRequireOne")) (EVar "rs")))))
(DTypeSig false "ppRequireOne" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "ppRequireOne" ((PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "tys"))) false)) (EMatch (EVar "tys") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))))
(DTypeSig false "valueSig" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PVar "fallbackTy")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EVar "fallbackTy") (arm (PCon "Some" (PVar "ty")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderSig" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PCon "DExtern" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataCtors" (PVar "variants"))) false) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EMethodRef "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" ((PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "typarams")))) (DoLet false false (PVar "ms") (EApp (EApp (EMethodRef "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasRhs" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeCtor" (PVar "ctor")) (rf "newtypeFieldTy" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc"))) (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc"))))))
(DTypeSig false "extractEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))
(DFunDef false "extractEntries" ((PVar "decls") (PVar "positions") (PVar "schemes") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "pairs")) (EVar "schemes")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "extractFold" ((PList) PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EBlock (DoLet false false (PVar "extras") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "renderSig") (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "foldExtras" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldExtras" ((PList) (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "foldExtras" ((PCons (PTuple (PVar "name") (PVar "e")) (PVar "rest")) (PVar "revEntries") (PVar "seen")) (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EVar "revEntries")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))
(DTypeSig false "letgroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "letgroupOf" ((PCon "DLetGroup" (PVar "isPub") (PVar "bindings"))) (EApp (EVar "Some") (ETuple (EVar "isPub") (EVar "bindings"))))
(DFunDef false "letgroupOf" (PWild) (EVar "None"))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "zipDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipDoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDoc" (PWild (PList)) (EListLit))
(DFunDef false "zipDoc" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zipDoc") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "stripPipePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripPipePrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EIf (EBinOp "==" (EVar "line") (ELit (LString "|"))) (ELit (LString "")) (EVar "line"))))
(DData Private "DocSegment" () ((variant "ProseSeg" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "ExampleSeg" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Private "SegMode" () ((variant "ModeProse" (ConPos)) (variant "ModeExample" (ConPos))) ())
(DTypeSig false "isExampleStart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExampleStart" ((PVar "line")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "> ")))))
(DTypeSig false "allBlankLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allBlankLines" ((PList)) (EVar "True"))
(DFunDef false "allBlankLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "allBlankLines") (EVar "xs"))))
(DTypeSig false "pushSeg" (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))
(DFunDef false "pushSeg" (PWild (PList) (PVar "segs")) (EVar "segs"))
(DFunDef false "pushSeg" ((PCon "ModeProse") (PVar "acc") (PVar "segs")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "reverseL") (EVar "acc"))) (DoExpr (EIf (EApp (EVar "allBlankLines") (EVar "ls")) (EVar "segs") (EBinOp "::" (EApp (EVar "ProseSeg") (EVar "ls")) (EVar "segs"))))))
(DFunDef false "pushSeg" ((PCon "ModeExample") (PVar "acc") (PVar "segs")) (EBinOp "::" (EApp (EVar "ExampleSeg") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "segs")))
(DTypeSig false "docSegGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment")))))))
(DFunDef false "docSegGo" ((PList) (PVar "mode") (PVar "acc") (PVar "segs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "pushSeg") (EVar "mode")) (EVar "acc")) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeProse") (PVar "acc") (PVar "segs")) (EIf (EApp (EVar "isExampleStart") (EVar "line")) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EListLit (EVar "line"))) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeProse")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EBinOp "::" (EApp (EVar "stripPipePrefix") (EVar "line")) (EVar "acc"))) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeExample") (PVar "acc") (PVar "segs")) (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EListLit)) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeExample")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EBinOp "::" (EVar "line") (EVar "acc"))) (EVar "segs"))))
(DTypeSig false "docSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DocSegment"))))
(DFunDef false "docSegments" ((PVar "lines")) (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "lines")) (EVar "ModeProse")) (EListLit)) (EListLit)))
(DTypeSig false "renderDocSegment" (TyFun (TyCon "DocSegment") (TyCon "String")))
(DFunDef false "renderDocSegment" ((PCon "ProseSeg" (PVar "ls"))) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls")))
(DFunDef false "renderDocSegment" ((PCon "ExampleSeg" (PVar "ls"))) (EBinOp "++" (EBinOp "++" (ELit (LString "```medaka\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls"))) (ELit (LString "\n```"))))
(DTypeSig false "renderDocProse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderDocProse" ((PVar "doc")) (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "segs") (EApp (EVar "docSegments") (EApp (EVar "splitNl") (EVar "doc")))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\n\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderDocSegment")) (EVar "segs")))))))
(DTypeSig false "moduleHeaderFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "String")))
(DFunDef false "moduleHeaderFrom" ((PList)) (ELit (LString "")))
(DFunDef false "moduleHeaderFrom" ((PCons (PTuple (PVar "startLine") (PVar "text")) (PVar "rest"))) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "collectHeaderLines") (EBinOp "::" (ETuple (EVar "startLine") (EVar "text")) (EVar "rest"))) (EVar "startLine")))))
(DTypeSig false "collectHeaderLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectHeaderLines" ((PVar "tbl") (PVar "line")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "text")) () (EBinOp "::" (EVar "text") (EApp (EApp (EVar "collectHeaderLines") (EVar "tbl")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "header") (PVar "entries")) (EBlock (DoLet false false (PVar "titleBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n")))) (DoLet false false (PVar "headerProse") (EApp (EVar "renderDocProse") (EVar "header"))) (DoLet false false (PVar "headerBlock") (EIf (EBinOp "==" (EVar "headerProse") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "headerProse") (ELit (LString "\n\n"))))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "::" (EVar "titleBlock") (EBinOp "::" (EVar "headerBlock") (EApp (EApp (EMethodRef "map") (EVar "renderEntry")) (EVar "entries"))))))))
(DTypeSig false "renderEntry" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc"))) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EVar "name")) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "rendered") (EApp (EVar "renderDocProse") (EVar "doc"))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "rendered") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "rendered")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "docBlock"))) (ELit (LString "\n"))))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EVar "filename")) (EVar "roots")) (arm (PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries")) () (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))))
(DData Abstract "ModuleDoc" () ((variant "ModuleDoc" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "DocEntry"))))) ())
(DTypeSig true "mdName" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "mdName" ((PCon "ModuleDoc" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "mdEntries" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyCon "DocEntry"))))
(DFunDef false "mdEntries" ((PCon "ModuleDoc" PWild PWild (PVar "es"))) (EVar "es"))
(DTypeSig true "computeModuleDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "ModuleDoc"))))))))
(DFunDef false "computeModuleDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filename")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "header") (EApp (EVar "moduleHeaderFrom") (EVar "tbl"))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "comments"))) (DoExpr (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "moduleName")) (EApp (EApp (EVar "dedupHeader") (EVar "header")) (EVar "entries"))) (EVar "entries")))))
(DTypeSig false "dedupHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "dedupHeader" ((PVar "header") (PVar "entries")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "header") (ELit (LString ""))) (EBinOp "==" (EVar "header") (EApp (EVar "firstEntryDoc") (EVar "entries")))) (ELit (LString "")) (EVar "header")))
(DTypeSig false "firstEntryDoc" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "firstEntryDoc" ((PList)) (ELit (LString "")))
(DFunDef false "firstEntryDoc" ((PCons (PCon "DocEntry" PWild PWild (PVar "doc")) PWild)) (EVar "doc"))
(DTypeSig true "renderModulePage" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderModulePage" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries"))) (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))
(DTypeSig true "excludedLibraryModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "excludedLibraryModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "async"))))
(DTypeSig true "slugifyAnchor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "slugifyAnchor" ((PVar "name")) (EBlock (DoLet false false (PVar "lowered") (EApp (EVar "toLower") (EVar "name"))) (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "lowered"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EVar "stringTrimDashes") (EApp (EApp (EApp (EVar "slugCharsGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "slugCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "slugCharsGo" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "slugCharsGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "isSlugChar") (EVar "c")) (EBinOp "++" (EApp (EVar "charToStr") (EVar "c")) (EVar "rest")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "dlen") (EVar "rest")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rest")) (ELit (LString "-")))) (EVar "rest") (EBinOp "++" (ELit (LString "-")) (EVar "rest"))))))))
(DTypeSig false "isSlugChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSlugChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9"))))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EBinOp "==" (EVar "c") (ELit (LChar "-")))))
(DTypeSig false "stringTrimDashes" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashes" ((PVar "s")) (EApp (EVar "stringTrimDashEnd") (EApp (EVar "stringTrimDashStart") (EVar "s"))))
(DTypeSig false "stringTrimDashStart" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashStart" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))) (EApp (EVar "stringTrimDashStart") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 1))) (EApp (EVar "dlen") (EVar "s"))) (EVar "s"))) (EVar "s")))
(DTypeSig false "stringTrimDashEnd" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimDashEnd" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (EBinOp "-" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1)))) (EApp (EVar "dlen") (EVar "s"))) (EVar "s")) (ELit (LString "-")))) (EApp (EVar "stringTrimDashEnd") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "dlen") (EVar "s")) (ELit (LInt 1)))) (EVar "s"))) (EVar "s")))
(DTypeSig true "libraryInventoryJson" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "Json")))
(DFunDef false "libraryInventoryJson" ((PVar "mds")) (EApp (EVar "jArray") (EApp (EApp (EVar "concatMapDoc") (EVar "inventoryEntriesFor")) (EVar "mds"))))
(DTypeSig false "inventoryEntriesFor" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "inventoryEntriesFor" ((PCon "ModuleDoc" (PVar "moduleName") PWild (PVar "entries"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "inventoryEntryJson") (EVar "moduleName"))) (EVar "entries")))
(DTypeSig false "inventoryEntryJson" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Json"))))
(DFunDef false "inventoryEntryJson" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") (PVar "sig") PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "module")) (EApp (EVar "JString") (EVar "moduleName"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "signature")) (EApp (EVar "JString") (EVar "sig"))))))
(DTypeSig true "renderIndex" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "String")))
(DFunDef false "renderIndex" ((PVar "mds")) (EApp (EVar "stringConcat") (EBinOp "::" (ELit (LString "# Library Index\n\n")) (EApp (EApp (EMethodRef "map") (EVar "renderIndexModule")) (EVar "mds")))))
(DTypeSig false "renderIndexModule" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderIndexModule" ((PCon "ModuleDoc" (PVar "name") PWild (PVar "entries"))) (EBlock (DoLet false false (PVar "count") (EApp (EVar "intToString2") (EApp (EVar "listLenDoc") (EVar "entries")))) (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` ("))) (EApp (EMethodRef "display") (EDictApp "count"))) (ELit (LString " entries)\n\n")))) (DoLet false false (PVar "links") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderIndexLink") (EVar "name"))) (EVar "entries")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "links"))) (ELit (LString "\n\n"))))))
(DTypeSig false "renderIndexLink" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "String"))))
(DFunDef false "renderIndexLink" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- [`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EMethodRef "display") (EVar "moduleName"))) (ELit (LString ".md#"))) (EApp (EMethodRef "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "listLenDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLenDoc" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLenDoc" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLenDoc") (EVar "xs"))))
(DTypeSig false "intToString2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "intToString2" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filename") (PVar "roots") (PVar "rawUser")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "filename")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "schemes")) () (EVar "schemes"))))
