# META
source_lines=2963
stages=DESUGAR,MARK
# SOURCE
-- lint-disable-file rule-duplicate-body
-- (A handful of small pure cursor/env helpers here — identifierAt/offsetOfLineCol/
--  prefixBefore/lookupSchemeL/jHover/… — are intentionally mirrored in
--  compiler/entries/playground_main.mdk, which cannot import this module: doing so
--  drags tools.fmt + io into that entry's graph and trips a pre-existing
--  multi-module flat-union conflation.  The duplication is deliberate; see the
--  note atop playground_main.mdk.)
-- compiler/lsp.mdk — self-hosted Language Server (Stage 4 Phase B.10)
--
-- Slices B.10.0 + B.10.1:
--   B.10.0 — JSON-RPC-over-stdio skeleton: Content-Length framing, the
--            `initialize` handshake, `initialized`/`shutdown`/`exit`.
--   B.10.1 — textDocument/didOpen + didChange → publishDiagnostics
--            (decl-level fidelity; the compiler AST is location-stripped so
--            resolve/typecheck diagnostics span the whole document, parse
--            errors use parseResult's located line/col).
--
-- Mirrors lib/lsp_server.ml's framing (`Content-Length: N\r\n\r\n` then exactly
-- N body bytes) and handle_initialize's capability set, but only advertises
-- what B.10 implements: textDocumentSync = Full (1).  Hover/completion/
-- definition/symbols/highlight/inlay and the ELoc expr-level ranges are LATER
-- slices and are deliberately NOT advertised here.
--
-- The runtime/core prelude sources are threaded in from the driver
-- (lsp_main.mdk reads them once at startup) so `analyze` can run the full
-- resolve+typecheck pipeline per document.

import json.{
  Json,
  JNull,
  JBool,
  JInt,
  JString,
  JArray,
  JObject,
  jObject,
  jArray,
  stringify,
  parse,
  lookup,
  asString,
  asInt,
}
import driver.diagnostics.{
  Diag,
  Severity,
  SevError,
  SevWarning,
  analyzeLocated,
  analyzeProject,
  projectEntrySchemes,
}
import driver.loader.{findProjectRoot}
import frontend.parser.{
  ParseError,
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
  parseWithPositions,
  parseWithPositionsOpt,
  positionsDecls,
  DeclPos,
  declPosLine,
  declPosEndLine,
  declPosNameLoc,
  declPosChildLocs,
}
import frontend.lexer.{Token(..), tokenizeWithOffsetPairs}
import support.char.{isIdentChar, isDigit, isLower, isUpper, isIdentStart}
import support.util.{maxI, utf8Len, joinWith, splitOnChar, startsWith, endsWith}
import support.path.{joinPath}
import io.{stripCR}
import frontend.desugar.{desugar, mapProg}
import types.typecheck.{
  checkProgramSchemes,
  checkProgramSchemesWithRuntime,
  ppSchemeNamed,
  Scheme(..),
  currentLocalSchemes,
  currentSeedSchemes,
}
import tools.fmt.{formatSource}
import tools.refindex.{
  RefIndex,
  buildRefIndexProject,
  binderAt,
  usesOf,
  defsOf,
  allDefKeys,
}
import list.{sortBy}
import frontend.ast.{
  Decl,
  DTypeSig,
  DExtern,
  DFunDef,
  DData,
  DUse,
  DEffect,
  DProp,
  DTest,
  DBench,
  DInterface,
  DImpl,
  DTypeAlias,
  DNewtype,
  DLetGroup,
  DAttrib,
  Ty,
  TyEffect,
  Loc(..),
  Variant,
  ConPayload(..),
  Field,
  IfaceMethod,
  ImplMethod,
  LetBind,
  UsePath,
  UseName,
  UseGroup,
  UseWild,
  UseAlias,
  -- F3(b) import-scope capture (arm 3): the name a selective-import member
  -- binds LOCALLY is its alias when it has one, so `import m.{f as g}` must be
  -- read as binding `g`, not `f`.
  useMemberLocal,
  -- #963 pun expansion (`punFieldsOfDecls` below) — the pattern side needs the
  -- pattern constructors, the expression side the pattern-HOSTING expression
  -- constructors.
  Pat(..),
  RecPatField(..),
  Arm(..),
  Guard(..),
  GuardArm,
  DoStmt(..),
  FunClause(..),
  MethodDefault(..),
  Expr,
  ELoc,
  EDoOrigin,
  EVar,
  ELam,
  ELet,
  ELetGroup,
  EMatch,
  EBlock,
  EDo,
  EGuards,
  ESetLit,
}

-- ── open-document store ─────────────────────────────────────────────────────
-- uri → source text.  A plain association list; LSP sessions open a handful of
-- files, so linear scan is fine.

public export data Docs = Docs (List (String, String))

-- Exported alongside `Docs`/`uriOfPath` so `medaka_references` (mcp.mdk) can
-- build a single-buffer table and reuse `referencesResult` verbatim — the
-- SAME code path the LSP handler runs, per #254's "one code path" design.
export emptyDocs : Docs
emptyDocs = Docs []

export docsPut : String -> String -> Docs -> Docs
docsPut uri src (Docs xs) = Docs ((uri, src) :: docsRemove uri xs)

docsRemove : String -> List (String, String) -> List (String, String)
docsRemove _ [] = []
docsRemove uri ((k, v)::rest)
  | k == uri = docsRemove uri rest
  | otherwise = (k, v) :: docsRemove uri rest

-- ── JSON helpers ────────────────────────────────────────────────────────────

-- 0-based LSP Position: { line, character }.
jPosition : Int -> Int -> Json
jPosition line ch = jObject [("line", JInt line), ("character", JInt ch)]

-- LSP Range: { start, end }.
jRange : Int -> Int -> Int -> Int -> Json
jRange sl sc el ec =
  jObject [("start", jPosition sl sc), ("end", jPosition el ec)]

-- A single LSP Diagnostic object.  severity: 1=Error, 2=Warning (LSP spec).
jDiagnostic : Int -> Json -> String -> Json
jDiagnostic sev range msg = jObject
  [
    ("range", range),
    ("severity", JInt sev),
    ("source", JString "medaka"),
    ("message", JString msg),
  ]

severityCode : Severity -> Int
severityCode SevError = 1
severityCode SevWarning = 2

-- ── diagnostics → LSP (expr-level) ──────────────────────────────────────────
--
-- B.10.2b: type-error Diags now carry the ELoc span captured at the push site
-- (`Some Loc`), so they map to an expr-level LSP range — mirror of the OCaml
-- LSP's `range_of_loc` (lib/lsp_server.ml:100): a 1-based `Loc` line maps to a
-- 0-based LSP line (line-1), the col is already 0-based.  Resolve / guard /
-- match diagnostics carry `None` (the compiler pipeline doesn't locate them) and
-- fall back to the whole-document range.  Parse errors keep using parseResult's
-- located line/col (below).

-- Count the lines in a source string (number of '\n' separators).  Used to
-- build the whole-document range end position.
countLines : String -> Int
countLines src = countLinesGo (stringToChars src) 0 0

countLinesGo : Array Char -> Int -> Int -> Int
countLinesGo arr i acc
  | i >= arrayLength arr = acc
  | arrayGetUnsafe i arr == '\n' = countLinesGo arr (i + 1) (acc + 1)
  | otherwise = countLinesGo arr (i + 1) acc

-- The range covering the whole document: (0,0) .. (lineCount, 0).
wholeDocRange : String -> Json
wholeDocRange src = jRange 0 0 (countLines src) 0

-- Map an `Option Loc` to an LSP range.  `Some` → the expr-level span (mirror of
-- OCaml `range_of_loc`: line-1 for both start/end line, cols verbatim); `None` →
-- the whole-document fallback.
rangeOfLoc : String -> Option Loc -> Json
rangeOfLoc src (Some (Loc _ sl sc el ec)) = jRange (sl - 1) sc (el - 1) ec
rangeOfLoc src None = wholeDocRange src

-- A bare (non-Option) `Loc` to an LSP range — same line/col convention as
-- `rangeOfLoc`'s `Some` arm, factored out for the #331 decl-NAME-span callers
-- (`renderSymbol`/`defZip`), which have their own decl-range fallback (NOT
-- `wholeDocRange`) when there is no name `Loc`.
jRangeOfLoc : Loc -> Json
jRangeOfLoc (Loc _ sl sc el ec) = jRange (sl - 1) sc (el - 1) ec

-- Map one analyze Diag onto an LSP diagnostic JSON, using its captured span
-- (B.10.2b) for an expr-level range, falling back to whole-document for
-- loc-less diagnostics.
diagToJson : String -> Diag -> Json
diagToJson src (Diag sev _ msg loc _ _) =
  jDiagnostic (severityCode sev) (rangeOfLoc src loc) msg

-- Produce the LSP diagnostics array for a source.  A parse failure short-
-- circuits to a single located diagnostic (parseResult); otherwise run the
-- full resolve+typecheck `analyzeLocated` pipeline (real ELoc spans, so type
-- errors carry expr-level ranges).
diagnosticsFor : String -> String -> String -> List Json
diagnosticsFor runtimeSrc coreSrc src = match parseResult src
  Err e =>
    let ln = maxI 0 (parseErrorLine e - 1)
    let col = maxI 0 (parseErrorCol e)
    let r = jRange ln col ln (col + 1)
    [jDiagnostic 1 r (parseErrorMessage e)]
  Ok _ => map (diagToJson src) (analyzeLocated runtimeSrc coreSrc src)
-- parseResult line is 1-based, col 0-based (matches the OCaml loader); LSP
-- wants 0-based lines, so subtract 1 from the line.

-- ── document store accessor (request handlers) ──────────────────────────────
-- Look up an open document's source by uri.  Request handlers (formatting/
-- documentSymbol/definition/highlight) read the buffer the client last sent.
docsGet : String -> Docs -> Option String
docsGet uri (Docs xs) = docsLookup uri xs

docsLookup : String -> List (String, String) -> Option String
docsLookup _ [] = None
docsLookup uri ((k, v)::rest)
  | k == uri = Some v
  | otherwise = docsLookup uri rest

-- ── textDocument/formatting ─────────────────────────────────────────────────
-- Mirror lib/lsp_server.ml handle_formatting: run the formatter; if the text is
-- unchanged return [] (no edits); otherwise return ONE TextEdit replacing the
-- whole document with the formatted source.  The replaced range is
-- (0,0)..(lineCount+1, 0) — mirrors OCaml full_document_range, which uses
-- `nl = newline_count + 1` for the end line so every line (incl. the last) is
-- covered without knowing its width.  A formatter/parse failure yields [] here
-- rather than crashing (the compiler formatSource is total on parseable input;
-- a parse error short-circuits to []).
fullDocRangeFmt : String -> Json
fullDocRangeFmt src = jRange 0 0 (countLines src + 1) 0

formattingEdits : String -> List Json
formattingEdits src = match parseResult src
  Err _ => []
  Ok _ =>
    let formatted = formatSource src
    if formatted == src then
      []
    else
      [jObject [("range", fullDocRangeFmt src), ("newText", JString formatted)]]
-- unparseable → no edits (client keeps buffer)

-- ── identifier-at-cursor + occurrence scan (pure string ops) ────────────────
-- Mirrors lib/lsp_server.ml is_ident_char / identifier_at / find_all_occurrences.

-- Byte offset of 0-based (line, col): walk to the line start, add col.  Returns
-- None if the line doesn't exist or the offset is past EOF.
offsetOfLineCol : Array Char -> Int -> Int -> Option Int
offsetOfLineCol arr line col = offsetGo arr (arrayLength arr) 0 0 0 line col

offsetGo : Array Char -> Int -> Int -> Int -> Int -> Int -> Int -> Option Int
offsetGo arr len i curLine lineStart line col
  | curLine == line =
    let pos = lineStart + col
    let lineEnd = lineEndFrom arr len lineStart
    if pos >= 0 && pos < len && pos < lineEnd then Some pos else None
  | i >= len = None
  | arrayGetUnsafe i arr == '\n' =
    offsetGo arr len (i + 1) (curLine + 1) (i + 1) line col
  | otherwise = offsetGo arr len (i + 1) curLine lineStart line col
-- ran out before reaching `line`

-- The exclusive end offset of the line starting at `i`: the index of its
-- terminating '\n', or `len` if it is the file's last (unterminated) line.
-- Used to clamp `col` to THIS line's own length rather than the whole file's
-- (#286 — an out-of-range col was walking arithmetic-coincidentally into a
-- later line and returning a confident wrong symbol instead of no-symbol).
lineEndFrom : Array Char -> Int -> Int -> Int
lineEndFrom arr len i
  | i >= len = len
  | arrayGetUnsafe i arr == '\n' = i
  | otherwise = lineEndFrom arr len (i + 1)

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
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineCol arr line col
    None => None
    Some pos => if not (isIdentChar (arrayGetUnsafe pos arr)) then None
    else
      let s = identStart arr pos
      let e = identStop arr len pos
      Some (stringSlice s e src)

-- 0-based (line, character) of a byte offset.  Used to turn occurrence offsets
-- back into LSP Positions (mirror offset_to_position).
posOfOffset : Array Char -> Int -> (Int, Int)
posOfOffset arr off = posOffGo arr off 0 0 0

posOffGo : Array Char -> Int -> Int -> Int -> Int -> (Int, Int)
posOffGo arr off i line lineStart
  | i >= off = (line, off - lineStart)
  | arrayGetUnsafe i arr == '\n' = posOffGo arr off (i + 1) (line + 1) (i + 1)
  | otherwise = posOffGo arr off (i + 1) line lineStart

-- A whole-source word-boundary occurrence scan: every offset where `name`
-- appears as a standalone identifier.  Returns the offsets in source order.
occurrences : String -> String -> List Int
occurrences src name =
  let arr = stringToChars src
  let len = arrayLength arr
  let nlen = stringLength name
  if nlen == 0 then [] else occGo src arr len name nlen 0

occGo : String -> Array Char -> Int -> String -> Int -> Int -> List Int
occGo src arr len name nlen i
  | i + nlen > len = []
  | windowEq src i name nlen && (i == 0 || not (isIdentChar (arrayGetUnsafe (i - 1) arr))) && (i + nlen == len || not (isIdentChar (arrayGetUnsafe (i + nlen) arr))) = i :: occGo src arr len name nlen (i + nlen)
  | otherwise = occGo src arr len name nlen (i + 1)

windowEq : String -> Int -> String -> Int -> Bool
windowEq src i name nlen = stringSlice i (i + nlen) src == name

-- documentHighlight ranges (one per occurrence) of `name` in `src`.
highlightRanges : String -> String -> List Json
highlightRanges src name =
  let arr = stringToChars src
  let nlen = stringLength name
  map (occToHighlight arr nlen) (occurrences src name)

occToHighlight : Array Char -> Int -> Int -> Json
occToHighlight arr nlen off = match posOfOffset arr off
  (sl, sc) => match posOfOffset arr (off + nlen)
    (el, ec) => jObject [("range", jRange sl sc el ec)]

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

-- Strip a DAttrib wrapper to the inner decl (mirror inner_decl).
innerDecl : Decl -> Decl
innerDecl (DAttrib _ d) = innerDecl d
innerDecl d = d

-- `range` = the decl's whole line span; `selRange` = the LSP `selectionRange`
-- (#331: the decl's real NAME-token span when known, else the same as
-- `range` — see `renderSymbol`). Kept as separate params (rather than always
-- reusing `range`) so a real name span can differ from the enclosing range.
jSymbol : String -> Int -> Json -> Json -> List Json -> Json
jSymbol name kind range selRange children = jObject
  [
    ("name", JString name),
    ("kind", JInt kind),
    ("range", range),
    ("selectionRange", selRange),
    ("children", jArray children),
  ]

