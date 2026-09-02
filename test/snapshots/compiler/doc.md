# META
source_lines=1531
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/doc.mdk — the native `medaka doc` documentation extractor.
--
-- A doc-comment extractor and Markdown renderer, in two modes:
--   • SINGLE-FILE (`runDoc`) — one module in, one Markdown page on stdout.
--   • LIBRARY (`computeModuleDoc` + `renderModulePage`/`renderIndex`/
--     `libraryInventoryJson`, driven by `medaka doc --out DIR`) — many modules
--     in, one page each plus an index and a machine-readable inventory, with
--     library-wide corrections (`rebucketLibraryImpls`) no single-file run can
--     make.
--
-- Both modes share one pipeline: harvest comments from the lexer's
-- side-channel (`collectComments`), match them to top-level declarations by
-- source position, infer schemes through the SAME multi-module loader path
-- `check`/`run`/LSP use (`projectEntrySchemes`, so an import-bearing module
-- resolves its siblings — S-doc-multimodule), and render.
--
-- Entries are extracted from the RAW, PRE-DESUGAR program, so `renderSig`
-- shows the surface a reader wrote.  Type rendering is this file's own
-- `ppTyP`, not `types/typecheck.ppTy`, because the latter DROPS `TyEffect`
-- rows and interface method types carry them.

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
  tyParamSources,
  Constraint(..),
  DataVis(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  IfaceMethod(..),
  Require(..),
  LetBind(..),
  UsePath(..),
  UseMember,
  useMemberOrigin,
  useMemberLocal,
  DeriveRef,
  deriveRefName,
}
import types.typecheck.{Scheme(..), ppScheme}
import frontend.resolve.{internalExterns}
import support.util.{joinWith, reverseL, escStr, stringTrim, splitNl}
import support.path.{baseOf, chopExt}
import driver.diagnostics.{projectEntrySchemes}
import frontend.desugar.{dataDerivers, newtypeDerivers}
import json.{Json, JString, jObject, jArray}
import string.{toLower}

-- ── doc_entry ──────────────────────────────────────────────────────────────
-- de_name / de_sig (never empty) / de_doc (stripped doc prose, may be "") /
-- de_kind (S-doc-surface-truth: the ATTRIBUTION facts about the declaration
-- this entry came from, threaded at extraction time rather than re-derived by
-- parsing `de_sig` back — the sig is a rendering, not a data structure) /
-- de_line (the declaration's source line, which is what places a `-- # Title`
-- section heading relative to the entries around it).
data DocEntry = DocEntry String String String DocKind Int

-- What kind of declaration produced an entry, for the library-mode impl
-- rebucketing pass (`rebucketLibraryImpls`).  `KTypeDecl` marks a `data`/
-- `newtype` declaration — the evidence that this module OWNS that type name.
-- `KImplOn` carries the head type-constructor name of the impl's FIRST type
-- argument (`impl Debug (Array a)` -> `Some "Array"`), or `None` when the impl
-- has no type arguments or its head is a type VARIABLE (`impl Debug a`), which
-- has no owner by construction.  `KSection` is not a declaration at all: a
-- `-- # Title` comment between declarations, rendered as a page section and
-- excluded from the index and the inventory.  Everything else is `KPlain`.
data DocKind = KPlain | KTypeDecl | KImplOn (Option String) | KSection

-- One row of the comment table: (source line, text, block).  `block` is the
-- start line of the `{- -}` comment the row came from, or 0 for a line
-- comment.  It is what lets `markedDoc` stop at the end of a doc block
-- instead of absorbing a maintainer note written directly under it.
type CommentRow = (Int, String, Int)