-- One outline child symbol carrying its OWN name-token range/selectionRange
-- (#331, increment 2): use the child's name `Loc` when the parser found one,
-- else fall back to the parent decl `range` (`fallback`).  Both `range` and
-- `selectionRange` are the name span (a leaf symbol has no distinct enclosing
-- range).
jChildLoc : String -> Int -> Json -> Option Loc -> Json
jChildLoc name kind fallback loc =
  let r = match loc
    Some l => jRangeOfLoc l
    None => fallback
  jSymbol name kind r r []

fieldName : Field -> String
fieldName (Field n _) = n

-- Outline children for the variant list of a data decl, consuming child-name
-- `Loc`s (#331, increment 2) from `locs` in outline order.  Mirrors the old
-- `flatMap variantSymChildren`: a nameOmitted record variant (`data X = { … }`)
-- exposes one Field symbol (kind 8) per field; any other variant shows its
-- single constructor name (kind 22).  ⚠️ The parser's `declChildSpansOf`
-- produces `locs` in exactly this order — keep the two in lockstep.
variantKids : Json -> List (Option Loc) -> List Variant -> List Json
variantKids _ _ [] = []
variantKids fb locs ((Variant _ (ConNamed fs True))::vs) =
  let step = fieldKidsStep fb locs (map fieldName fs)
  fst step ++ variantKids fb (snd step) vs
variantKids fb [] ((Variant vn _)::vs) =
  jChildLoc vn 22 fb None :: variantKids fb [] vs
variantKids fb (l::ls) ((Variant vn _)::vs) =
  jChildLoc vn 22 fb l :: variantKids fb ls vs

-- One Field child (kind 8) per field name, consuming a `Loc` each; returns the
-- kids plus the leftover `Loc`s for the next variant.
fieldKidsStep : Json -> List (Option Loc) -> List String -> (List Json, List (Option Loc))
fieldKidsStep _ locs [] = ([], locs)
fieldKidsStep fb [] (fn::fns) =
  let rest = fieldKidsStep fb [] fns
  (jChildLoc fn 8 fb None :: fst rest, snd rest)
fieldKidsStep fb (l::ls) (fn::fns) =
  let rest = fieldKidsStep fb ls fns
  (jChildLoc fn 8 fb l :: fst rest, snd rest)

-- 1:1 child symbols for a fixed-shape child list (methods, let-binds),
-- consuming a `Loc` each in order.
zipKids : Json -> Int -> List (Option Loc) -> List String -> List Json
zipKids _ _ _ [] = []
zipKids fb kind [] (nm::nms) =
  jChildLoc nm kind fb None :: zipKids fb kind [] nms
zipKids fb kind (l::ls) (nm::nms) =
  jChildLoc nm kind fb l :: zipKids fb kind ls nms

ifaceMethodName : IfaceMethod -> String
ifaceMethodName (IfaceMethod n _ _) = n

implMethodName : ImplMethod -> String
implMethodName (ImplMethod n _ _) = n

letBindName : LetBind -> String
letBindName (LetBind n _) = n

-- The outline (name, kind, clauseLike, children) for a decl, given its
-- precomputed decl-level `range` (used for the child symbols' spans), or None for
-- decls that don't surface in the outline (DUse).  The decl's own range is
-- reattached by the caller (symbolParts), which also spans it across collapsed
-- clauses.  `clauseLike` is True ONLY for a signature or a value-binding clause
-- (DTypeSig/DFunDef/DLetGroup) — the decls that legitimately repeat under one name
-- (a sig + its clauses) and so may coalesce.  Everything else is False: crucially
-- DTest/DProp/DBench take a FREE string label (`test "double"`) that resolve.mdk
-- never enters into any namespace or duplicate check, so a test named after the
-- function it tests must NOT be swallowed into that function's outline entry.
-- `childLocs` (#331, increment 2) is the parser's ordered list of this decl's
-- child name-token `Loc`s (`declPosChildLocs`), consumed in the SAME order the
-- children are emitted below.  ⚠️ The order here IS the invariant the parser's
-- `declChildSpansOf` mirrors — change one, change both.
symbolPartsOfDecl : Decl -> Json -> List (Option Loc) -> Option (String, Int, Bool, List Json)
symbolPartsOfDecl d range childLocs = match innerDecl d
    DTypeSig _ name _ => Some (name, 13, True, [])
    DExtern _ name _ => Some (name, 12, False, [])
    DFunDef _ name _ _ => Some (name, 12, True, [])
    DLetGroup _ binds => match binds
      [] => None
      (LetBind n0 _)::_ =>
        let kids = zipKids range 12 childLocs (map letBindName binds)
        Some (n0, 12, True, kids)
    DData _ name _ variants _ =>
      -- records (the `data X = { … }` short form, nameOmitted) expose their
      -- fields as child symbols (kind 8); ordinary variants show their ctor name.
      let kids = variantKids range childLocs variants
      Some (name, 10, False, kids)
    DInterface { name = n, methods = ms, ... } =>
      let kids = zipKids range 6 childLocs (map ifaceMethodName ms)
      Some (n, 11, False, kids)
    DImpl { iface = ifc, methods = ms, ... } =>
      let label = implLabel ifc
      let kids = zipKids range 6 childLocs (map implMethodName ms)
      Some (label, 5, False, kids)
    DTypeAlias _ name _ _ => Some (name, 26, False, [])
    DNewtype _ name _ _ _ _ => Some (name, 23, False, [])
    DUse _ _ _ => None
    DProp _ name _ _ => Some (name, 12, False, [])
    DTest _ name _ => Some (name, 12, False, [])
    DBench _ name _ => Some (name, 12, False, [])
    DEffect _ name _ => Some (name, 24, False, [])
    DAttrib _ _ => None  -- unreachable post innerDecl
-- Variable
-- Function
-- Function

-- EnumMember
-- Enum

-- Field
-- Struct

-- Interface

-- Class
-- TypeParameter
-- Struct

-- Event

-- "impl Iface" / "Name of impl Iface" label (mirror handle_document_symbol's).
implLabel : String -> String
implLabel iface = stringConcat ["impl ", iface]

-- Parse → parts → collapse same-name clauses → render.  Exported for
-- `medaka_symbols` (#255) — parse-only, no typecheck, so it's a pure function of
-- `src` and safe for the stateless MCP disk-read harness (mirrors `typeAtPoint`'s
-- export shape).
export documentSymbols : String -> List Json
documentSymbols src = match parseWithPositionsOpt src
  None => []
  Some (decls, positions) => map renderSymbol (collapseSymbols (symbolParts decls (positionsDecls positions)))

-- One outline row before collapse: name, LSP SymbolKind, 0-based start/end line,
-- whether it's a signature/clause row (only those coalesce — see
-- symbolPartsOfDecl), its child symbols, and its NAME-token `Loc` (#331,
-- `None` when the decl has no single name token or the finder missed — see
-- `declNameTokIdxAt`).  A dedicated type rather than a tuple because it
-- carries 7 fields (past the tuple ceiling) and reads better.
data SymRow = SymRow String Int Int Int Bool (List Json) (Option Loc)

-- Zip decls with positions (1:1; defensive truncation to the shorter list) into
-- SymRow rows, dropping non-outline decls.
symbolParts : List Decl -> List DeclPos -> List SymRow
symbolParts (d::ds) (p::ps) =
  let sl = declPosLine p - 1
  let el = declPosEndLine p - 1
  match symbolPartsOfDecl d (jRange sl 0 el 0) (declPosChildLocs p)
    None => symbolParts ds ps
    Some (name, kind, clauseLike, kids) => SymRow name kind sl el clauseLike kids (declPosNameLoc p) :: symbolParts ds ps
symbolParts _ _ = []

-- Collapse a signature+clauses run — consecutive rows that share the EXACT same
-- name AND are BOTH clause-like — into ONE outline symbol (#300 part 3): the
-- shared name, the LAST row's kind (so a `sig`(Variable)+`def`(Function) pair
-- reads as the Function, not the sig), the range spanning first-start..last-end,
-- and the concatenated children.  The clause-like gate is what stops a
-- `test "double"`/`prop`/`bench` (free string label, never a duplicate) from being
-- fused into an adjacent same-named function; only sig/clause runs coalesce, and
-- only adjacent ones, so decls that merely share a prefix are never merged either.
-- The collapsed row keeps the FIRST clause's name `Loc` (`nl0`) — it pairs with
-- the kept start line `s0`, same as the OCaml/line-based fields already do.
collapseSymbols : List SymRow -> List SymRow
collapseSymbols [] = []
collapseSymbols (x::xs) = collapseGo x xs

collapseGo : SymRow -> List SymRow -> List SymRow
collapseGo cur [] = [cur]
collapseGo (SymRow n0 k0 s0 e0 cl0 c0 nl0) ((SymRow n1 k1 s1 e1 cl1 c1 nl1)::rest) = if n0 == n1 && cl0 && cl1 then collapseGo (SymRow n0 k1 s0 e1 True (c0 ++ c1) nl0) rest else SymRow n0 k0 s0 e0 cl0 c0 nl0 :: collapseGo (SymRow n1 k1 s1 e1 cl1 c1 nl1) rest

renderSymbol : SymRow -> Json
renderSymbol (SymRow name kind sl el _ kids nameLoc) =
  let range = jRange sl 0 el 0
  let selRange = match nameLoc
    Some l => jRangeOfLoc l
    None => range
  jSymbol name kind range selRange kids

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
  DTypeSig _ n _ => n == name
  DExtern _ n _ => n == name
  DFunDef _ n _ _ => n == name
  DLetGroup _ binds => anyName (map letBindName binds) name
  DData _ n _ _ _ => n == name
  DInterface { name = n, ... } => n == name
  DImpl { ... } => False
  DTypeAlias _ n _ _ => n == name
  DNewtype _ n _ c _ _ => n == name || c == name
  DUse _ _ _ => False
  DProp _ n _ _ => n == name
  DTest _ n _ => n == name
  DBench _ n _ => n == name
  DEffect _ n _ => n == name
  DAttrib _ _ => False

-- `d`'s CHILD names, in the SAME order `declPosChildLocs`/`symbolPartsOfDecl`
-- emit them. ⚠️ THE ORDERING INVARIANT: index `k` here must be index `k` in
-- `declPosChildLocs` — a mismatch attaches a `Loc` to the WRONG child, a
-- silent wrong answer (same invariant `declChildSpansOf`, parser.mdk, names).
-- `[]` for decl kinds with no children.
declChildNames : Decl -> List String
declChildNames d = match innerDecl d
  DData _ _ _ vs _ => dataChildNames vs
  DInterface { methods = ms, ... } => map ifaceMethodName ms
  DImpl { methods = ms, ... } => map implMethodName ms
  DLetGroup _ binds => map letBindName binds
  _ => []

-- Mirrors `variantKids`'s traversal exactly: a nameOmitted record variant
-- (`data X = { … }`) expands to one entry per field; any other variant
-- contributes its single ctor name.
dataChildNames : List Variant -> List String
dataChildNames [] = []
dataChildNames ((Variant _ (ConNamed fs True))::vs) = map fieldName fs
  ++ dataChildNames vs
dataChildNames ((Variant vn _)::vs) = vn :: dataChildNames vs

anyName : List String -> String -> Bool
anyName [] _ = False
anyName (x::xs) name = x == name || anyName xs name

-- 0-based index of the first occurrence of `name` in `xs`, or `None`.
indexOfName : String -> List String -> Option Int
indexOfName name xs = indexOfNameGo name xs 0

indexOfNameGo : String -> List String -> Int -> Option Int
indexOfNameGo _ [] _ = None
indexOfNameGo name (x::xs) i =
  if x == name then
    Some i
  else
    indexOfNameGo name xs (i + 1)

-- The `Option Loc` at 0-based index `i` of `ls`, or `None` if out of range.
locAtIndex : Int -> List (Option Loc) -> Option Loc
locAtIndex _ [] = None
locAtIndex 0 (l::_) = l
locAtIndex i (_::ls) = locAtIndex (i - 1) ls

-- The DeclPos of the first decl defining `name`, or None.
definitionRange : String -> String -> Option Json
definitionRange src name = match parseWithPositionsOpt src
  None => None
  Some (decls, positions) => defZip decls (positionsDecls positions) name

-- #331: the go-to-definition RANGE for `name` in the decl (`d`, `p`) that
-- defines it — own-name span first, else the matching child's span
-- (increment 5, Part B) — falling back to the old (line, 0)..(end_line, 0)
-- whole-decl range only when the parser's name-finder didn't resolve a span
-- for that particular name.
defZip : List Decl -> List DeclPos -> String -> Option Json
defZip (d::ds) (p::ps) name = match defZipDeclMatch d p name
  Some j => Some j
  None => defZip ds ps name
defZip _ _ _ = None

defZipDeclMatch : Decl -> DeclPos -> String -> Option Json
defZipDeclMatch d p name
  | declOwnNameMatches d name = Some (defZipLocOr (declPosNameLoc p) p)
  | otherwise = map (k => defZipLocOr (locAtIndex k (declPosChildLocs p)) p) (indexOfName name (declChildNames d))

defZipLocOr : Option Loc -> DeclPos -> Json
defZipLocOr (Some l) _ = jRangeOfLoc l
defZipLocOr None p = jRange (declPosLine p - 1) 0 (declPosEndLine p - 1) 0

-- ── typecheck-env build (hover / completion / inlayHint) ────────────────────
-- Mirror lib/lsp_server.ml's handlers, which run `Typecheck.check_program prog`
-- (which prepends the prelude) and look names up in the returned env.  Here the
-- self-host `checkProgram` does NOT auto-prepend, so we mirror repl.mdk's
-- pipeline (compiler/repl.mdk:221): desugar the prelude (coreSrc) + the desugared
-- user buffer, then `checkProgram (coreDecls ++ userDecls)` → the (name, Scheme)
-- env.  The runtime externs reach scope via core.mdk's own DExterns, exactly as
-- in repl (whose `checkProgram (preludeDecls ++ combined)` likewise omits a
-- separate runtime seed).  Returns None when the buffer doesn't parse (the
-- OCaml handlers bail the same way on a parse failure).
docSchemes : String -> String -> String -> Option (List (String, Scheme))
docSchemes runtimeSrc coreSrc src = match parseResult src
  Err _ => None
  Ok userRaw =>
    let runtimeDecls = desugar (unwrapDecls (parseResult runtimeSrc))
    let coreDecls = desugar (unwrapDecls (parseResult coreSrc))
    let userDecls = desugar userRaw
    Some (checkProgramSchemesWithRuntime runtimeDecls coreDecls userDecls)

-- core.mdk always parses; unwrap its parseResult (defensive None → []).
unwrapDecls : Result ParseError (List Decl) -> List Decl
unwrapDecls (Ok ds) = ds
unwrapDecls (Err _) = []

-- Lookup a name's Scheme in the env (mirror repl.mdk lookupScheme / OCaml
-- List.assoc_opt).
lookupSchemeL : String -> List (String, Scheme) -> Option Scheme
lookupSchemeL _ [] = None
lookupSchemeL name ((n, s)::rest)
  | name == n = Some s
  | otherwise = lookupSchemeL name rest

-- ── textDocument/hover ──────────────────────────────────────────────────────
-- Mirror handle_hover (lib/lsp_server.ml:482): identifier-at-cursor → checkProgram
-- env → lookup → a Hover whose contents is a Markdown MarkupContent rendering
--   ```medaka
--   <name> : <type>
--   ```
-- (exactly the OCaml format string).  Null when off an identifier or not in env.
-- Extension over the OCaml oracle: when the name isn't a top-level/global binding,
-- fall back to `localSchemesOut` (let-bound names, lambda/clause params, match
-- binders captured during the typecheck docSchemes just ran), so local variables
-- also show their inferred type on hover.
-- Produce the hover Json for the cursor position.  Resolve the identifier FIRST
-- (cheap), then build the env (potentially loading the project graph), so an
-- off-identifier hover never pays for a typecheck/load.
hoverFor : String -> String -> String -> String -> Json -> Docs -> <IO> Json
hoverFor runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => match hoverEnvFor runtimeSrc coreSrc uri src docs
      None => JNull
      Some env => match hoverScheme name env
        None => JNull
        Some sch =>
          let pfx = sigLeadingEff name (unwrapDecls (parseResult src))
          jHover name (stringConcat [pfx, ppSchemeNamed name sch])
  _ => JNull

-- Stateless type-at-point for the `medaka mcp` `medaka_type_at` tool (#251) — and
-- the shared query substrate #255 reuses.  It is `hoverFor` with two differences:
-- it takes the (0-based, LSP-style) line/col as plain Ints rather than fishing
-- them out of a synthetic params Json, and it returns the rendered `<name> :
-- <type>` as PLAIN TEXT (no markdown/JSON wrapper) so the MCP layer drops it
-- straight into a tool-result content block.  The ORDER is load-bearing and
-- mirrors hoverFor exactly: resolve the identifier first (cheap), THEN build the
-- env — `hoverEnvFor` both returns the entry schemes AND populates the typecheck
-- hover side-channel Refs (currentLocalSchemes/currentSeedSchemes) that
-- `hoverScheme` reads next; reading them before the env build would silently lose
-- locals' and imported names' types.  The buffer is seeded into `docs` under its
-- own uri so the import-bearing project load (projectEntryEnv) sees exactly this
-- text as the entry module; imported siblings resolve from disk through the
-- loader's read/disk fallback (readModuleProgF).  None ⇒ off any identifier or
-- not in scope — the caller maps that to a clean "no symbol" result, never a
-- crash.
export typeAtPoint : String -> String -> String -> String -> Int -> Int -> <IO> Option String
-- Not a single-monad passthrough bind: identifierAt/hoverScheme are pure Option
-- while hoverEnvFor is <IO> Option, and the nesting deliberately mirrors hoverFor's
-- load-bearing order — a `do` block cannot express the mixed pure/IO steps.
-- lint-disable-next-line rule-bind-chain-to-do
typeAtPoint runtimeSrc coreSrc filePath src line col = match identifierAt src line col
  None => None
  Some name =>
    let uri = uriOfPath filePath
    let docs = docsPut uri src emptyDocs
    match hoverEnvFor runtimeSrc coreSrc uri src docs
      None => None
      Some env => match hoverScheme name env
        None => None
        Some sch =>
          let pfx = sigLeadingEff name (unwrapDecls (parseResult src))
          Some (stringConcat [name, " : ", pfx, ppSchemeNamed name sch])

-- The hover lookup env for the buffer.  A buffer with a non-core sibling import
-- goes through the multi-module project pipeline (loads the import graph; the
-- entry's own schemes are returned and its locals + import-scoped seed land in the
-- hover side-channels), so imported names resolve.  A single-file buffer keeps the
-- fast `docSchemes` path (core + runtime + this buffer only).
hoverEnvFor : String -> String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
hoverEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src = projectEntryEnv runtimeSrc coreSrc uri docs
  | otherwise = docSchemes runtimeSrc coreSrc src

-- Load the import graph rooted at this buffer (same loader/cache/read disk-
-- fallback as publishProjectDiagnostics) and return the ENTRY module's own
-- schemes.  Side effect: the entry's locals + import-scoped seed (runtime + core
-- + imported names) are left in the typecheck hover side-channels.
projectEntryEnv : String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
projectEntryEnv runtimeSrc coreSrc uri docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRoot (dirOfPath rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  projectEntrySchemes
    projectCache
    projectParseCache
    read
    rootFile
    [projectDir, stdlibDir]
    runtimeSrc
    coreSrc

-- Resolve a hovered name's scheme: the returned typecheck env (globals +
-- top-level) first, then the hover-only side-channels — locals (let/param/match
-- binders) and the seed (runtime.mdk externs) — neither of which the env carries.
hoverScheme : String -> List (String, Scheme) -> Option Scheme
hoverScheme name env = match lookupSchemeL name env
  Some s => Some s
  None => match lookupSchemeL name (currentLocalSchemes ())
    Some s => Some s
    None => lookupSchemeL name (currentSeedSchemes ())

-- The leading effect annotation of NAME's top-level signature, rendered as a
-- `<IO> ` prefix (trailing space), or "" if none.  `from_ast_type` drops a
-- leading `TyEffect` when building the Mono (both compilers do — it's a latent
-- computation effect, not part of the value's type), so `main : <IO> Unit`
-- otherwise renders as bare `Unit`.  Recover it from the written sig for display.
sigLeadingEff : String -> List Decl -> String
sigLeadingEff _ [] = ""
sigLeadingEff name (d::ds) = match sigLeadingEffOne name d
  Some pfx => pfx
  None => sigLeadingEff name ds

sigLeadingEffOne : String -> Decl -> Option String
sigLeadingEffOne name (DAttrib _ d) = sigLeadingEffOne name d
sigLeadingEffOne name (DTypeSig _ n ty)
  | n == name = leadingEffOf ty
  | otherwise = None
sigLeadingEffOne _ _ = None

leadingEffOf : Ty -> Option String
leadingEffOf (TyEffect labels tail _) =
  Some (stringConcat [renderEffRow labels tail, " "])
leadingEffOf _ = None

-- Render a written effect row to surface syntax: `<IO>`, `<IO, State>`,
-- `<IO | e>`, `<e>` (mirrors parser.mdk effectBody: comma-separated labels, an
-- optional `| tail` var).
renderEffRow : List (String, Option String) -> Option String -> String
renderEffRow labels tail =
  let lbls = joinWith ", " (map renderEffAtom labels)
  let body = match tail
    None => lbls
    Some v => if lbls == "" then v else stringConcat [lbls, " | ", v]
  stringConcat ["<", body, ">"]

renderEffAtom : (String, Option String) -> String
renderEffAtom (nm, None) = nm
renderEffAtom (nm, Some "_") = stringConcat [nm, " _"]
renderEffAtom (nm, Some p) = stringConcat [nm, " \"", p, "\""]

-- Build the Hover { contents: MarkupContent{ kind:"markdown", value } } object.
jHover : String -> String -> Json
jHover name ty =
  let value = stringConcat ["```medaka\n", name, " : ", ty, "\n```"]
  jObject
    [
      (
        "contents",
        jObject [("kind", JString "markdown"), ("value", JString value)],
      )
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
-- Mirror handle_completion (lib/lsp_server.ml:693): the identifier prefix ending
-- just before the cursor → env names with that prefix → CompletionItem[]
-- { label, kind, detail }.  kind = Function (3) for every item (OCaml's
-- completion_kind_for_scheme defaults to Function); detail = ppScheme.  Names are
-- emitted in env order, deduplicated, prefix-filtered — mirroring
-- filter_completions.
prefixBefore : String -> Int -> Int -> String
prefixBefore src line col =
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineStart arr len line
    None => ""
    Some lineStart =>
      let stop = lineStart + col - 1
      if stop < lineStart then ""
      else
        if stop >= len then ""
        else
          if not (isIdentChar (arrayGetUnsafe stop arr)) then ""
          else
            let start = prefixStart arr lineStart stop
            stringSlice start (stop + 1) src

-- Byte offset of the start of 0-based `line`, or None if it doesn't exist.
offsetOfLineStart : Array Char -> Int -> Int -> Option Int
offsetOfLineStart arr len line = lineStartGo arr len 0 0 0 line

lineStartGo : Array Char -> Int -> Int -> Int -> Int -> Int -> Option Int
lineStartGo arr len i curLine lineStart line
  | curLine == line = Some lineStart
  | i >= len = None
  | arrayGetUnsafe i arr == '\n' =
    lineStartGo arr len (i + 1) (curLine + 1) (i + 1) line
  | otherwise = lineStartGo arr len (i + 1) curLine lineStart line

-- Walk left from `stop` over identifier chars, not past the line start.
prefixStart : Array Char -> Int -> Int -> Int
prefixStart arr lineStart i
  | i <= lineStart = lineStart
  | isIdentChar (arrayGetUnsafe (i - 1) arr) = prefixStart arr lineStart (i - 1)
  | otherwise = i

-- True when string n has prefix p (mirror plen==0 || prefix match).
startsWith : String -> String -> Bool
startsWith p n =
  let pl = stringLength p
  if pl == 0 then True else stringLength n >= pl && stringSlice 0 pl n == p

-- Filter env to names matching the prefix, deduplicating (first occurrence
-- wins).  Mirror filter_completions.
filterCompletions : String -> List String -> List (String, Scheme) -> List Json
filterCompletions _ _ [] = []
filterCompletions prefix seen ((n, s)::rest)
  | startsWith prefix n && not (anyName seen n) = jCompletionItem n (ppSchemeNamed n s) :: filterCompletions prefix (n::seen) rest
  | otherwise = filterCompletions prefix seen rest

-- One CompletionItem { label, kind, detail }.  kind 3 = Function (LSP spec).
jCompletionItem : String -> String -> Json
jCompletionItem label detail = jObject
  [("label", JString label), ("kind", JInt 3), ("detail", JString detail)]

completionFor : String -> String -> String -> String -> Json -> Docs -> <IO> Json
completionFor runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params)
  (Some line, Some col) => match completionEnvFor runtimeSrc coreSrc uri src docs
    None => JNull
    Some env =>
      let prefix = prefixBefore src line col
      jArray (filterCompletions prefix [] env)
  _ => JNull

-- Completion suggests names from the env directly (no side-channel fallback like
-- hover), so for a project buffer the env must be the FULL visible set: the
-- entry's own schemes + its locals + its import-scoped seed (core + runtime +
-- imported names).  A single-file buffer keeps `docSchemes` unchanged — adding
-- the seed/locals there would change the single-file completion golden.
completionEnvFor : String -> String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
completionEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src = map (own => own ++ currentLocalSchemes () ++ currentSeedSchemes ()) (projectEntryEnv runtimeSrc coreSrc uri docs)
  | otherwise = docSchemes runtimeSrc coreSrc src

handleCompletion : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleCompletion runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => completionFor runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

-- ── textDocument/inlayHint ──────────────────────────────────────────────────
-- Mirror handle_inlay_hint (lib/lsp_server.ml:759): for each top-level decl that
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
  DFunDef _ n _ _ => Some n
  DLetGroup _ binds => match binds
    (LetBind n _)::_ => Some n
    [] => None
  _ => None

-- Whether `prog` carries an explicit DTypeSig for `name` (mirror has_explicit_sig).
hasExplicitSig : List Decl -> String -> Bool
hasExplicitSig [] _ = False
hasExplicitSig (d::rest) name = match innerDecl d
  DTypeSig _ n _ => n == name || hasExplicitSig rest name
  _ => hasExplicitSig rest name

-- Column right after the name on the decl's start line (0-based `line`).  Scan
-- from char 0 over identifier chars; None if the line has no leading identifier.
-- Intentionally kept (not retired) as `inlayNamePos`'s `None` fallback — full F5 retirement stays deferred.
columnAfterName : String -> Int -> Option Int
columnAfterName src line =
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineStart arr len line
    None => None
    Some lineStart =>
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
-- unsignatured value bindings present in the env, place one hint each.
inlayHints : String -> String -> String -> List Json
inlayHints runtimeSrc coreSrc src = match docSchemes runtimeSrc coreSrc src
  None => []
  Some env => match parseWithPositionsOpt src
    None => []
    Some (decls, positions) =>
      inlayZip src decls decls (positionsDecls positions) env

-- The (0-based line, col) right after a decl's name: the real name `Loc`'s end
-- position (#331) when there is one, else the old `columnAfterName` heuristic
-- over the decl's start line.
inlayNamePos : String -> DeclPos -> Option (Int, Int)
inlayNamePos src p = match declPosNameLoc p
  Some (Loc _ sl _ _ ec) => Some (sl - 1, ec)
  None => map (col => (declPosLine p - 1, col)) (columnAfterName src (declPosLine p - 1))

-- decls passed twice: `allDecls` for the has-explicit-sig scan, `ds` walked.
inlayZip : String -> List Decl -> List Decl -> List DeclPos -> List (String, Scheme) -> List Json
inlayZip src allDecls (d::ds) (p::ps) env = match declBindingName d
  None => inlayZip src allDecls ds ps env
  Some name => if hasExplicitSig allDecls name then inlayZip src allDecls ds ps env
  else match lookupSchemeL name env
    None => inlayZip src allDecls ds ps env
    Some sch => match inlayNamePos src p
      None => inlayZip src allDecls ds ps env
      Some (line, col) => jInlayHint line col (stringConcat [": ", ppSchemeNamed name sch]) :: inlayZip src allDecls ds ps env
inlayZip _ _ _ _ _ = []

-- One InlayHint { position, label, paddingLeft } (mirror the OCaml create).
jInlayHint : Int -> Int -> String -> Json
jInlayHint line col label = jObject
  [
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
      Some src => jArray (inlayHints runtimeSrc coreSrc src)
  writeMessage (responseMsg idJson result)

-- ── request-position helpers ────────────────────────────────────────────────
-- Pull params.position.{line,character} (0-based) from a request message.
positionLine : Json -> Option Int
positionLine params = match lookup "position" params
  Some pos => match lookup "line" pos
    Some v => asInt v
    None => None
  None => None

positionChar : Json -> Option Int
positionChar params = match lookup "position" params
  Some pos => match lookup "character" pos
    Some v => asInt v
    None => None
  None => None

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
  let _ = appendFile (logFilePath ()) (stringConcat [floatToString ts, " ", s, "\n"])
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
-- moved to support/util.mdk (imported above).

-- A JSON-RPC response envelope: { jsonrpc, id, result }.
responseMsg : Json -> Json -> Json
responseMsg idJson result =
  jObject [("jsonrpc", JString "2.0"), ("id", idJson), ("result", result)]

-- A JSON-RPC error response: { jsonrpc, id, error: { code, message } }. Used by
-- `textDocument/rename` to surface an F3 refusal as an error (so the client
-- shows the reason and applies NO edit) rather than a malformed WorkspaceEdit.
-- code -32803 = LSP `RequestFailed`.
responseErr : Json -> String -> Json
responseErr idJson message = jObject
  [
    ("jsonrpc", JString "2.0"),
    ("id", idJson),
    ("error", jObject [("code", JInt (-32803)), ("message", JString message)]),
  ]

-- A JSON-RPC notification envelope: { jsonrpc, method, params }.
notificationMsg : String -> Json -> Json
notificationMsg meth params = jObject
  [("jsonrpc", JString "2.0"), ("method", JString meth), ("params", params)]

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
    if line == "" then Some lenAcc
    else
      let lenAcc2 = match parseContentLength line
        Some n => n
        None => lenAcc
      readHeaders lenAcc2
-- EOF mid-stream

-- blank line ends the header block

-- Parse "Content-Length: <n>" (case-sensitive, as clients emit it).  Returns
-- the integer N or None if this header line is something else.
parseContentLength : String -> Option Int
parseContentLength line =
  let prefix = "Content-Length:"
  let pn = stringLength prefix
  if stringLength line >= pn && stringSlice 0 pn line == prefix then
    parseDigits (stringToChars (stringSlice pn (stringLength line) line)) 0 (arrayLength (stringToChars (stringSlice pn (stringLength line) line))) 0 False
  else
    None

-- Parse a run of ASCII digits (skipping leading spaces) into an Int.  `seen`
-- tracks whether at least one digit was consumed.
parseDigits : Array Char -> Int -> Int -> Int -> Bool -> Option Int
parseDigits arr i n acc seen
  | i >= n = if seen then Some acc else None
  | arrayGetUnsafe i arr == ' ' && not seen = parseDigits arr (i + 1) n acc seen
  | isDigit (arrayGetUnsafe i arr) = parseDigits arr (i + 1) n (acc * 10 + (charCode (arrayGetUnsafe i arr) - 48)) True
  | otherwise = if seen then Some acc else None

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

   Positions: `tokenizeWithOffsetPairs` gives each token a (startByte, endByte)
   char-offset pair; synthetic layout tokens (NEWLINE/INDENT/DEDENT/EOF) carry an
   EMPTY span (start == end) and are filtered.  `posOfOffset` turns an offset into
   a 0-based (line, char) — codepoint-based, which equals UTF-16 for BMP chars
   (incl. em-dashes); only astral/emoji positions would differ (DEFERRED — see
   the multiline/astral note in `semTokenLen`).  The wire format is delta-encoded:
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
semanticTokensOptions = jObject
  [
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

-- Decides how an uppercase name (and record fields) is colored at this point.
data SMode =
  | MExpr
  | MType
  | MDataHead
  | MDataVariant
  | MDataPayload
  | MRecord
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
isKeywordTok TRecord = True
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
roleOf (TIdent _) depth lineStart mode =
  if lineStart && (depth == 0) then Some 3      -- top-level definition head
  else match mode
    MRecord => Some 4                            -- record field name
    _ => None                                    -- local / param / reference
roleOf (TBacktickIdent _) _ _ _ = Some 3
roleOf (TString _) _ _ _ = Some 5
roleOf (TChar _) _ _ _ = Some 5
roleOf (TInterpOpen _) _ _ _ = Some 5
roleOf (TInterpMid _) _ _ _ = Some 5
roleOf (TInterpEnd _) _ _ _ = Some 5
roleOf (TInt _ _) _ _ _ = Some 6
roleOf (TFloat _) _ _ _ = Some 6
roleOf (TBool _) _ _ _ = Some 0
roleOf t _ _ _ = if isKeywordTok t then Some 0 else None

-- The mode AFTER consuming a token.
nextMode : Token -> SMode -> SMode
nextMode TData _ = MDataHead
nextMode TNewtype _ = MDataHead
nextMode TRecord _ = MRecord
nextMode TInterface _ = MIfaceOne
nextMode TImpl _ = MIfaceOne
nextMode TRequires _ = MIfaceMany
nextMode TDeriving _ = MIfaceMany
nextMode TExtern _ = MType
nextMode TType _ = MType
nextMode TOf _ = MType
nextMode TWhere _ = MExpr
nextMode (TUpper _) MIfaceOne = MType
nextMode TColon MRecord = MRecord
nextMode TColon _ = MType
nextMode TEqual MDataHead = MDataVariant
nextMode TEqual MRecord = MRecord
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
semToksOf : Array Char -> List Token -> List (Int, Int) -> SemCtx -> List SemTok
semToksOf _ [] _ _ = []
semToksOf _ _ [] _ = []
semToksOf arr (t::ts) ((s, e)::ps) ctx = match classify t ctx
  (roleOpt, ctx2) => match roleOpt
    None => semToksOf arr ts ps ctx2
    Some ty => if s >= e then semToksOf arr ts ps ctx2
    else match (posOfOffset arr s, posOfOffset arr e)
      ((sl, sc), (el, ec)) =>
        if sl == el then
          SemTok sl sc (ec - sc) ty :: semToksOf arr ts ps ctx2
        else
          semToksOf arr ts ps ctx2

{- Delta-encode the (start-ordered) SemTok list into the flat 5-int LSP array.
   prevLine/prevChar start at 0, so the first token's deltaLine is its absolute
   line; deltaChar is relative to prevChar only when deltaLine == 0. -}
encodeSemToks : Int -> Int -> List SemTok -> List Int
encodeSemToks _ _ [] = []
encodeSemToks prevLine prevChar ((SemTok line ch len ty)::rest) =
  let dLine = line - prevLine
  let dChar = if dLine == 0 then ch - prevChar else ch
  dLine :: dChar :: len :: ty :: 0 :: encodeSemToks line ch rest

-- The full semantic-tokens `data` array (flat ints) for a source string.
semanticTokensData : String -> List Int
semanticTokensData src =
  let arr = stringToChars src
  match tokenizeWithOffsetPairs src
    (toks, pairs) =>
      encodeSemToks 0 0 (semToksOf arr toks pairs (SemCtx 0 True MExpr))

-- ── request dispatch ────────────────────────────────────────────────────────
--
-- The driver loops: read headers → read body → parse JSON → dispatch.  The
-- state threaded through the loop is the Docs store; the runtime/core prelude
-- sources are constants for the session.

-- The `initialize` result: serverInfo + the B.10 capability set.
-- textDocumentSync = 1 (Full).  B.10.3 adds the decl/textual providers:
-- formatting / documentSymbol / definition / documentHighlight (each a plain
-- `true`, mirroring lib/lsp_server.ml's `Bool true`).  The richer providers
-- (hover/completion/inlayHint) and ELoc expr-precise ranges are later slices.
initializeResult : Json
initializeResult = jObject
  [
    (
      "capabilities",
      jObject [
        ("textDocumentSync", JInt 1),
        ("documentFormattingProvider", JBool True),
        ("documentSymbolProvider", JBool True),
        ("definitionProvider", JBool True),
        ("documentHighlightProvider", JBool True),
        ("referencesProvider", JBool True),
        ("renameProvider", JBool True),
        ("hoverProvider", JBool True),
        ("completionProvider", jObject []),
        ("inlayHintProvider", JBool True),
        ("semanticTokensProvider", semanticTokensOptions),
      ],
    ),
    (
      "serverInfo",
      jObject [("name", JString "medaka-lsp"), ("version", JString "0.1.0")],
    ),
  ]

-- Build + send a publishDiagnostics notification for one uri.
publishDiagnostics : String -> String -> String -> String -> <IO> Unit
publishDiagnostics runtimeSrc coreSrc uri src =
  let diags = diagnosticsFor runtimeSrc coreSrc src
  let params = jObject [("uri", JString uri), ("diagnostics", jArray diags)]
  writeMessage (notificationMsg "textDocument/publishDiagnostics" params)

-- ── B.10.5: project-wide (multi-file) diagnostics ───────────────────────────
--
-- When the edited buffer imports a sibling module, run analyzeProject over the
-- whole import graph (with the OPEN BUFFERS as unsaved-source overrides) and
-- publish one publishDiagnostics PER affected file — the self-hosted analog of
-- lib/lsp_server.ml's publish_project_diagnostics.  A buffer with no (non-core)
-- imports keeps the single-document path (publishDiagnostics above).
--
-- Simplifications vs the OCaml LSP (consistent with the single-root compiler
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
projectParseCache : Ref (List (String, List Decl))
projectParseCache = Ref []

-- file:// URI ↔ filesystem path.  LSP clients send `file://<abs-path>`; the
-- loader works in plain paths.  pathOfUri strips the scheme; uriOfPath re-adds
-- it (so a loader file path maps back to the Docs key for the read override).
pathOfUri : String -> String
pathOfUri uri =
  if stringLength uri >= 7 && stringSlice 0 7 uri == "file://" then
    stringSlice 7 (stringLength uri) uri
  else
    uri

export uriOfPath : String -> String
uriOfPath path =
  if stringLength path >= 7 && stringSlice 0 7 path == "file://" then
    path
  else
    stringConcat ["file://", path]

-- directory of a path (everything before the last '/'; "." if none).
dirOfPath : String -> String
dirOfPath path = dirGo path (stringLength path)

dirGo : String -> Int -> String
dirGo path 0 = "."
-- Intentional cross-file duplicate of the same helper in path.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
dirGo path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    dirGo path (i - 1)

-- True when the buffer has a non-core `import` (→ project / multi-file path).
bufferHasImports : String -> Bool
bufferHasImports src = match parseResult src
  Err _ => False
  Ok decls => anyImport decls
-- unparseable → single-doc path squiggles it

anyImport : List Decl -> Bool
anyImport [] = False
anyImport ((DUse _ path _)::rest) = not (isCoreImport path) || anyImport rest
anyImport (_::rest) = anyImport rest

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
headOr _ (x::_) = x

-- Run analyzeProject over the graph rooted at the edited file and publish one
-- notification per file in the result (clean files → []).  `docs` already holds
-- the just-edited buffer; the read override maps a loader file path back to the
-- Docs buffer for that uri (unsaved buffers shadow disk).
--
-- Roots mirror the build/run loader (`medaka_cli` runRunCmd): the edited file's
-- directory first (user modules shadow stdlib), then MEDAKA_ROOT/stdlib so an
-- `import json` / other stdlib module resolves (without this, a buffer importing
-- a stdlib module reports a spurious `UnknownModule`).
publishProjectDiagnostics : String -> String -> String -> Docs -> <IO> Unit
publishProjectDiagnostics runtimeSrc coreSrc uri docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRoot (dirOfPath rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  let results = analyzeProject projectCache projectParseCache read rootFile [projectDir, stdlibDir] runtimeSrc coreSrc
  publishEach results
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
publishEach : List (String, List Diag) -> <IO> Unit
publishEach [] = ()
publishEach ((file, ds)::rest) =
  let uri = uriOfPath file
  let params = jObject [("uri", JString uri), ("diagnostics", jArray (map (diagToJson "") ds))]
  let _ = writeMessage (notificationMsg "textDocument/publishDiagnostics" params)
  publishEach rest

-- Choose the single-document or project path for a freshly-edited buffer.
publishFor : String -> String -> String -> String -> Docs -> <IO> Unit
publishFor runtimeSrc coreSrc uri text docs =
  if bufferHasImports text then
    publishProjectDiagnostics runtimeSrc coreSrc uri docs
  else
    publishDiagnostics runtimeSrc coreSrc uri text

-- Extract a textDocument/{didOpen,didChange} uri + text and publish.
-- didOpen:   params.textDocument.{uri,text}
-- didChange: params.textDocument.uri + params.contentChanges[last].text
--            (Full sync: the last change replaces the whole document).
handleDidOpen : String -> String -> Json -> Docs -> <IO> Docs
handleDidOpen runtimeSrc coreSrc params docs = match fieldStr "uri" (fieldOr "textDocument" params)
  None => docs
  Some uri => match fieldStr "text" (fieldOr "textDocument" params)
    None => docs
    Some text =>
      let docs2 = docsPut uri text docs
      let _ = publishFor runtimeSrc coreSrc uri text docs2
      docs2

handleDidChange : String -> String -> Json -> Docs -> <IO> Docs
handleDidChange runtimeSrc coreSrc params docs = match fieldStr "uri" (fieldOr "textDocument" params)
  None => docs
  Some uri => match lastChangeText (fieldOr "contentChanges" params)
    None => docs
    Some text =>
      let docs2 = docsPut uri text docs
      let _ = publishFor runtimeSrc coreSrc uri text docs2
      docs2

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
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (documentSymbols src)
  writeMessage (responseMsg idJson result)

-- textDocument/definition → Location[] (singleton) or null.
handleDefinition : Json -> Json -> Docs -> <IO> Unit
handleDefinition idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => definitionResult uri src params
  writeMessage (responseMsg idJson result)

-- Exported for `medaka_definition` (#255) — intra-file only: `definitionRange`
-- scans decls in the SAME `src` it's given and never resolves an import, so a
-- cross-file name simply falls through to `None` → `JNull`, never a wrong
-- same-file match.  `uri` is echoed VERBATIM into the response's `range`'s
-- sibling `uri` field — the MCP handler passes the caller's own `file` string
-- through unmodified (no `uriOfPath` wrapping) so a relative request path stays
-- relative in the result (path-stable for a golden).
export definitionResult : String -> String -> Json -> Json
definitionResult uri src params = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => match definitionRange src name
      None => JNull
      Some range => jArray [jObject [("uri", JString uri), ("range", range)]]
  _ => JNull

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
handleReferences : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleReferences runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => referencesResult runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

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
-- construction (compiler/REFERENCES-RENAME-DESIGN.md §5). `uri` is the
-- Docs-table key for the CLICKED buffer (so unsaved edits there win, exactly
-- like `projectEntryEnv`); every OTHER project file is read through the same
-- `docs`-then-disk override the loader already uses elsewhere, so an unsaved
-- sibling buffer's edits are seen too. Each result entry's own `uri` is a
-- `file://` URI built from the index's recorded (loader-)path via
-- `uriOfPath`, independent of the query's own `uri` shape. F1 (locked):
-- intra-project only — `buildRefIndexProject` enumerates under the project
-- root alone, never the separate stdlib root, so it never descends into
-- stdlib/prelude bodies.
export referencesResult : String -> String -> String -> String -> Json -> Docs -> <IO> Json
referencesResult runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => jArray []
    Some _ =>
      let rootFile = pathOfUri uri
      let projectDir = findProjectRoot (dirOfPath rootFile)
      let read = path => docsGet (uriOfPath path) docs
      let idx = buildRefIndexProject read projectDir runtimeSrc coreSrc
      -- `binderAt` wants a 1-based line (the `Loc` convention); LSP positions
      -- are 0-based, hence `line + 1`. `col` is 0-based in both conventions.
      match binderAt idx rootFile (line + 1) col
        None => jArray []
        Some key => jArray (referenceLocations idx key (includeDeclarationOf params))
  _ => jArray []

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
referenceLocations : RefIndex -> String -> Bool -> List Json
referenceLocations idx key includeDecl =
  let uses = usesOf idx key
  let all = if includeDecl then defsOf idx key ++ uses else uses
  map locationJson (sortBy compareUseLoc all)

-- (path, then start line, then start char) — see `referenceLocations`.
compareUseLoc : (String, Loc) -> (String, Loc) -> Ordering
compareUseLoc (p1, Loc _ sl1 sc1 _ _) (p2, Loc _ sl2 sc2 _ _) = match compare p1 p2
  Lt => Lt
  Gt => Gt
  Eq => match compare sl1 sl2
    Lt => Lt
    Gt => Gt
    Eq => compare sc1 sc2

locationJson : (String, Loc) -> Json
locationJson (path, loc) =
  jObject [("uri", JString (uriOfPath path)), ("range", jRangeOfLoc loc)]

-- `params.context.includeDeclaration` (LSP `ReferenceContext`). Missing
-- `context`/field, or a non-bool value, defaults to `True` (F6, locked).
includeDeclarationOf : Json -> Bool
includeDeclarationOf params = match lookup "context" params
  None => True
  Some ctx => match lookup "includeDeclaration" ctx
    Some (JBool b) => b
    _ => True

-- ── rename (#254 Stage 2) ────────────────────────────────────────────────────
-- The SHARED rename substrate: MCP's `medaka_rename` and LSP's
-- `textDocument/rename` both call this ONE function (the #254 "one code path"
-- design). It reuses the Stage-1 reference index verbatim
-- (`buildRefIndexProject`/`binderAt`/`usesOf`/`defsOf`) — rename is "references +
-- an edit per site + safety checks", nothing more.
--
-- Returns EITHER an LSP `WorkspaceEdit { changes: { <uri>: [ {range, newText} ] } }`
-- (F5) on success, OR a structured refusal `{ refused: true, reason }` — NEVER a
-- crash and NEVER a wrong/silent edit (F3 conservative-refuse: a bad edit set the
-- client applies BREAKS the program, so when in doubt we REFUSE with a reason).
-- It NEVER writes to disk — the caller applies the returned edits (the #250 /
-- `fmt --write` guardrail, exactly as `medaka_fmt`).
--
-- EVERY def site is in the edit set (F6 rename-includes-def) and they are sorted
-- IN with the uses by (path, line, char) — the same deterministic order
-- `referenceLocations` uses, so the emitted edit list is stable across
-- runs/machines (the merge queue runs the full suite on a DIFFERENT runner; any
-- enumeration/hash-order-dependent list BOUNCES it — #912 did exactly that).
--
-- F3 refusal cases (each SAFETY-CRITICAL):
--   (a) out-of-project — `defsOf key` is `[]` (an external/`?ext`/prelude key
--       carries no project def site), so the symbol is defined outside the
--       project (stdlib/prelude): REFUSE. `buildRefIndexProject` only indexes
--       files under the project root, so every `defsOf` uri is in-project.
--   (b) capture/shadow — `newName` is already taken IN AN AFFECTED SCOPE:
--       a same-namespace binder anywhere in the project (a coarse conservative
--       scan of `allDefKeys`), a PRELUDE binder (#966(b) — the prelude is seeded
--       into the index WITHOUT def entries, so `allDefKeys` alone never sees it
--       and a rename onto `length` silently shadowed it), ANY-namespace binder
--       defined in a file this rename edits (the namespace-tag scan alone let a
--       local capture a top-level name and change the program's answer), or a
--       name an affected file IMPORTS (`import list.{sortBy}`): REFUSE.
--       Over-refusal is acceptable (conservative spirit); silent capture is NOT.
--   (c) illegal newName — `newName`'s LEXICAL CLASS must match the binder's
--       namespace (#966(a)): a value/local/method/field binder needs a
--       lowercase-initial identifier, a type/constructor needs an
--       uppercase-initial one. Renaming a value to `Color` used to be accepted
--       and the applied edit then failed to parse (`unexpected \`Color\``) —
--       a wrong edit, which this path exists to never emit. `newName` must also
--       LEX as an identifier: every reserved word is a lowercase identifier, so
--       `foo` → `match` sailed through the case check (`newNameReserved`).
--   (d) span verification — an emitted span that does not spell the old name
--       (`renameEmitVerified`).
--   (f) index ambiguity — a SECOND binder spelling the old name has an
--       occurrence in an affected file, so the index's split of that name across
--       keys is exactly what is in doubt (`renameIndexAmbiguous`; #951/#1003/
--       #1056/#965a all take this shape).
--   F2  partial graph — a project file that does not parse and mentions the old
--       name has contributed NO occurrences, so the edit set is silently
--       truncated (`renameBrokenProjectFile`).
export renameResult : String -> String -> String -> String -> Json -> Docs -> <IO> Json
renameResult runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params, renameNewName params)
  (Some line, Some col, Some newName) => match identifierAt src line col
    None => renameRefusal "position is not on an identifier"
    Some _ =>
      let rootFile = pathOfUri uri
      let projectDir = findProjectRoot (dirOfPath rootFile)
      let read = path => docsGet (uriOfPath path) docs
      let idx = buildRefIndexProject read projectDir runtimeSrc coreSrc
      -- `binderAt` wants a 1-based line (the `Loc` convention); LSP positions
      -- are 0-based, hence `line + 1`. `col` is 0-based in both conventions.
      match binderAt idx rootFile (line + 1) col
        None => renameRefusal "no renameable symbol at this position"
        Some key => renameEditFor idx runtimeSrc coreSrc projectDir key newName docs
  _ => renameRefusal "rename requires a position and a newName"

-- LSP `textDocument/rename` carries the target spelling in top-level
-- `params.newName`; MCP synthesizes the same shape (`renameParams`, mcp.mdk).
renameNewName : Json -> Option String
renameNewName params = fieldStr "newName" params

-- The refusal object surfaced to BOTH layers. MCP renders it as an isError text
-- result; LSP maps it to a JSON-RPC error response (`isRenameRefusal`).
renameRefusal : String -> Json
renameRefusal reason =
  jObject [("refused", JBool True), ("reason", JString reason)]

-- True iff a `renameResult` Json is a refusal (vs a WorkspaceEdit). The MCP/LSP
-- wrappers key their error rendering off this.
export isRenameRefusal : Json -> Bool
isRenameRefusal j = match lookup "refused" j
  Some (JBool True) => True
  _ => False

-- Build the WorkspaceEdit for `key` → `newName`, or refuse (F3).
--
-- `defsOf` is PLURAL and every entry is edited (#964). A multi-clause top-level
-- function is N `DFunDef` decls under ONE key, and an impl method contributes one
-- clause head per impl (#1002): editing only one head left the others spelling the
-- OLD name, which still COMPILES and silently changes runtime behaviour. That is
-- the exact silent-wrongness this whole path exists to avoid.
renameEditFor : RefIndex -> String -> String -> String -> String -> String -> Docs -> <IO> Json
renameEditFor idx runtimeSrc coreSrc projectDir key newName docs =
  if isExternalKey key then renameRefusal "cannot rename a symbol defined outside the project"
  else match defsOf idx key
    [] => renameRefusal "cannot rename a symbol defined outside the project"
    defs => renameEditChecked idx runtimeSrc coreSrc projectDir key newName defs docs

-- The symbol IS in-project and has def sites; now vet `newName` itself, then
-- the SCOPES the edit lands in, then the INDEX those scopes were derived from,
-- and only then emit. F3(c) (#966(a)) runs BEFORE the collision scan so an
-- ill-formed or wrong-case name is reported as such rather than as an incidental
-- collision.
--
-- The edit set is built ONCE, up front, because three of the four checks below
-- are questions about the FILES it touches ("any affected scope", F3(b)) rather
-- than about the request:
--   F3(b) capture — `newName` already visible in an affected file
--   F3(f) index ambiguity — the index holds a SECOND binder spelling the OLD
--         name in an affected file, so its occurrence split cannot be trusted
--   F2    partial graph — some project file does not parse and mentions the old
--         name, so its occurrences are missing from the index entirely
renameEditChecked : RefIndex -> String -> String -> String -> String -> String -> List (String, Loc) -> Docs -> <IO> Json
renameEditChecked idx runtimeSrc coreSrc projectDir key newName defs docs = match newNameIllegal key newName
  Some reason => renameRefusal reason
  None =>
    -- F6: EVERY def site is included, sorted IN with the uses (never a
    -- duplicate — `recordDef` never pushes into `refs`, and `pushDef` refuses
    -- a (uri, span) it already holds, refindex.mdk).
    let all = sortBy compareUseLoc (defs ++ usesOf idx key)
    let files = affectedPaths all
    if renameCollides idx runtimeSrc coreSrc projectDir key newName files docs then
      renameRefusal (stringConcat ["renaming to `", newName, "` would collide with an existing binder"])
    else match renameIndexAmbiguous idx key files
      Some reason => renameRefusal reason
      None => match renameBrokenProjectFile projectDir key docs
        Some reason => renameRefusal reason
        None => renameEmitVerified key newName all docs

-- The DISTINCT files the edit set touches, in the sorted order `all` already
-- carries — the "affected scope" of `REFERENCES-RENAME-DESIGN.md:368-370`,
-- approximated at FILE granularity (the coarsest unit that is still sound:
-- capture and shadowing are both intra-file phenomena once the importing file
-- is itself in the set). `all` is sorted by path, so same-path entries are
-- contiguous and `spanSamePath` yields each file exactly once.
affectedPaths : List (String, Loc) -> List String
affectedPaths [] = []
affectedPaths ((p, _)::rest) = p :: affectedPaths (snd (spanSamePath p rest))

pathIsIn : String -> List String -> Bool
pathIsIn _ [] = False
pathIsIn p (q::qs) = p == q || pathIsIn p qs

-- F3(d) SPAN VERIFICATION — the last line of the "never a wrong edit" contract,
-- and the only F3 arm that is not about the user's request at all: it audits the
-- INDEX. Every one of F3(a)-(c) assumes the (uri, Loc) set really does point at
-- occurrences of the symbol; if the index puts a def at a span that does NOT
-- spell the old name, the emitted WorkspaceEdit silently overwrites *something
-- else* and the caller applies it sight-unseen.
--
-- That is not hypothetical. Renaming an INTERFACE METHOD (`area` → `zarea` in
-- `interface Shape a where / area : a -> Int`) used to emit an edit over the
-- span `Shape` — `refindex.mdk`'s `defsOfDecl` recorded an interface's method
-- decls at the enclosing DECL's name `Loc` (the interface name), not each
-- method's own — so the applied edit produced `interface zarea a where` while
-- leaving the method declaration untouched: a program that no longer parses.
-- This arm caught it and refused. **#1013 has since fixed the Loc**, so that
-- rename now emits a complete, correct edit set (interface decl + every impl
-- head + every call site) and this arm no longer fires on it; the shapes that
-- still reach it are the two puns whose element `Loc` the parser drops — see
-- the F3(e) note below — which `pun.jsonl` pins.
--
-- Being a property of the EDIT SET rather than of one known bug, this also
-- catches any future Loc regression in the same shape — the check is cheap
-- (one `identifierAt` per edit) and its failure direction is refusal.
renameEmitVerified : String -> String -> List (String, Loc) -> Docs -> <IO> Json
renameEmitVerified key newName all docs = match keyNsName key
  None => renameRefusal "cannot determine the kind of the symbol being renamed"
  Some (_ns, oldName) =>
    if allSpansSpell oldName all docs then
      workspaceEditJson (punTablesFor all docs) newName all
    else
      renameRefusal (stringConcat [
        "the reference index reports an occurrence of `",
        oldName,
        "` at a span that does not spell it — refusing rather than emit an edit that would corrupt the source",
      ])

allSpansSpell : String -> List (String, Loc) -> Docs -> <IO> Bool
allSpansSpell _ [] _ = True
allSpansSpell oldName ((p, loc)::rest) docs = spanSpells oldName p loc docs
  && allSpansSpell oldName rest docs

-- Does the edit span `loc` in file `p` currently hold exactly the identifier
-- `oldName`? An occurrence is always a single name token, so a multi-line span
-- or a width mismatch is already wrong; `identifierAt` then confirms the token
-- starts where the span does and reads as the same name. An unreadable file
-- yields False (refuse) — the index derived the span from SOME text, so failing
-- to re-read it means we cannot vouch for the edit.
spanSpells : String -> String -> Loc -> Docs -> <IO> Bool
spanSpells oldName p (Loc _ sl sc el ec) docs =
  if sl != el || ec - sc != stringLength oldName then False
  else match renameSrcOf p docs
    None => False
    Some src => match identifierAt src (sl - 1) sc
      Some got => got == oldName
      None => False

-- The current text of `p`: the open-document buffer if the client has one (an
-- unsaved edit must be what we verify against), else the file on disk. Mirrors
-- `refindex.mdk`'s `getSrc`, whose index we are auditing.
renameSrcOf : String -> Docs -> <IO> Option String
renameSrcOf p docs = match docsGet (uriOfPath p) docs
  Some s => Some s
  None => match readFile p
    Ok s => Some s
    Err _ => None

-- ── F3(e) PUN EXPANSION (#963) ───────────────────────────────────────────────
-- A record PUN spells a FIELD name and a BINDER name with ONE token:
--
--   pattern     `area s = match s / Circle { radius } => radius * 3`
--   expression  `mk radius = Circle { radius }`
--
-- Both `{ radius }` tokens are indexed — correctly — as an occurrence of the
-- LOCAL `radius` (refindex's `recFieldBinders` gives the pattern pun the field
-- token's own `Loc`; `walkExpr`'s `ESetLit` arm walks the bare element as an
-- ordinary use). So the span really does spell `radius` and F3(d) waves it
-- through; replacing it outright with `rad` yields `Circle { rad }`, which names
-- a field that does not exist — a LOUD `Unknown field: rad` (#963). Wrong edit,
-- and the one class span verification structurally cannot see: the span is right,
-- the REPLACEMENT is what is wrong.
--
-- The fix is not a fourth refusal but the expansion the sugar already stands
-- for: emit `radius = rad` over the whole pun token, which is what
-- `Circle { radius = rad }` means in both pattern and expression position. The
-- field name is preserved, the binder moves, and the applied program compiles.
--
-- WHY IT IS SAFE TO REWRITE MORE THAN THE NAME. A pun span reaches an edit set
-- ONLY as a val/local occurrence: refindex never records a field USE for a
-- record-literal label (`walkFields` drops the label) and files every field DEF
-- at the enclosing `data` decl's own name `Loc` (`fieldDef`) — so no `field`-key
-- edit can ever land on a pun token, and the expansion cannot collide with a
-- field rename.
--
-- WHY THE DETECTION IS COMPLETE, not a best-effort scan:
--   * PATTERN puns are intrinsic to the AST — `RecPatField name loc None` IS the
--     pun, `Some pat` is the explicit form. No inference, no ambiguity.
--   * EXPRESSION puns are `ESetLit`s that desugar rewrites into `ERecordCreate`,
--     and `punRecordSetLit` reproduces `rewriteRecordPun`'s guard EXACTLY
--     (desugar.mdk: head is a `ConNamed` ctor OF THIS FILE, non-empty, every
--     item a bare var). Anything that guard rejects is a genuine `Set { … }` /
--     `Map { … }` literal, whose elements are plain uses that must be replaced
--     by the bare name — which is what falls through to. ⚠️ The per-FILE ctor
--     scope is not a shortcut: a cross-module pun does not compile
--     (`desugarRecordPuns` collects record names from one module's decls), so
--     widening it would expand a genuine set element.
--   * REACHABILITY is `mapProg`'s, i.e. desugar's own: a pun the traversal
--     cannot reach is a pun `desugarRecordPuns` never expanded either, so it is
--     not a record pun in any program that compiles.
--
-- Two pun forms are NOT expanded here and do not need to be: a MIXED brace
-- (`Circle { radius, tag = 1 }`, which the parser folds to `ERecordCreate` via
-- `kvElemToField` and whose element `Loc` is dropped) and a record-update pun
-- (`{ c | radius }`, whose `EVar` the parser builds unlocated). Both leave the
-- index pointing at the enclosing expression's span, so F3(d) already refuses
-- them — safe, and the residual belongs to those two dropped `Loc`s, not here.

-- The punned-field spans of ONE file, as ((1-based line, 0-based char), field).
-- `[]` for a file that does not parse — the caller then emits the bare name,
-- exactly as before; a file that does not parse also has no index entries for
-- the rename to have found in the first place.
punFieldsOfSrc : String -> List ((Int, Int), String)
punFieldsOfSrc src = match parseWithPositionsOpt src
  None => []
  Some (decls, _) => punFieldsOfDecls decls

punFieldsOfDecls : List Decl -> List ((Int, Int), String)
punFieldsOfDecls decls =
  let acc = Ref []
  let recNames = recordCtorNames decls
  -- `mapProg` for the expression side (desugar's own traversal — see the
  -- reachability note above) and, from each node it visits, the patterns that
  -- node HOSTS; `declParamPuns` adds the clause params `mapDecl` steps over.
  let _ = mapProg (punVisit acc recNames) decls
  declParamPuns decls ++ acc.value

-- `mapProg`'s callback is a REWRITER; this one rewrites nothing and only
-- harvests, so the rebuilt tree it returns is discarded.
punVisit : Ref (List ((Int, Int), String)) -> List String -> Expr -> Expr
punVisit acc recNames e =
  let _ = collectExprPuns acc recNames e
  e

-- Every constructor that can head a record brace, from THIS file's decls —
-- the same set `desugarRecordPuns` computes (a `ConNamed` variant's ctor name).
recordCtorNames : List Decl -> List String
recordCtorNames decls = flatMapL recordCtorNamesOf decls

recordCtorNamesOf : Decl -> List String
recordCtorNamesOf d = match innerDecl d
  DData _ _ _ vs _ => namedVariantCtors vs
  _ => []

namedVariantCtors : List Variant -> List String
namedVariantCtors [] = []
namedVariantCtors ((Variant n (ConNamed _ _))::vs) = n :: namedVariantCtors vs
namedVariantCtors (_::vs) = namedVariantCtors vs

-- Push this node's puns. The `ESetLit` arm is the expression pun; every other
-- arm hands over the patterns the node holds directly (their sub-patterns are
-- walked by `patPuns`), which is where a pattern pun can appear.
collectExprPuns : Ref (List ((Int, Int), String)) -> List String -> Expr -> Unit
collectExprPuns acc recNames (ESetLit name items) =
  if punRecordSetLit recNames name items then
    pushPuns acc (flatMapL punItemSpan items)
  else
    ()
collectExprPuns acc _ (ELam ps _) = pushPuns acc (flatMapL patPuns ps)
collectExprPuns acc _ (ELet _ _ p _ _) = pushPuns acc (patPuns p)
collectExprPuns acc _ (EMatch _ arms) = pushPuns acc (flatMapL armPuns arms)
collectExprPuns acc _ (EGuards arms) = pushPuns acc (flatMapL guardArmPuns arms)
collectExprPuns acc _ (EBlock stmts) = pushPuns acc (flatMapL stmtPuns stmts)
collectExprPuns acc _ (EDo stmts) = pushPuns acc (flatMapL stmtPuns stmts)
collectExprPuns acc _ (ELetGroup binds _) =
  pushPuns acc (flatMapL letBindPuns binds)
collectExprPuns _ _ _ = ()

pushPuns : Ref (List ((Int, Int), String)) -> List ((Int, Int), String) -> Unit
pushPuns acc [] = ()
pushPuns acc found = acc := found ++ acc.value

-- `rewriteRecordPun`'s guard, verbatim (desugar.mdk): a record-literal brace
-- whose items are ALL bare vars. `Set { a, b }` fails the head test, `Map { … }`
-- never reaches `ESetLit` at all, and `Circle { radius, tag = 1 }` is already an
-- `ERecordCreate` — so this is true of pun braces and nothing else.
punRecordSetLit : List String -> String -> List Expr -> Bool
punRecordSetLit _ _ [] = False
punRecordSetLit recNames name items = anyName recNames name && allBareVars items

allBareVars : List Expr -> Bool
allBareVars [] = True
allBareVars (e::rest) = match punItemSpan e
  [] => False
  _ => allBareVars rest

-- The (span, field) of one pun item — a located bare variable. `[]` for
-- anything else, which is also how `allBareVars` rejects a non-pun brace.
punItemSpan : Expr -> List ((Int, Int), String)
punItemSpan (ELoc (Loc _ sl sc _ _) (EVar n)) = [((sl, sc), n)]
punItemSpan (ELoc _ e) = punItemSpan e
punItemSpan (EDoOrigin _ e) = punItemSpan e
punItemSpan _ = []

armPuns : Arm -> List ((Int, Int), String)
armPuns (Arm p gs _) = patPuns p ++ flatMapL guardPuns gs

guardArmPuns : GuardArm -> List ((Int, Int), String)
guardArmPuns (GuardArm gs _) = flatMapL guardPuns gs

guardPuns : Guard -> List ((Int, Int), String)
guardPuns (GBind p _) = patPuns p
guardPuns _ = []

stmtPuns : DoStmt -> List ((Int, Int), String)
stmtPuns (DoBind p _) = patPuns p
stmtPuns (DoLet _ _ p _) = patPuns p
stmtPuns _ = []

letBindPuns : LetBind -> List ((Int, Int), String)
letBindPuns (LetBind _ clauses) = flatMapL clausePuns clauses

clausePuns : FunClause -> List ((Int, Int), String)
clausePuns (FunClause ps _) = flatMapL patPuns ps

-- Clause parameters: `mapDecl` maps only a decl's BODY, so a `PRec` parameter
-- (`draw (Circle { radius }) = …`) is reachable from the decl alone.
declParamPuns : List Decl -> List ((Int, Int), String)
declParamPuns decls = flatMapL declParamPunsOf decls

declParamPunsOf : Decl -> List ((Int, Int), String)
declParamPunsOf d = match innerDecl d
  DFunDef _ _ ps _ => flatMapL patPuns ps
  DLetGroup _ binds => flatMapL letBindPuns binds
  DImpl { methods = ms, ... } => flatMapL implMethodPuns ms
  DInterface { methods = ms, ... } => flatMapL ifaceMethodPuns ms
  _ => []

implMethodPuns : ImplMethod -> List ((Int, Int), String)
implMethodPuns (ImplMethod _ ps _) = flatMapL patPuns ps

ifaceMethodPuns : IfaceMethod -> List ((Int, Int), String)
ifaceMethodPuns (IfaceMethod _ _ (Some (MethodDefault ps _))) =
  flatMapL patPuns ps
ifaceMethodPuns _ = []

-- A pattern's punned record fields: `RecPatField name loc None` IS the pun
-- (`Some p` is the explicit `field = pat` form, whose sub-pattern is walked).
patPuns : Pat -> List ((Int, Int), String)
patPuns (PRec _ fields _) = flatMapL recFieldPuns fields
patPuns (PCon _ ps) = flatMapL patPuns ps
patPuns (PCons a b) = patPuns a ++ patPuns b
patPuns (PTuple ps) = flatMapL patPuns ps
patPuns (PList ps) = flatMapL patPuns ps
patPuns (PAs _ _ p) = patPuns p
patPuns _ = []

recFieldPuns : RecPatField -> List ((Int, Int), String)
recFieldPuns (RecPatField name (Loc _ sl sc _ _) None) = [((sl, sc), name)]
recFieldPuns (RecPatField _ _ (Some p)) = patPuns p

flatMapL : (a -> List b) -> List a -> List b
flatMapL _ [] = []
flatMapL f (x::xs) = f x ++ flatMapL f xs

-- One pun table per DISTINCT file in the edit set. `all` is sorted by path
-- (`compareUseLoc`), so same-path entries are contiguous and `spanSamePath`
-- yields each file exactly once — one parse per affected file, never per edit.
-- The enclosing request already built the whole-project index, so this is
-- strictly cheaper than the work `renameResult` has already done.
punTablesFor : List (String, Loc) -> Docs -> <IO> List (String, List ((Int, Int), String))
punTablesFor [] _ = []
punTablesFor ((p, _)::rest) docs =
  let sameRest = spanSamePath p rest
  let tbl = match renameSrcOf p docs
    None => []
    Some src => punFieldsOfSrc src
  (p, tbl) :: punTablesFor (snd sameRest) docs

punTableOf : String -> List (String, List ((Int, Int), String)) -> List ((Int, Int), String)
punTableOf _ [] = []
punTableOf p ((q, tbl)::rest) = if p == q then tbl else punTableOf p rest

-- The replacement text for ONE edit: `field = newName` at a pun token, the bare
-- `newName` everywhere else. Both lists are per-FILE and small (a file's puns ×
-- that file's edits), and the request is already O(project) — see `punTablesFor`.
punAwareText : List ((Int, Int), String) -> String -> Loc -> String
punAwareText tbl newName (Loc _ sl sc _ _) = match punFieldAt tbl sl sc
  Some field => stringConcat [field, " = ", newName]
  None => newName

punFieldAt : List ((Int, Int), String) -> Int -> Int -> Option String
punFieldAt [] _ _ = None
punFieldAt (((l, c), field)::rest) sl sc =
  if l == sl && c == sc then
    Some field
  else
    punFieldAt rest sl sc

-- An external / prelude / out-of-project key: refindex mints these as
-- `"?ext\t<ns>\t<name>"` (extKey, refindex.mdk). `defsOf` already returns `[]`
-- for them, but the explicit prefix check documents the F3(a) intent.
isExternalKey : String -> Bool
isExternalKey key = match splitOnChar keyTab key
  m::_ => m == "?ext"
  _ => False

-- The TAB separator refindex forms binder keys with (`sep`, refindex.mdk) —
-- an identifier / module id / namespace tag can contain none, so a split on it
-- recovers the key's fields injectively.
keyTab : Char
keyTab = '\t'

-- (namespace, name) of a binder key — field 1 and field 2 of the
-- TAB-separated `"<mod>\t<ns>\t<name>[\t<freshId>]"`. `None` if unparseable
-- (treated as a collision → conservative refuse).
keyNsName : String -> Option (String, String)
keyNsName key = match splitOnChar keyTab key
  _::ns::name::_ => Some (ns, name)
  _ => None

-- F3(b) coarse conservative capture check: is `newName` already taken — by a
-- same-namespace binder anywhere in the project, by ANY binder the PRELUDE
-- declares, by ANY binder (any namespace) defined in a file this rename edits,
-- or by a name an affected file IMPORTS? Over-refusal is acceptable (F3 spirit);
-- a silent capture is not. An unparseable key → refuse.
--
-- ⚠️ THE PRELUDE ARM IS NOT REDUNDANT (#966(b)). `allDefKeys idx` is
-- `hmKeys idx.defs`, and `refindex.mdk`'s `seedPrelude` deliberately seeds the
-- prelude's names as import ORIGINS ONLY — it records **no def entries** for them
-- (F1: never descend into stdlib). So the project scan alone cannot see `length`,
-- `map`, `Option`, … and a rename onto one of them was accepted, shadowing the
-- prelude binding. The prelude's own SOURCE is the complete answer and both
-- sources are already threaded here for the index build, so re-deriving the name
-- set costs one extra parse of each prelude module per rename REQUEST — O(prelude),
-- independent of project size, so it cannot perturb the references scaling gate.
--
-- The prelude arm is namespace-BLIND, and that is sound only because
-- `newNameIllegal` has already pinned `newName`'s lexical class to the binder's
-- namespace: a lowercase `newName` can only match a prelude value/method/field and
-- an uppercase one only a prelude type/constructor. (The residual over-refusal —
-- a value vs a record field of the same lowercase spelling — is the acceptable
-- direction.)
--
-- ⚠️ THE SAME-NAMESPACE PROJECT SCAN IS NOT THE WHOLE CHECK EITHER (S0-1). It
-- compares `ns2 == ns`, so a `local` key can never match a `val` key — the
-- capture arm was blind in EXACTLY the direction capture happens. Renaming the
-- local `x` of
--
--   top = 100
--   f n = let x = n + 1
--         x + top
--
-- to `top` was accepted, and the applied edit (`let top = n + 1` / `top + top`)
-- still compiles and prints `4` instead of `102` — a silent wrong answer, the
-- worst failure this path can produce. The design doc has always specified the
-- right rule (`compiler/REFERENCES-RENAME-DESIGN.md:368-370`: refuse if
-- `newName` would capture/shadow an existing binder **in any affected scope**);
-- the `ns2 == ns` scan implemented a namespace tag instead of a scope.
--
-- The two arms below implement "visible in an affected scope", where the scope
-- is approximated by the FILES the edit touches (`affectedPaths`):
--   * `anyKeyNamedInFiles` — ANY namespace, any binder the index has a def site
--     for in an affected file. Namespace-blind for the same reason the prelude
--     arm can be: `newNameIllegal` has already pinned `newName`'s lexical class.
--   * `anyImportBindsIn` — the names an affected file's IMPORTS bring into it.
--     `allDefKeys` cannot see these for the same structural reason it could not
--     see the prelude (an imported name has no def entry in the importing
--     module), so `import list.{sortBy}` + rename-a-value-to-`sortBy` was
--     accepted and shadowed the import: #966(b) unfixed one module over.
renameCollides : RefIndex -> String -> String -> String -> String -> String -> List String -> Docs -> <IO> Bool
renameCollides idx runtimeSrc coreSrc projectDir key newName files docs = match keyNsName key
  None => True
  Some (ns, _name) => anyDefKeyMatches (allDefKeys idx) ns newName
    || preludeDeclares coreSrc newName
    || preludeDeclares runtimeSrc newName
    || anyKeyNamedInFiles idx (allDefKeys idx) newName files
    || anyImportBindsIn newName projectDir files docs

anyDefKeyMatches : List String -> String -> String -> Bool
anyDefKeyMatches [] _ _ = False
anyDefKeyMatches (k::ks) ns newName = match keyNsName k
  Some (ns2, nm2) =>
    if ns2 == ns && nm2 == newName then
      True
    else
      anyDefKeyMatches ks ns newName
  None => anyDefKeyMatches ks ns newName

-- Any binder named `newName` — in ANY namespace — with a def site in one of the
-- files this rename edits. O(total def sites), the same order as the index build
-- the request already paid for.
anyKeyNamedInFiles : RefIndex -> List String -> String -> List String -> Bool
anyKeyNamedInFiles _ [] _ _ = False
anyKeyNamedInFiles idx (k::ks) newName files = keyNameIs k newName && anyPathIn (defsOf idx k) files
  || anyKeyNamedInFiles idx ks newName files

keyNameIs : String -> String -> Bool
keyNameIs k name = match keyNsName k
  Some (_ns, n) => n == name
  None => False

anyPathIn : List (String, Loc) -> List String -> Bool
anyPathIn [] _ = False
anyPathIn ((p, _)::rest) files = pathIsIn p files || anyPathIn rest files

-- Does any affected file's import list already bind `newName`? A selective
-- member binds its ALIAS when it has one (`useMemberLocal`); a wildcard binds
-- everything the imported module declares, which is answered by parsing that
-- module exactly as the prelude arm parses `core`/`runtime`; a module ALIAS
-- (`import m as D`) occupies the name `D`, so renaming onto it would shadow the
-- qualifier. A BARE `import m` binds no names at all and is correctly ignored.
anyImportBindsIn : String -> String -> List String -> Docs -> <IO> Bool
anyImportBindsIn _ _ [] _ = False
anyImportBindsIn newName projectDir (p::ps) docs = fileImportsBind newName projectDir p docs
  || anyImportBindsIn newName projectDir ps docs

fileImportsBind : String -> String -> String -> Docs -> <IO> Bool
fileImportsBind newName projectDir p docs = match renameSrcOf p docs
  None => False
  Some src => match parseWithPositionsOpt src
    None => False
    Some (decls, _) => anyImportDeclBinds newName projectDir decls docs

anyImportDeclBinds : String -> String -> List Decl -> Docs -> <IO> Bool
anyImportDeclBinds _ _ [] _ = False
anyImportDeclBinds newName projectDir (d::ds) docs = importDeclBinds newName projectDir (innerDecl d) docs
  || anyImportDeclBinds newName projectDir ds docs

importDeclBinds : String -> String -> Decl -> Docs -> <IO> Bool
importDeclBinds newName projectDir (DUse _ path _) docs =
  usePathBinds newName projectDir path docs
importDeclBinds _ _ _ _ = False

usePathBinds : String -> String -> UsePath -> Docs -> <IO> Bool
usePathBinds newName _ (UseGroup _ members) _ =
  anyName (map useMemberLocal members) newName
usePathBinds newName projectDir (UseWild mods) docs = match importedModuleSrc projectDir mods docs
  None => False
  Some src => preludeDeclares src newName
usePathBinds newName _ (UseAlias _ alias) _ = alias == newName
usePathBinds _ _ (UseName _) _ = False

-- The source of an imported module, looked up the two places a project's
-- `import m.n` can resolve to: under the project root, then under `stdlib/`.
-- Unreadable ⇒ `None`, which reads as "declares nothing" — best-effort in the
-- F2 spirit, and the only direction available without duplicating the loader's
-- `[dependencies]` multi-root resolution here.
importedModuleSrc : String -> List String -> Docs -> <IO> Option String
importedModuleSrc projectDir mods docs =
  let rel = joinWith "/" mods ++ ".mdk"
  match renameSrcOf (joinPath projectDir rel) docs
    Some s => Some s
    None => renameSrcOf (joinPath (lspMedakaRoot "." ++ "/stdlib") rel) docs

-- ── F3(f) INDEX-AMBIGUITY REFUSE ────────────────────────────────────────────
-- F3(d) (`renameEmitVerified`) audits the spans the index DID produce. This arm
-- audits the ones it MIGHT HAVE DROPPED — the failure mode F3(d) is structurally
-- blind to, because a missing occurrence has no span to verify.
--
-- ⚠️ THE CHEAP GATE PROPOSED IN REVIEW ("refuse whenever an edit span was
-- recorded at the enclosing decl's `curLoc` rather than at a name token") DOES
-- NOT WORK, and measuring the four open defects is what showed why:
--   * it is not observable from outside `refindex.mdk`. A caller sees a `Loc`,
--     not where it came from; the only observable proxy — "this span equals a
--     top-level declaration's own name `Loc`" — is EXACTLY what a legitimate
--     top-level definition looks like, so the gate cannot fire without refusing
--     every `val` rename;
--   * of the four defects it was proposed to cover, only #965(a) even has a
--     mis-placed span. Dumped indexes for the other three (see below) show the
--     occurrence is not misplaced but ABSENT from the clicked key, so no
--     span-shaped check of any kind can see it.
--
-- What the same dumps DO show is one signature common to all four: a SECOND
-- binder spelling the old name, with an occurrence in a file this rename edits.
--   #951  `let rec countDown` — `main|local|countDown|1` and `main|val|countDown`
--         BOTH have a def at 1:8; the recursive call is a use of the first, the
--         external call a use of the second. Clicking either edits half.
--   #1003 self-recursive local `go` under an outer `go` — the recursive call is
--         recorded as a use of `main|val|go`, so it survives the rename and
--         REBINDS to the outer definition: `10` becomes `104`, silently.
--   #1056 imported interface shadowing a local one — the impl head lands on the
--         phantom key `a|method|mlocal` while the click resolves to
--         `main2|method|mlocal`; the head is dropped from the edit.
--   #965a alias-qualified `D.bar` under a re-export wrapper also called `bar` —
--         the use is filed at the wrapper's own decl name, which is
--         `main|val|bar`'s DEF site.
-- So: if any OTHER binder named `oldName` has a def or use in an affected file,
-- the index's split of that name across keys is precisely what is in doubt, and
-- the honest answer is to refuse.
--
-- TWO PAIRINGS ARE EXCLUDED, both measured against the corpus rather than
-- assumed — they are the reason this is not "refuse on any namesake":
--   * local ↔ local — nested shadowed locals. `refindex` keys each with a fresh
--     id and gets them RIGHT (the review verified this end-to-end); refusing
--     would break a working rename, which is the worse regression.
--   * anything ↔ field — a record field and a binder share a spelling BY DESIGN;
--     that is what a pun IS. `test/references_fixtures/rename/pdefs.mdk` has
--     `pdefs|field|girth` sitting in the same file as the three `pdefs|local|
--     girth|…` binders the #963 transcript renames, so without this exclusion
--     F3(e) pun expansion could never be reached.
renameIndexAmbiguous : RefIndex -> String -> List String -> Option String
renameIndexAmbiguous idx key files = match keyNsName key
  None => Some "cannot determine the kind of the symbol being renamed"
  Some (ns, name) =>
    let cands = allDefKeys idx ++ extNamesakeKeys name
    map
      (f => stringConcat [
        "the reference index holds a second binder also named `",
        name,
        "` with an occurrence in `",
        f,
        "`, so the occurrences of this one cannot be told apart from that one's — refusing rather than emit an edit set that may be incomplete; disambiguate the two names first, or edit by hand",
      ])
      (firstAmbiguousFile idx key ns name cands files)

-- Iteration is over the FILES (already sorted by `compareUseLoc`), not over
-- `allDefKeys` — `hmKeys` order is a hash-table detail, and a refusal message
-- that named a key-order-dependent file would differ across runners (#912).
firstAmbiguousFile : RefIndex -> String -> String -> String -> List String -> List String -> Option String
firstAmbiguousFile _ _ _ _ _ [] = None
firstAmbiguousFile idx key ns name cands (f::fs)
  | anyNamesakeInFile idx key ns name cands f = Some f
  | otherwise = firstAmbiguousFile idx key ns name cands fs

anyNamesakeInFile : RefIndex -> String -> String -> String -> List String -> String -> Bool
anyNamesakeInFile _ _ _ _ [] _ = False
anyNamesakeInFile idx key ns name (k::ks) f = namesakeHitsFile idx key ns name k f
  || anyNamesakeInFile idx key ns name ks f

namesakeHitsFile : RefIndex -> String -> String -> String -> String -> String -> Bool
namesakeHitsFile idx key ns name k f
  | k == key = False
  | otherwise = match keyNsName k
    None => False
    Some (ns2, n2) => n2 == name
      && !(benignNamesake ns ns2)
      && anyPathIn (defsOf idx k ++ usesOf idx k) [f]

-- The namesake pairings that are NOT evidence of an index defect — see the
-- block comment above `renameIndexAmbiguous` for why each is safe.
benignNamesake : String -> String -> Bool
benignNamesake "field" _ = True
benignNamesake _ "field" = True
benignNamesake "local" "local" = True
benignNamesake _ _ = False

-- An occurrence `refindex` could not resolve to any project binder is recorded
-- under `extKey ns name` = `"?ext\t<ns>\t<name>"` (refindex.mdk), a key with no
-- def entry — so `allDefKeys` cannot see it, exactly as it could not see the
-- prelude (#966(b)). It is the shape a self-recursive local takes with NO outer
-- namesake (#1003's own reproducer): the recursive call resolves to nothing at
-- all, and the rename drops it. Synthesizing the six keys costs six hash lookups.
extNamesakeKeys : String -> List String
extNamesakeKeys name = map
  (ns => joinWith "\t" ["?ext", ns, name])
  ["val", "local", "method", "ty", "ctor", "iface"]

-- ── F2 PARTIAL-GRAPH REFUSE ─────────────────────────────────────────────────
-- `REFERENCES-RENAME-DESIGN.md:362-367`: "a rename computed over a partial graph
-- can miss a use → silent corruption." `refindex`'s `indexModule` no-ops a file
-- that fails to parse — correct for `references` (best-effort listing) and
-- CORRUPTING for rename, which hands the caller an edit set it will apply
-- wholesale. Measured: a sibling with a trailing `zzz = (` returned a clean,
-- `isError:false`, 4-edit success with that file's THREE occurrences (its
-- `import gdefs.{gval}` clause and both uses) silently dropped.
--
-- REFUSE rather than mark `partial: true`. `textDocument/rename` returns a
-- `WorkspaceEdit` and every editor applies it wholesale — the protocol has no
-- slot for "this is only most of the rename", so a partial marker would be
-- ignored by exactly the client most likely to act on it. And a partial rename
-- is not a partial success: it is a program that no longer compiles (or, with a
-- namesake in scope, one that compiles and does something else). Naming the
-- broken file is the actionable answer, and it is one the user can act on.
--
-- SCOPED TO FILES THAT MENTION THE OLD NAME. A broken file with no token
-- spelling `oldName` cannot be hiding an occurrence of it, so refusing on it
-- would be pure over-refusal — one unrelated broken scratch file would block
-- every rename in the project. The lexical pre-filter also bounds the cost: a
-- lex per project file, a parse only for the few that mention the name.
renameBrokenProjectFile : String -> String -> Docs -> <IO> Option String
renameBrokenProjectFile projectDir key docs = match keyNsName key
  None => None
  Some (_ns, name) => map (p => stringConcat [
    "`",
    p,
    "` is under the project root, mentions `",
    name,
    "`, and does not parse — its occurrences are missing from the reference index, so this rename would silently skip them; fix that file's parse error first",
  ]) (firstBrokenMentioning name (projectMdkFiles projectDir) docs)

firstBrokenMentioning : String -> List String -> Docs -> <IO> Option String
firstBrokenMentioning _ [] _ = None
firstBrokenMentioning name (p::ps) docs =
  if brokenAndMentions name p docs then
    Some p
  else
    firstBrokenMentioning name ps docs

brokenAndMentions : String -> String -> Docs -> <IO> Bool
brokenAndMentions name p docs = match renameSrcOf p docs
  None => False
  Some src => srcMentionsName name src && srcFailsToParse src

srcFailsToParse : String -> Bool
srcFailsToParse src = match parseWithPositionsOpt src
  None => True
  Some _ => False

-- Token-level, not substring: `gvalue` must not read as a mention of `gval`.
-- The lexer still runs on a file the PARSER rejects, which is exactly the file
-- this question is asked about.
srcMentionsName : String -> String -> Bool
srcMentionsName name src = anyNameTok name (fst (tokenizeWithOffsetPairs src))

anyNameTok : String -> List Token -> Bool
anyNameTok _ [] = False
anyNameTok name (t::ts) = tokSpells t name || anyNameTok name ts

tokSpells : Token -> String -> Bool
tokSpells (TIdent n) name = n == name
tokSpells (TUpper n) name = n == name
tokSpells _ _ = False

-- Every `.mdk` under the project root, sorted. Sorted because the refusal above
-- names the FIRST broken file and `listDir` order is a filesystem detail that
-- differs across machines (#912). Dot-entries are skipped (`.git`); an
-- unlistable directory contributes nothing rather than aborting the walk.
projectMdkFiles : String -> <IO> List String
projectMdkFiles root =
  let acc = Ref []
  let _ = collectMdkUnder acc root
  sortBy compare acc.value

collectMdkUnder : Ref (List String) -> String -> <IO> Unit
collectMdkUnder acc dir = match listDir dir
  Err _ => ()
  Ok entries => collectMdkEntries acc dir entries

collectMdkEntries : Ref (List String) -> String -> List String -> <IO> Unit
collectMdkEntries _ _ [] = ()
collectMdkEntries acc dir (n::rest) =
  let _ = collectMdkEntry acc dir n
  collectMdkEntries acc dir rest

collectMdkEntry : Ref (List String) -> String -> String -> <IO> Unit
collectMdkEntry acc dir n
  | startsWith "." n = ()
  | otherwise = collectMdkPath acc (joinPath dir n) n

-- `listDir` on an entry doubles as the dir/file discriminator: `Ok` = directory
-- (recurse), `Err` = a file (or unreadable — either way, no recursion).
collectMdkPath : Ref (List String) -> String -> String -> <IO> Unit
collectMdkPath acc full n = match listDir full
  Ok _ => collectMdkUnder acc full
  Err _ => if endsWith ".mdk" n then acc := full::acc.value else ()

-- Does prelude source `src` declare `name` at top level (own name or child name:
-- variant ctor, record field, interface/impl method, let-bind)? Reuses the same
-- `declOwnNameMatches`/`declChildNames` pair the document-symbol path uses, so a
-- new declaration form is covered here the moment it is covered there. A prelude
-- that fails to parse yields `False` — the project scan still applies, and a
-- broken prelude is a louder failure elsewhere.
preludeDeclares : String -> String -> Bool
preludeDeclares src name = match parseWithPositionsOpt src
  None => False
  Some (decls, _) => anyDeclDeclares decls name

anyDeclDeclares : List Decl -> String -> Bool
anyDeclDeclares [] _ = False
anyDeclDeclares (d::ds) name = declOwnNameMatches d name
  || anyName (declChildNames d) name
  || anyDeclDeclares ds name

-- F3(c) (#966(a)): is `newName` unusable for a binder in `key`'s namespace?
-- `Some reason` ⇒ REFUSE with that reason; `None` ⇒ lexically fine.
--
-- Three independent ways a newName breaks the applied edit:
--   * it is not an identifier at all (empty, leading digit, embedded space/
--     punctuation) — the edited file no longer lexes;
--   * the LEXER does not read it as an identifier even though every character
--     is an identifier character — i.e. it is a RESERVED WORD, or `_`. See
--     `newNameReserved`;
--   * its CASE contradicts the namespace. Medaka's lexical convention is load-
--     bearing, not cosmetic: an uppercase leading letter IS a constructor/type
--     token, so `alpha` → `Color` produced a value binding `Color = …` and the
--     parse error `unexpected \`Color\``. The inverse (`Color` → `alpha`) is just
--     as broken in type position.
-- An unparseable key → refuse (same conservative default as `renameCollides`).
newNameIllegal : String -> String -> Option String
newNameIllegal key newName = match keyNsName key
  None => Some "cannot determine the kind of the symbol being renamed"
  Some (ns, _name) => match firstChar newName
    None => Some "the new name is empty"
    Some c =>
      if !(isIdentStart c) || !(allIdentChars newName) then
        Some (stringConcat ["`", newName, "` is not a legal Medaka identifier"])
      else if newNameReserved newName then
        Some (stringConcat [
          "`",
          newName,
          "` is reserved by the language (a keyword, or `_`) and cannot name a ",
          nsNoun ns,
          " — choose a different name",
        ])
      else if uppercaseNs ns then
        if isUpper c then None else Some (stringConcat [
          "`",
          newName,
          "` cannot name a ",
          nsNoun ns,
          " — it must start with an uppercase letter",
        ])
      else if isUpper c then
        Some (stringConcat [
          "`",
          newName,
          "` cannot name a ",
          nsNoun ns,
          " — an uppercase name is a type/constructor, not a value",
        ])
      else
        None

-- The two namespaces refindex spells whose members are UPPERCASE-initial
-- (`nsTy`/`nsCtor`, refindex.mdk); every other namespace it mints — `val`,
-- `local`, `method`, `field` — is lowercase-initial.
uppercaseNs : String -> Bool
uppercaseNs ns = ns == "ty" || ns == "ctor"

-- The refusal wording's noun for a namespace tag — the tags are refindex's
-- (`nsVal`/`nsTy`/… , refindex.mdk); an unrecognized one degrades to "binding"
-- rather than leaking the raw tag.
nsNoun : String -> String
nsNoun "val" = "value"
nsNoun "local" = "local binding"
nsNoun "method" = "method"
nsNoun "field" = "record field"
nsNoun "ty" = "type"
nsNoun "ctor" = "constructor"
nsNoun _ = "binding"

allIdentChars : String -> Bool
allIdentChars s = allIdentCharsGo (stringToChars s) 0

allIdentCharsGo : Array Char -> Int -> Bool
allIdentCharsGo arr i
  | i >= arrayLength arr = True
  | !(isIdentChar (arrayGetUnsafe i arr)) = False
  | otherwise = allIdentCharsGo arr (i + 1)

firstChar : String -> Option Char
firstChar s =
  let arr = stringToChars s
  if arrayLength arr == 0 then None else Some (arrayGetUnsafe 0 arr)

-- Is `newName` something the LEXER refuses to read as a plain identifier, even
-- though every one of its characters is an identifier character? That is the
-- reserved words (`match`, `where`, `let`, `data`, `True`, …) and `_`.
--
-- ⚠️ DERIVED FROM THE LEXER, NEVER A COPIED LIST. `#966(a)` fixed the INSTANCE
-- "an uppercase name is illegal for a value"; the PROPERTY is "`newName` must be
-- a legal identifier in that namespace", and every keyword in
-- `frontend/lexer.mdk`'s `keywordOrIdent` table is a lowercase identifier that
-- sailed straight through the `isIdentStart`/`allIdentChars`/case checks —
-- `foo` → `match` was accepted and the applied edit produced ``unexpected
-- `match` ``, character for character the failure #966(a) exists to prevent. A
-- hand-copied keyword list would re-create the same instance-not-property error
-- one dimension over AND rot the next time a keyword is added, so this asks the
-- real tokenizer: a name is usable iff it lexes to exactly ONE identifier token
-- spelling itself. `keywordOrIdent` is the lexer's own dispatcher and needs no
-- export for this — running the tokenizer over the candidate consults it.
newNameReserved : String -> Bool
newNameReserved s = match significantToks s
  [TIdent n] => n != s
  [TUpper n] => n != s
  _ => True

-- The token stream minus the layout heralds the lexer wraps every source in.
significantToks : String -> List Token
significantToks s = dropLayoutToks (fst (tokenizeWithOffsetPairs s))

dropLayoutToks : List Token -> List Token
dropLayoutToks [] = []
dropLayoutToks (t::ts)
  | isLayoutTok t = dropLayoutToks ts
  | otherwise = t :: dropLayoutToks ts

isLayoutTok : Token -> Bool
isLayoutTok TNewline = True
isLayoutTok TIndent = True
isLayoutTok TDedent = True
isLayoutTok TEof = True
isLayoutTok _ = False

-- Group the sorted (path, Loc) edits by uri into a `WorkspaceEdit { changes }`.
-- Sorted by path first (compareUseLoc), so same-path entries are contiguous —
-- one group per file, no `List`-as-map accumulation.
--
-- `puns` is the per-file punned-field table (#963): an edit that lands on a
-- `{ radius }` token becomes `radius = <newName>`, never a bare replacement.
workspaceEditJson : List (String, List ((Int, Int), String)) -> String -> List (String, Loc) -> Json
workspaceEditJson puns newName sorted =
  jObject [("changes", jObject (groupEdits puns newName sorted))]

groupEdits : List (String, List ((Int, Int), String)) -> String -> List (String, Loc) -> List (String, Json)
groupEdits _ _ [] = []
groupEdits puns newName ((p, loc)::rest) =
  let sameRest = spanSamePath p rest
  let tbl = punTableOf p puns
  let edits = map (textEditJson tbl newName) (loc :: map snd (fst sameRest))
  (uriOfPath p, jArray edits) :: groupEdits puns newName (snd sameRest)

-- (edits whose path == p from the front, then the remainder) — contiguous run.
spanSamePath : String -> List (String, Loc) -> (List (String, Loc), List (String, Loc))
spanSamePath _ [] = ([], [])
spanSamePath p ((q, loc)::rest) =
  if q == p then
    let sr = spanSamePath p rest
    ((q, loc) :: fst sr, snd sr)
  else ([], (q, loc)::rest)

textEditJson : List ((Int, Int), String) -> String -> Loc -> Json
textEditJson tbl newName loc = jObject
  [
    ("range", jRangeOfLoc loc),
    ("newText", JString (punAwareText tbl newName loc)),
  ]

-- textDocument/rename → WorkspaceEdit | error (#254 Stage 2). Shares
-- `renameResult` with the `medaka_rename` MCP tool. A refusal (F3) becomes a
-- JSON-RPC error response so the client SHOWS the reason and applies NOTHING —
-- the correct LSP behavior for a rename that cannot be performed safely.
handleRename : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleRename runtimeSrc coreSrc idJson params docs =
  let msg = match requestUri params
    None => renameRefusal "rename requires a document uri"
    Some uri => match docsGet uri docs
      None => renameRefusal "document is not open"
      Some src => renameResult runtimeSrc coreSrc uri src params docs
  if isRenameRefusal msg then
    writeMessage (responseErr idJson (renameReasonOf msg))
  else
    writeMessage (responseMsg idJson msg)

renameReasonOf : Json -> String
renameReasonOf j = match lookup "reason" j
  Some (JString s) => s
  _ => "rename refused"

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
highlightResult src params = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => jArray (highlightRanges src name)
  _ => JNull

-- textDocument/semanticTokens/full → { data: [int] } (delta-encoded).
handleSemanticTokens : Json -> Json -> Docs -> <IO> Unit
handleSemanticTokens idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jObject [("data", jArray (map JInt (semanticTokensData src)))]
  writeMessage (responseMsg idJson result)

-- The `.text` of the LAST element of a contentChanges JArray (Full sync).
lastChangeText : Json -> Option String
lastChangeText (JArray arr)
  | arrayLength arr == 0 = None
  | otherwise = fieldStr "text" (arrayGetUnsafe (arrayLength arr - 1) arr)
lastChangeText _ = None

-- json field accessors specialized to the shapes we read.
fieldOr : String -> Json -> Json
fieldOr key j = match lookup key j
  Some v => v
  None => JNull

fieldStr : String -> Json -> Option String
fieldStr key j = match lookup key j
  Some v => asString v
  None => None

-- The request `id` (number or string), passed through verbatim into responses.
-- We keep it as the raw Json so a string id round-trips unchanged.
requestId : Json -> Json
requestId msg = fieldOr "id" msg

methodOf : Json -> Option String
methodOf msg = fieldStr "method" msg

-- Dispatch one decoded message.  Returns the (possibly updated) Docs store and
-- a flag: True = keep looping, False = `exit` was received (stop).
public export data Step = Step Docs Bool

dispatch : String -> String -> Json -> Docs -> <IO> Step
dispatch runtimeSrc coreSrc msg docs = match methodOf msg
  None => Step docs True
  Some meth => if meth == "initialize" then
    let _ = writeMessage (responseMsg (requestId msg) initializeResult)
    Step docs True
  else
    if meth == "initialized" then Step docs True
    else
      if meth == "textDocument/didOpen" then
        let docs2 = handleDidOpen runtimeSrc coreSrc (fieldOr "params" msg) docs
        Step docs2 True
      else
        if meth == "textDocument/didChange" then
          let docs2 = handleDidChange runtimeSrc coreSrc (fieldOr "params" msg) docs
          Step docs2 True
        else
          if meth == "textDocument/formatting" then
            let _ = handleFormatting (requestId msg) (fieldOr "params" msg) docs
            Step docs True
          else
            if meth == "textDocument/documentSymbol" then
              let _ = handleDocumentSymbol (requestId msg) (fieldOr "params" msg) docs
              Step docs True
            else
              if meth == "textDocument/definition" then
                let _ = handleDefinition (requestId msg) (fieldOr "params" msg) docs
                Step docs True
              else
                if meth == "textDocument/documentHighlight" then
                  let _ = handleHighlight (requestId msg) (fieldOr "params" msg) docs
                  Step docs True
                else
                  if meth == "textDocument/references" then
                    let _ = handleReferences runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                    Step docs True
                  else
                    if meth == "textDocument/hover" then
                      let _ = handleHover runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                      Step docs True
                    else
                      if meth == "textDocument/completion" then
                        let _ = handleCompletion runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                        Step docs True
                      else
                        if meth == "textDocument/inlayHint" then
                          let _ = handleInlayHint runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                          Step docs True
                        else
                          if meth == "textDocument/semanticTokens/full" then
                            let _ = handleSemanticTokens (requestId msg) (fieldOr "params" msg) docs
                            Step docs True
                          else
                            if meth == "shutdown" then
                              let _ = writeMessage (responseMsg (requestId msg) JNull)
                              Step docs True
                            else
                              if meth == "exit" then
                                let _ = logLine "exit (clean shutdown)"
                                Step docs False
                              else
                                if meth == "textDocument/rename" then
                                  let _ = handleRename runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                                  Step docs True
                                else Step docs True  -- unrecognized method — ignore
-- a response/unknown — ignore, keep going

-- stop the loop

-- ── the framed read/dispatch loop ───────────────────────────────────────────

-- Read one full message (headers + body), parse it, dispatch.  Returns the
-- next Step, or a terminal Step on EOF.
serveOnce : String -> String -> Docs -> <IO> Step
serveOnce runtimeSrc coreSrc docs = match readHeaders 0
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
          let step = dispatch runtimeSrc coreSrc msg docs
          let _ = logLine "  handled"
          step
-- input stream closed

-- short read / EOF mid-body

-- malformed JSON body — skip, keep going

-- The session loop: serve messages until `exit` or EOF.
serve : String -> String -> Docs -> <IO> Unit
serve runtimeSrc coreSrc docs = match serveOnce runtimeSrc coreSrc docs
  Step _ False => unit
  Step docs2 True => serve runtimeSrc coreSrc docs2

-- Public entry point for the driver.
export runServer : String -> String -> <IO> Unit
runServer runtimeSrc coreSrc =
  let _ = logLine "=== medaka-lsp session start ==="
  serve runtimeSrc coreSrc emptyDocs

unit : Unit
unit = ()
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "Severity" false) (mem "SevError" false) (mem "SevWarning" false) (mem "analyzeLocated" false) (mem "analyzeProject" false) (mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isIdentStart" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "endsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "mapProg" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramSchemes" false) (mem "checkProgramSchemesWithRuntime" false) (mem "ppSchemeNamed" false) (mem "Scheme" true) (mem "currentLocalSchemes" false) (mem "currentSeedSchemes" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "refindex") ((mem "RefIndex" false) (mem "buildRefIndexProject" false) (mem "binderAt" false) (mem "usesOf" false) (mem "defsOf" false) (mem "allDefKeys" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTypeSig" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DData" false) (mem "DUse" false) (mem "DEffect" false) (mem "DProp" false) (mem "DTest" false) (mem "DBench" false) (mem "DInterface" false) (mem "DImpl" false) (mem "DTypeAlias" false) (mem "DNewtype" false) (mem "DLetGroup" false) (mem "DAttrib" false) (mem "Ty" false) (mem "TyEffect" false) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false) (mem "useMemberLocal" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" false) (mem "DoStmt" true) (mem "FunClause" true) (mem "MethodDefault" true) (mem "Expr" false) (mem "ELoc" false) (mem "EDoOrigin" false) (mem "EVar" false) (mem "ELam" false) (mem "ELet" false) (mem "ELetGroup" false) (mem "EMatch" false) (mem "EBlock" false) (mem "EDo" false) (mem "EGuards" false) (mem "ESetLit" false))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) ())
(DTypeSig true "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EVar "Docs") (EListLit)))
(DTypeSig true "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs"))) (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig false "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jDiagnostic" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jDiagnostic" ((PVar "sev") (PVar "range") (PVar "msg")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EVar "sev"))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "countLines" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countLines" ((PVar "src")) (EApp (EApp (EApp (EVar "countLinesGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "countLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countLinesGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "countLines") (EVar "src"))) (ELit (LInt 0))))
(DTypeSig false "rangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EVar "wholeDocRange") (EVar "src")))
(DTypeSig false "jRangeOfLoc" (TyFun (TyCon "Loc") (TyCon "Json")))
(DFunDef false "jRangeOfLoc" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DTypeSig false "diagToJson" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagToJson" ((PVar "src") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PVar "loc") PWild PWild)) (EApp (EApp (EApp (EVar "jDiagnostic") (EApp (EVar "severityCode") (EVar "sev"))) (EApp (EApp (EVar "rangeOfLoc") (EVar "src")) (EVar "loc"))) (EVar "msg")))
(DTypeSig false "diagnosticsFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "diagnosticsFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PVar "col") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "jDiagnostic") (ELit (LInt 1))) (EVar "r")) (EApp (EVar "parseErrorMessage") (EVar "e"))))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "map") (EApp (EVar "diagToJson") (EVar "src"))) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs"))) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "countLines") (EVar "src")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "offsetOfLineCol" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineCol" ((PVar "arr") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col")))
(DTypeSig false "offsetGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "offsetGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EBlock (DoLet false false (PVar "pos") (EBinOp "+" (EVar "lineStart") (EVar "col"))) (DoLet false false (PVar "lineEnd") (EApp (EApp (EApp (EVar "lineEndFrom") (EVar "arr")) (EVar "len")) (EVar "lineStart"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EVar "pos") (EVar "len"))) (EBinOp "<" (EVar "pos") (EVar "lineEnd"))) (EApp (EVar "Some") (EVar "pos")) (EVar "None")))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "col")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EVar "col")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lineEndFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineEndFrom" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineEndFrom") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineCol") (EVar "arr")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr")))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")))))))))))
(DTypeSig false "posOfOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "posOfOffset" ((PVar "arr") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "posOffGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posOffGo" ((PVar "arr") (PVar "off") (PVar "i") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "off")) (ETuple (EVar "line") (EBinOp "-" (EVar "off") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (ELit (LInt 0)))))))
(DTypeSig false "occGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "occGo" ((PVar "src") (PVar "arr") (PVar "len") (PVar "name") (PVar "nlen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "windowEq") (EVar "src")) (EVar "i")) (EVar "name")) (EVar "nlen")) (EBinOp "||" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr")))))) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "arr")))))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "windowEq" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "windowEq" ((PVar "src") (PVar "i") (PVar "name") (PVar "nlen")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "src")) (EVar "name")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "occToHighlight") (EVar "arr")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "occToHighlight" ((PVar "arr") (PVar "nlen") (PVar "off")) (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "off")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EBinOp "+" (EVar "off") (EVar "nlen"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))))))
(DTypeSig false "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "selRange") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "selRange")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChildLoc" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))))
(DFunDef false "jChildLoc" ((PVar "name") (PVar "kind") (PVar "fallback") (PVar "loc")) (EBlock (DoLet false false (PVar "r") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EVar "jRangeOfLoc") (EVar "l"))) (arm (PCon "None") () (EVar "fallback")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "r")) (EVar "r")) (EListLit)))))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantKids" (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "variantKids" (PWild PWild (PList)) (EListLit))
(DFunDef false "variantKids" ((PVar "fb") (PVar "locs") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EVar "locs")) (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")))) (DoExpr (EBinOp "++" (EApp (EVar "fst") (EVar "step")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EApp (EVar "snd") (EVar "step"))) (EVar "vs"))))))
(DFunDef false "variantKids" ((PVar "fb") (PList) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EListLit)) (EVar "vs"))))
(DFunDef false "variantKids" ((PVar "fb") (PCons (PVar "l") (PVar "ls")) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EVar "ls")) (EVar "vs"))))
(DTypeSig false "fieldKidsStep" (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "fieldKidsStep" (PWild (PVar "locs") (PList)) (ETuple (EListLit) (EVar "locs")))
(DFunDef false "fieldKidsStep" ((PVar "fb") (PList) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EListLit)) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "None")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "fieldKidsStep" ((PVar "fb") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EVar "ls")) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "l")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DTypeSig false "zipKids" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Json")))))))
(DFunDef false "zipKids" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipKids" ((PVar "fb") (PVar "kind") (PList) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "fb")) (EVar "kind")) (EListLit)) (EVar "nms"))))
(DFunDef false "zipKids" ((PVar "fb") (PVar "kind") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "fb")) (EVar "kind")) (EVar "ls")) (EVar "nms"))))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "symbolPartsOfDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "symbolPartsOfDecl" ((PVar "d") (PVar "range") (PVar "childLocs")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 13)) (EVar "True") (EListLit)))) (arm (PCon "DExtern" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "True") (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 12))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n0") (ELit (LInt 12)) (EVar "True") (EVar "kids")))))))) (arm (PCon "DData" PWild (PVar "name") PWild (PVar "variants") PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EVar "variantKids") (EVar "range")) (EVar "childLocs")) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 10)) (EVar "False") (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n") (ELit (LInt 11)) (EVar "False") (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "label") (ELit (LInt 5)) (EVar "False") (EVar "kids")))))) (arm (PCon "DTypeAlias" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 26)) (EVar "False") (EListLit)))) (arm (PCon "DNewtype" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 23)) (EVar "False") (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DBench" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 24)) (EVar "False") (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig true "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EVar "map") (EVar "renderSymbol")) (EApp (EVar "collapseSymbols") (EApp (EApp (EVar "symbolParts") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))))))))
(DData Private "SymRow" () ((variant "SymRow" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "symbolParts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "symbolParts" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "sl") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (DoLet false false (PVar "el") (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "symbolPartsOfDecl") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (EApp (EVar "declPosChildLocs") (EVar "p"))) (arm (PCon "None") () (EApp (EApp (EVar "symbolParts") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "kind") (PVar "clauseLike") (PVar "kids"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "name")) (EVar "kind")) (EVar "sl")) (EVar "el")) (EVar "clauseLike")) (EVar "kids")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EApp (EApp (EVar "symbolParts") (EVar "ds")) (EVar "ps"))))))))
(DFunDef false "symbolParts" (PWild PWild) (EListLit))
(DTypeSig false "collapseSymbols" (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow"))))
(DFunDef false "collapseSymbols" ((PList)) (EListLit))
(DFunDef false "collapseSymbols" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "collapseGo") (EVar "x")) (EVar "xs")))
(DTypeSig false "collapseGo" (TyFun (TyCon "SymRow") (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "collapseGo" ((PVar "cur") (PList)) (EListLit (EVar "cur")))
(DFunDef false "collapseGo" ((PCon "SymRow" (PVar "n0") (PVar "k0") (PVar "s0") (PVar "e0") (PVar "cl0") (PVar "c0") (PVar "nl0")) (PCons (PCon "SymRow" (PVar "n1") (PVar "k1") (PVar "s1") (PVar "e1") (PVar "cl1") (PVar "c1") (PVar "nl1")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n0") (EVar "n1")) (EVar "cl0")) (EVar "cl1")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k1")) (EVar "s0")) (EVar "e1")) (EVar "True")) (EBinOp "++" (EVar "c0") (EVar "c1"))) (EVar "nl0"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k0")) (EVar "s0")) (EVar "e0")) (EVar "cl0")) (EVar "c0")) (EVar "nl0")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n1")) (EVar "k1")) (EVar "s1")) (EVar "e1")) (EVar "cl1")) (EVar "c1")) (EVar "nl1"))) (EVar "rest")))))
(DTypeSig false "renderSymbol" (TyFun (TyCon "SymRow") (TyCon "Json")))
(DFunDef false "renderSymbol" ((PCon "SymRow" (PVar "name") (PVar "kind") (PVar "sl") (PVar "el") PWild (PVar "kids") (PVar "nameLoc"))) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (DoLet false false (PVar "selRange") (EMatch (EVar "nameLoc") (arm (PCon "Some" (PVar "l")) () (EApp (EVar "jRangeOfLoc") (EVar "l"))) (arm (PCon "None") () (EVar "range")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EVar "selRange")) (EVar "kids")))))
(DTypeSig false "declOwnNameMatches" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declOwnNameMatches" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PCon "DData" PWild (PVar "n") PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DImpl" () true) () (EVar "False")) (arm (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DNewtype" PWild (PVar "n") PWild (PVar "c") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DBench" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "declChildNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declChildNames" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "vs") PWild) () (EApp (EVar "dataChildNames") (EVar "vs"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "ms"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "ms"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))
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
(DTypeSig false "definitionRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "definitionRange" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EVar "defZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))))
(DTypeSig false "defZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "defZipDeclMatch") (EVar "d")) (EVar "p")) (EVar "name")) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EVar "j"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "defZip") (EVar "ds")) (EVar "ps")) (EVar "name")))))
(DFunDef false "defZip" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "defZipDeclMatch" (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZipDeclMatch" ((PVar "d") (PVar "p") (PVar "name")) (EIf (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EVar "defZipLocOr") (EApp (EVar "declPosNameLoc") (EVar "p"))) (EVar "p"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EApp (EApp (EVar "defZipLocOr") (EApp (EApp (EVar "locAtIndex") (EVar "k")) (EApp (EVar "declPosChildLocs") (EVar "p")))) (EVar "p")))) (EApp (EApp (EVar "indexOfName") (EVar "name")) (EApp (EVar "declChildNames") (EVar "d")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "defZipLocOr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclPos") (TyCon "Json"))))
(DFunDef false "defZipLocOr" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "jRangeOfLoc") (EVar "l")))
(DFunDef false "defZipLocOr" ((PCon "None") (PVar "p")) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "docSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "docSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls"))))))))
(DTypeSig false "unwrapDecls" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "unwrapDecls" ((PCon "Ok" (PVar "ds"))) (EVar "ds"))
(DFunDef false "unwrapDecls" ((PCon "Err" PWild)) (EListLit))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "stringConcat") (EListLit (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch")))))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig true "typeAtPoint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typeAtPoint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "filePath"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " : ")) (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))))))))))))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))))))
(DTypeSig false "sigLeadingEff" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "sigLeadingEff" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sigLeadingEff" ((PVar "name") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")) (arm (PCon "Some" (PVar "pfx")) () (EVar "pfx")) (arm (PCon "None") () (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EVar "ds")))))
(DTypeSig false "sigLeadingEffOne" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "leadingEffOf") (EVar "ty")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "sigLeadingEffOne" (PWild PWild) (EVar "None"))
(DTypeSig false "leadingEffOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "leadingEffOf" ((PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "renderEffRow") (EVar "labels")) (EVar "tail")) (ELit (LString " "))))))
(DFunDef false "leadingEffOf" (PWild) (EVar "None"))
(DTypeSig false "renderEffRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderEffRow" ((PVar "labels") (PVar "tail")) (EBlock (DoLet false false (PVar "lbls") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderEffAtom")) (EVar "labels")))) (DoLet false false (PVar "body") (EMatch (EVar "tail") (arm (PCon "None") () (EVar "lbls")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "lbls") (ELit (LString ""))) (EVar "v") (EApp (EVar "stringConcat") (EListLit (EVar "lbls") (ELit (LString " | ")) (EVar "v"))))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "<")) (EVar "body") (ELit (LString ">")))))))
(DTypeSig false "renderEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "None"))) (EVar "nm"))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PLit (LString "_"))))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " _")))))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PVar "p")))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " \"")) (EVar "p") (ELit (LString "\"")))))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "offsetOfLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineStart" ((PVar "arr") (PVar "len") (PVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")))
(DTypeSig false "lineStartGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "lineStartGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EApp (EVar "Some") (EVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "n")) (EBlock (DoLet false false (PVar "pl") (EApp (EVar "stringLength") (EVar "p"))) (DoExpr (EIf (EBinOp "==" (EVar "pl") (ELit (LInt 0))) (EVar "True") (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "n")) (EVar "pl")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pl")) (EVar "n")) (EVar "p")))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "n")) (EVar "s"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EVar "map") (ELam ((PVar "own")) (EBinOp "++" (EBinOp "++" (EVar "own") (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "columnAfterName" ((PVar "src") (PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol"))))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "env")))))))
(DTypeSig false "inlayNamePos" (TyFun (TyCon "String") (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "inlayNamePos" ((PVar "src") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "sl") PWild PWild (PVar "ec"))) () (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "sl") (ELit (LInt 1))) (EVar "ec")))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam ((PVar "col")) (ETuple (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EVar "columnAfterName") (EVar "src")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "inlayZip" ((PVar "src") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EVar "inlayNamePos") (EVar "src")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EVar "line")) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "positionLine" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionLine" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "line"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "positionChar" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionChar" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "character"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "responseErr" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "responseErr" ((PVar "idJson") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EUnOp "-" (ELit (LInt 32803))))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "Content-Length:"))) (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "line")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "line")) (EVar "prefix"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line")))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))))) (ELit (LInt 0))) (EVar "False")) (EVar "None")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EVar "not") (EVar "seen"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EVar "seen")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MRecord" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
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
(DFunDef false "isKeywordTok" ((PCon "TRecord")) (EVar "True"))
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
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") (PVar "mode")) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EMatch (EVar "mode") (arm (PCon "MRecord") () (EApp (EVar "Some") (ELit (LInt 4)))) (arm PWild () (EVar "None")))))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TRecord") PWild) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MRecord")) (EVar "MRecord"))
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
(DTypeSig false "semToksOf" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyCon "List") (TyCon "SemTok")))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "e"))) (arm (PTuple (PTuple (PVar "sl") (PVar "sc")) (PTuple (PVar "el") (PVar "ec"))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "referencesProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "renameProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (ELit (LString "0.1.0"))))))))))
(DTypeSig false "publishDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "diagnosticsFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig true "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "dirOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOfPath" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
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
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EApp (EVar "publishEach") (EVar "results")))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "publishEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "publishEach" ((PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EApp (EVar "diagToJson") (ELit (LString "")))) (EVar "ds"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EVar "publishEach") (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "text")) (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "publishDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text"))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDefinition" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EVar "definitionResult") (EVar "uri")) (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig true "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EVar "definitionRange") (EVar "src")) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleReferences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleReferences" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig true "referencesResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "referencesResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "read")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "referenceLocations") (EVar "idx")) (EVar "key")) (EApp (EVar "includeDeclarationOf") (EVar "params"))))))))))) (arm PWild () (EApp (EVar "jArray") (EListLit)))))
(DTypeSig false "referenceLocations" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "referenceLocations" ((PVar "idx") (PVar "key") (PVar "includeDecl")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))) (DoLet false false (PVar "all") (EIf (EVar "includeDecl") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (EVar "uses")) (EVar "uses"))) (DoExpr (EApp (EApp (EVar "map") (EVar "locationJson")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EVar "all"))))))
(DTypeSig false "compareUseLoc" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Ordering"))))
(DFunDef false "compareUseLoc" ((PTuple (PVar "p1") (PCon "Loc" PWild (PVar "sl1") (PVar "sc1") PWild PWild)) (PTuple (PVar "p2") (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") PWild PWild))) (EMatch (EApp (EApp (EVar "compare") (EVar "p1")) (EVar "p2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "sl1")) (EVar "sl2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "sc1")) (EVar "sc2")))))))
(DTypeSig false "locationJson" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Json")))
(DFunDef false "locationJson" ((PTuple (PVar "path") (PVar "loc"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "range")) (EApp (EVar "jRangeOfLoc") (EVar "loc"))))))
(DTypeSig false "includeDeclarationOf" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "includeDeclarationOf" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "context"))) (EVar "params")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "ctx")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "includeDeclaration"))) (EVar "ctx")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "True"))))))
(DTypeSig true "renameResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "renameResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params")) (EApp (EVar "renameNewName") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col")) (PCon "Some" (PVar "newName"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "position is not on an identifier")))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "read")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "no renameable symbol at this position")))) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameEditFor") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "docs"))))))))) (arm PWild () (EApp (EVar "renameRefusal") (ELit (LString "rename requires a position and a newName"))))))
(DTypeSig false "renameNewName" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "renameNewName" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "newName"))) (EVar "params")))
(DTypeSig false "renameRefusal" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "renameRefusal" ((PVar "reason")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "refused")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (EVar "reason"))))))
(DTypeSig true "isRenameRefusal" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "isRenameRefusal" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "refused"))) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PCon "True"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "renameEditFor" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json"))))))))))
(DFunDef false "renameEditFor" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "docs")) (EIf (EApp (EVar "isExternalKey") (EVar "key")) (EApp (EVar "renameRefusal") (ELit (LString "cannot rename a symbol defined outside the project"))) (EMatch (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (arm (PList) () (EApp (EVar "renameRefusal") (ELit (LString "cannot rename a symbol defined outside the project")))) (arm (PVar "defs") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameEditChecked") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "defs")) (EVar "docs"))))))
(DTypeSig false "renameEditChecked" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))))
(DFunDef false "renameEditChecked" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "defs") (PVar "docs")) (EMatch (EApp (EApp (EVar "newNameIllegal") (EVar "key")) (EVar "newName")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "all") (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EBinOp "++" (EVar "defs") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))))) (DoLet false false (PVar "files") (EApp (EVar "affectedPaths") (EVar "all"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameCollides") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "files")) (EVar "docs")) (EApp (EVar "renameRefusal") (EApp (EVar "stringConcat") (EListLit (ELit (LString "renaming to `")) (EVar "newName") (ELit (LString "` would collide with an existing binder"))))) (EMatch (EApp (EApp (EApp (EVar "renameIndexAmbiguous") (EVar "idx")) (EVar "key")) (EVar "files")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "renameBrokenProjectFile") (EVar "projectDir")) (EVar "key")) (EVar "docs")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "renameEmitVerified") (EVar "key")) (EVar "newName")) (EVar "all")) (EVar "docs"))))))))))))
(DTypeSig false "affectedPaths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "affectedPaths" ((PList)) (EListLit))
(DFunDef false "affectedPaths" ((PCons (PTuple (PVar "p") PWild) (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "affectedPaths") (EApp (EVar "snd") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))))))
(DTypeSig false "pathIsIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "pathIsIn" (PWild (PList)) (EVar "False"))
(DFunDef false "pathIsIn" ((PVar "p") (PCons (PVar "q") (PVar "qs"))) (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "q")) (EApp (EApp (EVar "pathIsIn") (EVar "p")) (EVar "qs"))))
(DTypeSig false "renameEmitVerified" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "renameEmitVerified" ((PVar "key") (PVar "newName") (PVar "all") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "oldName"))) () (EIf (EApp (EApp (EApp (EVar "allSpansSpell") (EVar "oldName")) (EVar "all")) (EVar "docs")) (EApp (EApp (EApp (EVar "workspaceEditJson") (EApp (EApp (EVar "punTablesFor") (EVar "all")) (EVar "docs"))) (EVar "newName")) (EVar "all")) (EApp (EVar "renameRefusal") (EApp (EVar "stringConcat") (EListLit (ELit (LString "the reference index reports an occurrence of `")) (EVar "oldName") (ELit (LString "` at a span that does not spell it — refusing rather than emit an edit that would corrupt the source")))))))))
(DTypeSig false "allSpansSpell" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "allSpansSpell" (PWild (PList) PWild) (EVar "True"))
(DFunDef false "allSpansSpell" ((PVar "oldName") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest")) (PVar "docs")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "spanSpells") (EVar "oldName")) (EVar "p")) (EVar "loc")) (EVar "docs")) (EApp (EApp (EApp (EVar "allSpansSpell") (EVar "oldName")) (EVar "rest")) (EVar "docs"))))
(DTypeSig false "spanSpells" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "spanSpells" ((PVar "oldName") (PVar "p") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "docs")) (EIf (EBinOp "||" (EBinOp "!=" (EVar "sl") (EVar "el")) (EBinOp "!=" (EBinOp "-" (EVar "ec") (EVar "sc")) (EApp (EVar "stringLength") (EVar "oldName")))) (EVar "False") (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (arm (PCon "Some" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "oldName"))) (arm (PCon "None") () (EVar "False")))))))
(DTypeSig false "renameSrcOf" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "renameSrcOf" ((PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "p"))) (EVar "docs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "p")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "punFieldsOfSrc" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punFieldsOfSrc" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EVar "punFieldsOfDecls") (EVar "decls")))))
(DTypeSig false "punFieldsOfDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punFieldsOfDecls" ((PVar "decls")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "recNames") (EApp (EVar "recordCtorNames") (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "punVisit") (EVar "acc")) (EVar "recNames"))) (EVar "decls"))) (DoExpr (EBinOp "++" (EApp (EVar "declParamPuns") (EVar "decls")) (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "punVisit" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "punVisit" ((PVar "acc") (PVar "recNames") (PVar "e")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectExprPuns") (EVar "acc")) (EVar "recNames")) (EVar "e"))) (DoExpr (EVar "e"))))
(DTypeSig false "recordCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordCtorNames" ((PVar "decls")) (EApp (EApp (EVar "flatMapL") (EVar "recordCtorNamesOf")) (EVar "decls")))
(DTypeSig false "recordCtorNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordCtorNamesOf" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "vs") PWild) () (EApp (EVar "namedVariantCtors") (EVar "vs"))) (arm PWild () (EListLit))))
(DTypeSig false "namedVariantCtors" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "namedVariantCtors" ((PList)) (EListLit))
(DFunDef false "namedVariantCtors" ((PCons (PCon "Variant" (PVar "n") (PCon "ConNamed" PWild PWild)) (PVar "vs"))) (EBinOp "::" (EVar "n") (EApp (EVar "namedVariantCtors") (EVar "vs"))))
(DFunDef false "namedVariantCtors" ((PCons PWild (PVar "vs"))) (EApp (EVar "namedVariantCtors") (EVar "vs")))
(DTypeSig false "collectExprPuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "collectExprPuns" ((PVar "acc") (PVar "recNames") (PCon "ESetLit" (PVar "name") (PVar "items"))) (EIf (EApp (EApp (EApp (EVar "punRecordSetLit") (EVar "recNames")) (EVar "name")) (EVar "items")) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "punItemSpan")) (EVar "items"))) (ELit LUnit)))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELam" (PVar "ps") PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELet" PWild PWild (PVar "p") PWild PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EVar "patPuns") (EVar "p"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "armPuns")) (EVar "arms"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "guardArmPuns")) (EVar "arms"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "stmtPuns")) (EVar "stmts"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "stmtPuns")) (EVar "stmts"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELetGroup" (PVar "binds") PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "letBindPuns")) (EVar "binds"))))
(DFunDef false "collectExprPuns" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "pushPuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "pushPuns" ((PVar "acc") (PList)) (ELit LUnit))
(DFunDef false "pushPuns" ((PVar "acc") (PVar "found")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "++" (EVar "found") (EFieldAccess (EVar "acc") "value"))))
(DTypeSig false "punRecordSetLit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "punRecordSetLit" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "punRecordSetLit" ((PVar "recNames") (PVar "name") (PVar "items")) (EBinOp "&&" (EApp (EApp (EVar "anyName") (EVar "recNames")) (EVar "name")) (EApp (EVar "allBareVars") (EVar "items"))))
(DTypeSig false "allBareVars" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "allBareVars" ((PList)) (EVar "True"))
(DFunDef false "allBareVars" ((PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EVar "punItemSpan") (EVar "e")) (arm (PList) () (EVar "False")) (arm PWild () (EApp (EVar "allBareVars") (EVar "rest")))))
(DTypeSig false "punItemSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punItemSpan" ((PCon "ELoc" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (PCon "EVar" (PVar "n")))) (EListLit (ETuple (ETuple (EVar "sl") (EVar "sc")) (EVar "n"))))
(DFunDef false "punItemSpan" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "punItemSpan") (EVar "e")))
(DFunDef false "punItemSpan" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "punItemSpan") (EVar "e")))
(DFunDef false "punItemSpan" (PWild) (EListLit))
(DTypeSig false "armPuns" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "armPuns" ((PCon "Arm" (PVar "p") (PVar "gs") PWild)) (EBinOp "++" (EApp (EVar "patPuns") (EVar "p")) (EApp (EApp (EVar "flatMapL") (EVar "guardPuns")) (EVar "gs"))))
(DTypeSig false "guardArmPuns" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "guardArmPuns" ((PCon "GuardArm" (PVar "gs") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "guardPuns")) (EVar "gs")))
(DTypeSig false "guardPuns" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "guardPuns" ((PCon "GBind" (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "guardPuns" (PWild) (EListLit))
(DTypeSig false "stmtPuns" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "stmtPuns" ((PCon "DoBind" (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "stmtPuns" ((PCon "DoLet" PWild PWild (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "stmtPuns" (PWild) (EListLit))
(DTypeSig false "letBindPuns" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "letBindPuns" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMapL") (EVar "clausePuns")) (EVar "clauses")))
(DTypeSig false "clausePuns" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "clausePuns" ((PCon "FunClause" (PVar "ps") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DTypeSig false "declParamPuns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "declParamPuns" ((PVar "decls")) (EApp (EApp (EVar "flatMapL") (EVar "declParamPunsOf")) (EVar "decls")))
(DTypeSig false "declParamPunsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "declParamPunsOf" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild PWild (PVar "ps") PWild) () (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "flatMapL") (EVar "letBindPuns")) (EVar "binds"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "flatMapL") (EVar "implMethodPuns")) (EVar "ms"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "flatMapL") (EVar "ifaceMethodPuns")) (EVar "ms"))) (arm PWild () (EListLit))))
(DTypeSig false "implMethodPuns" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "implMethodPuns" ((PCon "ImplMethod" PWild (PVar "ps") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DTypeSig false "ifaceMethodPuns" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "ifaceMethodPuns" ((PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") PWild)))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "ifaceMethodPuns" (PWild) (EListLit))
(DTypeSig false "patPuns" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "patPuns" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "recFieldPuns")) (EVar "fields")))
(DFunDef false "patPuns" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patPuns") (EVar "a")) (EApp (EVar "patPuns") (EVar "b"))))
(DFunDef false "patPuns" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "patPuns" (PWild) (EListLit))
(DTypeSig false "recFieldPuns" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "recFieldPuns" ((PCon "RecPatField" (PVar "name") (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (PCon "None"))) (EListLit (ETuple (ETuple (EVar "sl") (EVar "sc")) (EVar "name"))))
(DFunDef false "recFieldPuns" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patPuns") (EVar "p")))
(DTypeSig false "flatMapL" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "flatMapL" (PWild (PList)) (EListLit))
(DFunDef false "flatMapL" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "flatMapL") (EVar "f")) (EVar "xs"))))
(DTypeSig false "punTablesFor" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))))))
(DFunDef false "punTablesFor" ((PList) PWild) (EListLit))
(DFunDef false "punTablesFor" ((PCons (PTuple (PVar "p") PWild) (PVar "rest")) (PVar "docs")) (EBlock (DoLet false false (PVar "sameRest") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoLet false false (PVar "tbl") (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "punFieldsOfSrc") (EVar "src"))))) (DoExpr (EBinOp "::" (ETuple (EVar "p") (EVar "tbl")) (EApp (EApp (EVar "punTablesFor") (EApp (EVar "snd") (EVar "sameRest"))) (EVar "docs"))))))
(DTypeSig false "punTableOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "punTableOf" (PWild (PList)) (EListLit))
(DFunDef false "punTableOf" ((PVar "p") (PCons (PTuple (PVar "q") (PVar "tbl")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "q")) (EVar "tbl") (EApp (EApp (EVar "punTableOf") (EVar "p")) (EVar "rest"))))
(DTypeSig false "punAwareText" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String")))))
(DFunDef false "punAwareText" ((PVar "tbl") (PVar "newName") (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "punFieldAt") (EVar "tbl")) (EVar "sl")) (EVar "sc")) (arm (PCon "Some" (PVar "field")) () (EApp (EVar "stringConcat") (EListLit (EVar "field") (ELit (LString " = ")) (EVar "newName")))) (arm (PCon "None") () (EVar "newName"))))
(DTypeSig false "punFieldAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "punFieldAt" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "punFieldAt" ((PCons (PTuple (PTuple (PVar "l") (PVar "c")) (PVar "field")) (PVar "rest")) (PVar "sl") (PVar "sc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "sl")) (EBinOp "==" (EVar "c") (EVar "sc"))) (EApp (EVar "Some") (EVar "field")) (EApp (EApp (EApp (EVar "punFieldAt") (EVar "rest")) (EVar "sl")) (EVar "sc"))))
(DTypeSig false "isExternalKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExternalKey" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (EVar "keyTab")) (EVar "key")) (arm (PCons (PVar "m") PWild) () (EBinOp "==" (EVar "m") (ELit (LString "?ext")))) (arm PWild () (EVar "False"))))
(DTypeSig false "keyTab" (TyCon "Char"))
(DFunDef false "keyTab" () (ELit (LChar "\t")))
(DTypeSig false "keyNsName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "keyNsName" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (EVar "keyTab")) (EVar "key")) (arm (PCons PWild (PCons (PVar "ns") (PCons (PVar "name") PWild))) () (EApp (EVar "Some") (ETuple (EVar "ns") (EVar "name")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameCollides" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "renameCollides" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "files") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "_name"))) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EApp (EVar "allDefKeys") (EVar "idx"))) (EVar "ns")) (EVar "newName")) (EApp (EApp (EVar "preludeDeclares") (EVar "coreSrc")) (EVar "newName"))) (EApp (EApp (EVar "preludeDeclares") (EVar "runtimeSrc")) (EVar "newName"))) (EApp (EApp (EApp (EApp (EVar "anyKeyNamedInFiles") (EVar "idx")) (EApp (EVar "allDefKeys") (EVar "idx"))) (EVar "newName")) (EVar "files"))) (EApp (EApp (EApp (EApp (EVar "anyImportBindsIn") (EVar "newName")) (EVar "projectDir")) (EVar "files")) (EVar "docs"))))))
(DTypeSig false "anyDefKeyMatches" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "anyDefKeyMatches" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "anyDefKeyMatches" ((PCons (PVar "k") (PVar "ks")) (PVar "ns") (PVar "newName")) (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "Some" (PTuple (PVar "ns2") (PVar "nm2"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "ns2") (EVar "ns")) (EBinOp "==" (EVar "nm2") (EVar "newName"))) (EVar "True") (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EVar "ks")) (EVar "ns")) (EVar "newName")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EVar "ks")) (EVar "ns")) (EVar "newName")))))
(DTypeSig false "anyKeyNamedInFiles" (TyFun (TyCon "RefIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyKeyNamedInFiles" (PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyKeyNamedInFiles" ((PVar "idx") (PCons (PVar "k") (PVar "ks")) (PVar "newName") (PVar "files")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "keyNameIs") (EVar "k")) (EVar "newName")) (EApp (EApp (EVar "anyPathIn") (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "k"))) (EVar "files"))) (EApp (EApp (EApp (EApp (EVar "anyKeyNamedInFiles") (EVar "idx")) (EVar "ks")) (EVar "newName")) (EVar "files"))))
(DTypeSig false "keyNameIs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "keyNameIs" ((PVar "k") (PVar "name")) (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "anyPathIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyPathIn" ((PList) PWild) (EVar "False"))
(DFunDef false "anyPathIn" ((PCons (PTuple (PVar "p") PWild) (PVar "rest")) (PVar "files")) (EBinOp "||" (EApp (EApp (EVar "pathIsIn") (EVar "p")) (EVar "files")) (EApp (EApp (EVar "anyPathIn") (EVar "rest")) (EVar "files"))))
(DTypeSig false "anyImportBindsIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "anyImportBindsIn" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyImportBindsIn" ((PVar "newName") (PVar "projectDir") (PCons (PVar "p") (PVar "ps")) (PVar "docs")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "fileImportsBind") (EVar "newName")) (EVar "projectDir")) (EVar "p")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "anyImportBindsIn") (EVar "newName")) (EVar "projectDir")) (EVar "ps")) (EVar "docs"))))
(DTypeSig false "fileImportsBind" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "fileImportsBind" ((PVar "newName") (PVar "projectDir") (PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EApp (EApp (EVar "anyImportDeclBinds") (EVar "newName")) (EVar "projectDir")) (EVar "decls")) (EVar "docs")))))))
(DTypeSig false "anyImportDeclBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "anyImportDeclBinds" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyImportDeclBinds" ((PVar "newName") (PVar "projectDir") (PCons (PVar "d") (PVar "ds")) (PVar "docs")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "importDeclBinds") (EVar "newName")) (EVar "projectDir")) (EApp (EVar "innerDecl") (EVar "d"))) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "anyImportDeclBinds") (EVar "newName")) (EVar "projectDir")) (EVar "ds")) (EVar "docs"))))
(DTypeSig false "importDeclBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "importDeclBinds" ((PVar "newName") (PVar "projectDir") (PCon "DUse" PWild (PVar "path") PWild) (PVar "docs")) (EApp (EApp (EApp (EApp (EVar "usePathBinds") (EVar "newName")) (EVar "projectDir")) (EVar "path")) (EVar "docs")))
(DFunDef false "importDeclBinds" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "usePathBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "usePathBinds" ((PVar "newName") PWild (PCon "UseGroup" PWild (PVar "members")) PWild) (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EVar "members"))) (EVar "newName")))
(DFunDef false "usePathBinds" ((PVar "newName") (PVar "projectDir") (PCon "UseWild" (PVar "mods")) (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "importedModuleSrc") (EVar "projectDir")) (EVar "mods")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "preludeDeclares") (EVar "src")) (EVar "newName")))))
(DFunDef false "usePathBinds" ((PVar "newName") PWild (PCon "UseAlias" PWild (PVar "alias")) PWild) (EBinOp "==" (EVar "alias") (EVar "newName")))
(DFunDef false "usePathBinds" (PWild PWild (PCon "UseName" PWild) PWild) (EVar "False"))
(DTypeSig false "importedModuleSrc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "importedModuleSrc" ((PVar "projectDir") (PVar "mods") (PVar "docs")) (EBlock (DoLet false false (PVar "rel") (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "mods")) (ELit (LString ".mdk")))) (DoExpr (EMatch (EApp (EApp (EVar "renameSrcOf") (EApp (EApp (EVar "joinPath") (EVar "projectDir")) (EVar "rel"))) (EVar "docs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "renameSrcOf") (EApp (EApp (EVar "joinPath") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (EVar "rel"))) (EVar "docs")))))))
(DTypeSig false "renameIndexAmbiguous" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "renameIndexAmbiguous" ((PVar "idx") (PVar "key") (PVar "files")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "name"))) () (EBlock (DoLet false false (PVar "cands") (EBinOp "++" (EApp (EVar "allDefKeys") (EVar "idx")) (EApp (EVar "extNamesakeKeys") (EVar "name")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "the reference index holds a second binder also named `")) (EVar "name") (ELit (LString "` with an occurrence in `")) (EVar "f") (ELit (LString "`, so the occurrences of this one cannot be told apart from that one's — refusing rather than emit an edit set that may be incomplete; disambiguate the two names first, or edit by hand")))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstAmbiguousFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "files"))))))))
(DTypeSig false "firstAmbiguousFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "firstAmbiguousFile" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstAmbiguousFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PVar "cands") (PCons (PVar "f") (PVar "fs"))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyNamesakeInFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "f")) (EApp (EVar "Some") (EVar "f")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstAmbiguousFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "fs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyNamesakeInFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "anyNamesakeInFile" (PWild PWild PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyNamesakeInFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PCons (PVar "k") (PVar "ks")) (PVar "f")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "namesakeHitsFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "k")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyNamesakeInFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "ks")) (EVar "f"))))
(DTypeSig false "namesakeHitsFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "namesakeHitsFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PVar "k") (PVar "f")) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "ns2") (PVar "n2"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n2") (EVar "name")) (EUnOp "!" (EApp (EApp (EVar "benignNamesake") (EVar "ns")) (EVar "ns2")))) (EApp (EApp (EVar "anyPathIn") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "k")) (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "k")))) (EListLit (EVar "f")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "benignNamesake" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "benignNamesake" ((PLit (LString "field")) PWild) (EVar "True"))
(DFunDef false "benignNamesake" (PWild (PLit (LString "field"))) (EVar "True"))
(DFunDef false "benignNamesake" ((PLit (LString "local")) (PLit (LString "local"))) (EVar "True"))
(DFunDef false "benignNamesake" (PWild PWild) (EVar "False"))
(DTypeSig false "extNamesakeKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "extNamesakeKeys" ((PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "ns")) (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (ELit (LString "?ext")) (EVar "ns") (EVar "name"))))) (EListLit (ELit (LString "val")) (ELit (LString "local")) (ELit (LString "method")) (ELit (LString "ty")) (ELit (LString "ctor")) (ELit (LString "iface")))))
(DTypeSig false "renameBrokenProjectFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "renameBrokenProjectFile" ((PVar "projectDir") (PVar "key") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "name"))) () (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "p") (ELit (LString "` is under the project root, mentions `")) (EVar "name") (ELit (LString "`, and does not parse — its occurrences are missing from the reference index, so this rename would silently skip them; fix that file's parse error first")))))) (EApp (EApp (EApp (EVar "firstBrokenMentioning") (EVar "name")) (EApp (EVar "projectMdkFiles") (EVar "projectDir"))) (EVar "docs"))))))
(DTypeSig false "firstBrokenMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "firstBrokenMentioning" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstBrokenMentioning" ((PVar "name") (PCons (PVar "p") (PVar "ps")) (PVar "docs")) (EIf (EApp (EApp (EApp (EVar "brokenAndMentions") (EVar "name")) (EVar "p")) (EVar "docs")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EApp (EVar "firstBrokenMentioning") (EVar "name")) (EVar "ps")) (EVar "docs"))))
(DTypeSig false "brokenAndMentions" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "brokenAndMentions" ((PVar "name") (PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EBinOp "&&" (EApp (EApp (EVar "srcMentionsName") (EVar "name")) (EVar "src")) (EApp (EVar "srcFailsToParse") (EVar "src"))))))
(DTypeSig false "srcFailsToParse" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "srcFailsToParse" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" PWild) () (EVar "False"))))
(DTypeSig false "srcMentionsName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "srcMentionsName" ((PVar "name") (PVar "src")) (EApp (EApp (EVar "anyNameTok") (EVar "name")) (EApp (EVar "fst") (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")))))
(DTypeSig false "anyNameTok" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "anyNameTok" (PWild (PList)) (EVar "False"))
(DFunDef false "anyNameTok" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EApp (EApp (EVar "tokSpells") (EVar "t")) (EVar "name")) (EApp (EApp (EVar "anyNameTok") (EVar "name")) (EVar "ts"))))
(DTypeSig false "tokSpells" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "tokSpells" ((PCon "TIdent" (PVar "n")) (PVar "name")) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "tokSpells" ((PCon "TUpper" (PVar "n")) (PVar "name")) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "tokSpells" (PWild PWild) (EVar "False"))
(DTypeSig false "projectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "projectMdkFiles" ((PVar "root")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "collectMdkUnder") (EVar "acc")) (EVar "root"))) (DoExpr (EApp (EApp (EVar "sortBy") (EVar "compare")) (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "collectMdkUnder" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "collectMdkUnder" ((PVar "acc") (PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "collectMdkEntries") (EVar "acc")) (EVar "dir")) (EVar "entries")))))
(DTypeSig false "collectMdkEntries" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkEntries" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectMdkEntries" ((PVar "acc") (PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectMdkEntry") (EVar "acc")) (EVar "dir")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "collectMdkEntries") (EVar "acc")) (EVar "dir")) (EVar "rest")))))
(DTypeSig false "collectMdkEntry" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkEntry" ((PVar "acc") (PVar "dir") (PVar "n")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectMdkPath") (EVar "acc")) (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n"))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "collectMdkPath" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkPath" ((PVar "acc") (PVar "full") (PVar "n")) (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "collectMdkUnder") (EVar "acc")) (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (EVar "full") (EFieldAccess (EVar "acc") "value"))) (ELit LUnit)))))
(DTypeSig false "preludeDeclares" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "preludeDeclares" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EVar "anyDeclDeclares") (EVar "decls")) (EVar "name")))))
(DTypeSig false "anyDeclDeclares" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyDeclDeclares" ((PList) PWild) (EVar "False"))
(DFunDef false "anyDeclDeclares" ((PCons (PVar "d") (PVar "ds")) (PVar "name")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EVar "declChildNames") (EVar "d"))) (EVar "name"))) (EApp (EApp (EVar "anyDeclDeclares") (EVar "ds")) (EVar "name"))))
(DTypeSig false "newNameIllegal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newNameIllegal" ((PVar "key") (PVar "newName")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "_name"))) () (EMatch (EApp (EVar "firstChar") (EVar "newName")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "the new name is empty")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "||" (EUnOp "!" (EApp (EVar "isIdentStart") (EVar "c"))) (EUnOp "!" (EApp (EVar "allIdentChars") (EVar "newName")))) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` is not a legal Medaka identifier"))))) (EIf (EApp (EVar "newNameReserved") (EVar "newName")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` is reserved by the language (a keyword, or `_`) and cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — choose a different name"))))) (EIf (EApp (EVar "uppercaseNs") (EVar "ns")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — it must start with an uppercase letter")))))) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — an uppercase name is a type/constructor, not a value"))))) (EVar "None"))))))))))
(DTypeSig false "uppercaseNs" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "uppercaseNs" ((PVar "ns")) (EBinOp "||" (EBinOp "==" (EVar "ns") (ELit (LString "ty"))) (EBinOp "==" (EVar "ns") (ELit (LString "ctor")))))
(DTypeSig false "nsNoun" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nsNoun" ((PLit (LString "val"))) (ELit (LString "value")))
(DFunDef false "nsNoun" ((PLit (LString "local"))) (ELit (LString "local binding")))
(DFunDef false "nsNoun" ((PLit (LString "method"))) (ELit (LString "method")))
(DFunDef false "nsNoun" ((PLit (LString "field"))) (ELit (LString "record field")))
(DFunDef false "nsNoun" ((PLit (LString "ty"))) (ELit (LString "type")))
(DFunDef false "nsNoun" ((PLit (LString "ctor"))) (ELit (LString "constructor")))
(DFunDef false "nsNoun" (PWild) (ELit (LString "binding")))
(DTypeSig false "allIdentChars" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allIdentChars" ((PVar "s")) (EApp (EApp (EVar "allIdentCharsGo") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "allIdentCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allIdentCharsGo" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "True") (EIf (EUnOp "!" (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "allIdentCharsGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstChar" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "firstChar" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))))))
(DTypeSig false "newNameReserved" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "newNameReserved" ((PVar "s")) (EMatch (EApp (EVar "significantToks") (EVar "s")) (arm (PList (PCon "TIdent" (PVar "n"))) () (EBinOp "!=" (EVar "n") (EVar "s"))) (arm (PList (PCon "TUpper" (PVar "n"))) () (EBinOp "!=" (EVar "n") (EVar "s"))) (arm PWild () (EVar "True"))))
(DTypeSig false "significantToks" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "significantToks" ((PVar "s")) (EApp (EVar "dropLayoutToks") (EApp (EVar "fst") (EApp (EVar "tokenizeWithOffsetPairs") (EVar "s")))))
(DTypeSig false "dropLayoutToks" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "dropLayoutToks" ((PList)) (EListLit))
(DFunDef false "dropLayoutToks" ((PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EVar "isLayoutTok") (EVar "t")) (EApp (EVar "dropLayoutToks") (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "t") (EApp (EVar "dropLayoutToks") (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isLayoutTok" (PWild) (EVar "False"))
(DTypeSig false "workspaceEditJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyCon "Json")))))
(DFunDef false "workspaceEditJson" ((PVar "puns") (PVar "newName") (PVar "sorted")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "changes")) (EApp (EVar "jObject") (EApp (EApp (EApp (EVar "groupEdits") (EVar "puns")) (EVar "newName")) (EVar "sorted")))))))
(DTypeSig false "groupEdits" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))))
(DFunDef false "groupEdits" (PWild PWild (PList)) (EListLit))
(DFunDef false "groupEdits" ((PVar "puns") (PVar "newName") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sameRest") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoLet false false (PVar "tbl") (EApp (EApp (EVar "punTableOf") (EVar "p")) (EVar "puns"))) (DoLet false false (PVar "edits") (EApp (EApp (EVar "map") (EApp (EApp (EVar "textEditJson") (EVar "tbl")) (EVar "newName"))) (EBinOp "::" (EVar "loc") (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "fst") (EVar "sameRest")))))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "uriOfPath") (EVar "p")) (EApp (EVar "jArray") (EVar "edits"))) (EApp (EApp (EApp (EVar "groupEdits") (EVar "puns")) (EVar "newName")) (EApp (EVar "snd") (EVar "sameRest")))))))
(DTypeSig false "spanSamePath" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))))
(DFunDef false "spanSamePath" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanSamePath" ((PVar "p") (PCons (PTuple (PVar "q") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "q") (EVar "p")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "q") (EVar "loc")) (EApp (EVar "fst") (EVar "sr"))) (EApp (EVar "snd") (EVar "sr"))))) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "q") (EVar "loc")) (EVar "rest")))))
(DTypeSig false "textEditJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Json")))))
(DFunDef false "textEditJson" ((PVar "tbl") (PVar "newName") (PVar "loc")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "jRangeOfLoc") (EVar "loc"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EApp (EApp (EApp (EVar "punAwareText") (EVar "tbl")) (EVar "newName")) (EVar "loc")))))))
(DTypeSig false "handleRename" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleRename" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "msg") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "rename requires a document uri")))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "document is not open")))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EIf (EApp (EVar "isRenameRefusal") (EVar "msg")) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseErr") (EVar "idJson")) (EApp (EVar "renameReasonOf") (EVar "msg")))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "msg")))))))
(DTypeSig false "renameReasonOf" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "renameReasonOf" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "reason"))) (EVar "j")) (arm (PCon "Some" (PCon "JString" (PVar "s"))) () (EVar "s")) (arm PWild () (ELit (LString "rename refused")))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JInt")) (EApp (EVar "semanticTokensData") (EVar "src")))))))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "initializeResult")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDefinition") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/references"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleReferences") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/rename"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleRename") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "emptyDocs")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "Severity" false) (mem "SevError" false) (mem "SevWarning" false) (mem "analyzeLocated" false) (mem "analyzeProject" false) (mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isIdentStart" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "endsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "mapProg" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramSchemes" false) (mem "checkProgramSchemesWithRuntime" false) (mem "ppSchemeNamed" false) (mem "Scheme" true) (mem "currentLocalSchemes" false) (mem "currentSeedSchemes" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "refindex") ((mem "RefIndex" false) (mem "buildRefIndexProject" false) (mem "binderAt" false) (mem "usesOf" false) (mem "defsOf" false) (mem "allDefKeys" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTypeSig" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DData" false) (mem "DUse" false) (mem "DEffect" false) (mem "DProp" false) (mem "DTest" false) (mem "DBench" false) (mem "DInterface" false) (mem "DImpl" false) (mem "DTypeAlias" false) (mem "DNewtype" false) (mem "DLetGroup" false) (mem "DAttrib" false) (mem "Ty" false) (mem "TyEffect" false) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false) (mem "useMemberLocal" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" false) (mem "DoStmt" true) (mem "FunClause" true) (mem "MethodDefault" true) (mem "Expr" false) (mem "ELoc" false) (mem "EDoOrigin" false) (mem "EVar" false) (mem "ELam" false) (mem "ELet" false) (mem "ELetGroup" false) (mem "EMatch" false) (mem "EBlock" false) (mem "EDo" false) (mem "EGuards" false) (mem "ESetLit" false))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) ())
(DTypeSig true "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EVar "Docs") (EListLit)))
(DTypeSig true "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs"))) (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig false "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jDiagnostic" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jDiagnostic" ((PVar "sev") (PVar "range") (PVar "msg")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EVar "sev"))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "countLines" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countLines" ((PVar "src")) (EApp (EApp (EApp (EVar "countLinesGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "countLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countLinesGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "countLines") (EVar "src"))) (ELit (LInt 0))))
(DTypeSig false "rangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EVar "wholeDocRange") (EVar "src")))
(DTypeSig false "jRangeOfLoc" (TyFun (TyCon "Loc") (TyCon "Json")))
(DFunDef false "jRangeOfLoc" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DTypeSig false "diagToJson" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagToJson" ((PVar "src") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PVar "loc") PWild PWild)) (EApp (EApp (EApp (EVar "jDiagnostic") (EApp (EVar "severityCode") (EVar "sev"))) (EApp (EApp (EVar "rangeOfLoc") (EVar "src")) (EVar "loc"))) (EVar "msg")))
(DTypeSig false "diagnosticsFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "diagnosticsFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PVar "col") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "jDiagnostic") (ELit (LInt 1))) (EVar "r")) (EApp (EVar "parseErrorMessage") (EVar "e"))))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EMethodRef "map") (EApp (EVar "diagToJson") (EVar "src"))) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs"))) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "countLines") (EVar "src")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "offsetOfLineCol" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineCol" ((PVar "arr") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col")))
(DTypeSig false "offsetGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "offsetGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EBlock (DoLet false false (PVar "pos") (EBinOp "+" (EVar "lineStart") (EVar "col"))) (DoLet false false (PVar "lineEnd") (EApp (EApp (EApp (EVar "lineEndFrom") (EVar "arr")) (EVar "len")) (EVar "lineStart"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EVar "pos") (EVar "len"))) (EBinOp "<" (EVar "pos") (EVar "lineEnd"))) (EApp (EVar "Some") (EVar "pos")) (EVar "None")))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "col")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EVar "col")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lineEndFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lineEndFrom" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineEndFrom") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineCol") (EVar "arr")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr")))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")))))))))))
(DTypeSig false "posOfOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "posOfOffset" ((PVar "arr") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "posOffGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posOffGo" ((PVar "arr") (PVar "off") (PVar "i") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "off")) (ETuple (EVar "line") (EBinOp "-" (EVar "off") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (ELit (LInt 0)))))))
(DTypeSig false "occGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "occGo" ((PVar "src") (PVar "arr") (PVar "len") (PVar "name") (PVar "nlen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "windowEq") (EVar "src")) (EVar "i")) (EVar "name")) (EVar "nlen")) (EBinOp "||" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr")))))) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "arr")))))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "windowEq" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "windowEq" ((PVar "src") (PVar "i") (PVar "name") (PVar "nlen")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "src")) (EVar "name")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "occToHighlight") (EVar "arr")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "occToHighlight" ((PVar "arr") (PVar "nlen") (PVar "off")) (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "off")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EBinOp "+" (EVar "off") (EVar "nlen"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))))))
(DTypeSig false "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "selRange") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "selRange")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChildLoc" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))))
(DFunDef false "jChildLoc" ((PVar "name") (PVar "kind") (PVar "fallback") (PVar "loc")) (EBlock (DoLet false false (PVar "r") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EVar "jRangeOfLoc") (EVar "l"))) (arm (PCon "None") () (EVar "fallback")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "r")) (EVar "r")) (EListLit)))))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantKids" (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "variantKids" (PWild PWild (PList)) (EListLit))
(DFunDef false "variantKids" ((PVar "fb") (PVar "locs") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EVar "locs")) (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")))) (DoExpr (EBinOp "++" (EApp (EVar "fst") (EVar "step")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EApp (EVar "snd") (EVar "step"))) (EVar "vs"))))))
(DFunDef false "variantKids" ((PVar "fb") (PList) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EListLit)) (EVar "vs"))))
(DFunDef false "variantKids" ((PVar "fb") (PCons (PVar "l") (PVar "ls")) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EVar "variantKids") (EVar "fb")) (EVar "ls")) (EVar "vs"))))
(DTypeSig false "fieldKidsStep" (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "fieldKidsStep" (PWild (PVar "locs") (PList)) (ETuple (EListLit) (EVar "locs")))
(DFunDef false "fieldKidsStep" ((PVar "fb") (PList) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EListLit)) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "None")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DFunDef false "fieldKidsStep" ((PVar "fb") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "fb")) (EVar "ls")) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "l")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest"))))))
(DTypeSig false "zipKids" (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Json")))))))
(DFunDef false "zipKids" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipKids" ((PVar "fb") (PVar "kind") (PList) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "fb")) (EVar "kind")) (EListLit)) (EVar "nms"))))
(DFunDef false "zipKids" ((PVar "fb") (PVar "kind") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "fb")) (EVar "kind")) (EVar "ls")) (EVar "nms"))))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "symbolPartsOfDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "symbolPartsOfDecl" ((PVar "d") (PVar "range") (PVar "childLocs")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 13)) (EVar "True") (EListLit)))) (arm (PCon "DExtern" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "True") (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 12))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n0") (ELit (LInt 12)) (EVar "True") (EVar "kids")))))))) (arm (PCon "DData" PWild (PVar "name") PWild (PVar "variants") PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EVar "variantKids") (EVar "range")) (EVar "childLocs")) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 10)) (EVar "False") (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n") (ELit (LInt 11)) (EVar "False") (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "label") (ELit (LInt 5)) (EVar "False") (EVar "kids")))))) (arm (PCon "DTypeAlias" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 26)) (EVar "False") (EListLit)))) (arm (PCon "DNewtype" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 23)) (EVar "False") (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DBench" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 24)) (EVar "False") (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig true "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EMethodRef "map") (EVar "renderSymbol")) (EApp (EVar "collapseSymbols") (EApp (EApp (EVar "symbolParts") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))))))))
(DData Private "SymRow" () ((variant "SymRow" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "symbolParts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "symbolParts" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "sl") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (DoLet false false (PVar "el") (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "symbolPartsOfDecl") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (EApp (EVar "declPosChildLocs") (EVar "p"))) (arm (PCon "None") () (EApp (EApp (EVar "symbolParts") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "kind") (PVar "clauseLike") (PVar "kids"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "name")) (EVar "kind")) (EVar "sl")) (EVar "el")) (EVar "clauseLike")) (EVar "kids")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EApp (EApp (EVar "symbolParts") (EVar "ds")) (EVar "ps"))))))))
(DFunDef false "symbolParts" (PWild PWild) (EListLit))
(DTypeSig false "collapseSymbols" (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow"))))
(DFunDef false "collapseSymbols" ((PList)) (EListLit))
(DFunDef false "collapseSymbols" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "collapseGo") (EVar "x")) (EVar "xs")))
(DTypeSig false "collapseGo" (TyFun (TyCon "SymRow") (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "collapseGo" ((PVar "cur") (PList)) (EListLit (EVar "cur")))
(DFunDef false "collapseGo" ((PCon "SymRow" (PVar "n0") (PVar "k0") (PVar "s0") (PVar "e0") (PVar "cl0") (PVar "c0") (PVar "nl0")) (PCons (PCon "SymRow" (PVar "n1") (PVar "k1") (PVar "s1") (PVar "e1") (PVar "cl1") (PVar "c1") (PVar "nl1")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n0") (EVar "n1")) (EVar "cl0")) (EVar "cl1")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k1")) (EVar "s0")) (EVar "e1")) (EVar "True")) (EBinOp "++" (EVar "c0") (EVar "c1"))) (EVar "nl0"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k0")) (EVar "s0")) (EVar "e0")) (EVar "cl0")) (EVar "c0")) (EVar "nl0")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n1")) (EVar "k1")) (EVar "s1")) (EVar "e1")) (EVar "cl1")) (EVar "c1")) (EVar "nl1"))) (EVar "rest")))))
(DTypeSig false "renderSymbol" (TyFun (TyCon "SymRow") (TyCon "Json")))
(DFunDef false "renderSymbol" ((PCon "SymRow" (PVar "name") (PVar "kind") (PVar "sl") (PVar "el") PWild (PVar "kids") (PVar "nameLoc"))) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (DoLet false false (PVar "selRange") (EMatch (EVar "nameLoc") (arm (PCon "Some" (PVar "l")) () (EApp (EVar "jRangeOfLoc") (EVar "l"))) (arm (PCon "None") () (EVar "range")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EVar "selRange")) (EVar "kids")))))
(DTypeSig false "declOwnNameMatches" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declOwnNameMatches" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PCon "DData" PWild (PVar "n") PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DInterface" ((rf "name" (PVar "n"))) true) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PRec "DImpl" () true) () (EVar "False")) (arm (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DNewtype" PWild (PVar "n") PWild (PVar "c") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DBench" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "declChildNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declChildNames" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "vs") PWild) () (EApp (EVar "dataChildNames") (EVar "vs"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "ms"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "ms"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (arm PWild () (EListLit))))
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
(DTypeSig false "definitionRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "definitionRange" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EVar "defZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))))
(DTypeSig false "defZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "defZipDeclMatch") (EVar "d")) (EVar "p")) (EVar "name")) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EVar "j"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "defZip") (EVar "ds")) (EVar "ps")) (EVar "name")))))
(DFunDef false "defZip" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "defZipDeclMatch" (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZipDeclMatch" ((PVar "d") (PVar "p") (PVar "name")) (EIf (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EVar "defZipLocOr") (EApp (EVar "declPosNameLoc") (EVar "p"))) (EVar "p"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EApp (EApp (EVar "defZipLocOr") (EApp (EApp (EVar "locAtIndex") (EVar "k")) (EApp (EVar "declPosChildLocs") (EVar "p")))) (EVar "p")))) (EApp (EApp (EVar "indexOfName") (EVar "name")) (EApp (EVar "declChildNames") (EVar "d")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "defZipLocOr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclPos") (TyCon "Json"))))
(DFunDef false "defZipLocOr" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "jRangeOfLoc") (EVar "l")))
(DFunDef false "defZipLocOr" ((PCon "None") (PVar "p")) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "docSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "docSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls"))))))))
(DTypeSig false "unwrapDecls" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "unwrapDecls" ((PCon "Ok" (PVar "ds"))) (EVar "ds"))
(DFunDef false "unwrapDecls" ((PCon "Err" PWild)) (EListLit))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "stringConcat") (EListLit (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch")))))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig true "typeAtPoint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typeAtPoint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "filePath") (PVar "src") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "name")) () (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "filePath"))) (DoLet false false (PVar "docs") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "src")) (EVar "emptyDocs"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " : ")) (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))))))))))))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))))))
(DTypeSig false "sigLeadingEff" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "sigLeadingEff" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sigLeadingEff" ((PVar "name") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")) (arm (PCon "Some" (PVar "pfx")) () (EVar "pfx")) (arm (PCon "None") () (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EVar "ds")))))
(DTypeSig false "sigLeadingEffOne" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "leadingEffOf") (EVar "ty")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "sigLeadingEffOne" (PWild PWild) (EVar "None"))
(DTypeSig false "leadingEffOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "leadingEffOf" ((PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "renderEffRow") (EVar "labels")) (EVar "tail")) (ELit (LString " "))))))
(DFunDef false "leadingEffOf" (PWild) (EVar "None"))
(DTypeSig false "renderEffRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderEffRow" ((PVar "labels") (PVar "tail")) (EBlock (DoLet false false (PVar "lbls") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderEffAtom")) (EVar "labels")))) (DoLet false false (PVar "body") (EMatch (EVar "tail") (arm (PCon "None") () (EVar "lbls")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "lbls") (ELit (LString ""))) (EVar "v") (EApp (EVar "stringConcat") (EListLit (EVar "lbls") (ELit (LString " | ")) (EVar "v"))))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "<")) (EVar "body") (ELit (LString ">")))))))
(DTypeSig false "renderEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "None"))) (EVar "nm"))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PLit (LString "_"))))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " _")))))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PVar "p")))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " \"")) (EVar "p") (ELit (LString "\"")))))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "offsetOfLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineStart" ((PVar "arr") (PVar "len") (PVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")))
(DTypeSig false "lineStartGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "lineStartGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EApp (EVar "Some") (EVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "n")) (EBlock (DoLet false false (PVar "pl") (EApp (EVar "stringLength") (EVar "p"))) (DoExpr (EIf (EBinOp "==" (EVar "pl") (ELit (LInt 0))) (EVar "True") (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "n")) (EVar "pl")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pl")) (EVar "n")) (EVar "p")))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "n")) (EVar "s"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "own")) (EBinOp "++" (EBinOp "++" (EVar "own") (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "columnAfterName" ((PVar "src") (PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol"))))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "env")))))))
(DTypeSig false "inlayNamePos" (TyFun (TyCon "String") (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "inlayNamePos" ((PVar "src") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "sl") PWild PWild (PVar "ec"))) () (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "sl") (ELit (LInt 1))) (EVar "ec")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "col")) (ETuple (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))) (EVar "col")))) (EApp (EApp (EVar "columnAfterName") (EVar "src")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1))))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "inlayZip" ((PVar "src") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EVar "inlayNamePos") (EVar "src")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EVar "line")) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "positionLine" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionLine" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "line"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "positionChar" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionChar" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "character"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "responseErr" (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "responseErr" ((PVar "idJson") (PVar "message")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "error")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JInt") (EUnOp "-" (ELit (LInt 32803))))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "message")))))))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "Content-Length:"))) (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "line")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "line")) (EVar "prefix"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line")))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))))) (ELit (LInt 0))) (EVar "False")) (EVar "None")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EVar "not") (EVar "seen"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EVar "seen")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MRecord" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
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
(DFunDef false "isKeywordTok" ((PCon "TRecord")) (EVar "True"))
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
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") (PVar "mode")) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EMatch (EVar "mode") (arm (PCon "MRecord") () (EApp (EVar "Some") (ELit (LInt 4)))) (arm PWild () (EVar "None")))))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TRecord") PWild) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MRecord")) (EVar "MRecord"))
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
(DTypeSig false "semToksOf" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyCon "List") (TyCon "SemTok")))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "e"))) (arm (PTuple (PTuple (PVar "sl") (PVar "sc")) (PTuple (PVar "el") (PVar "ec"))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "referencesProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "renameProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (ELit (LString "0.1.0"))))))))))
(DTypeSig false "publishDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "diagnosticsFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig true "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "dirOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOfPath" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
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
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EApp (EVar "publishEach") (EVar "results")))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "publishEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "publishEach" ((PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "diagToJson") (ELit (LString "")))) (EVar "ds"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EVar "publishEach") (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "text")) (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "publishDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text"))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDefinition" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EVar "definitionResult") (EVar "uri")) (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig true "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EVar "definitionRange") (EVar "src")) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleReferences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleReferences" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "referencesResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig true "referencesResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "referencesResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "read")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "jArray") (EListLit))) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "referenceLocations") (EVar "idx")) (EVar "key")) (EApp (EVar "includeDeclarationOf") (EVar "params"))))))))))) (arm PWild () (EApp (EVar "jArray") (EListLit)))))
(DTypeSig false "referenceLocations" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "referenceLocations" ((PVar "idx") (PVar "key") (PVar "includeDecl")) (EBlock (DoLet false false (PVar "uses") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))) (DoLet false false (PVar "all") (EIf (EVar "includeDecl") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (EVar "uses")) (EVar "uses"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "locationJson")) (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EDictApp "all"))))))
(DTypeSig false "compareUseLoc" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Ordering"))))
(DFunDef false "compareUseLoc" ((PTuple (PVar "p1") (PCon "Loc" PWild (PVar "sl1") (PVar "sc1") PWild PWild)) (PTuple (PVar "p2") (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") PWild PWild))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "p1")) (EVar "p2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "sl1")) (EVar "sl2")) (arm (PCon "Lt") () (EVar "Lt")) (arm (PCon "Gt") () (EVar "Gt")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "sc1")) (EVar "sc2")))))))
(DTypeSig false "locationJson" (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyCon "Json")))
(DFunDef false "locationJson" ((PTuple (PVar "path") (PVar "loc"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EApp (EVar "uriOfPath") (EVar "path")))) (ETuple (ELit (LString "range")) (EApp (EVar "jRangeOfLoc") (EVar "loc"))))))
(DTypeSig false "includeDeclarationOf" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "includeDeclarationOf" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "context"))) (EVar "params")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "ctx")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "includeDeclaration"))) (EVar "ctx")) (arm (PCon "Some" (PCon "JBool" (PVar "b"))) () (EVar "b")) (arm PWild () (EVar "True"))))))
(DTypeSig true "renameResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "renameResult" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params")) (EApp (EVar "renameNewName") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col")) (PCon "Some" (PVar "newName"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "position is not on an identifier")))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "idx") (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "read")) (EVar "projectDir")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "binderAt") (EVar "idx")) (EVar "rootFile")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EVar "col")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "no renameable symbol at this position")))) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameEditFor") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "docs"))))))))) (arm PWild () (EApp (EVar "renameRefusal") (ELit (LString "rename requires a position and a newName"))))))
(DTypeSig false "renameNewName" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "renameNewName" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "newName"))) (EVar "params")))
(DTypeSig false "renameRefusal" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "renameRefusal" ((PVar "reason")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "refused")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "reason")) (EApp (EVar "JString") (EVar "reason"))))))
(DTypeSig true "isRenameRefusal" (TyFun (TyCon "Json") (TyCon "Bool")))
(DFunDef false "isRenameRefusal" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "refused"))) (EVar "j")) (arm (PCon "Some" (PCon "JBool" (PCon "True"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "renameEditFor" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json"))))))))))
(DFunDef false "renameEditFor" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "docs")) (EIf (EApp (EVar "isExternalKey") (EVar "key")) (EApp (EVar "renameRefusal") (ELit (LString "cannot rename a symbol defined outside the project"))) (EMatch (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "key")) (arm (PList) () (EApp (EVar "renameRefusal") (ELit (LString "cannot rename a symbol defined outside the project")))) (arm (PVar "defs") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameEditChecked") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "defs")) (EVar "docs"))))))
(DTypeSig false "renameEditChecked" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))))
(DFunDef false "renameEditChecked" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "defs") (PVar "docs")) (EMatch (EApp (EApp (EVar "newNameIllegal") (EVar "key")) (EVar "newName")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "all") (EApp (EApp (EVar "sortBy") (EVar "compareUseLoc")) (EBinOp "++" (EVar "defs") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))))) (DoLet false false (PVar "files") (EApp (EVar "affectedPaths") (EDictApp "all"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameCollides") (EVar "idx")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "projectDir")) (EVar "key")) (EVar "newName")) (EVar "files")) (EVar "docs")) (EApp (EVar "renameRefusal") (EApp (EVar "stringConcat") (EListLit (ELit (LString "renaming to `")) (EVar "newName") (ELit (LString "` would collide with an existing binder"))))) (EMatch (EApp (EApp (EApp (EVar "renameIndexAmbiguous") (EVar "idx")) (EVar "key")) (EVar "files")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "renameBrokenProjectFile") (EVar "projectDir")) (EVar "key")) (EVar "docs")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "renameRefusal") (EVar "reason"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "renameEmitVerified") (EVar "key")) (EVar "newName")) (EDictApp "all")) (EVar "docs"))))))))))))
(DTypeSig false "affectedPaths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "affectedPaths" ((PList)) (EListLit))
(DFunDef false "affectedPaths" ((PCons (PTuple (PVar "p") PWild) (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "affectedPaths") (EApp (EVar "snd") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))))))
(DTypeSig false "pathIsIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "pathIsIn" (PWild (PList)) (EVar "False"))
(DFunDef false "pathIsIn" ((PVar "p") (PCons (PVar "q") (PVar "qs"))) (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "q")) (EApp (EApp (EVar "pathIsIn") (EVar "p")) (EVar "qs"))))
(DTypeSig false "renameEmitVerified" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))
(DFunDef false "renameEmitVerified" ((PVar "key") (PVar "newName") (PVar "all") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "oldName"))) () (EIf (EApp (EApp (EApp (EVar "allSpansSpell") (EVar "oldName")) (EDictApp "all")) (EVar "docs")) (EApp (EApp (EApp (EVar "workspaceEditJson") (EApp (EApp (EVar "punTablesFor") (EDictApp "all")) (EVar "docs"))) (EVar "newName")) (EDictApp "all")) (EApp (EVar "renameRefusal") (EApp (EVar "stringConcat") (EListLit (ELit (LString "the reference index reports an occurrence of `")) (EVar "oldName") (ELit (LString "` at a span that does not spell it — refusing rather than emit an edit that would corrupt the source")))))))))
(DTypeSig false "allSpansSpell" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "allSpansSpell" (PWild (PList) PWild) (EVar "True"))
(DFunDef false "allSpansSpell" ((PVar "oldName") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest")) (PVar "docs")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "spanSpells") (EVar "oldName")) (EVar "p")) (EVar "loc")) (EVar "docs")) (EApp (EApp (EApp (EVar "allSpansSpell") (EVar "oldName")) (EVar "rest")) (EVar "docs"))))
(DTypeSig false "spanSpells" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "spanSpells" ((PVar "oldName") (PVar "p") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "docs")) (EIf (EBinOp "||" (EBinOp "!=" (EVar "sl") (EVar "el")) (EBinOp "!=" (EBinOp "-" (EVar "ec") (EVar "sc")) (EApp (EVar "stringLength") (EVar "oldName")))) (EVar "False") (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (arm (PCon "Some" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "oldName"))) (arm (PCon "None") () (EVar "False")))))))
(DTypeSig false "renameSrcOf" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "renameSrcOf" ((PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "p"))) (EVar "docs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "p")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "punFieldsOfSrc" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punFieldsOfSrc" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EVar "punFieldsOfDecls") (EVar "decls")))))
(DTypeSig false "punFieldsOfDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punFieldsOfDecls" ((PVar "decls")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "recNames") (EApp (EVar "recordCtorNames") (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "punVisit") (EVar "acc")) (EVar "recNames"))) (EVar "decls"))) (DoExpr (EBinOp "++" (EApp (EVar "declParamPuns") (EVar "decls")) (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "punVisit" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "punVisit" ((PVar "acc") (PVar "recNames") (PVar "e")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectExprPuns") (EVar "acc")) (EVar "recNames")) (EVar "e"))) (DoExpr (EVar "e"))))
(DTypeSig false "recordCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordCtorNames" ((PVar "decls")) (EApp (EApp (EVar "flatMapL") (EVar "recordCtorNamesOf")) (EVar "decls")))
(DTypeSig false "recordCtorNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordCtorNamesOf" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "vs") PWild) () (EApp (EVar "namedVariantCtors") (EVar "vs"))) (arm PWild () (EListLit))))
(DTypeSig false "namedVariantCtors" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "namedVariantCtors" ((PList)) (EListLit))
(DFunDef false "namedVariantCtors" ((PCons (PCon "Variant" (PVar "n") (PCon "ConNamed" PWild PWild)) (PVar "vs"))) (EBinOp "::" (EVar "n") (EApp (EVar "namedVariantCtors") (EVar "vs"))))
(DFunDef false "namedVariantCtors" ((PCons PWild (PVar "vs"))) (EApp (EVar "namedVariantCtors") (EVar "vs")))
(DTypeSig false "collectExprPuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "collectExprPuns" ((PVar "acc") (PVar "recNames") (PCon "ESetLit" (PVar "name") (PVar "items"))) (EIf (EApp (EApp (EApp (EVar "punRecordSetLit") (EVar "recNames")) (EVar "name")) (EVar "items")) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "punItemSpan")) (EVar "items"))) (ELit LUnit)))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELam" (PVar "ps") PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELet" PWild PWild (PVar "p") PWild PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EVar "patPuns") (EVar "p"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "armPuns")) (EVar "arms"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "guardArmPuns")) (EVar "arms"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "stmtPuns")) (EVar "stmts"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "stmtPuns")) (EVar "stmts"))))
(DFunDef false "collectExprPuns" ((PVar "acc") PWild (PCon "ELetGroup" (PVar "binds") PWild)) (EApp (EApp (EVar "pushPuns") (EVar "acc")) (EApp (EApp (EVar "flatMapL") (EVar "letBindPuns")) (EVar "binds"))))
(DFunDef false "collectExprPuns" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "pushPuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "pushPuns" ((PVar "acc") (PList)) (ELit LUnit))
(DFunDef false "pushPuns" ((PVar "acc") (PVar "found")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "++" (EVar "found") (EFieldAccess (EVar "acc") "value"))))
(DTypeSig false "punRecordSetLit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "punRecordSetLit" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "punRecordSetLit" ((PVar "recNames") (PVar "name") (PVar "items")) (EBinOp "&&" (EApp (EApp (EVar "anyName") (EVar "recNames")) (EVar "name")) (EApp (EVar "allBareVars") (EVar "items"))))
(DTypeSig false "allBareVars" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "allBareVars" ((PList)) (EVar "True"))
(DFunDef false "allBareVars" ((PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EVar "punItemSpan") (EVar "e")) (arm (PList) () (EVar "False")) (arm PWild () (EApp (EVar "allBareVars") (EVar "rest")))))
(DTypeSig false "punItemSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "punItemSpan" ((PCon "ELoc" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (PCon "EVar" (PVar "n")))) (EListLit (ETuple (ETuple (EVar "sl") (EVar "sc")) (EVar "n"))))
(DFunDef false "punItemSpan" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "punItemSpan") (EVar "e")))
(DFunDef false "punItemSpan" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "punItemSpan") (EVar "e")))
(DFunDef false "punItemSpan" (PWild) (EListLit))
(DTypeSig false "armPuns" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "armPuns" ((PCon "Arm" (PVar "p") (PVar "gs") PWild)) (EBinOp "++" (EApp (EVar "patPuns") (EVar "p")) (EApp (EApp (EVar "flatMapL") (EVar "guardPuns")) (EVar "gs"))))
(DTypeSig false "guardArmPuns" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "guardArmPuns" ((PCon "GuardArm" (PVar "gs") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "guardPuns")) (EVar "gs")))
(DTypeSig false "guardPuns" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "guardPuns" ((PCon "GBind" (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "guardPuns" (PWild) (EListLit))
(DTypeSig false "stmtPuns" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "stmtPuns" ((PCon "DoBind" (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "stmtPuns" ((PCon "DoLet" PWild PWild (PVar "p") PWild)) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "stmtPuns" (PWild) (EListLit))
(DTypeSig false "letBindPuns" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "letBindPuns" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMapL") (EVar "clausePuns")) (EVar "clauses")))
(DTypeSig false "clausePuns" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "clausePuns" ((PCon "FunClause" (PVar "ps") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DTypeSig false "declParamPuns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "declParamPuns" ((PVar "decls")) (EApp (EApp (EVar "flatMapL") (EVar "declParamPunsOf")) (EVar "decls")))
(DTypeSig false "declParamPunsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "declParamPunsOf" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild PWild (PVar "ps") PWild) () (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "flatMapL") (EVar "letBindPuns")) (EVar "binds"))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "flatMapL") (EVar "implMethodPuns")) (EVar "ms"))) (arm (PRec "DInterface" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "flatMapL") (EVar "ifaceMethodPuns")) (EVar "ms"))) (arm PWild () (EListLit))))
(DTypeSig false "implMethodPuns" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "implMethodPuns" ((PCon "ImplMethod" PWild (PVar "ps") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DTypeSig false "ifaceMethodPuns" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "ifaceMethodPuns" ((PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") PWild)))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "ifaceMethodPuns" (PWild) (EListLit))
(DTypeSig false "patPuns" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "patPuns" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMapL") (EVar "recFieldPuns")) (EVar "fields")))
(DFunDef false "patPuns" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patPuns") (EVar "a")) (EApp (EVar "patPuns") (EVar "b"))))
(DFunDef false "patPuns" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMapL") (EVar "patPuns")) (EVar "ps")))
(DFunDef false "patPuns" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patPuns") (EVar "p")))
(DFunDef false "patPuns" (PWild) (EListLit))
(DTypeSig false "recFieldPuns" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "recFieldPuns" ((PCon "RecPatField" (PVar "name") (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (PCon "None"))) (EListLit (ETuple (ETuple (EVar "sl") (EVar "sc")) (EVar "name"))))
(DFunDef false "recFieldPuns" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patPuns") (EVar "p")))
(DTypeSig false "flatMapL" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "flatMapL" (PWild (PList)) (EListLit))
(DFunDef false "flatMapL" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "flatMapL") (EVar "f")) (EVar "xs"))))
(DTypeSig false "punTablesFor" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))))))))
(DFunDef false "punTablesFor" ((PList) PWild) (EListLit))
(DFunDef false "punTablesFor" ((PCons (PTuple (PVar "p") PWild) (PVar "rest")) (PVar "docs")) (EBlock (DoLet false false (PVar "sameRest") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoLet false false (PVar "tbl") (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "punFieldsOfSrc") (EVar "src"))))) (DoExpr (EBinOp "::" (ETuple (EVar "p") (EVar "tbl")) (EApp (EApp (EVar "punTablesFor") (EApp (EVar "snd") (EVar "sameRest"))) (EVar "docs"))))))
(DTypeSig false "punTableOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "punTableOf" (PWild (PList)) (EListLit))
(DFunDef false "punTableOf" ((PVar "p") (PCons (PTuple (PVar "q") (PVar "tbl")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "q")) (EVar "tbl") (EApp (EApp (EVar "punTableOf") (EVar "p")) (EVar "rest"))))
(DTypeSig false "punAwareText" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String")))))
(DFunDef false "punAwareText" ((PVar "tbl") (PVar "newName") (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "punFieldAt") (EVar "tbl")) (EVar "sl")) (EVar "sc")) (arm (PCon "Some" (PVar "field")) () (EApp (EVar "stringConcat") (EListLit (EVar "field") (ELit (LString " = ")) (EVar "newName")))) (arm (PCon "None") () (EVar "newName"))))
(DTypeSig false "punFieldAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "punFieldAt" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "punFieldAt" ((PCons (PTuple (PTuple (PVar "l") (PVar "c")) (PVar "field")) (PVar "rest")) (PVar "sl") (PVar "sc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "sl")) (EBinOp "==" (EVar "c") (EVar "sc"))) (EApp (EVar "Some") (EVar "field")) (EApp (EApp (EApp (EVar "punFieldAt") (EVar "rest")) (EVar "sl")) (EVar "sc"))))
(DTypeSig false "isExternalKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExternalKey" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (EVar "keyTab")) (EVar "key")) (arm (PCons (PVar "m") PWild) () (EBinOp "==" (EVar "m") (ELit (LString "?ext")))) (arm PWild () (EVar "False"))))
(DTypeSig false "keyTab" (TyCon "Char"))
(DFunDef false "keyTab" () (ELit (LChar "\t")))
(DTypeSig false "keyNsName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "keyNsName" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (EVar "keyTab")) (EVar "key")) (arm (PCons PWild (PCons (PVar "ns") (PCons (PVar "name") PWild))) () (EApp (EVar "Some") (ETuple (EVar "ns") (EVar "name")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameCollides" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "renameCollides" ((PVar "idx") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "projectDir") (PVar "key") (PVar "newName") (PVar "files") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "_name"))) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EApp (EVar "allDefKeys") (EVar "idx"))) (EVar "ns")) (EVar "newName")) (EApp (EApp (EVar "preludeDeclares") (EVar "coreSrc")) (EVar "newName"))) (EApp (EApp (EVar "preludeDeclares") (EVar "runtimeSrc")) (EVar "newName"))) (EApp (EApp (EApp (EApp (EVar "anyKeyNamedInFiles") (EVar "idx")) (EApp (EVar "allDefKeys") (EVar "idx"))) (EVar "newName")) (EVar "files"))) (EApp (EApp (EApp (EApp (EVar "anyImportBindsIn") (EVar "newName")) (EVar "projectDir")) (EVar "files")) (EVar "docs"))))))
(DTypeSig false "anyDefKeyMatches" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "anyDefKeyMatches" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "anyDefKeyMatches" ((PCons (PVar "k") (PVar "ks")) (PVar "ns") (PVar "newName")) (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "Some" (PTuple (PVar "ns2") (PVar "nm2"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "ns2") (EVar "ns")) (EBinOp "==" (EVar "nm2") (EVar "newName"))) (EVar "True") (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EVar "ks")) (EVar "ns")) (EVar "newName")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "anyDefKeyMatches") (EVar "ks")) (EVar "ns")) (EVar "newName")))))
(DTypeSig false "anyKeyNamedInFiles" (TyFun (TyCon "RefIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "anyKeyNamedInFiles" (PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyKeyNamedInFiles" ((PVar "idx") (PCons (PVar "k") (PVar "ks")) (PVar "newName") (PVar "files")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "keyNameIs") (EVar "k")) (EVar "newName")) (EApp (EApp (EVar "anyPathIn") (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "k"))) (EVar "files"))) (EApp (EApp (EApp (EApp (EVar "anyKeyNamedInFiles") (EVar "idx")) (EVar "ks")) (EVar "newName")) (EVar "files"))))
(DTypeSig false "keyNameIs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "keyNameIs" ((PVar "k") (PVar "name")) (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "anyPathIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "anyPathIn" ((PList) PWild) (EVar "False"))
(DFunDef false "anyPathIn" ((PCons (PTuple (PVar "p") PWild) (PVar "rest")) (PVar "files")) (EBinOp "||" (EApp (EApp (EVar "pathIsIn") (EVar "p")) (EVar "files")) (EApp (EApp (EVar "anyPathIn") (EVar "rest")) (EVar "files"))))
(DTypeSig false "anyImportBindsIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "anyImportBindsIn" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyImportBindsIn" ((PVar "newName") (PVar "projectDir") (PCons (PVar "p") (PVar "ps")) (PVar "docs")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "fileImportsBind") (EVar "newName")) (EVar "projectDir")) (EVar "p")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "anyImportBindsIn") (EVar "newName")) (EVar "projectDir")) (EVar "ps")) (EVar "docs"))))
(DTypeSig false "fileImportsBind" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "fileImportsBind" ((PVar "newName") (PVar "projectDir") (PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EApp (EApp (EVar "anyImportDeclBinds") (EVar "newName")) (EVar "projectDir")) (EVar "decls")) (EVar "docs")))))))
(DTypeSig false "anyImportDeclBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "anyImportDeclBinds" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyImportDeclBinds" ((PVar "newName") (PVar "projectDir") (PCons (PVar "d") (PVar "ds")) (PVar "docs")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "importDeclBinds") (EVar "newName")) (EVar "projectDir")) (EApp (EVar "innerDecl") (EVar "d"))) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "anyImportDeclBinds") (EVar "newName")) (EVar "projectDir")) (EVar "ds")) (EVar "docs"))))
(DTypeSig false "importDeclBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "importDeclBinds" ((PVar "newName") (PVar "projectDir") (PCon "DUse" PWild (PVar "path") PWild) (PVar "docs")) (EApp (EApp (EApp (EApp (EVar "usePathBinds") (EVar "newName")) (EVar "projectDir")) (EVar "path")) (EVar "docs")))
(DFunDef false "importDeclBinds" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "usePathBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "usePathBinds" ((PVar "newName") PWild (PCon "UseGroup" PWild (PVar "members")) PWild) (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EVar "members"))) (EVar "newName")))
(DFunDef false "usePathBinds" ((PVar "newName") (PVar "projectDir") (PCon "UseWild" (PVar "mods")) (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "importedModuleSrc") (EVar "projectDir")) (EVar "mods")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "preludeDeclares") (EVar "src")) (EVar "newName")))))
(DFunDef false "usePathBinds" ((PVar "newName") PWild (PCon "UseAlias" PWild (PVar "alias")) PWild) (EBinOp "==" (EVar "alias") (EVar "newName")))
(DFunDef false "usePathBinds" (PWild PWild (PCon "UseName" PWild) PWild) (EVar "False"))
(DTypeSig false "importedModuleSrc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "importedModuleSrc" ((PVar "projectDir") (PVar "mods") (PVar "docs")) (EBlock (DoLet false false (PVar "rel") (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "mods")) (ELit (LString ".mdk")))) (DoExpr (EMatch (EApp (EApp (EVar "renameSrcOf") (EApp (EApp (EVar "joinPath") (EVar "projectDir")) (EVar "rel"))) (EVar "docs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "renameSrcOf") (EApp (EApp (EVar "joinPath") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (EVar "rel"))) (EVar "docs")))))))
(DTypeSig false "renameIndexAmbiguous" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "renameIndexAmbiguous" ((PVar "idx") (PVar "key") (PVar "files")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "name"))) () (EBlock (DoLet false false (PVar "cands") (EBinOp "++" (EApp (EVar "allDefKeys") (EVar "idx")) (EApp (EVar "extNamesakeKeys") (EVar "name")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "the reference index holds a second binder also named `")) (EVar "name") (ELit (LString "` with an occurrence in `")) (EVar "f") (ELit (LString "`, so the occurrences of this one cannot be told apart from that one's — refusing rather than emit an edit set that may be incomplete; disambiguate the two names first, or edit by hand")))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstAmbiguousFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "files"))))))))
(DTypeSig false "firstAmbiguousFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "firstAmbiguousFile" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstAmbiguousFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PVar "cands") (PCons (PVar "f") (PVar "fs"))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyNamesakeInFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "f")) (EApp (EVar "Some") (EVar "f")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstAmbiguousFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "cands")) (EVar "fs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyNamesakeInFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "anyNamesakeInFile" (PWild PWild PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyNamesakeInFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PCons (PVar "k") (PVar "ks")) (PVar "f")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "namesakeHitsFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "k")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyNamesakeInFile") (EVar "idx")) (EVar "key")) (EVar "ns")) (EVar "name")) (EVar "ks")) (EVar "f"))))
(DTypeSig false "namesakeHitsFile" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "namesakeHitsFile" ((PVar "idx") (PVar "key") (PVar "ns") (PVar "name") (PVar "k") (PVar "f")) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EVar "keyNsName") (EVar "k")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "ns2") (PVar "n2"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n2") (EVar "name")) (EUnOp "!" (EApp (EApp (EVar "benignNamesake") (EVar "ns")) (EVar "ns2")))) (EApp (EApp (EVar "anyPathIn") (EBinOp "++" (EApp (EApp (EVar "defsOf") (EVar "idx")) (EVar "k")) (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "k")))) (EListLit (EVar "f")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "benignNamesake" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "benignNamesake" ((PLit (LString "field")) PWild) (EVar "True"))
(DFunDef false "benignNamesake" (PWild (PLit (LString "field"))) (EVar "True"))
(DFunDef false "benignNamesake" ((PLit (LString "local")) (PLit (LString "local"))) (EVar "True"))
(DFunDef false "benignNamesake" (PWild PWild) (EVar "False"))
(DTypeSig false "extNamesakeKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "extNamesakeKeys" ((PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ns")) (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (ELit (LString "?ext")) (EVar "ns") (EVar "name"))))) (EListLit (ELit (LString "val")) (ELit (LString "local")) (ELit (LString "method")) (ELit (LString "ty")) (ELit (LString "ctor")) (ELit (LString "iface")))))
(DTypeSig false "renameBrokenProjectFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "renameBrokenProjectFile" ((PVar "projectDir") (PVar "key") (PVar "docs")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "_ns") (PVar "name"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "p") (ELit (LString "` is under the project root, mentions `")) (EVar "name") (ELit (LString "`, and does not parse — its occurrences are missing from the reference index, so this rename would silently skip them; fix that file's parse error first")))))) (EApp (EApp (EApp (EVar "firstBrokenMentioning") (EVar "name")) (EApp (EVar "projectMdkFiles") (EVar "projectDir"))) (EVar "docs"))))))
(DTypeSig false "firstBrokenMentioning" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "firstBrokenMentioning" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstBrokenMentioning" ((PVar "name") (PCons (PVar "p") (PVar "ps")) (PVar "docs")) (EIf (EApp (EApp (EApp (EVar "brokenAndMentions") (EVar "name")) (EVar "p")) (EVar "docs")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EApp (EVar "firstBrokenMentioning") (EVar "name")) (EVar "ps")) (EVar "docs"))))
(DTypeSig false "brokenAndMentions" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "brokenAndMentions" ((PVar "name") (PVar "p") (PVar "docs")) (EMatch (EApp (EApp (EVar "renameSrcOf") (EVar "p")) (EVar "docs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "src")) () (EBinOp "&&" (EApp (EApp (EVar "srcMentionsName") (EVar "name")) (EVar "src")) (EApp (EVar "srcFailsToParse") (EVar "src"))))))
(DTypeSig false "srcFailsToParse" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "srcFailsToParse" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" PWild) () (EVar "False"))))
(DTypeSig false "srcMentionsName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "srcMentionsName" ((PVar "name") (PVar "src")) (EApp (EApp (EVar "anyNameTok") (EVar "name")) (EApp (EVar "fst") (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")))))
(DTypeSig false "anyNameTok" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "anyNameTok" (PWild (PList)) (EVar "False"))
(DFunDef false "anyNameTok" ((PVar "name") (PCons (PVar "t") (PVar "ts"))) (EBinOp "||" (EApp (EApp (EVar "tokSpells") (EVar "t")) (EVar "name")) (EApp (EApp (EVar "anyNameTok") (EVar "name")) (EVar "ts"))))
(DTypeSig false "tokSpells" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "tokSpells" ((PCon "TIdent" (PVar "n")) (PVar "name")) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "tokSpells" ((PCon "TUpper" (PVar "n")) (PVar "name")) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "tokSpells" (PWild PWild) (EVar "False"))
(DTypeSig false "projectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "projectMdkFiles" ((PVar "root")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "collectMdkUnder") (EVar "acc")) (EVar "root"))) (DoExpr (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "collectMdkUnder" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "collectMdkUnder" ((PVar "acc") (PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "collectMdkEntries") (EVar "acc")) (EVar "dir")) (EVar "entries")))))
(DTypeSig false "collectMdkEntries" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkEntries" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectMdkEntries" ((PVar "acc") (PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectMdkEntry") (EVar "acc")) (EVar "dir")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "collectMdkEntries") (EVar "acc")) (EVar "dir")) (EVar "rest")))))
(DTypeSig false "collectMdkEntry" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkEntry" ((PVar "acc") (PVar "dir") (PVar "n")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectMdkPath") (EVar "acc")) (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n"))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "collectMdkPath" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "collectMdkPath" ((PVar "acc") (PVar "full") (PVar "n")) (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "collectMdkUnder") (EVar "acc")) (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "n")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (EVar "full") (EFieldAccess (EVar "acc") "value"))) (ELit LUnit)))))
(DTypeSig false "preludeDeclares" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "preludeDeclares" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EVar "anyDeclDeclares") (EVar "decls")) (EVar "name")))))
(DTypeSig false "anyDeclDeclares" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyDeclDeclares" ((PList) PWild) (EVar "False"))
(DFunDef false "anyDeclDeclares" ((PCons (PVar "d") (PVar "ds")) (PVar "name")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "declOwnNameMatches") (EVar "d")) (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EVar "declChildNames") (EVar "d"))) (EVar "name"))) (EApp (EApp (EVar "anyDeclDeclares") (EVar "ds")) (EVar "name"))))
(DTypeSig false "newNameIllegal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newNameIllegal" ((PVar "key") (PVar "newName")) (EMatch (EApp (EVar "keyNsName") (EVar "key")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "cannot determine the kind of the symbol being renamed")))) (arm (PCon "Some" (PTuple (PVar "ns") (PVar "_name"))) () (EMatch (EApp (EVar "firstChar") (EVar "newName")) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "the new name is empty")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "||" (EUnOp "!" (EApp (EVar "isIdentStart") (EVar "c"))) (EUnOp "!" (EApp (EVar "allIdentChars") (EVar "newName")))) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` is not a legal Medaka identifier"))))) (EIf (EApp (EVar "newNameReserved") (EVar "newName")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` is reserved by the language (a keyword, or `_`) and cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — choose a different name"))))) (EIf (EApp (EVar "uppercaseNs") (EVar "ns")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — it must start with an uppercase letter")))))) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "`")) (EVar "newName") (ELit (LString "` cannot name a ")) (EApp (EVar "nsNoun") (EVar "ns")) (ELit (LString " — an uppercase name is a type/constructor, not a value"))))) (EVar "None"))))))))))
(DTypeSig false "uppercaseNs" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "uppercaseNs" ((PVar "ns")) (EBinOp "||" (EBinOp "==" (EVar "ns") (ELit (LString "ty"))) (EBinOp "==" (EVar "ns") (ELit (LString "ctor")))))
(DTypeSig false "nsNoun" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nsNoun" ((PLit (LString "val"))) (ELit (LString "value")))
(DFunDef false "nsNoun" ((PLit (LString "local"))) (ELit (LString "local binding")))
(DFunDef false "nsNoun" ((PLit (LString "method"))) (ELit (LString "method")))
(DFunDef false "nsNoun" ((PLit (LString "field"))) (ELit (LString "record field")))
(DFunDef false "nsNoun" ((PLit (LString "ty"))) (ELit (LString "type")))
(DFunDef false "nsNoun" ((PLit (LString "ctor"))) (ELit (LString "constructor")))
(DFunDef false "nsNoun" (PWild) (ELit (LString "binding")))
(DTypeSig false "allIdentChars" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allIdentChars" ((PVar "s")) (EApp (EApp (EVar "allIdentCharsGo") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "allIdentCharsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allIdentCharsGo" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "True") (EIf (EUnOp "!" (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "allIdentCharsGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstChar" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "firstChar" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "arr")))))))
(DTypeSig false "newNameReserved" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "newNameReserved" ((PVar "s")) (EMatch (EApp (EVar "significantToks") (EVar "s")) (arm (PList (PCon "TIdent" (PVar "n"))) () (EBinOp "!=" (EVar "n") (EVar "s"))) (arm (PList (PCon "TUpper" (PVar "n"))) () (EBinOp "!=" (EVar "n") (EVar "s"))) (arm PWild () (EVar "True"))))
(DTypeSig false "significantToks" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "significantToks" ((PVar "s")) (EApp (EVar "dropLayoutToks") (EApp (EVar "fst") (EApp (EVar "tokenizeWithOffsetPairs") (EVar "s")))))
(DTypeSig false "dropLayoutToks" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "dropLayoutToks" ((PList)) (EListLit))
(DFunDef false "dropLayoutToks" ((PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EVar "isLayoutTok") (EVar "t")) (EApp (EVar "dropLayoutToks") (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "t") (EApp (EVar "dropLayoutToks") (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isLayoutTok" (PWild) (EVar "False"))
(DTypeSig false "workspaceEditJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyCon "Json")))))
(DFunDef false "workspaceEditJson" ((PVar "puns") (PVar "newName") (PVar "sorted")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "changes")) (EApp (EVar "jObject") (EApp (EApp (EApp (EVar "groupEdits") (EVar "puns")) (EVar "newName")) (EVar "sorted")))))))
(DTypeSig false "groupEdits" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))))
(DFunDef false "groupEdits" (PWild PWild (PList)) (EListLit))
(DFunDef false "groupEdits" ((PVar "puns") (PVar "newName") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sameRest") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoLet false false (PVar "tbl") (EApp (EApp (EVar "punTableOf") (EVar "p")) (EVar "puns"))) (DoLet false false (PVar "edits") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "textEditJson") (EVar "tbl")) (EVar "newName"))) (EBinOp "::" (EVar "loc") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "fst") (EVar "sameRest")))))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "uriOfPath") (EVar "p")) (EApp (EVar "jArray") (EVar "edits"))) (EApp (EApp (EApp (EVar "groupEdits") (EVar "puns")) (EVar "newName")) (EApp (EVar "snd") (EVar "sameRest")))))))
(DTypeSig false "spanSamePath" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))))
(DFunDef false "spanSamePath" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanSamePath" ((PVar "p") (PCons (PTuple (PVar "q") (PVar "loc")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "q") (EVar "p")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "spanSamePath") (EVar "p")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "q") (EVar "loc")) (EApp (EVar "fst") (EVar "sr"))) (EApp (EVar "snd") (EVar "sr"))))) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "q") (EVar "loc")) (EVar "rest")))))
(DTypeSig false "textEditJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Json")))))
(DFunDef false "textEditJson" ((PVar "tbl") (PVar "newName") (PVar "loc")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "jRangeOfLoc") (EVar "loc"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EApp (EApp (EApp (EVar "punAwareText") (EVar "tbl")) (EVar "newName")) (EVar "loc")))))))
(DTypeSig false "handleRename" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleRename" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "msg") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "rename requires a document uri")))) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EApp (EVar "renameRefusal") (ELit (LString "document is not open")))) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renameResult") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EIf (EApp (EVar "isRenameRefusal") (EVar "msg")) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseErr") (EVar "idJson")) (EApp (EVar "renameReasonOf") (EVar "msg")))) (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "msg")))))))
(DTypeSig false "renameReasonOf" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "renameReasonOf" ((PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "reason"))) (EVar "j")) (arm (PCon "Some" (PCon "JString" (PVar "s"))) () (EVar "s")) (arm PWild () (ELit (LString "rename refused")))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (EApp (EVar "semanticTokensData") (EVar "src")))))))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "initializeResult")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDefinition") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/references"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleReferences") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/rename"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleRename") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "emptyDocs")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