-- ── small string helpers (builtins; mirror doctest's local wrappers) ────────
dlen : String -> Int
dlen s = stringLength s

-- stringSlice a b = chars [a, b)
dsub : Int -> Int -> String -> String
dsub a b s = stringSlice a b s

-- ── pre-desugar type rendering ──────────────────────────────────────────
-- NOTE: types/typecheck.ppTy drops `TyEffect` rows, but interface method
-- types carry effect rows that doc output needs to show.  So this module
-- has its own precedence-passing renderer that keeps `TyEffect`/`TyRow`.

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
-- A label-free join takes its parenthesised type-argument spelling
-- (`f (e | e2) b`), matching printer.mdk.
-- Intentional cross-file duplicate of printer.mdk's `ppTyPrec` clause; not
-- consolidating (same divergent-by-design printer trio as `ppEffAtomDoc` below).
-- lint-disable-next-line rule-duplicate-body
ppTyP _ (TyRow [] (a::b::rest) _) = "(\{joinWith " | " (a :: b::rest)})"
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
ppEffInsideDoc : List (String, Option String) -> List String -> String
ppEffInsideDoc effs tails =
  let labs = map ppEffAtomDoc effs
  match tails
    [] => joinWith ", " labs
    _ =>
      let tls = joinWith " | " tails
      match effs
        [] => tls
        _ => "\{joinWith ", " labs} | \{tls}"

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

-- ── Comment-text extraction ───────────────────────────────────────────────

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

-- doctest.mdk's OWN rule for "this comment line is a doctest INPUT line",
-- spelled out on the raw comment lexeme: `isInputLine c = startsWith "-- > "
-- (clText c)` (compiler/tools/doctest.mdk).  Kept here as the single place
-- doc's example detection is tied to doctest's, so the two cannot drift.
isDoctestInputText : String -> Bool
isDoctestInputText t = dlen t >= 5 && dsub 0 5 t == "-- > "

-- The prose body of a LINE comment, with one correction on top of
-- `commentBody` (S2-2).
--
-- doc's segmenter (`isExampleStart`) keys on a `> ` prefix in the extracted
-- BODY; doctest keys on the literal 5-char `-- > ` prefix in the RAW lexeme.
-- Enumerating `commentBody`'s branches against `isDoctestInputText` shows the
-- two agree on every comment shape but ONE: `--> x` (no space after the `--`)
-- takes the 2-char-strip branch and yields the body `> x`, which doctest never
-- runs — so doc used to fence it and label it "run by `medaka test`", a claim
-- `medaka test` contradicts.
--
-- For exactly that shape the body's leading `>` is emitted MARKDOWN-ESCAPED
-- (`\> x`): it renders as the literal text the author wrote (rather than as a
-- blockquote, which is what an unescaped leading `>` means in Markdown), and
-- it cannot open an `ExampleSeg`.  An `ExampleSeg` therefore exists iff
-- doctest would collect the same line, which is what makes the fence's marker
-- true.  Block-comment lines need no correction: doctest's `expandBlock`
-- reshapes an inner `> x` into `-- > x` and runs it, which is precisely what
-- `isExampleStart` accepts.
docLineBody : String -> String
docLineBody t =
  let body = commentBody t
  if isDoctestInputText t || not (isExampleStart body) then
    body
  else
    "\\" ++ body

-- Undo `docLineBody`'s escape.  Inside a fenced example block a line is
-- reproduced VERBATIM, so the prose-level Markdown escape must not leak into
-- the fence.
unescapeGtPrefix : String -> String
unescapeGtPrefix line =
  if dlen line >= 3 && dsub 0 3 line == "\\> " then
    dsub 1 (dlen line) line
  else
    line

-- Expand a comment into table rows.  Block comments expand to one row per
-- inner line (bare trimmed), all tagged with the block's start line.  Line
-- comments → [(line, docLineBody text, 0)].
expandComment : Comment -> List CommentRow
expandComment c =
  let t = commentText c
  if dlen t >= 2 && dsub 0 2 t == "{-" then
    let n = dlen t
    -- OCaml String.sub t 2 (n-4): start 2, LENGTH n-4 → end index n-2.
    -- stringSlice takes (start, end), so end = n-2 (drops the 2-char `-}`).
    let inner = if n >= 4 then dsub 2 (n - 2) t else ""
    expandBlockLines (commentLine c) 0 (splitNl inner)
  else
    [(commentLine c, docLineBody t, 0)]

expandBlockLines : Int -> Int -> List String -> List CommentRow
expandBlockLines _ _ [] = []
expandBlockLines baseLine i (line::rest) =
  (baseLine + i, stringTrim line, baseLine) ::
    expandBlockLines baseLine (i + 1) rest

-- splitNl → support/util.mdk (imported above; #242 dedup of the splitNl cluster).

-- ── comment table: line -> row (assoc list; later entries win, like
-- Hashtbl.replace which keeps the last inserted for a key) ──────────────────
-- We build an assoc list, then look up by line.  build_comment_tbl iterates
-- comments in order, replacing per line; for lookup we want the LAST row set
-- for a line.  We keep insertion order and `lookupLast` returns the last match.

buildCommentTbl : List Comment -> List CommentRow
buildCommentTbl comments = concatMapDoc expandComment comments

concatMapDoc : (a -> List b) -> List a -> List b
concatMapDoc _ [] = []
concatMapDoc f (x::xs) = f x ++ concatMapDoc f xs

-- Find the LAST row whose line matches (mirrors Hashtbl.replace semantics:
-- the last insertion for a key wins).  Returns (text, block).
lookupLineLast : List CommentRow -> Int -> Option (String, Int)
lookupLineLast tbl line = lookupLineLastGo tbl line None

lookupLineLastGo : List CommentRow -> Int -> Option (String, Int) -> Option (String, Int)
lookupLineLastGo [] _ acc = acc
lookupLineLastGo ((l, t, b)::rest) line acc =
  if l == line then
    lookupLineLastGo rest line (Some (t, b))
  else
    lookupLineLastGo rest line acc

-- Return doc prose for the decl at [startLine]: the doc comment inside the
-- maximal consecutive run of comments immediately above it (no line gap),
-- per `markedDoc`.  Newline-joined + trimmed.
findDocForLine : List CommentRow -> Int -> String
findDocForLine tbl startLine =
  markedDoc (collectDocLines tbl (startLine - 1) [])

-- Collect backwards; accumulator ends up in ascending line order.
collectDocLines : List CommentRow -> Int -> List CommentRow -> List CommentRow
collectDocLines tbl line acc = match lookupLineLast tbl line
  None => acc
  Some (t, b) => collectDocLines tbl (line - 1) ((line, t, b)::acc)

-- THE RULE for what renders (`stdlib/README.md` § "Writing documentation"):
-- only a MARKED comment is documentation.  Within a run of comment rows, the
-- doc is the marker row and every row after it that belongs to the same
-- comment: the rest of the `{- | -}` block, or the following line comments
-- of a `-- |` run.  Rows before the marker and rows from a different comment
-- after it are maintainer notes and are dropped.  A run with no marker
-- documents nothing.
--
-- Where a marker may sit: on the run's first row (blank and decorative rows
-- excepted, `markerEligibleAfter`), or on the FIRST row of a `{- -}` block
-- anywhere in the run.  A `| ` deeper inside a line-comment run is user
-- content — a wrapped `data` declaration or a table row (S2-3) — and must not
-- start a doc; that is also why a `-- |` run cannot follow a note without a
-- blank line between them.
markedDoc : List CommentRow -> String
markedDoc rows = match dropToMarker True rows
  [] => ""
  (_, t, b)::rest => stringTrim (joinWith "\n" (t :: sameBlockTexts b rest))

dropToMarker : Bool -> List CommentRow -> List CommentRow
dropToMarker _ [] = []
dropToMarker atStart ((l, t, b)::rest)
  | hasPipeMarker t && (atStart || b > 0 && l == b) = (l, t, b)::rest
  | otherwise = dropToMarker (atStart && markerEligibleAfter t) rest

sameBlockTexts : Int -> List CommentRow -> List String
sameBlockTexts _ [] = []
sameBlockTexts b ((_, t, b2)::rest) =
  if b2 == b then
    t :: sameBlockTexts b rest
  else
    []

-- Section headings: every `-- # Title` line comment, as (line, title).  A
-- section is a page-level grouping of the entries that follow it, not
-- documentation of any one declaration, so it is collected from the whole
-- table rather than attached to a decl.
sectionsFrom : List CommentRow -> List (Int, String)
sectionsFrom [] = []
sectionsFrom ((l, t, b)::rest) =
  if b == 0 && dlen t >= 2 && dsub 0 2 t == "# " then
    (l, stringTrim (dsub 2 (dlen t) t)) :: sectionsFrom rest
  else
    sectionsFrom rest

-- ── signature rendering ────────────────────────────────────────────────────

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

-- Render the signature line for [name].  The AST annotation WINS when the
-- author wrote one (`DTypeSig`/`DExtern`), because it is the surface a reader
-- wrote and `ppTyDoc` renders it faithfully — `ppScheme` (types/typecheck)
-- DROPS constraint contexts and `TyEffect` rows, so rendering off the inferred
-- scheme silently published `nub : List a -> List a` for a source line reading
-- `nub : Eq a => List a -> List a` (#2448).  Only when there is no written
-- annotation at all (a bare `DFunDef`, or a `let` group) is the inferred scheme
-- the sole source of truth; its lossiness there is a separate problem.
valueSig : String -> List (String, Scheme) -> Option Ty -> String
valueSig name _ (Some ty) = "\{name} : \{ppTyDoc ty}"
valueSig name schemes None = match lookupScheme name schemes
  Some s => "\{name} : \{ppScheme s}"
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
--
-- The leading `Bool` is `docBareExterns` (S-doc-surface-truth hole (c)): when
-- True, an UNEXPORTED `extern` is documented anyway.  It is set for exactly one
-- module — `runtime` (`preludeOnlyModule` below) — because `export` status is
-- MEANINGLESS there, verified first-hand rather than assumed: `stdlib/runtime.mdk`
-- contains no `export` at all, and a selective import of one of its names is a
-- hard error ("Module 'runtime' has no exported name 'stringLength'"), so nothing
-- can reach those 138 externs by importing them — they are visible only because
-- runtime.mdk IS the prelude.  Every OTHER module's `pub = False` decls are
-- genuinely private helpers and stay undocumented, which is why this is a
-- per-module exception (keyed on the derived module name, mirroring
-- `excludedLibraryModule`) and not a global "ignore `pub`" relaxation.
renderSig : Bool -> Decl -> List (String, Scheme) -> Option (String, String)
renderSig _ (DTypeSig True name ty) schemes =
  Some (name, valueSig name schemes (Some ty))
renderSig _ (DFunDef True name _ _) schemes =
  Some (name, valueSig name schemes None)
renderSig bare (DExtern pub name ty) schemes
  | pub || bare = Some (name, valueSig name schemes (Some ty))
renderSig _ (DLetGroup True bindings) schemes = match bindings
  (LetBind name _)::_ => Some (name, valueSig name schemes None)
  [] => None
renderSig _ (DData { dataVis = vis, dataName = name, dataParams = params, dataParamKinds = kinds, dataCtors = variants }) _
  | not (dataVisPrivate vis) =
    let head = joinWith " " (name :: tyParamSources params kinds)
    let body = match variants
      [] => ""
      _ => "\n  = " ++ joinWith "\n  | " (map ppDataVariant variants)
    Some (name, "data \{head}\{body}")
renderSig _ (DInterface { pub = True, name, typarams, typaramKinds, methods }) _ =
  let head = joinWith " " (name :: tyParamSources typarams typaramKinds)
  let ms = map ppIfaceMethod methods
  let body = match ms
    [] => ""
    _ => "\n" ++ joinWith "\n" ms
  Some (name, "interface \{head}\{body}")
renderSig _ (DTypeAlias { tyAliasPub = True, tyAliasName = name, tyAliasParams = params, tyAliasParamKinds = kinds, tyAliasRhs = ty }) _ =
  let head = joinWith " " (name :: tyParamSources params kinds)
  Some (name, "type \{head} = \{ppTyDoc ty}")
renderSig _ (DNewtype { newtypePub = True, newtypeName = name, newtypeParams = params, newtypeParamKinds = kinds, newtypeCtor = ctor, newtypeFieldTy = ty }) _ =
  let head = joinWith " " (name :: tyParamSources params kinds)
  Some (name, "newtype \{head} = \{ctor} \{ppTyP 2 ty}")
renderSig _ (DImpl { pub = True, iface, tys, reqs }) _ =
  let args = match tys
    [] => ""
    _ => " " ++ joinWith " " (map (ppTyP 2) tys)
  Some (iface ++ args, "impl \{iface}\{args}\{ppRequiresDoc reqs}")
renderSig _ _ _ = None

dataVisPrivate : DataVis -> Bool
dataVisPrivate VisPrivate = True
dataVisPrivate _ = False

-- The one module whose unexported `extern`s are documented anyway (hole (c)).
-- Keyed on the DERIVED module name (post `baseOf`/`chopExt`), exactly like
-- `excludedLibraryModule` — a fixture module named `runtime` gets the same
-- treatment, so the rule is testable without touching `stdlib/runtime.mdk`.
preludeOnlyModule : String -> Bool
preludeOnlyModule moduleName = moduleName == "runtime"

-- ── attribution: what kind of declaration is this? (hole (b)) ───────────────

declKind : Decl -> DocKind
declKind (DImpl { tys = tys }) = KImplOn (headTyName tys)
declKind (DData { dataName = _ }) = KTypeDecl
declKind (DNewtype { newtypeName = _ }) = KTypeDecl
declKind _ = KPlain

-- Every type name this module DECLARES, public or private (S2-1).
--
-- `declKind` above answers the same question about a RENDERED entry, and that
-- is not good enough for ownership: `renderSig` emits no entry at all for a
-- private `data`/`newtype`, so an owner map built from entries is blind to a
-- privately-declared type and `rebucketLibraryImpls` used to fall through to
-- its bare-name clause and file the impl on an unrelated module's page.  A
-- declaration is evidence of ownership whether or not it is public, so the
-- owner map is built from the RAW decls instead.
declaredTypeNames : List Decl -> List String
declaredTypeNames [] = []
declaredTypeNames (d::ds) = declaredTypeName d ++ declaredTypeNames ds

declaredTypeName : Decl -> List String
declaredTypeName (DData { dataName = n }) = [n]
declaredTypeName (DNewtype { newtypeName = n }) = [n]
declaredTypeName _ = []

headTyName : List Ty -> Option String
headTyName [] = None
headTyName (t::_) = tyHeadName t

-- The head type CONSTRUCTOR of a type application spine: `Array a` -> `Array`,
-- `Array` -> `Array`, `a` -> None (a type variable owns nothing).
tyHeadName : Ty -> Option String
tyHeadName (TyCon { tyConName = s }) = Some s
tyHeadName (TyApp f _) = tyHeadName f
tyHeadName _ = None

-- ── entry extraction ───────────────────────────────────────────────────────

-- Expand a public DLetGroup into one (name, DocEntry) per binding.
allLetgroupEntries : Bool -> List LetBind -> Int -> List (String, Scheme) -> List CommentRow -> List (String, DocEntry)
allLetgroupEntries False _ _ _ _ = []
allLetgroupEntries True bindings line schemes tbl =
  let doc = findDocForLine tbl line
  letgroupEntriesGo bindings schemes doc line

letgroupEntriesGo : List LetBind -> List (String, Scheme) -> String -> Int -> List (String, DocEntry)
letgroupEntriesGo [] _ _ _ = []
letgroupEntriesGo ((LetBind name _)::rest) schemes doc line =
  let sigStr = valueSig name schemes None
  (name, DocEntry name sigStr doc KPlain line) :: letgroupEntriesGo rest schemes doc line

-- ── derived instances (`deriving (…)`) ─────────────────────────────────────
-- `public export data Duration = Duration Int deriving (Eq, Ord, Debug)`
-- (`stdlib/time.mdk:33`) used to publish ONE entry — the type — and nothing
-- for the three instances it brings into existence, so the reference asserted
-- by omission that `Duration` has no `Eq` (#2436).  Those instances are real:
-- `desugar.mdk`'s `expandDecl` turns each `DeriveRef` into exactly
-- `impl C (T p…) requires C p…` (`applyDeriveParams`/`appliedHead`/
-- `paramRequires`), a PUBLIC `DImpl`.
--
-- They are SYNTHESIZED here rather than read off the desugared program because
-- this file extracts from the RAW, PRE-DESUGAR decls on purpose (the surface
-- the author wrote).  The synthesis mirrors `applyDeriveParams` exactly — head
-- `(T p…)` when the type has params, bare `T` when it has none, and one
-- `requires C p` per param — so the rendered line is the impl desugar actually
-- generates, not an approximation of it.  Entry name and `DocKind` mirror
-- `renderSig`'s own `DImpl` arm (`iface ++ args`, `KImplOn (Some T)`) so that
-- dedup, anchors, and `rebucketLibraryImpls` treat a derived instance and a
-- hand-written one identically.
--
-- Derived entries carry NO doc prose: the type's doc comment belongs to the
-- type's entry, and repeating it under three instance headings would be noise.
-- Which type-shape a `deriving (…)` clause is attached to — carries exactly
-- the shape info `dataDerivers`/`newtypeDerivers` need to answer "does this
-- class have a deriver for this shape," so `derivedEntries` can filter
-- against the SAME oracle `unknownDerive`/`declDeriveErrors` (desugar.mdk)
-- already use to reject an unsupported class at compile time.
data DeriveShape = ShapeData (List Variant) | ShapeNewtype String Ty

-- True when `iface` has a deriver for this shape, per the canonical tables.
hasDeriver : String -> List String -> DeriveShape -> String -> Bool
hasDeriver tyName params (ShapeData variants) iface =
  elem iface (map fst (dataDerivers tyName params variants))
hasDeriver tyName params (ShapeNewtype con fty) iface =
  elem iface (map fst (newtypeDerivers tyName params con fty))

derivedEntries : String -> List String -> DeriveShape -> Int -> List DeriveRef -> List (String, DocEntry)
derivedEntries _ _ _ _ [] = []
derivedEntries tyName params shape line (d::ds) =
  let iface = deriveRefName d
  let rest = derivedEntries tyName params shape line ds
  if not (hasDeriver tyName params shape iface) then rest
  else
    let args = derivedHead tyName params
    let name = "\{iface} \{args}"
    let sigStr = "impl \{iface} \{args}\{derivedRequires iface params}"
    (name, DocEntry name sigStr "" (KImplOn (Some tyName)) line)::rest

-- `T` with no params, `(T a b)` with them — `ppTyP 2`'s rendering of the head
-- `appliedHead` builds.
derivedHead : String -> List String -> String
derivedHead tyName [] = tyName
derivedHead tyName params = "(\{joinWith " " (tyName::params)})"

-- `requires C a, C b` — `paramRequires`, one constraint per type param.
derivedRequires : String -> List String -> String
derivedRequires _ [] = ""
derivedRequires iface params = " requires "
  ++ joinWith ", " (map (p => "\{iface} \{p}") params)

noDerives : List DeriveRef -> Bool
noDerives [] = True
noDerives _ = False

-- (typeName, params, derives) for a decl carrying a non-empty `deriving (…)`
-- clause, else None.  A PRIVATE `data`/`newtype` is excluded here exactly as
-- in `renderSig`: an unpublished type's instances are not part of the surface.
derivesOf : Decl -> Option (String, List String, List DeriveRef, DeriveShape)
derivesOf (DData { dataVis = vis, dataName = n, dataParams = ps, dataCtors = variants, dataDerives = ds })
  | not (dataVisPrivate vis) && not (noDerives ds) =
    Some (n, ps, ds, ShapeData variants)
derivesOf (DNewtype { newtypePub = True, newtypeName = n, newtypeParams = ps, newtypeCtor = con, newtypeFieldTy = fty, newtypeDerives = ds })
  | not (noDerives ds) = Some (n, ps, ds, ShapeNewtype con fty)
derivesOf _ = None

-- The type's own entry (exactly what the single-entry path would have made)
-- followed by one entry per derived class.
derivingEntries : Bool -> Decl -> Int -> List (String, Scheme) -> List CommentRow -> (String, List String, List DeriveRef, DeriveShape) -> List (String, DocEntry)
derivingEntries bare decl line schemes tbl (tyName, params, derives, shape) =
  let doc = findDocForLine tbl line
  let own = match renderSig bare decl schemes
    None => []
    Some (name, sigStr) =>
      [(name, DocEntry name sigStr doc (declKind decl) line)]
  own ++ derivedEntries tyName params shape line derives

-- ── re-exports (hole (a)) ───────────────────────────────────────────────────
-- `export import core.{Filterable, filter, filterMap}` (`stdlib/list.mdk:8`,
-- the tree's only re-export today) parses to `DUse True (UseGroup path members)`
-- and rendered NOTHING before this slice: `renderSig` had no `DUse` arm, so
-- `list`'s page silently omitted three names its users reach through it.
--
-- Expansion is one entry per member (like `allLetgroupEntries`, not `renderSig`,
-- which is one-entry-per-decl by construction), under the member's LOCAL name
-- (`useMemberLocal` — its alias if written `a as b`).
--
-- THE RULE, decided after measuring rather than assuming: `docSchemesFor`
-- returns `entryOwnSchemes`, the importing module's OWN top-level schemes, and
-- a re-export is not a top-level binding there — so a re-exported name has no
-- LOCAL scheme to render (measured: `medaka check --types stdlib/list.mdk`
-- lists none of `Filterable`/`filter`/`filterMap`).  The local lookup is still
-- tried first (it costs nothing and is right if a future resolve change starts
-- registering re-exports locally); when it misses we resolve the ORIGIN
-- module's own schemes through the same `projectEntrySchemes` machinery
-- (`originSchemeTable`, computed once per page in `computeModuleDoc` because
-- it is IO) and render the real signature — `medaka check --types
-- stdlib/core.mdk` does list `filter`/`filterMap`, so the origin lookup hits
-- where the local one cannot (#2421).
--
-- Only when BOTH miss does the entry fall back to documenting the re-export by
-- name and origin — `Filterable : re-export of core.Filterable`.  That arm is
-- still reachable and still correct: a re-exported INTERFACE or TYPE name has
-- no value scheme anywhere by construction, so there is no signature to find,
-- and naming the origin is a true statement about the module's surface rather
-- than an inferred signature we cannot justify.
reexportEntries : Int -> List (String, Scheme) -> List CommentRow -> List (String, List (String, Scheme)) -> (List String, List UseMember) -> List (String, DocEntry)
reexportEntries line schemes tbl origins (path, members) =
  let doc = findDocForLine tbl line
  let originMod = joinWith "." path
  reexportEntriesGo
    originMod
    members
    schemes
    (originSchemesOf originMod origins)
    doc
    line

reexportEntriesGo : String -> List UseMember -> List (String, Scheme) -> List (String, Scheme) -> String -> Int -> List (String, DocEntry)
reexportEntriesGo _ [] _ _ _ _ = []
reexportEntriesGo originMod (m::rest) schemes originSchemes doc line =
  let local = useMemberLocal m
  let origin = useMemberOrigin m
  let sigStr = match lookupScheme local schemes
    Some s => "\{local} : \{ppScheme s}"
    None => match lookupScheme origin originSchemes
      Some s => "\{local} : \{ppScheme s}"
      None => "\{local} : re-export of \{originMod}.\{origin}"
  (local, DocEntry local sigStr doc KPlain line) :: reexportEntriesGo originMod rest schemes originSchemes doc line

-- The origin-module scheme table: dotted module id -> that module's own
-- top-level schemes, for every `export import m.{…}` in the page's raw decls.
-- Built once per page (a re-export names at most a handful of modules, and the
-- tree has exactly one such decl today), keyed by the dotted path so two
-- re-exports from the same module share one load.
originSchemesOf : String -> List (String, List (String, Scheme)) -> List (String, Scheme)
originSchemesOf _ [] = []
originSchemesOf mid ((m, ss)::rest)
  | mid == m = ss
  | otherwise = originSchemesOf mid rest

originSchemeTable : String -> String -> List String -> List Decl -> <IO> List (String, List (String, Scheme))
originSchemeTable _ _ _ [] = []
originSchemeTable runtimeSrc coreSrc roots (d::ds) =
  let rest = originSchemeTable runtimeSrc coreSrc roots ds
  match useGroupOf d
    None => rest
    Some (path, _) =>
      let mid = joinWith "." path
      if hasOriginEntry mid rest then
        rest
      else
        (mid, originModuleSchemes runtimeSrc coreSrc roots path)::rest

hasOriginEntry : String -> List (String, List (String, Scheme)) -> Bool
hasOriginEntry _ [] = False
hasOriginEntry mid ((m, _)::rest)
  | mid == m = True
  | otherwise = hasOriginEntry mid rest

-- Typecheck the ORIGIN module as its own entry point and hand back its own
-- top-level schemes.  Deliberately QUIET where `docSchemesFor` is loud: an
-- origin module that cannot be found or loaded costs a re-export line its
-- signature (the `re-export of` fallback), never the page.  `core` is the one
-- origin in the tree and it is the implicit prelude, so it is NEVER a member
-- of the importing module's loaded graph (`loader.mdk:389` drops it) — which
-- is exactly why its schemes have to be resolved by a separate entry load
-- rather than picked out of the page's own multi-module check.
originModuleSchemes : String -> String -> List String -> List String -> <IO> List (String, Scheme)
originModuleSchemes runtimeSrc coreSrc roots path = match findOriginFile roots (joinWith "/" path)
  None => []
  Some p => match projectEntrySchemes (Ref []) (Ref []) (_ => None) p roots runtimeSrc coreSrc
    None => []
    Some ss => ss

findOriginFile : List String -> String -> <IO> Option String
findOriginFile [] _ = None
findOriginFile (r::rs) rel =
  let p = "\{r}/\{rel}.mdk"
  if fileExists p then Some p else findOriginFile rs rel

-- Match a re-exporting `export import m.{a, b}`, returning (path, members).
-- Only `UseGroup` re-exports name members; `export import m.*` / `m as A` name
-- none individually and are deliberately left alone (there are none in the tree).
useGroupOf : Decl -> Option (List String, List UseMember)
useGroupOf (DUse True (UseGroup path members) _) = Some (path, members)
useGroupOf _ = None

-- The driver: zip decls with their positions, fold collecting entries, dedup by
-- name (first wins), emit in source order.  Mirror extract_entries.
extractEntries : Bool -> List Decl -> List DeclPos -> List (String, Scheme) -> List (String, List (String, Scheme)) -> List Comment -> List DocEntry
extractEntries bare decls positions schemes origins comments =
  let tbl = buildCommentTbl comments
  let pairs = zipDoc decls positions
  let result = extractFold bare pairs schemes origins tbl [] []
  reverseL (fst result)

-- Fold over (decl, pos) pairs.  State: (revEntries, seenNames).  Returns it.
extractFold : Bool -> List (Decl, DeclPos) -> List (String, Scheme) -> List (String, List (String, Scheme)) -> List CommentRow -> List DocEntry -> List String -> (List DocEntry, List String)
extractFold _ [] _ _ _ revEntries seen = (revEntries, seen)
extractFold bare ((decl, dp)::rest) schemes origins tbl revEntries seen =
  let line = declPosLine dp
  match multiEntriesFor bare decl line schemes origins tbl
    Some extras =>
      let acc = foldExtras extras revEntries seen
      extractFold bare rest schemes origins tbl (fst acc) (snd acc)
    None => match renderSig bare decl schemes
      None => extractFold bare rest schemes origins tbl revEntries seen
      Some (name, sigStr) => if memberStr name seen then extractFold bare rest schemes origins tbl revEntries seen
      else
        let doc = findDocForLine tbl line
        extractFold
          bare
          rest
          schemes
          origins
          tbl
          (DocEntry name sigStr doc (declKind decl) line :: revEntries)
          (name::seen)

-- Interleave `-- # Title` sections with the entries by source line: a section
-- precedes the first entry declared after it.  Both lists arrive in
-- ascending line order.
insertSections : List (Int, String) -> List DocEntry -> List DocEntry
insertSections [] entries = entries
insertSections ((l, title)::secs) [] =
  sectionEntry l title :: insertSections secs []
insertSections ((l, title)::secs) (e::es) =
  if l < entryLine e then
    sectionEntry l title :: insertSections secs (e::es)
  else
    e :: insertSections ((l, title)::secs) es

sectionEntry : Int -> String -> DocEntry
sectionEntry line title = DocEntry title "" "" KSection line

entryLine : DocEntry -> Int
entryLine (DocEntry _ _ _ _ line) = line

-- The three decl shapes that expand to MANY entries (a `let` group, a
-- re-exporting `export import`, a `data`/`newtype` with a `deriving (…)`
-- clause); `None` means "one entry at most, ask `renderSig`".
multiEntriesFor : Bool -> Decl -> Int -> List (String, Scheme) -> List (String, List (String, Scheme)) -> List CommentRow -> Option (List (String, DocEntry))
multiEntriesFor bare decl line schemes origins tbl = match letgroupOf decl
  Some (isPub, bindings) =>
    Some (allLetgroupEntries isPub bindings line schemes tbl)
  None => match useGroupOf decl
    Some pm => Some (reexportEntries line schemes tbl origins pm)
    None => map (derivingEntries bare decl line schemes tbl) (derivesOf decl)

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

-- Does this prose line carry a leading `| ` (or bare `|`) Haddock marker?
hasPipeMarker : String -> Bool
hasPipeMarker line = dlen line >= 2 && dsub 0 2 line == "| " || line == "|"

-- Strip a leading `| ` (or bare `|`) marker from a prose line.  Applied ONLY
-- where a marker can legitimately sit (`markerEligible` below) — never to
-- every prose line, because a `|`-led line deeper in prose is USER CONTENT (a
-- BNF alternative, a Markdown table row) and deleting its `|` silently
-- destroys what the author wrote (S2-3).
stripPipePrefix : String -> String
stripPipePrefix line =
  if dlen line >= 2 && dsub 0 2 line == "| " then
    dsub 2 (dlen line) line
  else if line == "|" then
    ""
  else
    line

-- Can a Haddock marker still sit on the NEXT line of a doc block?
--
-- Normally the marker is on the block's very first line (`{- | ... -}` marks
-- once at the top; a continuation `--   line two` never repeats it).  But a
-- decorative, unmarked section-separator comment (`-- ── Duration ──`,
-- `stdlib/time.mdk`) can sit directly above a `-- | ...`-marked one with no
-- blank line between, and `findDocForLine`'s proximity rule merges both into
-- ONE doc block — putting the marker on an interior line.  So marker
-- eligibility survives a blank line and a decorative separator, and nothing
-- else; the first real prose (or the marker itself) ends it.
--
-- "Decorative" is read off the first character: not a letter and not a digit
-- and not a space.  That covers the box-drawing/dash/equals rules the tree
-- actually writes, without this file naming a Unicode literal, and it
-- excludes indented continuation prose (which starts with a space).
markerEligibleAfter : String -> Bool
markerEligibleAfter line = line == "" || isDecorativeLine line

isDecorativeLine : String -> Bool
isDecorativeLine line =
  let cs = stringToChars line
  if arrayLength cs == 0 then False else isDecorativeChar (arrayGetUnsafe 0 cs)

isDecorativeChar : Char -> Bool
isDecorativeChar c = not (c >= 'a' && c <= 'z')
  && not (c >= 'A' && c <= 'Z')
  && not (c >= '0' && c <= '9')
  && c /= ' '

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
  let ls = reverseL (dropWhileBlank acc)
  if allBlankLines ls then segs else ProseSeg ls :: segs
pushSeg ModeExample acc segs = ExampleSeg (reverseL acc) :: segs

-- The accumulator is reversed, so its head is the run's LAST line: dropping
-- leading blanks here trims the paragraph gap that precedes an example, which
-- would otherwise render as a double blank line above the fence.
dropWhileBlank : List String -> List String
dropWhileBlank (""::rest) = dropWhileBlank rest
dropWhileBlank ls = ls

-- The `Bool` is marker eligibility: True while a Haddock `| ` marker could
-- still legitimately open this doc block (see `markerEligibleAfter`).  It
-- starts True (the block's first line), is consumed by the one marker the
-- block may carry, and is never restored — a `|`-led line after that is user
-- content.
docSegGo : List String -> SegMode -> Bool -> List String -> List DocSegment -> List DocSegment
docSegGo [] mode _ acc segs = reverseL (pushSeg mode acc segs)
docSegGo (line::rest) ModeProse markerOk acc segs =
  if isExampleStart line then
    docSegGo rest ModeExample False [line] (pushSeg ModeProse acc segs)
  else if markerOk && hasPipeMarker line then
    docSegGo rest ModeProse False (stripPipePrefix line :: acc) segs
  else
    docSegGo rest ModeProse (markerOk && markerEligibleAfter line) (line::acc) segs
docSegGo (line::rest) ModeExample _ acc segs =
  if line == "" then
    docSegGo rest ModeProse False [] (pushSeg ModeExample acc segs)
  else
    docSegGo rest ModeExample False (unescapeGtPrefix line :: acc) segs

docSegments : List String -> List DocSegment
docSegments lines = docSegGo lines ModeProse True [] []

-- An `ExampleSeg` is a doctest: `medaka test` extracts and runs it
-- (`compiler/tools/doctest.mdk`), so every rendered example is a verified
-- one.  The segmenter and doctest agree on what an example IS because
-- `docLineBody` (above) neutralises the one comment shape (`--> x`) whose
-- body would reach `isExampleStart` without satisfying doctest's `-- > `
-- rule; `isDoctestInputText` is the single place that rule is spelled.
-- Change `isExampleStart` or `docLineBody` together, never one alone.
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
moduleHeaderFrom : List CommentRow -> String
moduleHeaderFrom [] = ""
moduleHeaderFrom ((startLine, text, b)::rest) =
  markedDoc (collectHeaderLines ((startLine, text, b)::rest) startLine)

collectHeaderLines : List CommentRow -> Int -> List CommentRow
collectHeaderLines tbl line = match lookupLineLast tbl line
  None => []
  Some (t, b) => (line, t, b) :: collectHeaderLines tbl (line + 1)

-- A page: title, the header's lead paragraph, the entries, then a closing
-- "Instances" section.  A `KSection` renders as a `##` section heading (and
-- demotes every entry heading on the page to `###`).  An `impl` on a type
-- (`Eq Int`, `Debug (List a)`) never gets a heading in the main run of the
-- page: it is named on the "Instances" line under its type's entry when the
-- page declares that type, and otherwise in the closing section's list,
-- grouped by type.  An impl WITH prose of its own is also rendered as an
-- entry inside the closing section, and the listings link to it.
renderMarkdown : String -> String -> List DocEntry -> String
renderMarkdown moduleName header entries =
  let titleBlock = "# " ++ moduleName ++ "\n\n"
  let headerProse = renderDocProse header
  let headerBlock = if headerProse == "" then "" else headerProse ++ "\n\n"
  let sectioned = anyDoc isSection entries
  let main = filterDoc (e => not (isListedImpl e)) entries
  stringConcat
    (titleBlock :: primitiveLayerBanner moduleName :: headerBlock :: map (renderEntry sectioned entries) main ++ [renderInstancesSection entries])

-- The prelude-only page publishes host externs whose `<type><Op>` names sit
-- beside the library layer's (`stringToUpper` / `string.toUpper`); the page
-- says which layer it is so the two do not read as rival APIs.  Rendered from
-- the module name, so it reaches library mode and single-file `medaka doc`
-- alike.
primitiveLayerBanner : String -> String
primitiveLayerBanner moduleName
  | preludeOnlyModule moduleName = "> These are the host primitives. They are in scope everywhere without an\n> import, and their `<type><Op>` names (`stringToUpper`, `intToString`)\n> mark them as the primitive layer. Prefer the library name where one\n> exists (`string.toUpper`, `string.toFloat`), and reach for a name on this\n> page only when no library module covers it.\n\n"
  | otherwise = ""

isSection : DocEntry -> Bool
isSection (DocEntry _ _ _ KSection _) = True
isSection _ = False

isImpl : DocEntry -> Bool
isImpl (DocEntry _ _ _ (KImplOn _) _) = True
isImpl _ = False

-- An impl entry whose name carries at least one type argument (`Eq Int`,
-- `Debug (a, b)`) — the shape the instance listings absorb.  `impl Foo` with
-- no arguments has no type to be listed under and stays an ordinary entry.
isListedImpl : DocEntry -> Bool
isListedImpl (DocEntry name _ _ (KImplOn _) _) = instanceHead name /= ""
isListedImpl _ = False

anyDoc : (a -> Bool) -> List a -> Bool
anyDoc _ [] = False
anyDoc p (x::xs) = p x || anyDoc p xs

-- The interface name of an impl entry: `Eq (List a)` -> `Eq`.
instanceIface : String -> String
instanceIface name = match stringIndexOf " " name
  None => name
  Some i => dsub 0 i name

-- The type part of an impl entry's name: `Eq (List a)` -> `(List a)`,
-- `Eq Int` -> `Int`, `Foo` -> "".
instanceHead : String -> String
instanceHead name = match stringIndexOf " " name
  None => ""
  Some i => dsub (i + 1) (dlen name) name

-- What an impl is listed under: its head type constructor when it has one
-- (`Eq (List a)` and `Mappable List` both file under `List`), else the
-- literal type part of its name (`(a, b)` for a tuple instance).
instanceKey : DocEntry -> String
instanceKey (DocEntry _ _ _ (KImplOn (Some hd)) _) = hd
instanceKey (DocEntry name _ _ _ _) = instanceHead name

renderEntry : Bool -> List DocEntry -> DocEntry -> String
renderEntry _ _ (DocEntry title _ _ KSection _) = "## " ++ title ++ "\n\n"
renderEntry sectioned entries (DocEntry name sig doc kind _) =
  let level = if sectioned then "### " else "## "
  let header = "\{level}`\{name}`\n\n"
  let sigBlock = "```\n" ++ sig ++ "\n```\n"
  let instances = match kind
    KTypeDecl => instanceLine (instancesOf name entries)
    _ => ""
  let rendered = renderDocProse doc
  let docBlock = if rendered == "" then "" else "\n" ++ rendered ++ "\n"
  "\{header}\{sigBlock}\{docBlock}\{instances}\n"

-- Every impl entry on the page whose head type constructor is `tyName`.
instancesOf : String -> List DocEntry -> List DocEntry
instancesOf tyName entries = filterDoc (e => implHeadIs tyName e) entries

implHeadIs : String -> DocEntry -> Bool
implHeadIs tyName (DocEntry _ _ _ (KImplOn (Some hd)) _) = hd == tyName
implHeadIs _ _ = False

-- `Instances: \`Eq\`, \`Ord\`, [\`Debug\`](#debug-list-a)` — a documented
-- impl links to its own heading, an undocumented one is just named.
instanceLine : List DocEntry -> String
instanceLine [] = ""
instanceLine impls = "\nInstances: "
  ++ joinWith ", " (map instanceRef impls)
  ++ "\n"

instanceRef : DocEntry -> String
instanceRef (DocEntry name _ doc _ _) =
  let iface = "`" ++ instanceIface name ++ "`"
  if doc == "" then iface else "[\{iface}](#\{slugifyAnchor name})"

-- The closing section: one list line per type the page does not declare
-- (`Eq Int` on `core`, `Debug (a, b)`), in first-seen order, followed by the
-- documented impls as entries.  Empty when the page lists no impl at all.
renderInstancesSection : List DocEntry -> String
renderInstancesSection entries =
  let listed = filterDoc isListedImpl entries
  let orphans = filterDoc (e => not (hasTypeEntry entries e)) listed
  let keys = uniqueDoc (map instanceKey orphans)
  let bullets = match keys
    [] => ""
    _ => "\{joinWith "\n" (map (orphanLine orphans) keys)}\n\n"
  let documented = stringConcat (map (renderEntry True entries) (filterDoc (e => entryDoc e /= "") listed))
  match listed
    [] => ""
    _ => "## Instances\n\n\{bullets}\{documented}"

orphanLine : List DocEntry -> String -> String
orphanLine orphans key =
  let mine = filterDoc (e => instanceKey e == key) orphans
  "- `\{key}`: \{joinWith ", " (map instanceRef mine)}"

hasTypeEntry : List DocEntry -> DocEntry -> Bool
hasTypeEntry entries (DocEntry _ _ _ (KImplOn (Some hd)) _) =
  anyDoc (e => isTypeNamed hd e) entries
hasTypeEntry _ _ = False

isTypeNamed : String -> DocEntry -> Bool
isTypeNamed n (DocEntry name _ _ KTypeDecl _) = name == n
isTypeNamed _ _ = False

entryDoc : DocEntry -> String
entryDoc (DocEntry _ _ doc _ _) = doc

uniqueDoc : List String -> List String
uniqueDoc [] = []
uniqueDoc (x::xs) = x :: uniqueDoc (filterDoc (/= x) xs)

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
  ModuleDoc name header entries _ => renderMarkdown name header entries

-- ── library mode (S-doc-library-mode) ───────────────────────────────────────
-- A module's full extracted doc: name (page/index title, page filename minus
-- `.md`), header (lead paragraph, from `moduleHeaderFrom`), entries, and the
-- type names the module DECLARES — public or private, straight off the raw
-- decls, which is the ownership evidence `rebucketLibraryImpls` reads (S2-1;
-- the entries alone cannot answer it, see `declaredTypeNames`).
-- Abstract export: `medaka_cli.mdk`'s library-mode driver reads it only
-- through `mdName` + `renderModulePage`/`renderIndex`/`libraryInventoryJson`
-- below, never by constructing/pattern-matching it itself.
export data ModuleDoc = ModuleDoc String String (List DocEntry) (List String)

export
mdName : ModuleDoc -> String
mdName (ModuleDoc n _ _ _) = n

-- (`mdEntries` used to sit here, exported.  Nothing outside this file ever
-- called it — `grep -rn mdEntries compiler/ | grep -v doc.mdk` is empty — and
-- nothing inside did either, so it was dead in both directions and is gone
-- rather than merely un-exported.)

-- Shared by `runDoc` (single-file) and library mode: parse, infer schemes,
-- extract entries + the module header, in one place so both modes see
-- identical resolution behavior (S-doc-multimodule's per-module scheme fix
-- included).
-- D-6 (#2306): the reference must not publish a name the RESOLVER rejects.
-- `resolve.internalExterns` is the guard list — a module that is neither part
-- of the standard library nor built with `--allow-internal` gets
-- `'<name>' is an internal-only primitive` for any of them — yet they were
-- rendered on the `runtime` page with signature and doc comment, telling the
-- reader to do something the compiler forbids.  The list is IMPORTED, not
-- copied: one source of truth, so a name added to the guard disappears from
-- the page in the same commit.  The filter applies only where the guard does
-- (the prelude-only `runtime` page), so a fixture that legitimately shows an
-- internal name on some other page is unaffected.
-- D-7 (#2432): a SECOND, doc-only exclusion list — compiler/harness internals
-- that a user program can already call (the resolver's `internalExterns`
-- guard does not cover them), so they must NOT be added to that guard: doing
-- so would reject ordinary programs (`__fallthrough__` backs every match
-- guard) and red 6 fixtures for the other 9 names (measured in #2432). This
-- list is doc-only — never imported by/into `resolve.mdk` — and only trims
-- what the reference page renders.
docOnlyExcluded : List String
docOnlyExcluded = [
  "__fallthrough__",
  "setRef",
  "stashRunStdout",
  "enableRunStdoutFlush",
  "assertSnapshot",
  "indexError",
  "indexErrorAt",
  "sliceError",
  "debugStringLit",
  "debugCharLit",
  "buildFingerprint",
]

dropInternalExterns : Bool -> List DocEntry -> List DocEntry
dropInternalExterns False entries = entries
dropInternalExterns True entries =
  filter (e => not (isInternalExtern e)) entries

isInternalExtern : DocEntry -> Bool
isInternalExtern (DocEntry name _ _ _ _) = elem name internalExterns
  || elem name docOnlyExcluded

export
computeModuleDoc : String -> String -> String -> String -> List String -> <IO> ModuleDoc
computeModuleDoc runtimeSrc coreSrc src filename roots =
  let parsed = parseWithPositions src
  let rawDecls = fst parsed
  let positions = positionsDecls (snd parsed)
  let comments = collectComments src
  let schemes = docSchemesFor runtimeSrc coreSrc filename roots rawDecls
  let origins = originSchemeTable runtimeSrc coreSrc roots rawDecls
  let moduleName = chopExt (baseOf filename)
  let tbl = buildCommentTbl comments
  let header = moduleHeaderFrom tbl
  let primitiveLayer = preludeOnlyModule moduleName
  let entries = dropInternalExterns primitiveLayer (extractEntries primitiveLayer rawDecls positions schemes origins comments)
  ModuleDoc
    moduleName
    (dedupHeader header entries)
    (insertSections (sectionsFrom tbl) entries)
    (declaredTypeNames rawDecls)

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
firstEntryDoc ((DocEntry _ _ doc _ _)::_) = doc

export
renderModulePage : ModuleDoc -> String
renderModulePage (ModuleDoc name header entries _) =
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

-- ── impl rebucketing: file an impl under the TYPE's page (hole (b)) ─────────
--
-- `impl Debug (Array a)` / `Eq (Array a)` / `Display (Array a)` are declared in
-- `stdlib/core.mdk` (which does not even import `array`) and, before this pass,
-- rendered on `core`'s page — where nobody looking up "how do I print an Array"
-- would find them.  This is a LIBRARY-MODE-ONLY correction by construction:
-- single-file `medaka doc core.mdk` has no way to know `array` exists as a
-- sibling page, so `runDoc` never calls this.
--
-- THE RULE (decided here, and it is a rule, not a lookup — the packet's
-- suggested mechanism does not reach its own headline example, see MEASUREMENT
-- below).  The OWNER of a head type-constructor name `T` within a library set is:
--
--   1. the module whose own `data`/`newtype` declares `T` — PUBLIC OR PRIVATE,
--      read off the raw decls (`declaredTypeNames`), never off the rendered
--      entries.  Declaration is the strongest possible evidence and always
--      wins.  (S2-1: this clause used to read `KTypeDecl` ENTRIES, and
--      `renderSig` renders no entry for a private `data`, so a module that
--      privately declared `T` and publicly wrote `impl Debug T` lost that impl
--      to whatever module happened to be named `t` — silently, with no
--      warning.);
--   2. failing that, the module whose page NAME equals `toLower T` AND which
--      independently MENTIONS `T` in one of its own entries' signatures.  This
--      is the OPAQUE-BUILTIN clause: a type the compiler builds in has no
--      declaration to find, but the module that exists to operate on it is
--      named for it and cannot avoid naming it in its own signatures.  The
--      mention is what makes this evidence rather than a coincidence of
--      spelling (S2-1 again: a bare name match corroborates nothing — a
--      module named `widget` that never says `Widget` is not its home);
--   3. otherwise: no owner.
--
-- An impl entry moves to its head type's owner iff that owner is a DIFFERENT
-- module than the one that wrote the `impl`.  An impl whose head type has no
-- owner — a bare type variable (`impl Debug a`), or a builtin with no module
-- named for it (`Int`, `Char`, `Bool`, `Ref`) — STAYS where it was declared.
-- An impl with no type arguments at all stays too.
--
-- MEASUREMENT that forced clause 2 (packet §3(b) prescribed clause 1 alone, and
-- separately required `array.md` to carry `Debug (Array a)`; the two cannot both
-- hold, so the rule had to be decided rather than transcribed):
--
--   $ grep -rn 'data Array\|newtype Array' stdlib/ compiler/   # -> no output
--   $ sed -n 14p stdlib/array.mdk
--        2. Opaque builtin vs. typeclass member.  `Array a` cannot be pattern-
--
-- `Array` is declared NOWHERE, so clause 1 alone attributes it to nothing and
-- the impls would have stayed on `core`.  Clause 2 is what makes the array page
-- true.  Note it leaves the packet's own stated exception intact: `Int` has no
-- `int` module in the set, so `impl Debug Int` still stays in `core`.
--
-- Clause ordering matters and is not cosmetic: a type that IS declared keeps
-- its impls beside its `data` declaration rather than scattering them to a
-- module that merely operates on it.  The original instance was `Option`/
-- `Result`, declared in `core.mdk` while one-entry `option.mdk`/`result.mdk`
-- also existed; #2306 I-2 deleted those two modules, so that pair no longer
-- exercises the ordering.  The rule is unchanged and still load-bearing for
-- any core-declared type an operating module merely mentions.
export
rebucketLibraryImpls : List ModuleDoc -> List ModuleDoc
rebucketLibraryImpls mds =
  let owners = concatMapDoc typeOwnersOf mds
  let mentions = map moduleMentionIndex mds
  let moved = concatMapDoc (movedFrom owners mentions) mds
  map (rebucketOne owners mentions moved) mds

-- Clause 1's evidence: every (typeName, declaringModule) pair in the library,
-- from the raw declarations — private `data`/`newtype` included.
typeOwnersOf : ModuleDoc -> List (String, String)
typeOwnersOf (ModuleDoc n _ _ tyNames) = map (t => (t, n)) tyNames

-- Clause 2's evidence, per module: the module's name paired with the text its
-- own entries render, which is where a mention of the type has to show up.
moduleMentionIndex : ModuleDoc -> (String, List String)
moduleMentionIndex (ModuleDoc n _ es _) = (n, map entrySigOf es)

entrySigOf : DocEntry -> String
entrySigOf (DocEntry _ sig _ _ _) = sig

ownerOfType : List (String, String) -> List (String, List String) -> String -> Option String
ownerOfType owners mentions tyName = match lookupStrDoc tyName owners
  Some m => Some m
  None =>
    let lowered = toLower tyName
    match lookupSigsDoc lowered mentions
      None => None
      Some sigs => if anyMentions tyName sigs then Some lowered else None

lookupSigsDoc : String -> List (String, List String) -> Option (List String)
lookupSigsDoc _ [] = None
lookupSigsDoc k ((n, v)::rest) = if k == n then Some v else lookupSigsDoc k rest

anyMentions : String -> List String -> Bool
anyMentions _ [] = False
anyMentions tyName (s::rest) = mentionsToken tyName s || anyMentions tyName rest

-- Does `hay` contain `needle` as a whole identifier token?  Word-bounded on
-- both sides, so a module named `array` does not "mention" `Array` merely by
-- rendering `ArrayBuilder`.
mentionsToken : String -> String -> Bool
mentionsToken needle hay =
  let ns = stringToChars needle
  let hs = stringToChars hay
  mentionsTokenGo ns hs 0 (arrayLength ns) (arrayLength hs)

mentionsTokenGo : Array Char -> Array Char -> Int -> Int -> Int -> Bool
mentionsTokenGo ns hs i n h =
  if n == 0 || i + n > h then
    False
  else if charsMatchAt ns hs i n && not (isIdentCharAt hs (i - 1) h) && not (isIdentCharAt hs (i + n) h) then
    True
  else
    mentionsTokenGo ns hs (i + 1) n h

charsMatchAt : Array Char -> Array Char -> Int -> Int -> Bool
charsMatchAt ns hs i n = charsMatchAtGo ns hs i 0 n

charsMatchAtGo : Array Char -> Array Char -> Int -> Int -> Int -> Bool
charsMatchAtGo ns hs i j n =
  if j >= n then
    True
  else if arrayGetUnsafe (i + j) hs == arrayGetUnsafe j ns then
    charsMatchAtGo ns hs i (j + 1) n
  else
    False

isIdentCharAt : Array Char -> Int -> Int -> Bool
isIdentCharAt hs i h =
  if i < 0 || i >= h then
    False
  else
    isIdentChar (arrayGetUnsafe i hs)

isIdentChar : Char -> Bool
isIdentChar c = c >= 'a' && c <= 'z'
  || c >= 'A' && c <= 'Z'
  || c >= '0' && c <= '9'
  || c == '_'

lookupStrDoc : String -> List (String, String) -> Option String
lookupStrDoc _ [] = None
lookupStrDoc k ((n, v)::rest) = if k == n then Some v else lookupStrDoc k rest

-- `Some target` iff this entry is an impl that belongs on ANOTHER module's page.
entryTarget : List (String, String) -> List (String, List String) -> String -> DocEntry -> Option String
entryTarget owners mentions here (DocEntry _ _ _ (KImplOn (Some hd)) _) = match ownerOfType owners mentions hd
  Some m => if m == here then None else Some m
  None => None
entryTarget _ _ _ _ = None

movedFrom : List (String, String) -> List (String, List String) -> ModuleDoc -> List (String, DocEntry)
movedFrom owners mentions (ModuleDoc here _ es _) =
  concatMapDoc (movedEntry owners mentions here) es

movedEntry : List (String, String) -> List (String, List String) -> String -> DocEntry -> List (String, DocEntry)
movedEntry owners mentions here e = match entryTarget owners mentions here e
  Some m => [(m, e)]
  None => []

-- Keep everything that did not move out, then append everything that moved in
-- (source order preserved within each group; incoming impls land after the
-- module's own entries, which is where a reader expects "instances" to sit).
rebucketOne : List (String, String) -> List (String, List String) -> List (String, DocEntry) -> ModuleDoc -> ModuleDoc
rebucketOne owners mentions moved (ModuleDoc here header es tyNames) =
  let kept = filterDoc (e => isNoneDoc (entryTarget owners mentions here e)) es
  let incoming = concatMapDoc (takeForModule here) moved
  ModuleDoc here header (kept ++ incoming) tyNames

takeForModule : String -> (String, DocEntry) -> List DocEntry
takeForModule here (m, e) = if m == here then [e] else []

filterDoc : (a -> Bool) -> List a -> List a
filterDoc _ [] = []
filterDoc p (x::xs) = if p x then x :: filterDoc p xs else filterDoc p xs

isNoneDoc : Option String -> Bool
isNoneDoc None = True
isNoneDoc _ = False

-- GitHub's auto-anchor slug for a `## \`name\`` header: lowercase, run of
-- non `[a-z0-9_-]` chars collapses to one `-`, leading/trailing `-` trimmed.
-- Exact enough for the plain identifiers most entries render as; an impl
-- entry's compound name (`Debug (Array a)`) still gets a stable (if not
-- necessarily GitHub-exact) anchor — same-page linking never depended on
-- exactness, only on the entry's OWN header and the index's link agreeing,
-- which `slugifyAnchor` guarantees by construction (both read from the same
-- function).
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
inventoryEntriesFor (ModuleDoc moduleName _ entries _) = map
  (inventoryEntryJson moduleName)
  (filterDoc (e => not (isSection e)) entries)

inventoryEntryJson : String -> DocEntry -> Json
inventoryEntryJson moduleName (DocEntry name sig _ _ _) = jObject
  [
    ("module", JString moduleName),
    ("name", JString name),
    ("signature", JString sig),
  ]

-- Index page: one heading per module (linked to its page) with the module's
-- one-line summary, then a link to every function and type on the page.
-- Instances are not listed: a reader looks a type up, not `Eq Int`.
export
renderIndex : List ModuleDoc -> String
renderIndex mds =
  stringConcat ("# Library Index\n\n" :: map renderIndexModule mds)

renderIndexModule : ModuleDoc -> String
renderIndexModule (ModuleDoc name header entries _) =
  let head = "## [`\{name}`](\{name}.md)\n\n"
  let summary = firstSentence (renderDocProse header)
  let summaryBlock = if summary == "" then "" else summary ++ "\n\n"
  let listed = filterDoc (e => not (isImpl e) && not (isSection e)) entries
  let links = joinWith "\n" (map (renderIndexLink name) listed)
  "\{head}\{summaryBlock}\{links}\n\n"

renderIndexLink : String -> DocEntry -> String
renderIndexLink moduleName (DocEntry name _ _ _ _) =
  "- [`\{name}`](\{moduleName}.md#\{slugifyAnchor name})"

-- The first sentence of a prose block: up to and including the first `.`
-- that ends a word, or the first line when there is none.  Newlines inside
-- the sentence become spaces, since the source wraps at a fixed width.
firstSentence : String -> String
firstSentence prose =
  let cs = stringToChars prose
  let n = arrayLength cs
  let cut = sentenceEnd cs 0 n
  joinWith " " (splitNl (stringTrim (dsub 0 cut prose)))

sentenceEnd : Array Char -> Int -> Int -> Int
sentenceEnd cs i n =
  if i >= n then firstLineEnd cs 0 n
  else
    let c = arrayGetUnsafe i cs
    if c == '.' && (i + 1 >= n || isSentenceGap (arrayGetUnsafe (i + 1) cs)) then
      i + 1
    else
      sentenceEnd cs (i + 1) n

isSentenceGap : Char -> Bool
isSentenceGap c = c == ' ' || c == '\n'

firstLineEnd : Array Char -> Int -> Int -> Int
firstLineEnd cs i n =
  if i >= n then
    n
  else if arrayGetUnsafe i cs == '\n' then
    i
  else
    firstLineEnd cs (i + 1) n

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
-- so this arm is reached ONLY for the load-error case, never the no-import
-- one. Unlike lsp.mdk's completion consumer, this call site only ever looks
-- up schemes BY NAME for names the caller already knows it declared
-- (extractEntries/renderSig, never a full-environment enumeration).
-- #2422: falling back to `[]` here used to make a module with a broken
-- import graph and an un-annotated export render a silent, signature-less
-- page at exit 0 — indistinguishable from a module that simply has no
-- annotatable exports. `[]` is still the right EXTRACTION-level value (there
-- is nothing to look up), but the failure must stop being invisible, so this
-- now also reports the load error and exits non-zero, mirroring every other
-- load-error arm in this file's own callers (`runDocTargets`/
-- `runDocLibraryTargets`, medaka_cli.mdk) rather than swallowing it here.
docSchemesFor : String -> String -> String -> List String -> List Decl -> <IO> List (String, Scheme)
docSchemesFor runtimeSrc coreSrc filename roots rawUser = match projectEntrySchemes (Ref []) (Ref []) (_ => None) filename roots runtimeSrc coreSrc
  None =>
    let _ = ePutStrLn "medaka doc: '\{filename}' has an unresolved import graph (missing or cyclic import) — signatures unavailable"
    let _ = exit 1
    []
  Some schemes => schemes
# DESUGAR
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "tyParamSources" false) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true) (mem "UsePath" true) (mem "UseMember" false) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "DeriveRef" false) (mem "deriveRefName" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalExterns" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false) (mem "splitNl" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "dataDerivers" false) (mem "newtypeDerivers" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "DocKind") (TyCon "Int")))) ())
(DData Private "DocKind" () ((variant "KPlain" (ConPos)) (variant "KTypeDecl" (ConPos)) (variant "KImplOn" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "KSection" (ConPos))) ())
(DTypeAlias false "CommentRow" () (TyTuple (TyCon "Int") (TyCon "String") (TyCon "Int")))
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
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInsideDoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideDoc" ((PVar "effs") (PVar "tails")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EVar "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoExpr (EMatch (EVar "tails") (arm (PList) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm PWild () (EBlock (DoLet false false (PVar "tls") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))) (DoExpr (EMatch (EVar "effs") (arm (PList) () (EVar "tls")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "tls"))) (ELit (LString ""))))))))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "isDoctestInputText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDoctestInputText" ((PVar "t")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 5))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "t")) (ELit (LString "-- > ")))))
(DTypeSig false "docLineBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "docLineBody" ((PVar "t")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "commentBody") (EVar "t"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isDoctestInputText") (EVar "t")) (EApp (EVar "not") (EApp (EVar "isExampleStart") (EVar "body")))) (EVar "body") (EBinOp "++" (ELit (LString "\\")) (EVar "body"))))))
(DTypeSig false "unescapeGtPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unescapeGtPrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "line")) (ELit (LString "\\> ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 1))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EVar "line")))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "CommentRow"))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "docLineBody") (EVar "t")) (ELit (LInt 0))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "CommentRow"))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line")) (EVar "baseLine")) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "CommentRow"))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (ETuple (EVar "t") (EVar "b")))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "markedDoc") (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "CommentRow"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PTuple (PVar "t") (PVar "b"))) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "line") (EVar "t") (EVar "b")) (EVar "acc"))))))
(DTypeSig false "markedDoc" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyCon "String")))
(DFunDef false "markedDoc" ((PVar "rows")) (EMatch (EApp (EApp (EVar "dropToMarker") (EVar "True")) (EVar "rows")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PTuple PWild (PVar "t") (PVar "b")) (PVar "rest")) () (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "sameBlockTexts") (EVar "b")) (EVar "rest"))))))))
(DTypeSig false "dropToMarker" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "CommentRow")))))
(DFunDef false "dropToMarker" (PWild (PList)) (EListLit))
(DFunDef false "dropToMarker" ((PVar "atStart") (PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "hasPipeMarker") (EVar "t")) (EBinOp "||" (EVar "atStart") (EBinOp "&&" (EBinOp ">" (EVar "b") (ELit (LInt 0))) (EBinOp "==" (EVar "l") (EVar "b"))))) (EBinOp "::" (ETuple (EVar "l") (EVar "t") (EVar "b")) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EVar "dropToMarker") (EBinOp "&&" (EVar "atStart") (EApp (EVar "markerEligibleAfter") (EVar "t")))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sameBlockTexts" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sameBlockTexts" (PWild (PList)) (EListLit))
(DFunDef false "sameBlockTexts" ((PVar "b") (PCons (PTuple PWild (PVar "t") (PVar "b2")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "b2") (EVar "b")) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "sameBlockTexts") (EVar "b")) (EVar "rest"))) (EListLit)))
(DTypeSig false "sectionsFrom" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "sectionsFrom" ((PList)) (EListLit))
(DFunDef false "sectionsFrom" ((PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2)))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "# ")))) (EBinOp "::" (ETuple (EVar "l") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")))) (EApp (EVar "sectionsFrom") (EVar "rest"))) (EApp (EVar "sectionsFrom") (EVar "rest"))))
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
(DFunDef false "valueSig" ((PVar "name") PWild (PCon "Some" (PVar "ty"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PCon "None")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "renderSig" (PWild (PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" (PWild (PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PVar "bare") (PCon "DExtern" (PVar "pub") (PVar "name") (PVar "ty")) (PVar "schemes")) (EIf (EBinOp "||" (EVar "pub") (EVar "bare")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" (PWild (PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" (PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants"))) false) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EVar "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" (PWild (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "typarams")) (EVar "typaramKinds"))))) (DoLet false false (PVar "ms") (EApp (EApp (EVar "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "kinds")) (rf "tyAliasRhs" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "kinds")) (rf "newtypeCtor" (PVar "ctor")) (rf "newtypeFieldTy" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "args"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "preludeOnlyModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "preludeOnlyModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "runtime"))))
(DTypeSig false "declKind" (TyFun (TyCon "Decl") (TyCon "DocKind")))
(DFunDef false "declKind" ((PRec "DImpl" ((rf "tys" (PVar "tys"))) false)) (EApp (EVar "KImplOn") (EApp (EVar "headTyName") (EVar "tys"))))
(DFunDef false "declKind" ((PRec "DData" ((rf "dataName" PWild)) false)) (EVar "KTypeDecl"))
(DFunDef false "declKind" ((PRec "DNewtype" ((rf "newtypeName" PWild)) false)) (EVar "KTypeDecl"))
(DFunDef false "declKind" (PWild) (EVar "KPlain"))
(DTypeSig false "declaredTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypeNames" ((PList)) (EListLit))
(DFunDef false "declaredTypeNames" ((PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EVar "declaredTypeName") (EVar "d")) (EApp (EVar "declaredTypeNames") (EVar "ds"))))
(DTypeSig false "declaredTypeName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypeName" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredTypeName" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredTypeName" (PWild) (EListLit))
(DTypeSig false "headTyName" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyName" ((PList)) (EVar "None"))
(DFunDef false "headTyName" ((PCons (PVar "t") PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")) (EVar "line")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc") (PVar "line")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "KPlain")) (EVar "line"))) (EApp (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc")) (EVar "line"))))))
(DData Private "DeriveShape" () ((variant "ShapeData" (ConPos (TyApp (TyCon "List") (TyCon "Variant")))) (variant "ShapeNewtype" (ConPos (TyCon "String") (TyCon "Ty")))) ())
(DTypeSig false "hasDeriver" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveShape") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "hasDeriver" ((PVar "tyName") (PVar "params") (PCon "ShapeData" (PVar "variants")) (PVar "iface")) (EApp (EApp (EVar "elem") (EVar "iface")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "tyName")) (EVar "params")) (EVar "variants")))))
(DFunDef false "hasDeriver" ((PVar "tyName") (PVar "params") (PCon "ShapeNewtype" (PVar "con") (PVar "fty")) (PVar "iface")) (EApp (EApp (EVar "elem") (EVar "iface")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "tyName")) (EVar "params")) (EVar "con")) (EVar "fty")))))
(DTypeSig false "derivedEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveShape") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "derivedEntries" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "derivedEntries" ((PVar "tyName") (PVar "params") (PVar "shape") (PVar "line") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "iface") (EApp (EVar "deriveRefName") (EVar "d"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EVar "derivedEntries") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "line")) (EVar "ds"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "hasDeriver") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "iface"))) (EVar "rest") (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "derivedHead") (EVar "tyName")) (EVar "params"))) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "args"))) (ELit (LString "")))) (DoLet false false (PVar "sigStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "args"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "derivedRequires") (EVar "iface")) (EVar "params")))) (ELit (LString "")))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (ELit (LString ""))) (EApp (EVar "KImplOn") (EApp (EVar "Some") (EVar "tyName")))) (EVar "line"))) (EVar "rest"))))))))
(DTypeSig false "derivedHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "derivedHead" ((PVar "tyName") (PList)) (EVar "tyName"))
(DFunDef false "derivedHead" ((PVar "tyName") (PVar "params")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "tyName") (EVar "params"))))) (ELit (LString ")"))))
(DTypeSig false "derivedRequires" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "derivedRequires" (PWild (PList)) (ELit (LString "")))
(DFunDef false "derivedRequires" ((PVar "iface") (PVar "params")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "p"))) (ELit (LString ""))))) (EVar "params")))))
(DTypeSig false "noDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Bool")))
(DFunDef false "noDerives" ((PList)) (EVar "True"))
(DFunDef false "noDerives" (PWild) (EVar "False"))
(DTypeSig false "derivesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "DeriveShape")))))
(DFunDef false "derivesOf" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "ds"))) false)) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EApp (EVar "not") (EApp (EVar "noDerives") (EVar "ds")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "ps") (EVar "ds") (EApp (EVar "ShapeData") (EVar "variants")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "derivesOf" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeDerives" (PVar "ds"))) false)) (EIf (EApp (EVar "not") (EApp (EVar "noDerives") (EVar "ds"))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "ps") (EVar "ds") (EApp (EApp (EVar "ShapeNewtype") (EVar "con")) (EVar "fty")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "derivesOf" (PWild) (EVar "None"))
(DTypeSig false "derivingEntries" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "DeriveShape")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))))
(DFunDef false "derivingEntries" ((PVar "bare") (PVar "decl") (PVar "line") (PVar "schemes") (PVar "tbl") (PTuple (PVar "tyName") (PVar "params") (PVar "derives") (PVar "shape"))) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoLet false false (PVar "own") (EMatch (EApp (EApp (EApp (EVar "renderSig") (EVar "bare")) (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EApp (EVar "declKind") (EVar "decl"))) (EVar "line"))))))) (DoExpr (EBinOp "++" (EVar "own") (EApp (EApp (EApp (EApp (EApp (EVar "derivedEntries") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "line")) (EVar "derives"))))))
(DTypeSig false "reexportEntries" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "reexportEntries" ((PVar "line") (PVar "schemes") (PVar "tbl") (PVar "origins") (PTuple (PVar "path") (PVar "members"))) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoLet false false (PVar "originMod") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntriesGo") (EVar "originMod")) (EVar "members")) (EVar "schemes")) (EApp (EApp (EVar "originSchemesOf") (EVar "originMod")) (EVar "origins"))) (EVar "doc")) (EVar "line")))))
(DTypeSig false "reexportEntriesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))))
(DFunDef false "reexportEntriesGo" (PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "reexportEntriesGo" ((PVar "originMod") (PCons (PVar "m") (PVar "rest")) (PVar "schemes") (PVar "originSchemes") (PVar "doc") (PVar "line")) (EBlock (DoLet false false (PVar "local") (EApp (EVar "useMemberLocal") (EVar "m"))) (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoLet false false (PVar "sigStr") (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "local")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "local"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "origin")) (EVar "originSchemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "local"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "local"))) (ELit (LString " : re-export of "))) (EApp (EVar "display") (EVar "originMod"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "origin"))) (ELit (LString "")))))))) (DoExpr (EBinOp "::" (ETuple (EVar "local") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "local")) (EVar "sigStr")) (EVar "doc")) (EVar "KPlain")) (EVar "line"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntriesGo") (EVar "originMod")) (EVar "rest")) (EVar "schemes")) (EVar "originSchemes")) (EVar "doc")) (EVar "line"))))))
(DTypeSig false "originSchemesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "originSchemesOf" (PWild (PList)) (EListLit))
(DFunDef false "originSchemesOf" ((PVar "mid") (PCons (PTuple (PVar "m") (PVar "ss")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "m")) (EVar "ss") (EIf (EVar "otherwise") (EApp (EApp (EVar "originSchemesOf") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originSchemeTable" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "originSchemeTable" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "originSchemeTable" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "roots") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EVar "originSchemeTable") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "ds"))) (DoExpr (EMatch (EApp (EVar "useGroupOf") (EVar "d")) (arm (PCon "None") () (EVar "rest")) (arm (PCon "Some" (PTuple (PVar "path") PWild)) () (EBlock (DoLet false false (PVar "mid") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path"))) (DoExpr (EIf (EApp (EApp (EVar "hasOriginEntry") (EVar "mid")) (EVar "rest")) (EVar "rest") (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EVar "originModuleSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "path"))) (EVar "rest"))))))))))
(DTypeSig false "hasOriginEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyCon "Bool"))))
(DFunDef false "hasOriginEntry" (PWild (PList)) (EVar "False"))
(DFunDef false "hasOriginEntry" ((PVar "mid") (PCons (PTuple (PVar "m") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "m")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasOriginEntry") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originModuleSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "originModuleSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "roots") (PVar "path")) (EMatch (EApp (EApp (EVar "findOriginFile") (EVar "roots")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "path"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "p")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ss")) () (EVar "ss"))))))
(DTypeSig false "findOriginFile" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "findOriginFile" ((PList) PWild) (EVar "None"))
(DFunDef false "findOriginFile" ((PCons (PVar "r") (PVar "rs")) (PVar "rel")) (EBlock (DoLet false false (PVar "p") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "r"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "rel"))) (ELit (LString ".mdk")))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "p")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "findOriginFile") (EVar "rs")) (EVar "rel"))))))
(DTypeSig false "useGroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember"))))))
(DFunDef false "useGroupOf" ((PCon "DUse" (PCon "True") (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "members"))))
(DFunDef false "useGroupOf" (PWild) (EVar "None"))
(DTypeSig false "extractEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))))
(DFunDef false "extractEntries" ((PVar "bare") (PVar "decls") (PVar "positions") (PVar "schemes") (PVar "origins") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "pairs")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "extractFold" (PWild (PList) PWild PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PVar "bare") (PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "origins") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "multiEntriesFor") (EVar "bare")) (EVar "decl")) (EVar "line")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (arm (PCon "Some" (PVar "extras")) () (EBlock (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "renderSig") (EVar "bare")) (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EApp (EVar "declKind") (EVar "decl"))) (EVar "line")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "insertSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "insertSections" ((PList) (PVar "entries")) (EVar "entries"))
(DFunDef false "insertSections" ((PCons (PTuple (PVar "l") (PVar "title")) (PVar "secs")) (PList)) (EBinOp "::" (EApp (EApp (EVar "sectionEntry") (EVar "l")) (EVar "title")) (EApp (EApp (EVar "insertSections") (EVar "secs")) (EListLit))))
(DFunDef false "insertSections" ((PCons (PTuple (PVar "l") (PVar "title")) (PVar "secs")) (PCons (PVar "e") (PVar "es"))) (EIf (EBinOp "<" (EVar "l") (EApp (EVar "entryLine") (EVar "e"))) (EBinOp "::" (EApp (EApp (EVar "sectionEntry") (EVar "l")) (EVar "title")) (EApp (EApp (EVar "insertSections") (EVar "secs")) (EBinOp "::" (EVar "e") (EVar "es")))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "insertSections") (EBinOp "::" (ETuple (EVar "l") (EVar "title")) (EVar "secs"))) (EVar "es")))))
(DTypeSig false "sectionEntry" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "DocEntry"))))
(DFunDef false "sectionEntry" ((PVar "line") (PVar "title")) (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "title")) (ELit (LString ""))) (ELit (LString ""))) (EVar "KSection")) (EVar "line")))
(DTypeSig false "entryLine" (TyFun (TyCon "DocEntry") (TyCon "Int")))
(DFunDef false "entryLine" ((PCon "DocEntry" PWild PWild PWild PWild (PVar "line"))) (EVar "line"))
(DTypeSig false "multiEntriesFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))))
(DFunDef false "multiEntriesFor" ((PVar "bare") (PVar "decl") (PVar "line") (PVar "schemes") (PVar "origins") (PVar "tbl")) (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl")))) (arm (PCon "None") () (EMatch (EApp (EVar "useGroupOf") (EVar "decl")) (arm (PCon "Some" (PVar "pm")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntries") (EVar "line")) (EVar "schemes")) (EVar "tbl")) (EVar "origins")) (EVar "pm")))) (arm (PCon "None") () (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "derivingEntries") (EVar "bare")) (EVar "decl")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (EApp (EVar "derivesOf") (EVar "decl"))))))))
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
(DTypeSig false "hasPipeMarker" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasPipeMarker" ((PVar "line")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EBinOp "==" (EVar "line") (ELit (LString "|")))))
(DTypeSig false "stripPipePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripPipePrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EIf (EBinOp "==" (EVar "line") (ELit (LString "|"))) (ELit (LString "")) (EVar "line"))))
(DTypeSig false "markerEligibleAfter" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "markerEligibleAfter" ((PVar "line")) (EBinOp "||" (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "isDecorativeLine") (EVar "line"))))
(DTypeSig false "isDecorativeLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDecorativeLine" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EApp (EVar "isDecorativeChar") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))))))
(DTypeSig false "isDecorativeChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDecorativeChar" ((PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z"))))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z")))))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))) (EBinOp "/=" (EVar "c") (ELit (LChar " ")))))
(DData Private "DocSegment" () ((variant "ProseSeg" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "ExampleSeg" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Private "SegMode" () ((variant "ModeProse" (ConPos)) (variant "ModeExample" (ConPos))) ())
(DTypeSig false "isExampleStart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExampleStart" ((PVar "line")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "> ")))))
(DTypeSig false "allBlankLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allBlankLines" ((PList)) (EVar "True"))
(DFunDef false "allBlankLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "allBlankLines") (EVar "xs"))))
(DTypeSig false "pushSeg" (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))
(DFunDef false "pushSeg" (PWild (PList) (PVar "segs")) (EVar "segs"))
(DFunDef false "pushSeg" ((PCon "ModeProse") (PVar "acc") (PVar "segs")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "reverseL") (EApp (EVar "dropWhileBlank") (EVar "acc")))) (DoExpr (EIf (EApp (EVar "allBlankLines") (EVar "ls")) (EVar "segs") (EBinOp "::" (EApp (EVar "ProseSeg") (EVar "ls")) (EVar "segs"))))))
(DFunDef false "pushSeg" ((PCon "ModeExample") (PVar "acc") (PVar "segs")) (EBinOp "::" (EApp (EVar "ExampleSeg") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "segs")))
(DTypeSig false "dropWhileBlank" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropWhileBlank" ((PCons (PLit (LString "")) (PVar "rest"))) (EApp (EVar "dropWhileBlank") (EVar "rest")))
(DFunDef false "dropWhileBlank" ((PVar "ls")) (EVar "ls"))
(DTypeSig false "docSegGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "SegMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))))
(DFunDef false "docSegGo" ((PList) (PVar "mode") PWild (PVar "acc") (PVar "segs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "pushSeg") (EVar "mode")) (EVar "acc")) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeProse") (PVar "markerOk") (PVar "acc") (PVar "segs")) (EIf (EApp (EVar "isExampleStart") (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EVar "False")) (EListLit (EVar "line"))) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeProse")) (EVar "acc")) (EVar "segs"))) (EIf (EBinOp "&&" (EVar "markerOk") (EApp (EVar "hasPipeMarker") (EVar "line"))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EVar "False")) (EBinOp "::" (EApp (EVar "stripPipePrefix") (EVar "line")) (EVar "acc"))) (EVar "segs")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EBinOp "&&" (EVar "markerOk") (EApp (EVar "markerEligibleAfter") (EVar "line")))) (EBinOp "::" (EVar "line") (EVar "acc"))) (EVar "segs")))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeExample") PWild (PVar "acc") (PVar "segs")) (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EVar "False")) (EListLit)) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeExample")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EVar "False")) (EBinOp "::" (EApp (EVar "unescapeGtPrefix") (EVar "line")) (EVar "acc"))) (EVar "segs"))))
(DTypeSig false "docSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DocSegment"))))
(DFunDef false "docSegments" ((PVar "lines")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "lines")) (EVar "ModeProse")) (EVar "True")) (EListLit)) (EListLit)))
(DTypeSig false "renderDocSegment" (TyFun (TyCon "DocSegment") (TyCon "String")))
(DFunDef false "renderDocSegment" ((PCon "ProseSeg" (PVar "ls"))) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls")))
(DFunDef false "renderDocSegment" ((PCon "ExampleSeg" (PVar "ls"))) (EBinOp "++" (EBinOp "++" (ELit (LString "```medaka\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls"))) (ELit (LString "\n```"))))
(DTypeSig false "renderDocProse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderDocProse" ((PVar "doc")) (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "segs") (EApp (EVar "docSegments") (EApp (EVar "splitNl") (EVar "doc")))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\n\n"))) (EApp (EApp (EVar "map") (EVar "renderDocSegment")) (EVar "segs")))))))
(DTypeSig false "moduleHeaderFrom" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyCon "String")))
(DFunDef false "moduleHeaderFrom" ((PList)) (ELit (LString "")))
(DFunDef false "moduleHeaderFrom" ((PCons (PTuple (PVar "startLine") (PVar "text") (PVar "b")) (PVar "rest"))) (EApp (EVar "markedDoc") (EApp (EApp (EVar "collectHeaderLines") (EBinOp "::" (ETuple (EVar "startLine") (EVar "text") (EVar "b")) (EVar "rest"))) (EVar "startLine"))))
(DTypeSig false "collectHeaderLines" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "CommentRow")))))
(DFunDef false "collectHeaderLines" ((PVar "tbl") (PVar "line")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "t") (PVar "b"))) () (EBinOp "::" (ETuple (EVar "line") (EVar "t") (EVar "b")) (EApp (EApp (EVar "collectHeaderLines") (EVar "tbl")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "header") (PVar "entries")) (EBlock (DoLet false false (PVar "titleBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n")))) (DoLet false false (PVar "headerProse") (EApp (EVar "renderDocProse") (EVar "header"))) (DoLet false false (PVar "headerBlock") (EIf (EBinOp "==" (EVar "headerProse") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "headerProse") (ELit (LString "\n\n"))))) (DoLet false false (PVar "sectioned") (EApp (EApp (EVar "anyDoc") (EVar "isSection")) (EVar "entries"))) (DoLet false false (PVar "main") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isListedImpl") (EVar "e"))))) (EVar "entries"))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "::" (EVar "titleBlock") (EBinOp "::" (EApp (EVar "primitiveLayerBanner") (EVar "moduleName")) (EBinOp "::" (EVar "headerBlock") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EApp (EVar "renderEntry") (EVar "sectioned")) (EVar "entries"))) (EVar "main")) (EListLit (EApp (EVar "renderInstancesSection") (EVar "entries")))))))))))
(DTypeSig false "primitiveLayerBanner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "primitiveLayerBanner" ((PVar "moduleName")) (EIf (EApp (EVar "preludeOnlyModule") (EVar "moduleName")) (ELit (LString "> These are the host primitives. They are in scope everywhere without an\n> import, and their `<type><Op>` names (`stringToUpper`, `intToString`)\n> mark them as the primitive layer. Prefer the library name where one\n> exists (`string.toUpper`, `string.toFloat`), and reach for a name on this\n> page only when no library module covers it.\n\n")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isSection" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isSection" ((PCon "DocEntry" PWild PWild PWild (PCon "KSection") PWild)) (EVar "True"))
(DFunDef false "isSection" (PWild) (EVar "False"))
(DTypeSig false "isImpl" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isImpl" ((PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" PWild) PWild)) (EVar "True"))
(DFunDef false "isImpl" (PWild) (EVar "False"))
(DTypeSig false "isListedImpl" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isListedImpl" ((PCon "DocEntry" (PVar "name") PWild PWild (PCon "KImplOn" PWild) PWild)) (EBinOp "/=" (EApp (EVar "instanceHead") (EVar "name")) (ELit (LString ""))))
(DFunDef false "isListedImpl" (PWild) (EVar "False"))
(DTypeSig false "anyDoc" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyDoc" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDoc" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyDoc") (EVar "p")) (EVar "xs"))))
(DTypeSig false "instanceIface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "instanceIface" ((PVar "name")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString " "))) (EVar "name")) (arm (PCon "None") () (EVar "name")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EVar "i")) (EVar "name")))))
(DTypeSig false "instanceHead" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "instanceHead" ((PVar "name")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString " "))) (EVar "name")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "dsub") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "dlen") (EVar "name"))) (EVar "name")))))
(DTypeSig false "instanceKey" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "instanceKey" ((PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EVar "hd"))
(DFunDef false "instanceKey" ((PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EApp (EVar "instanceHead") (EVar "name")))
(DTypeSig false "renderEntry" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "DocEntry") (TyCon "String")))))
(DFunDef false "renderEntry" (PWild PWild (PCon "DocEntry" (PVar "title") PWild PWild (PCon "KSection") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "## ")) (EVar "title")) (ELit (LString "\n\n"))))
(DFunDef false "renderEntry" ((PVar "sectioned") (PVar "entries") (PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc") (PVar "kind") PWild)) (EBlock (DoLet false false (PVar "level") (EIf (EVar "sectioned") (ELit (LString "### ")) (ELit (LString "## ")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "level"))) (ELit (LString "`"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "instances") (EMatch (EVar "kind") (arm (PCon "KTypeDecl") () (EApp (EVar "instanceLine") (EApp (EApp (EVar "instancesOf") (EVar "name")) (EVar "entries")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "rendered") (EApp (EVar "renderDocProse") (EVar "doc"))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "rendered") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "rendered")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "header"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "docBlock"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "instances"))) (ELit (LString "\n"))))))
(DTypeSig false "instancesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "instancesOf" ((PVar "tyName") (PVar "entries")) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EApp (EVar "implHeadIs") (EVar "tyName")) (EVar "e")))) (EVar "entries")))
(DTypeSig false "implHeadIs" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "implHeadIs" ((PVar "tyName") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EBinOp "==" (EVar "hd") (EVar "tyName")))
(DFunDef false "implHeadIs" (PWild PWild) (EVar "False"))
(DTypeSig false "instanceLine" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "instanceLine" ((PList)) (ELit (LString "")))
(DFunDef false "instanceLine" ((PVar "impls")) (EBinOp "++" (EBinOp "++" (ELit (LString "\nInstances: ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "instanceRef")) (EVar "impls")))) (ELit (LString "\n"))))
(DTypeSig false "instanceRef" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "instanceRef" ((PCon "DocEntry" (PVar "name") PWild (PVar "doc") PWild PWild)) (EBlock (DoLet false false (PVar "iface") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "instanceIface") (EVar "name"))) (ELit (LString "`")))) (DoExpr (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "](#"))) (EApp (EVar "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")")))))))
(DTypeSig false "renderInstancesSection" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "renderInstancesSection" ((PVar "entries")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "filterDoc") (EVar "isListedImpl")) (EVar "entries"))) (DoLet false false (PVar "orphans") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "hasTypeEntry") (EVar "entries")) (EVar "e"))))) (EVar "listed"))) (DoLet false false (PVar "keys") (EApp (EVar "uniqueDoc") (EApp (EApp (EVar "map") (EVar "instanceKey")) (EVar "orphans")))) (DoLet false false (PVar "bullets") (EMatch (EVar "keys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EApp (EVar "orphanLine") (EVar "orphans"))) (EVar "keys"))))) (ELit (LString "\n\n")))))) (DoLet false false (PVar "documented") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renderEntry") (EVar "True")) (EVar "entries"))) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "/=" (EApp (EVar "entryDoc") (EVar "e")) (ELit (LString ""))))) (EVar "listed"))))) (DoExpr (EMatch (EVar "listed") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## Instances\n\n")) (EApp (EVar "display") (EVar "bullets"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "documented"))) (ELit (LString ""))))))))
(DTypeSig false "orphanLine" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "orphanLine" ((PVar "orphans") (PVar "key")) (EBlock (DoLet false false (PVar "mine") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "instanceKey") (EVar "e")) (EVar "key")))) (EVar "orphans"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- `")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "`: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "instanceRef")) (EVar "mine"))))) (ELit (LString ""))))))
(DTypeSig false "hasTypeEntry" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "hasTypeEntry" ((PVar "entries") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EApp (EApp (EVar "anyDoc") (ELam ((PVar "e")) (EApp (EApp (EVar "isTypeNamed") (EVar "hd")) (EVar "e")))) (EVar "entries")))
(DFunDef false "hasTypeEntry" (PWild PWild) (EVar "False"))
(DTypeSig false "isTypeNamed" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "isTypeNamed" ((PVar "n") (PCon "DocEntry" (PVar "name") PWild PWild (PCon "KTypeDecl") PWild)) (EBinOp "==" (EVar "name") (EVar "n")))
(DFunDef false "isTypeNamed" (PWild PWild) (EVar "False"))
(DTypeSig false "entryDoc" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "entryDoc" ((PCon "DocEntry" PWild PWild (PVar "doc") PWild PWild)) (EVar "doc"))
(DTypeSig false "uniqueDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "uniqueDoc" ((PList)) (EListLit))
(DFunDef false "uniqueDoc" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "uniqueDoc") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "x")))) (EVar "xs")))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EVar "filename")) (EVar "roots")) (arm (PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild) () (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))))
(DData Abstract "ModuleDoc" () ((variant "ModuleDoc" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "mdName" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "mdName" ((PCon "ModuleDoc" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "docOnlyExcluded" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "docOnlyExcluded" () (EListLit (ELit (LString "__fallthrough__")) (ELit (LString "setRef")) (ELit (LString "stashRunStdout")) (ELit (LString "enableRunStdoutFlush")) (ELit (LString "assertSnapshot")) (ELit (LString "indexError")) (ELit (LString "indexErrorAt")) (ELit (LString "sliceError")) (ELit (LString "debugStringLit")) (ELit (LString "debugCharLit")) (ELit (LString "buildFingerprint"))))
(DTypeSig false "dropInternalExterns" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "dropInternalExterns" ((PCon "False") (PVar "entries")) (EVar "entries"))
(DFunDef false "dropInternalExterns" ((PCon "True") (PVar "entries")) (EApp (EApp (EVar "filter") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isInternalExtern") (EVar "e"))))) (EVar "entries")))
(DTypeSig false "isInternalExtern" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isInternalExtern" ((PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EBinOp "||" (EApp (EApp (EVar "elem") (EVar "name")) (EVar "internalExterns")) (EApp (EApp (EVar "elem") (EVar "name")) (EVar "docOnlyExcluded"))))
(DTypeSig true "computeModuleDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "ModuleDoc"))))))))
(DFunDef false "computeModuleDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filename")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "origins") (EApp (EApp (EApp (EApp (EVar "originSchemeTable") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "header") (EApp (EVar "moduleHeaderFrom") (EVar "tbl"))) (DoLet false false (PVar "primitiveLayer") (EApp (EVar "preludeOnlyModule") (EVar "moduleName"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "dropInternalExterns") (EVar "primitiveLayer")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "primitiveLayer")) (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "origins")) (EVar "comments")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "moduleName")) (EApp (EApp (EVar "dedupHeader") (EVar "header")) (EVar "entries"))) (EApp (EApp (EVar "insertSections") (EApp (EVar "sectionsFrom") (EVar "tbl"))) (EVar "entries"))) (EApp (EVar "declaredTypeNames") (EVar "rawDecls"))))))
(DTypeSig false "dedupHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "dedupHeader" ((PVar "header") (PVar "entries")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "header") (ELit (LString ""))) (EBinOp "==" (EVar "header") (EApp (EVar "firstEntryDoc") (EVar "entries")))) (ELit (LString "")) (EVar "header")))
(DTypeSig false "firstEntryDoc" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "firstEntryDoc" ((PList)) (ELit (LString "")))
(DFunDef false "firstEntryDoc" ((PCons (PCon "DocEntry" PWild PWild (PVar "doc") PWild PWild) PWild)) (EVar "doc"))
(DTypeSig true "renderModulePage" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderModulePage" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild)) (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))
(DTypeSig true "excludedLibraryModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "excludedLibraryModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "async"))))
(DTypeSig true "rebucketLibraryImpls" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyApp (TyCon "List") (TyCon "ModuleDoc"))))
(DFunDef false "rebucketLibraryImpls" ((PVar "mds")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "concatMapDoc") (EVar "typeOwnersOf")) (EVar "mds"))) (DoLet false false (PVar "mentions") (EApp (EApp (EVar "map") (EVar "moduleMentionIndex")) (EVar "mds"))) (DoLet false false (PVar "moved") (EApp (EApp (EVar "concatMapDoc") (EApp (EApp (EVar "movedFrom") (EVar "owners")) (EVar "mentions"))) (EVar "mds"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rebucketOne") (EVar "owners")) (EVar "mentions")) (EVar "moved"))) (EVar "mds")))))
(DTypeSig false "typeOwnersOf" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeOwnersOf" ((PCon "ModuleDoc" (PVar "n") PWild PWild (PVar "tyNames"))) (EApp (EApp (EVar "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EVar "n")))) (EVar "tyNames")))
(DTypeSig false "moduleMentionIndex" (TyFun (TyCon "ModuleDoc") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleMentionIndex" ((PCon "ModuleDoc" (PVar "n") PWild (PVar "es") PWild)) (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "entrySigOf")) (EVar "es"))))
(DTypeSig false "entrySigOf" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "entrySigOf" ((PCon "DocEntry" PWild (PVar "sig") PWild PWild PWild)) (EVar "sig"))
(DTypeSig false "ownerOfType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "ownerOfType" ((PVar "owners") (PVar "mentions") (PVar "tyName")) (EMatch (EApp (EApp (EVar "lookupStrDoc") (EVar "tyName")) (EVar "owners")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Some") (EVar "m"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "lowered") (EApp (EVar "toLower") (EVar "tyName"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupSigsDoc") (EVar "lowered")) (EVar "mentions")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "sigs")) () (EIf (EApp (EApp (EVar "anyMentions") (EVar "tyName")) (EVar "sigs")) (EApp (EVar "Some") (EVar "lowered")) (EVar "None")))))))))
(DTypeSig false "lookupSigsDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupSigsDoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSigsDoc" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupSigsDoc") (EVar "k")) (EVar "rest"))))
(DTypeSig false "anyMentions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyMentions" (PWild (PList)) (EVar "False"))
(DFunDef false "anyMentions" ((PVar "tyName") (PCons (PVar "s") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "mentionsToken") (EVar "tyName")) (EVar "s")) (EApp (EApp (EVar "anyMentions") (EVar "tyName")) (EVar "rest"))))
(DTypeSig false "mentionsToken" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "mentionsToken" ((PVar "needle") (PVar "hay")) (EBlock (DoLet false false (PVar "ns") (EApp (EVar "stringToChars") (EVar "needle"))) (DoLet false false (PVar "hs") (EApp (EVar "stringToChars") (EVar "hay"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mentionsTokenGo") (EVar "ns")) (EVar "hs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "ns"))) (EApp (EVar "arrayLength") (EVar "hs"))))))
(DTypeSig false "mentionsTokenGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "mentionsTokenGo" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "n") (PVar "h")) (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "n")) (EVar "h"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "charsMatchAt") (EVar "ns")) (EVar "hs")) (EVar "i")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentCharAt") (EVar "hs")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "h")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentCharAt") (EVar "hs")) (EBinOp "+" (EVar "i") (EVar "n"))) (EVar "h")))) (EVar "True") (EApp (EApp (EApp (EApp (EApp (EVar "mentionsTokenGo") (EVar "ns")) (EVar "hs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "h")))))
(DTypeSig false "charsMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "charsMatchAt" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "charsMatchAtGo") (EVar "ns")) (EVar "hs")) (EVar "i")) (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "charsMatchAtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "charsMatchAtGo" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "j") (PVar "n")) (EIf (EBinOp ">=" (EVar "j") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "hs")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "ns"))) (EApp (EApp (EApp (EApp (EApp (EVar "charsMatchAtGo") (EVar "ns")) (EVar "hs")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DTypeSig false "isIdentCharAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isIdentCharAt" ((PVar "hs") (PVar "i") (PVar "h")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EVar "h"))) (EVar "False") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "hs")))))
(DTypeSig false "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9"))))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "lookupStrDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupStrDoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupStrDoc" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupStrDoc") (EVar "k")) (EVar "rest"))))
(DTypeSig false "entryTarget" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "entryTarget" ((PVar "owners") (PVar "mentions") (PVar "here") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EMatch (EApp (EApp (EApp (EVar "ownerOfType") (EVar "owners")) (EVar "mentions")) (EVar "hd")) (arm (PCon "Some" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "here")) (EVar "None") (EApp (EVar "Some") (EVar "m")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "entryTarget" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "movedFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "movedFrom" ((PVar "owners") (PVar "mentions") (PCon "ModuleDoc" (PVar "here") PWild (PVar "es") PWild)) (EApp (EApp (EVar "concatMapDoc") (EApp (EApp (EApp (EVar "movedEntry") (EVar "owners")) (EVar "mentions")) (EVar "here"))) (EVar "es")))
(DTypeSig false "movedEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))
(DFunDef false "movedEntry" ((PVar "owners") (PVar "mentions") (PVar "here") (PVar "e")) (EMatch (EApp (EApp (EApp (EApp (EVar "entryTarget") (EVar "owners")) (EVar "mentions")) (EVar "here")) (EVar "e")) (arm (PCon "Some" (PVar "m")) () (EListLit (ETuple (EVar "m") (EVar "e")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "rebucketOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyCon "ModuleDoc") (TyCon "ModuleDoc"))))))
(DFunDef false "rebucketOne" ((PVar "owners") (PVar "mentions") (PVar "moved") (PCon "ModuleDoc" (PVar "here") (PVar "header") (PVar "es") (PVar "tyNames"))) (EBlock (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "isNoneDoc") (EApp (EApp (EApp (EApp (EVar "entryTarget") (EVar "owners")) (EVar "mentions")) (EVar "here")) (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "incoming") (EApp (EApp (EVar "concatMapDoc") (EApp (EVar "takeForModule") (EVar "here"))) (EVar "moved"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "here")) (EVar "header")) (EBinOp "++" (EVar "kept") (EVar "incoming"))) (EVar "tyNames")))))
(DTypeSig false "takeForModule" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "takeForModule" ((PVar "here") (PTuple (PVar "m") (PVar "e"))) (EIf (EBinOp "==" (EVar "m") (EVar "here")) (EListLit (EVar "e")) (EListLit)))
(DTypeSig false "filterDoc" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterDoc" (PWild (PList)) (EListLit))
(DFunDef false "filterDoc" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterDoc") (EVar "p")) (EVar "xs"))) (EApp (EApp (EVar "filterDoc") (EVar "p")) (EVar "xs"))))
(DTypeSig false "isNoneDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isNoneDoc" ((PCon "None")) (EVar "True"))
(DFunDef false "isNoneDoc" (PWild) (EVar "False"))
(DTypeSig false "slugifyAnchor" (TyFun (TyCon "String") (TyCon "String")))
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
(DFunDef false "inventoryEntriesFor" ((PCon "ModuleDoc" (PVar "moduleName") PWild (PVar "entries") PWild)) (EApp (EApp (EVar "map") (EApp (EVar "inventoryEntryJson") (EVar "moduleName"))) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isSection") (EVar "e"))))) (EVar "entries"))))
(DTypeSig false "inventoryEntryJson" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Json"))))
(DFunDef false "inventoryEntryJson" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") (PVar "sig") PWild PWild PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "module")) (EApp (EVar "JString") (EVar "moduleName"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "signature")) (EApp (EVar "JString") (EVar "sig"))))))
(DTypeSig true "renderIndex" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "String")))
(DFunDef false "renderIndex" ((PVar "mds")) (EApp (EVar "stringConcat") (EBinOp "::" (ELit (LString "# Library Index\n\n")) (EApp (EApp (EVar "map") (EVar "renderIndexModule")) (EVar "mds")))))
(DTypeSig false "renderIndexModule" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderIndexModule" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild)) (EBlock (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## [`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ".md)\n\n")))) (DoLet false false (PVar "summary") (EApp (EVar "firstSentence") (EApp (EVar "renderDocProse") (EVar "header")))) (DoLet false false (PVar "summaryBlock") (EIf (EBinOp "==" (EVar "summary") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "summary") (ELit (LString "\n\n"))))) (DoLet false false (PVar "listed") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isImpl") (EVar "e"))) (EApp (EVar "not") (EApp (EVar "isSection") (EVar "e")))))) (EVar "entries"))) (DoLet false false (PVar "links") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EApp (EVar "renderIndexLink") (EVar "name"))) (EVar "listed")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "summaryBlock"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "links"))) (ELit (LString "\n\n"))))))
(DTypeSig false "renderIndexLink" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "String"))))
(DFunDef false "renderIndexLink" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- [`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EVar "display") (EVar "moduleName"))) (ELit (LString ".md#"))) (EApp (EVar "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "firstSentence" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstSentence" ((PVar "prose")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "prose"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "cut") (EApp (EApp (EApp (EVar "sentenceEnd") (EVar "cs")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "splitNl") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EVar "cut")) (EVar "prose"))))))))
(DTypeSig false "sentenceEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "sentenceEnd" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "firstLineEnd") (EVar "cs")) (ELit (LInt 0))) (EVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "."))) (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "isSentenceGap") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "sentenceEnd") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))))
(DTypeSig false "isSentenceGap" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSentenceGap" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig false "firstLineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstLineEnd" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EVar "i") (EApp (EApp (EApp (EVar "firstLineEnd") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filename") (PVar "roots") (PVar "rawUser")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "filename")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka doc: '")) (EApp (EVar "display") (EVar "filename"))) (ELit (LString "' has an unresolved import graph (missing or cyclic import) — signatures unavailable"))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "schemes")) () (EVar "schemes"))))
# MARK
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "tyParamSources" false) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true) (mem "UsePath" true) (mem "UseMember" false) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "DeriveRef" false) (mem "deriveRefName" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalExterns" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false) (mem "splitNl" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "dataDerivers" false) (mem "newtypeDerivers" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "DocKind") (TyCon "Int")))) ())
(DData Private "DocKind" () ((variant "KPlain" (ConPos)) (variant "KTypeDecl" (ConPos)) (variant "KImplOn" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "KSection" (ConPos))) ())
(DTypeAlias false "CommentRow" () (TyTuple (TyCon "Int") (TyCon "String") (TyCon "Int")))
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
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTyP" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideDoc") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInsideDoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideDoc" ((PVar "effs") (PVar "tails")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EMethodRef "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoExpr (EMatch (EVar "tails") (arm (PList) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm PWild () (EBlock (DoLet false false (PVar "tls") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))) (DoExpr (EMatch (EVar "effs") (arm (PList) () (EVar "tls")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "tls"))) (ELit (LString ""))))))))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "isDoctestInputText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDoctestInputText" ((PVar "t")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 5))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "t")) (ELit (LString "-- > ")))))
(DTypeSig false "docLineBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "docLineBody" ((PVar "t")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "commentBody") (EVar "t"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isDoctestInputText") (EVar "t")) (EApp (EVar "not") (EApp (EVar "isExampleStart") (EVar "body")))) (EVar "body") (EBinOp "++" (ELit (LString "\\")) (EVar "body"))))))
(DTypeSig false "unescapeGtPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unescapeGtPrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "line")) (ELit (LString "\\> ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 1))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EVar "line")))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "CommentRow"))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNl") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "docLineBody") (EVar "t")) (ELit (LInt 0))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "CommentRow"))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line")) (EVar "baseLine")) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "CommentRow"))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (ETuple (EVar "t") (EVar "b")))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "markedDoc") (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "CommentRow"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PTuple (PVar "t") (PVar "b"))) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (ETuple (EVar "line") (EVar "t") (EVar "b")) (EVar "acc"))))))
(DTypeSig false "markedDoc" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyCon "String")))
(DFunDef false "markedDoc" ((PVar "rows")) (EMatch (EApp (EApp (EVar "dropToMarker") (EVar "True")) (EVar "rows")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PTuple PWild (PVar "t") (PVar "b")) (PVar "rest")) () (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "sameBlockTexts") (EVar "b")) (EVar "rest"))))))))
(DTypeSig false "dropToMarker" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "CommentRow")))))
(DFunDef false "dropToMarker" (PWild (PList)) (EListLit))
(DFunDef false "dropToMarker" ((PVar "atStart") (PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "hasPipeMarker") (EVar "t")) (EBinOp "||" (EVar "atStart") (EBinOp "&&" (EBinOp ">" (EVar "b") (ELit (LInt 0))) (EBinOp "==" (EVar "l") (EVar "b"))))) (EBinOp "::" (ETuple (EVar "l") (EVar "t") (EVar "b")) (EVar "rest")) (EIf (EVar "otherwise") (EApp (EApp (EVar "dropToMarker") (EBinOp "&&" (EVar "atStart") (EApp (EVar "markerEligibleAfter") (EVar "t")))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sameBlockTexts" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sameBlockTexts" (PWild (PList)) (EListLit))
(DFunDef false "sameBlockTexts" ((PVar "b") (PCons (PTuple PWild (PVar "t") (PVar "b2")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "b2") (EVar "b")) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "sameBlockTexts") (EVar "b")) (EVar "rest"))) (EListLit)))
(DTypeSig false "sectionsFrom" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "sectionsFrom" ((PList)) (EListLit))
(DFunDef false "sectionsFrom" ((PCons (PTuple (PVar "l") (PVar "t") (PVar "b")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2)))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "# ")))) (EBinOp "::" (ETuple (EVar "l") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")))) (EApp (EVar "sectionsFrom") (EVar "rest"))) (EApp (EVar "sectionsFrom") (EVar "rest"))))
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
(DFunDef false "valueSig" ((PVar "name") PWild (PCon "Some" (PVar "ty"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PCon "None")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "renderSig" (PWild (PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" (PWild (PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PVar "bare") (PCon "DExtern" (PVar "pub") (PVar "name") (PVar "ty")) (PVar "schemes")) (EIf (EBinOp "||" (EVar "pub") (EVar "bare")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" (PWild (PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" (PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants"))) false) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EMethodRef "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" (PWild (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "typarams")) (EVar "typaramKinds"))))) (DoLet false false (PVar "ms") (EApp (EApp (EMethodRef "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "kinds")) (rf "tyAliasRhs" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "kinds")) (rf "newtypeCtor" (PVar "ctor")) (rf "newtypeFieldTy" (PVar "ty"))) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild (PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "preludeOnlyModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "preludeOnlyModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "runtime"))))
(DTypeSig false "declKind" (TyFun (TyCon "Decl") (TyCon "DocKind")))
(DFunDef false "declKind" ((PRec "DImpl" ((rf "tys" (PVar "tys"))) false)) (EApp (EVar "KImplOn") (EApp (EVar "headTyName") (EVar "tys"))))
(DFunDef false "declKind" ((PRec "DData" ((rf "dataName" PWild)) false)) (EVar "KTypeDecl"))
(DFunDef false "declKind" ((PRec "DNewtype" ((rf "newtypeName" PWild)) false)) (EVar "KTypeDecl"))
(DFunDef false "declKind" (PWild) (EVar "KPlain"))
(DTypeSig false "declaredTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypeNames" ((PList)) (EListLit))
(DFunDef false "declaredTypeNames" ((PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EVar "declaredTypeName") (EVar "d")) (EApp (EVar "declaredTypeNames") (EVar "ds"))))
(DTypeSig false "declaredTypeName" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypeName" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredTypeName" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredTypeName" (PWild) (EListLit))
(DTypeSig false "headTyName" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyName" ((PList)) (EVar "None"))
(DFunDef false "headTyName" ((PCons (PVar "t") PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")) (EVar "line")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc") (PVar "line")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "KPlain")) (EVar "line"))) (EApp (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc")) (EVar "line"))))))
(DData Private "DeriveShape" () ((variant "ShapeData" (ConPos (TyApp (TyCon "List") (TyCon "Variant")))) (variant "ShapeNewtype" (ConPos (TyCon "String") (TyCon "Ty")))) ())
(DTypeSig false "hasDeriver" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveShape") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "hasDeriver" ((PVar "tyName") (PVar "params") (PCon "ShapeData" (PVar "variants")) (PVar "iface")) (EApp (EApp (EDictApp "elem") (EVar "iface")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "tyName")) (EVar "params")) (EVar "variants")))))
(DFunDef false "hasDeriver" ((PVar "tyName") (PVar "params") (PCon "ShapeNewtype" (PVar "con") (PVar "fty")) (PVar "iface")) (EApp (EApp (EDictApp "elem") (EVar "iface")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "tyName")) (EVar "params")) (EVar "con")) (EVar "fty")))))
(DTypeSig false "derivedEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveShape") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "derivedEntries" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "derivedEntries" ((PVar "tyName") (PVar "params") (PVar "shape") (PVar "line") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "iface") (EApp (EVar "deriveRefName") (EVar "d"))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EVar "derivedEntries") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "line")) (EVar "ds"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "hasDeriver") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "iface"))) (EVar "rest") (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "derivedHead") (EVar "tyName")) (EVar "params"))) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString "")))) (DoLet false false (PVar "sigStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "derivedRequires") (EVar "iface")) (EVar "params")))) (ELit (LString "")))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (ELit (LString ""))) (EApp (EVar "KImplOn") (EApp (EVar "Some") (EVar "tyName")))) (EVar "line"))) (EVar "rest"))))))))
(DTypeSig false "derivedHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "derivedHead" ((PVar "tyName") (PList)) (EVar "tyName"))
(DFunDef false "derivedHead" ((PVar "tyName") (PVar "params")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "tyName") (EVar "params"))))) (ELit (LString ")"))))
(DTypeSig false "derivedRequires" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "derivedRequires" (PWild (PList)) (ELit (LString "")))
(DFunDef false "derivedRequires" ((PVar "iface") (PVar "params")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString ""))))) (EVar "params")))))
(DTypeSig false "noDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Bool")))
(DFunDef false "noDerives" ((PList)) (EVar "True"))
(DFunDef false "noDerives" (PWild) (EVar "False"))
(DTypeSig false "derivesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "DeriveShape")))))
(DFunDef false "derivesOf" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "ds"))) false)) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EApp (EVar "not") (EApp (EVar "noDerives") (EVar "ds")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "ps") (EVar "ds") (EApp (EVar "ShapeData") (EVar "variants")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "derivesOf" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeDerives" (PVar "ds"))) false)) (EIf (EApp (EVar "not") (EApp (EVar "noDerives") (EVar "ds"))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "ps") (EVar "ds") (EApp (EApp (EVar "ShapeNewtype") (EVar "con")) (EVar "fty")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "derivesOf" (PWild) (EVar "None"))
(DTypeSig false "derivingEntries" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "DeriveShape")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))))
(DFunDef false "derivingEntries" ((PVar "bare") (PVar "decl") (PVar "line") (PVar "schemes") (PVar "tbl") (PTuple (PVar "tyName") (PVar "params") (PVar "derives") (PVar "shape"))) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoLet false false (PVar "own") (EMatch (EApp (EApp (EApp (EVar "renderSig") (EVar "bare")) (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EApp (EVar "declKind") (EVar "decl"))) (EVar "line"))))))) (DoExpr (EBinOp "++" (EVar "own") (EApp (EApp (EApp (EApp (EApp (EVar "derivedEntries") (EVar "tyName")) (EVar "params")) (EVar "shape")) (EVar "line")) (EVar "derives"))))))
(DTypeSig false "reexportEntries" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "reexportEntries" ((PVar "line") (PVar "schemes") (PVar "tbl") (PVar "origins") (PTuple (PVar "path") (PVar "members"))) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoLet false false (PVar "originMod") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntriesGo") (EVar "originMod")) (EVar "members")) (EVar "schemes")) (EApp (EApp (EVar "originSchemesOf") (EVar "originMod")) (EVar "origins"))) (EVar "doc")) (EVar "line")))))
(DTypeSig false "reexportEntriesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))))
(DFunDef false "reexportEntriesGo" (PWild (PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "reexportEntriesGo" ((PVar "originMod") (PCons (PVar "m") (PVar "rest")) (PVar "schemes") (PVar "originSchemes") (PVar "doc") (PVar "line")) (EBlock (DoLet false false (PVar "local") (EApp (EVar "useMemberLocal") (EVar "m"))) (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoLet false false (PVar "sigStr") (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "local")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "local"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "origin")) (EVar "originSchemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "local"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "local"))) (ELit (LString " : re-export of "))) (EApp (EMethodRef "display") (EVar "originMod"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "origin"))) (ELit (LString "")))))))) (DoExpr (EBinOp "::" (ETuple (EVar "local") (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "local")) (EVar "sigStr")) (EVar "doc")) (EVar "KPlain")) (EVar "line"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntriesGo") (EVar "originMod")) (EVar "rest")) (EVar "schemes")) (EVar "originSchemes")) (EVar "doc")) (EVar "line"))))))
(DTypeSig false "originSchemesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "originSchemesOf" (PWild (PList)) (EListLit))
(DFunDef false "originSchemesOf" ((PVar "mid") (PCons (PTuple (PVar "m") (PVar "ss")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "m")) (EVar "ss") (EIf (EVar "otherwise") (EApp (EApp (EVar "originSchemesOf") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originSchemeTable" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "originSchemeTable" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "originSchemeTable" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "roots") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EVar "originSchemeTable") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "ds"))) (DoExpr (EMatch (EApp (EVar "useGroupOf") (EVar "d")) (arm (PCon "None") () (EVar "rest")) (arm (PCon "Some" (PTuple (PVar "path") PWild)) () (EBlock (DoLet false false (PVar "mid") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path"))) (DoExpr (EIf (EApp (EApp (EVar "hasOriginEntry") (EVar "mid")) (EVar "rest")) (EVar "rest") (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EVar "originModuleSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "path"))) (EVar "rest"))))))))))
(DTypeSig false "hasOriginEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyCon "Bool"))))
(DFunDef false "hasOriginEntry" (PWild (PList)) (EVar "False"))
(DFunDef false "hasOriginEntry" ((PVar "mid") (PCons (PTuple (PVar "m") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "m")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasOriginEntry") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originModuleSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))
(DFunDef false "originModuleSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "roots") (PVar "path")) (EMatch (EApp (EApp (EVar "findOriginFile") (EVar "roots")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "path"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "p")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ss")) () (EVar "ss"))))))
(DTypeSig false "findOriginFile" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "findOriginFile" ((PList) PWild) (EVar "None"))
(DFunDef false "findOriginFile" ((PCons (PVar "r") (PVar "rs")) (PVar "rel")) (EBlock (DoLet false false (PVar "p") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "r"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "rel"))) (ELit (LString ".mdk")))) (DoExpr (EIf (EApp (EVar "fileExists") (EVar "p")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "findOriginFile") (EVar "rs")) (EVar "rel"))))))
(DTypeSig false "useGroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember"))))))
(DFunDef false "useGroupOf" ((PCon "DUse" (PCon "True") (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EApp (EVar "Some") (ETuple (EVar "path") (EVar "members"))))
(DFunDef false "useGroupOf" (PWild) (EVar "None"))
(DTypeSig false "extractEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))))
(DFunDef false "extractEntries" ((PVar "bare") (PVar "decls") (PVar "positions") (PVar "schemes") (PVar "origins") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "pairs")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "extractFold" (PWild (PList) PWild PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PVar "bare") (PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "origins") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "multiEntriesFor") (EVar "bare")) (EVar "decl")) (EVar "line")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (arm (PCon "Some" (PVar "extras")) () (EBlock (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "renderSig") (EVar "bare")) (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "bare")) (EVar "rest")) (EVar "schemes")) (EVar "origins")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EApp (EVar "declKind") (EVar "decl"))) (EVar "line")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "insertSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "insertSections" ((PList) (PVar "entries")) (EVar "entries"))
(DFunDef false "insertSections" ((PCons (PTuple (PVar "l") (PVar "title")) (PVar "secs")) (PList)) (EBinOp "::" (EApp (EApp (EVar "sectionEntry") (EVar "l")) (EVar "title")) (EApp (EApp (EVar "insertSections") (EVar "secs")) (EListLit))))
(DFunDef false "insertSections" ((PCons (PTuple (PVar "l") (PVar "title")) (PVar "secs")) (PCons (PVar "e") (PVar "es"))) (EIf (EBinOp "<" (EVar "l") (EApp (EVar "entryLine") (EVar "e"))) (EBinOp "::" (EApp (EApp (EVar "sectionEntry") (EVar "l")) (EVar "title")) (EApp (EApp (EVar "insertSections") (EVar "secs")) (EBinOp "::" (EVar "e") (EVar "es")))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "insertSections") (EBinOp "::" (ETuple (EVar "l") (EVar "title")) (EVar "secs"))) (EVar "es")))))
(DTypeSig false "sectionEntry" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "DocEntry"))))
(DFunDef false "sectionEntry" ((PVar "line") (PVar "title")) (EApp (EApp (EApp (EApp (EApp (EVar "DocEntry") (EVar "title")) (ELit (LString ""))) (ELit (LString ""))) (EVar "KSection")) (EVar "line")))
(DTypeSig false "entryLine" (TyFun (TyCon "DocEntry") (TyCon "Int")))
(DFunDef false "entryLine" ((PCon "DocEntry" PWild PWild PWild PWild (PVar "line"))) (EVar "line"))
(DTypeSig false "multiEntriesFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))) (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))))
(DFunDef false "multiEntriesFor" ((PVar "bare") (PVar "decl") (PVar "line") (PVar "schemes") (PVar "origins") (PVar "tbl")) (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl")))) (arm (PCon "None") () (EMatch (EApp (EVar "useGroupOf") (EVar "decl")) (arm (PCon "Some" (PVar "pm")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "reexportEntries") (EVar "line")) (EVar "schemes")) (EVar "tbl")) (EVar "origins")) (EVar "pm")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "derivingEntries") (EVar "bare")) (EVar "decl")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (EApp (EVar "derivesOf") (EVar "decl"))))))))
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
(DTypeSig false "hasPipeMarker" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasPipeMarker" ((PVar "line")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EBinOp "==" (EVar "line") (ELit (LString "|")))))
(DTypeSig false "stripPipePrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripPipePrefix" ((PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "| ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "line"))) (EVar "line")) (EIf (EBinOp "==" (EVar "line") (ELit (LString "|"))) (ELit (LString "")) (EVar "line"))))
(DTypeSig false "markerEligibleAfter" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "markerEligibleAfter" ((PVar "line")) (EBinOp "||" (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "isDecorativeLine") (EVar "line"))))
(DTypeSig false "isDecorativeLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDecorativeLine" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EApp (EVar "isDecorativeChar") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))))))
(DTypeSig false "isDecorativeChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDecorativeChar" ((PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z"))))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z")))))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))) (EBinOp "/=" (EVar "c") (ELit (LChar " ")))))
(DData Private "DocSegment" () ((variant "ProseSeg" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "ExampleSeg" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Private "SegMode" () ((variant "ModeProse" (ConPos)) (variant "ModeExample" (ConPos))) ())
(DTypeSig false "isExampleStart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExampleStart" ((PVar "line")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "line")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "line")) (ELit (LString "> ")))))
(DTypeSig false "allBlankLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allBlankLines" ((PList)) (EVar "True"))
(DFunDef false "allBlankLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "allBlankLines") (EVar "xs"))))
(DTypeSig false "pushSeg" (TyFun (TyCon "SegMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))
(DFunDef false "pushSeg" (PWild (PList) (PVar "segs")) (EVar "segs"))
(DFunDef false "pushSeg" ((PCon "ModeProse") (PVar "acc") (PVar "segs")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "reverseL") (EApp (EVar "dropWhileBlank") (EVar "acc")))) (DoExpr (EIf (EApp (EVar "allBlankLines") (EVar "ls")) (EVar "segs") (EBinOp "::" (EApp (EVar "ProseSeg") (EVar "ls")) (EVar "segs"))))))
(DFunDef false "pushSeg" ((PCon "ModeExample") (PVar "acc") (PVar "segs")) (EBinOp "::" (EApp (EVar "ExampleSeg") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "segs")))
(DTypeSig false "dropWhileBlank" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropWhileBlank" ((PCons (PLit (LString "")) (PVar "rest"))) (EApp (EVar "dropWhileBlank") (EVar "rest")))
(DFunDef false "dropWhileBlank" ((PVar "ls")) (EVar "ls"))
(DTypeSig false "docSegGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "SegMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DocSegment")) (TyApp (TyCon "List") (TyCon "DocSegment"))))))))
(DFunDef false "docSegGo" ((PList) (PVar "mode") PWild (PVar "acc") (PVar "segs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "pushSeg") (EVar "mode")) (EVar "acc")) (EVar "segs"))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeProse") (PVar "markerOk") (PVar "acc") (PVar "segs")) (EIf (EApp (EVar "isExampleStart") (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EVar "False")) (EListLit (EVar "line"))) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeProse")) (EVar "acc")) (EVar "segs"))) (EIf (EBinOp "&&" (EVar "markerOk") (EApp (EVar "hasPipeMarker") (EVar "line"))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EVar "False")) (EBinOp "::" (EApp (EVar "stripPipePrefix") (EVar "line")) (EVar "acc"))) (EVar "segs")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EBinOp "&&" (EVar "markerOk") (EApp (EVar "markerEligibleAfter") (EVar "line")))) (EBinOp "::" (EVar "line") (EVar "acc"))) (EVar "segs")))))
(DFunDef false "docSegGo" ((PCons (PVar "line") (PVar "rest")) (PCon "ModeExample") PWild (PVar "acc") (PVar "segs")) (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeProse")) (EVar "False")) (EListLit)) (EApp (EApp (EApp (EVar "pushSeg") (EVar "ModeExample")) (EVar "acc")) (EVar "segs"))) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "rest")) (EVar "ModeExample")) (EVar "False")) (EBinOp "::" (EApp (EVar "unescapeGtPrefix") (EVar "line")) (EVar "acc"))) (EVar "segs"))))
(DTypeSig false "docSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "DocSegment"))))
(DFunDef false "docSegments" ((PVar "lines")) (EApp (EApp (EApp (EApp (EApp (EVar "docSegGo") (EVar "lines")) (EVar "ModeProse")) (EVar "True")) (EListLit)) (EListLit)))
(DTypeSig false "renderDocSegment" (TyFun (TyCon "DocSegment") (TyCon "String")))
(DFunDef false "renderDocSegment" ((PCon "ProseSeg" (PVar "ls"))) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls")))
(DFunDef false "renderDocSegment" ((PCon "ExampleSeg" (PVar "ls"))) (EBinOp "++" (EBinOp "++" (ELit (LString "```medaka\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ls"))) (ELit (LString "\n```"))))
(DTypeSig false "renderDocProse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderDocProse" ((PVar "doc")) (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "segs") (EApp (EVar "docSegments") (EApp (EVar "splitNl") (EVar "doc")))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\n\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderDocSegment")) (EVar "segs")))))))
(DTypeSig false "moduleHeaderFrom" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyCon "String")))
(DFunDef false "moduleHeaderFrom" ((PList)) (ELit (LString "")))
(DFunDef false "moduleHeaderFrom" ((PCons (PTuple (PVar "startLine") (PVar "text") (PVar "b")) (PVar "rest"))) (EApp (EVar "markedDoc") (EApp (EApp (EVar "collectHeaderLines") (EBinOp "::" (ETuple (EVar "startLine") (EVar "text") (EVar "b")) (EVar "rest"))) (EVar "startLine"))))
(DTypeSig false "collectHeaderLines" (TyFun (TyApp (TyCon "List") (TyCon "CommentRow")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "CommentRow")))))
(DFunDef false "collectHeaderLines" ((PVar "tbl") (PVar "line")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "t") (PVar "b"))) () (EBinOp "::" (ETuple (EVar "line") (EVar "t") (EVar "b")) (EApp (EApp (EVar "collectHeaderLines") (EVar "tbl")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "header") (PVar "entries")) (EBlock (DoLet false false (PVar "titleBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n")))) (DoLet false false (PVar "headerProse") (EApp (EVar "renderDocProse") (EVar "header"))) (DoLet false false (PVar "headerBlock") (EIf (EBinOp "==" (EVar "headerProse") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "headerProse") (ELit (LString "\n\n"))))) (DoLet false false (PVar "sectioned") (EApp (EApp (EVar "anyDoc") (EVar "isSection")) (EVar "entries"))) (DoLet false false (PVar "main") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isListedImpl") (EVar "e"))))) (EVar "entries"))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "::" (EVar "titleBlock") (EBinOp "::" (EApp (EVar "primitiveLayerBanner") (EVar "moduleName")) (EBinOp "::" (EVar "headerBlock") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renderEntry") (EVar "sectioned")) (EVar "entries"))) (EVar "main")) (EListLit (EApp (EVar "renderInstancesSection") (EVar "entries")))))))))))
(DTypeSig false "primitiveLayerBanner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "primitiveLayerBanner" ((PVar "moduleName")) (EIf (EApp (EVar "preludeOnlyModule") (EVar "moduleName")) (ELit (LString "> These are the host primitives. They are in scope everywhere without an\n> import, and their `<type><Op>` names (`stringToUpper`, `intToString`)\n> mark them as the primitive layer. Prefer the library name where one\n> exists (`string.toUpper`, `string.toFloat`), and reach for a name on this\n> page only when no library module covers it.\n\n")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isSection" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isSection" ((PCon "DocEntry" PWild PWild PWild (PCon "KSection") PWild)) (EVar "True"))
(DFunDef false "isSection" (PWild) (EVar "False"))
(DTypeSig false "isImpl" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isImpl" ((PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" PWild) PWild)) (EVar "True"))
(DFunDef false "isImpl" (PWild) (EVar "False"))
(DTypeSig false "isListedImpl" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isListedImpl" ((PCon "DocEntry" (PVar "name") PWild PWild (PCon "KImplOn" PWild) PWild)) (EBinOp "/=" (EApp (EVar "instanceHead") (EVar "name")) (ELit (LString ""))))
(DFunDef false "isListedImpl" (PWild) (EVar "False"))
(DTypeSig false "anyDoc" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyDoc" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDoc" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyDoc") (EVar "p")) (EVar "xs"))))
(DTypeSig false "instanceIface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "instanceIface" ((PVar "name")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString " "))) (EVar "name")) (arm (PCon "None") () (EVar "name")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EVar "i")) (EVar "name")))))
(DTypeSig false "instanceHead" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "instanceHead" ((PVar "name")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString " "))) (EVar "name")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "dsub") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "dlen") (EVar "name"))) (EVar "name")))))
(DTypeSig false "instanceKey" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "instanceKey" ((PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EVar "hd"))
(DFunDef false "instanceKey" ((PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EApp (EVar "instanceHead") (EVar "name")))
(DTypeSig false "renderEntry" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "DocEntry") (TyCon "String")))))
(DFunDef false "renderEntry" (PWild PWild (PCon "DocEntry" (PVar "title") PWild PWild (PCon "KSection") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "## ")) (EVar "title")) (ELit (LString "\n\n"))))
(DFunDef false "renderEntry" ((PVar "sectioned") (PVar "entries") (PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc") (PVar "kind") PWild)) (EBlock (DoLet false false (PVar "level") (EIf (EVar "sectioned") (ELit (LString "### ")) (ELit (LString "## ")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "level"))) (ELit (LString "`"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "instances") (EMatch (EVar "kind") (arm (PCon "KTypeDecl") () (EApp (EVar "instanceLine") (EApp (EApp (EVar "instancesOf") (EVar "name")) (EVar "entries")))) (arm PWild () (ELit (LString ""))))) (DoLet false false (PVar "rendered") (EApp (EVar "renderDocProse") (EVar "doc"))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "rendered") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "rendered")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "docBlock"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "instances"))) (ELit (LString "\n"))))))
(DTypeSig false "instancesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "instancesOf" ((PVar "tyName") (PVar "entries")) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EApp (EVar "implHeadIs") (EVar "tyName")) (EVar "e")))) (EVar "entries")))
(DTypeSig false "implHeadIs" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "implHeadIs" ((PVar "tyName") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EBinOp "==" (EVar "hd") (EVar "tyName")))
(DFunDef false "implHeadIs" (PWild PWild) (EVar "False"))
(DTypeSig false "instanceLine" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "instanceLine" ((PList)) (ELit (LString "")))
(DFunDef false "instanceLine" ((PVar "impls")) (EBinOp "++" (EBinOp "++" (ELit (LString "\nInstances: ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "instanceRef")) (EVar "impls")))) (ELit (LString "\n"))))
(DTypeSig false "instanceRef" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "instanceRef" ((PCon "DocEntry" (PVar "name") PWild (PVar "doc") PWild PWild)) (EBlock (DoLet false false (PVar "iface") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "instanceIface") (EVar "name"))) (ELit (LString "`")))) (DoExpr (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "](#"))) (EApp (EMethodRef "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")")))))))
(DTypeSig false "renderInstancesSection" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "renderInstancesSection" ((PVar "entries")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "filterDoc") (EVar "isListedImpl")) (EVar "entries"))) (DoLet false false (PVar "orphans") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "hasTypeEntry") (EVar "entries")) (EVar "e"))))) (EVar "listed"))) (DoLet false false (PVar "keys") (EApp (EVar "uniqueDoc") (EApp (EApp (EMethodRef "map") (EVar "instanceKey")) (EVar "orphans")))) (DoLet false false (PVar "bullets") (EMatch (EVar "keys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "orphanLine") (EVar "orphans"))) (EVar "keys"))))) (ELit (LString "\n\n")))))) (DoLet false false (PVar "documented") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renderEntry") (EVar "True")) (EVar "entries"))) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "/=" (EApp (EVar "entryDoc") (EVar "e")) (ELit (LString ""))))) (EVar "listed"))))) (DoExpr (EMatch (EVar "listed") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## Instances\n\n")) (EApp (EMethodRef "display") (EVar "bullets"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "documented"))) (ELit (LString ""))))))))
(DTypeSig false "orphanLine" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "orphanLine" ((PVar "orphans") (PVar "key")) (EBlock (DoLet false false (PVar "mine") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "instanceKey") (EVar "e")) (EVar "key")))) (EVar "orphans"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- `")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "instanceRef")) (EVar "mine"))))) (ELit (LString ""))))))
(DTypeSig false "hasTypeEntry" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "hasTypeEntry" ((PVar "entries") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EApp (EApp (EVar "anyDoc") (ELam ((PVar "e")) (EApp (EApp (EVar "isTypeNamed") (EVar "hd")) (EVar "e")))) (EVar "entries")))
(DFunDef false "hasTypeEntry" (PWild PWild) (EVar "False"))
(DTypeSig false "isTypeNamed" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Bool"))))
(DFunDef false "isTypeNamed" ((PVar "n") (PCon "DocEntry" (PVar "name") PWild PWild (PCon "KTypeDecl") PWild)) (EBinOp "==" (EVar "name") (EVar "n")))
(DFunDef false "isTypeNamed" (PWild PWild) (EVar "False"))
(DTypeSig false "entryDoc" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "entryDoc" ((PCon "DocEntry" PWild PWild (PVar "doc") PWild PWild)) (EVar "doc"))
(DTypeSig false "uniqueDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "uniqueDoc" ((PList)) (EListLit))
(DFunDef false "uniqueDoc" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "uniqueDoc") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "x")))) (EVar "xs")))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EVar "filename")) (EVar "roots")) (arm (PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild) () (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))))
(DData Abstract "ModuleDoc" () ((variant "ModuleDoc" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "mdName" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "mdName" ((PCon "ModuleDoc" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "docOnlyExcluded" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "docOnlyExcluded" () (EListLit (ELit (LString "__fallthrough__")) (ELit (LString "setRef")) (ELit (LString "stashRunStdout")) (ELit (LString "enableRunStdoutFlush")) (ELit (LString "assertSnapshot")) (ELit (LString "indexError")) (ELit (LString "indexErrorAt")) (ELit (LString "sliceError")) (ELit (LString "debugStringLit")) (ELit (LString "debugCharLit")) (ELit (LString "buildFingerprint"))))
(DTypeSig false "dropInternalExterns" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "dropInternalExterns" ((PCon "False") (PVar "entries")) (EVar "entries"))
(DFunDef false "dropInternalExterns" ((PCon "True") (PVar "entries")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isInternalExtern") (EVar "e"))))) (EVar "entries")))
(DTypeSig false "isInternalExtern" (TyFun (TyCon "DocEntry") (TyCon "Bool")))
(DFunDef false "isInternalExtern" ((PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EBinOp "||" (EApp (EApp (EDictApp "elem") (EVar "name")) (EVar "internalExterns")) (EApp (EApp (EDictApp "elem") (EVar "name")) (EVar "docOnlyExcluded"))))
(DTypeSig true "computeModuleDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "ModuleDoc"))))))))
(DFunDef false "computeModuleDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename") (PVar "roots")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "filename")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "origins") (EApp (EApp (EApp (EApp (EVar "originSchemeTable") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "roots")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "header") (EApp (EVar "moduleHeaderFrom") (EVar "tbl"))) (DoLet false false (PVar "primitiveLayer") (EApp (EVar "preludeOnlyModule") (EVar "moduleName"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "dropInternalExterns") (EVar "primitiveLayer")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "primitiveLayer")) (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "origins")) (EVar "comments")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "moduleName")) (EApp (EApp (EVar "dedupHeader") (EVar "header")) (EVar "entries"))) (EApp (EApp (EVar "insertSections") (EApp (EVar "sectionsFrom") (EVar "tbl"))) (EVar "entries"))) (EApp (EVar "declaredTypeNames") (EVar "rawDecls"))))))
(DTypeSig false "dedupHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "dedupHeader" ((PVar "header") (PVar "entries")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "header") (ELit (LString ""))) (EBinOp "==" (EVar "header") (EApp (EVar "firstEntryDoc") (EVar "entries")))) (ELit (LString "")) (EVar "header")))
(DTypeSig false "firstEntryDoc" (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String")))
(DFunDef false "firstEntryDoc" ((PList)) (ELit (LString "")))
(DFunDef false "firstEntryDoc" ((PCons (PCon "DocEntry" PWild PWild (PVar "doc") PWild PWild) PWild)) (EVar "doc"))
(DTypeSig true "renderModulePage" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderModulePage" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild)) (EApp (EApp (EApp (EVar "renderMarkdown") (EVar "name")) (EVar "header")) (EVar "entries")))
(DTypeSig true "excludedLibraryModule" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "excludedLibraryModule" ((PVar "moduleName")) (EBinOp "==" (EVar "moduleName") (ELit (LString "async"))))
(DTypeSig true "rebucketLibraryImpls" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyApp (TyCon "List") (TyCon "ModuleDoc"))))
(DFunDef false "rebucketLibraryImpls" ((PVar "mds")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "concatMapDoc") (EVar "typeOwnersOf")) (EVar "mds"))) (DoLet false false (PVar "mentions") (EApp (EApp (EMethodRef "map") (EVar "moduleMentionIndex")) (EVar "mds"))) (DoLet false false (PVar "moved") (EApp (EApp (EVar "concatMapDoc") (EApp (EApp (EVar "movedFrom") (EVar "owners")) (EVar "mentions"))) (EVar "mds"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rebucketOne") (EVar "owners")) (EVar "mentions")) (EVar "moved"))) (EVar "mds")))))
(DTypeSig false "typeOwnersOf" (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeOwnersOf" ((PCon "ModuleDoc" (PVar "n") PWild PWild (PVar "tyNames"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EVar "n")))) (EVar "tyNames")))
(DTypeSig false "moduleMentionIndex" (TyFun (TyCon "ModuleDoc") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleMentionIndex" ((PCon "ModuleDoc" (PVar "n") PWild (PVar "es") PWild)) (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "entrySigOf")) (EVar "es"))))
(DTypeSig false "entrySigOf" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "entrySigOf" ((PCon "DocEntry" PWild (PVar "sig") PWild PWild PWild)) (EVar "sig"))
(DTypeSig false "ownerOfType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "ownerOfType" ((PVar "owners") (PVar "mentions") (PVar "tyName")) (EMatch (EApp (EApp (EVar "lookupStrDoc") (EVar "tyName")) (EVar "owners")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Some") (EVar "m"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "lowered") (EApp (EVar "toLower") (EVar "tyName"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupSigsDoc") (EVar "lowered")) (EVar "mentions")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "sigs")) () (EIf (EApp (EApp (EVar "anyMentions") (EVar "tyName")) (EVar "sigs")) (EApp (EVar "Some") (EVar "lowered")) (EVar "None")))))))))
(DTypeSig false "lookupSigsDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupSigsDoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSigsDoc" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupSigsDoc") (EVar "k")) (EVar "rest"))))
(DTypeSig false "anyMentions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyMentions" (PWild (PList)) (EVar "False"))
(DFunDef false "anyMentions" ((PVar "tyName") (PCons (PVar "s") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "mentionsToken") (EVar "tyName")) (EVar "s")) (EApp (EApp (EVar "anyMentions") (EVar "tyName")) (EVar "rest"))))
(DTypeSig false "mentionsToken" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "mentionsToken" ((PVar "needle") (PVar "hay")) (EBlock (DoLet false false (PVar "ns") (EApp (EVar "stringToChars") (EVar "needle"))) (DoLet false false (PVar "hs") (EApp (EVar "stringToChars") (EVar "hay"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "mentionsTokenGo") (EVar "ns")) (EVar "hs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "ns"))) (EApp (EVar "arrayLength") (EVar "hs"))))))
(DTypeSig false "mentionsTokenGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "mentionsTokenGo" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "n") (PVar "h")) (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "n")) (EVar "h"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "charsMatchAt") (EVar "ns")) (EVar "hs")) (EVar "i")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentCharAt") (EVar "hs")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "h")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentCharAt") (EVar "hs")) (EBinOp "+" (EVar "i") (EVar "n"))) (EVar "h")))) (EVar "True") (EApp (EApp (EApp (EApp (EApp (EVar "mentionsTokenGo") (EVar "ns")) (EVar "hs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "h")))))
(DTypeSig false "charsMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "charsMatchAt" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "charsMatchAtGo") (EVar "ns")) (EVar "hs")) (EVar "i")) (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "charsMatchAtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "charsMatchAtGo" ((PVar "ns") (PVar "hs") (PVar "i") (PVar "j") (PVar "n")) (EIf (EBinOp ">=" (EVar "j") (EVar "n")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "hs")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "ns"))) (EApp (EApp (EApp (EApp (EApp (EVar "charsMatchAtGo") (EVar "ns")) (EVar "hs")) (EVar "i")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DTypeSig false "isIdentCharAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isIdentCharAt" ((PVar "hs") (PVar "i") (PVar "h")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EVar "h"))) (EVar "False") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "hs")))))
(DTypeSig false "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9"))))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "lookupStrDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupStrDoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupStrDoc" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupStrDoc") (EVar "k")) (EVar "rest"))))
(DTypeSig false "entryTarget" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "entryTarget" ((PVar "owners") (PVar "mentions") (PVar "here") (PCon "DocEntry" PWild PWild PWild (PCon "KImplOn" (PCon "Some" (PVar "hd"))) PWild)) (EMatch (EApp (EApp (EApp (EVar "ownerOfType") (EVar "owners")) (EVar "mentions")) (EVar "hd")) (arm (PCon "Some" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "here")) (EVar "None") (EApp (EVar "Some") (EVar "m")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "entryTarget" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "movedFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "ModuleDoc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "movedFrom" ((PVar "owners") (PVar "mentions") (PCon "ModuleDoc" (PVar "here") PWild (PVar "es") PWild)) (EApp (EApp (EVar "concatMapDoc") (EApp (EApp (EApp (EVar "movedEntry") (EVar "owners")) (EVar "mentions")) (EVar "here"))) (EVar "es")))
(DTypeSig false "movedEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))))))))
(DFunDef false "movedEntry" ((PVar "owners") (PVar "mentions") (PVar "here") (PVar "e")) (EMatch (EApp (EApp (EApp (EApp (EVar "entryTarget") (EVar "owners")) (EVar "mentions")) (EVar "here")) (EVar "e")) (arm (PCon "Some" (PVar "m")) () (EListLit (ETuple (EVar "m") (EVar "e")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "rebucketOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyCon "ModuleDoc") (TyCon "ModuleDoc"))))))
(DFunDef false "rebucketOne" ((PVar "owners") (PVar "mentions") (PVar "moved") (PCon "ModuleDoc" (PVar "here") (PVar "header") (PVar "es") (PVar "tyNames"))) (EBlock (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "isNoneDoc") (EApp (EApp (EApp (EApp (EVar "entryTarget") (EVar "owners")) (EVar "mentions")) (EVar "here")) (EVar "e"))))) (EVar "es"))) (DoLet false false (PVar "incoming") (EApp (EApp (EVar "concatMapDoc") (EApp (EVar "takeForModule") (EVar "here"))) (EVar "moved"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ModuleDoc") (EVar "here")) (EVar "header")) (EBinOp "++" (EVar "kept") (EVar "incoming"))) (EVar "tyNames")))))
(DTypeSig false "takeForModule" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "DocEntry")))))
(DFunDef false "takeForModule" ((PVar "here") (PTuple (PVar "m") (PVar "e"))) (EIf (EBinOp "==" (EVar "m") (EVar "here")) (EListLit (EVar "e")) (EListLit)))
(DTypeSig false "filterDoc" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterDoc" (PWild (PList)) (EListLit))
(DFunDef false "filterDoc" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterDoc") (EVar "p")) (EVar "xs"))) (EApp (EApp (EVar "filterDoc") (EVar "p")) (EVar "xs"))))
(DTypeSig false "isNoneDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isNoneDoc" ((PCon "None")) (EVar "True"))
(DFunDef false "isNoneDoc" (PWild) (EVar "False"))
(DTypeSig false "slugifyAnchor" (TyFun (TyCon "String") (TyCon "String")))
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
(DFunDef false "inventoryEntriesFor" ((PCon "ModuleDoc" (PVar "moduleName") PWild (PVar "entries") PWild)) (EApp (EApp (EMethodRef "map") (EApp (EVar "inventoryEntryJson") (EVar "moduleName"))) (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isSection") (EVar "e"))))) (EVar "entries"))))
(DTypeSig false "inventoryEntryJson" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "Json"))))
(DFunDef false "inventoryEntryJson" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") (PVar "sig") PWild PWild PWild)) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "module")) (EApp (EVar "JString") (EVar "moduleName"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "signature")) (EApp (EVar "JString") (EVar "sig"))))))
(DTypeSig true "renderIndex" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyCon "String")))
(DFunDef false "renderIndex" ((PVar "mds")) (EApp (EVar "stringConcat") (EBinOp "::" (ELit (LString "# Library Index\n\n")) (EApp (EApp (EMethodRef "map") (EVar "renderIndexModule")) (EVar "mds")))))
(DTypeSig false "renderIndexModule" (TyFun (TyCon "ModuleDoc") (TyCon "String")))
(DFunDef false "renderIndexModule" ((PCon "ModuleDoc" (PVar "name") (PVar "header") (PVar "entries") PWild)) (EBlock (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "## [`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ".md)\n\n")))) (DoLet false false (PVar "summary") (EApp (EVar "firstSentence") (EApp (EVar "renderDocProse") (EVar "header")))) (DoLet false false (PVar "summaryBlock") (EIf (EBinOp "==" (EVar "summary") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EVar "summary") (ELit (LString "\n\n"))))) (DoLet false false (PVar "listed") (EApp (EApp (EVar "filterDoc") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isImpl") (EVar "e"))) (EApp (EVar "not") (EApp (EVar "isSection") (EVar "e")))))) (EVar "entries"))) (DoLet false false (PVar "links") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderIndexLink") (EVar "name"))) (EVar "listed")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "summaryBlock"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "links"))) (ELit (LString "\n\n"))))))
(DTypeSig false "renderIndexLink" (TyFun (TyCon "String") (TyFun (TyCon "DocEntry") (TyCon "String"))))
(DFunDef false "renderIndexLink" ((PVar "moduleName") (PCon "DocEntry" (PVar "name") PWild PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "- [`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`]("))) (EApp (EMethodRef "display") (EVar "moduleName"))) (ELit (LString ".md#"))) (EApp (EMethodRef "display") (EApp (EVar "slugifyAnchor") (EVar "name")))) (ELit (LString ")"))))
(DTypeSig false "firstSentence" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstSentence" ((PVar "prose")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "prose"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "cut") (EApp (EApp (EApp (EVar "sentenceEnd") (EVar "cs")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "splitNl") (EApp (EVar "stringTrim") (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (EVar "cut")) (EVar "prose"))))))))
(DTypeSig false "sentenceEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "sentenceEnd" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "firstLineEnd") (EVar "cs")) (ELit (LInt 0))) (EVar "n")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "."))) (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EApp (EVar "isSentenceGap") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "sentenceEnd") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))))
(DTypeSig false "isSentenceGap" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSentenceGap" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig false "firstLineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstLineEnd" ((PVar "cs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EVar "i") (EApp (EApp (EApp (EVar "firstLineEnd") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filename") (PVar "roots") (PVar "rawUser")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (ELam (PWild) (EVar "None"))) (EVar "filename")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka doc: '")) (EApp (EMethodRef "display") (EVar "filename"))) (ELit (LString "' has an unresolved import graph (missing or cyclic import) — signatures unavailable"))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "schemes")) () (EVar "schemes"))))
