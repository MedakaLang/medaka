# META
source_lines=764
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted comment-preserving formatter — port of lib/printer.ml's
-- `format_program` (the tail half of the printer, NOT covered by
-- compiler/printer.mdk's comment-FREE `programToString` core).
--
-- Walks the top-level declarations in source order, interleaving the lexer's
-- captured comment side-channel (compiler/lexer.mdk `collectComments` →
-- `Comment line col text`) at their original positions, using the parser's
-- position side-channel (compiler/parser.mdk `parseWithPositions` →
-- `Positions`: per-decl `(line, end_line)`, flat `data`-variant start lines,
-- and `last_content_line`).
--
-- Mirrors `format_program` byte-for-byte:
--   * leading comments (`c_line < loc.line`) flush as standalone lines, with a
--     blank-line gap when `target_line - cursor >= 2`;
--   * a single-line comment on `loc.end_line` is a TRAILING comment rendered
--     inline after the decl (`"  " ++ text`);
--   * a `DData` decl consumes its variants' source lines so an interior comment
--     anchors before the variant it precedes (`printDataDeclCommented`);
--   * a final `flush_before` (last_content_line + 1, i.e. drain-all) emits the
--     remaining trailing comments.
--
-- Pure state threading (no refs): the OCaml `ref` cell quartet
-- (cs / vlines / cursor / started) plus the output Buffer is carried as an
-- explicit `FmtState pieces cs vlines cursor started` and the output pieces are
-- accumulated reversed, then concatenated once at the end.

import frontend.ast.{DataVis(..), Variant(..), ConPayload(..), Decl(..)}
import tools.printer.{
  render,
  printDecl,
  printDataDeclCommented,
  printNamedFieldData,
  printDeclChainCommented,
  declChainLen,
  printDeclBlockCommented,
  declBlockLen,
  Doc,
}
import frontend.lexer.{
  Token(..),
  Comment,
  commentLine,
  commentCol,
  commentText,
  collectComments,
  tokenizeWithOffsetPairs,
}
import frontend.parser.{
  parseWithPositions,
  Positions,
  DeclPos,
  positionsDecls,
  positionsVariantLines,
  positionsLastContentLine,
  positionsChainLines,
  declPosLine,
  declPosEndLine,
}
import support.util.{
  listLen,
  reverseL,
  isEmptyL,
  isNonEmptyL,
  filterList,
  splitNl,
  joinNl,
  allList,
}

-- ── State ─────────────────────────────────────────
-- pieces : output fragments, REVERSED (cons-prepend, reverse+concat at end)
-- cs     : remaining captured comments, source order
-- vlines : remaining `data`-variant start lines, decl order
-- cursor : last consumed source line
-- started: whether any output has been emitted (gates the blank-line rule)
data FmtState = FmtState (List String) (List Comment) (List Int) Int Bool

-- ── String helpers (prelude-only; mirror lib/printer.ml's OCaml idioms) ──

-- Count '\n' in a comment lexeme — a multi-line block comment advances the
-- cursor by that many lines (OCaml: String.fold_left counting '\n').
countNl : String -> Int
countNl s = countNlChars (stringToChars s) 0 (arrayLength (stringToChars s)) 0

countNlChars : Array Char -> Int -> Int -> Int -> Int
countNlChars src i n acc
  | i >= n = acc
  | charAt src i == '\n' = countNlChars src (i + 1) n (acc + 1)
  | otherwise = countNlChars src (i + 1) n acc

charAt : Array Char -> Int -> Char
charAt src i = arrayGetUnsafe i src

-- True iff the lexeme is single-line (no embedded '\n'); a trailing comment
-- must be single-line (OCaml: `not (String.contains c.c_text '\n')`).
isSingleLine : String -> Bool
isSingleLine s = countNl s == 0

-- ── Blank-line / comment emission ─────────────────

-- Prepend a blank line when started and the gap to `targetLine` is >= 2
-- (OCaml `blank_line_if_needed`).  Returns the (possibly extended) pieces.
blankLineIfNeeded : List String -> Int -> Int -> Bool -> List String
blankLineIfNeeded pieces targetLine cursor started =
  if started && targetLine - cursor >= 2 then
    "\n"::pieces
  else
    pieces

-- Emit one standalone comment (OCaml `emit_comment`): blank-line gate, then
-- the lexeme + newline; advance cursor past any embedded newlines; mark started.
emitComment : FmtState -> Comment -> FmtState
emitComment (FmtState pieces cs vlines cursor started) c =
  let pieces1 = blankLineIfNeeded pieces (commentLine c) cursor started
  let pieces2 = "\n" :: commentText c :: pieces1
  let nls = countNl (commentText c)
  FmtState pieces2 cs vlines (commentLine c + nls) True

-- Emit all pending comments strictly above `line` (OCaml `flush_before`).
flushBefore : FmtState -> Int -> FmtState
flushBefore (FmtState pieces [] vlines cursor started) _ =
  FmtState pieces [] vlines cursor started
flushBefore (FmtState pieces (c::rest) vlines cursor started) line =
  if commentLine c < line then
    flushBefore (emitComment (FmtState pieces rest vlines cursor started) c) line
  else
    FmtState pieces (c::rest) vlines cursor started

-- ── Variant-line + interior-comment bucketing (DData) ─────

-- Take the next k variant start lines off `vlines` (OCaml `take_n_variant_lines`).
takeNVariantLines : List Int -> Int -> (List Int, List Int)
takeNVariantLines vlines k = takeNVarGo vlines k []

takeNVarGo : List Int -> Int -> List Int -> (List Int, List Int)
takeNVarGo vlines k acc
  | k <= 0 = (vlines, reverseL acc)
  | otherwise = match vlines
    [] => (vlines, reverseL acc)
    x::rest => takeNVarGo rest (k - 1) (x::acc)

-- Pop (WITHOUT emitting) the pending comments strictly above `line`, returning
-- their lexemes in source order plus the leftover comment stream (OCaml
-- `take_before`).  Used to bucket interior comments onto the variant they precede.
takeBefore : List Comment -> Int -> (List String, List Comment)
takeBefore cs line = takeBeforeGo cs line []

takeBeforeGo : List Comment -> Int -> List String -> (List String, List Comment)
takeBeforeGo [] _ acc = (reverseL acc, [])
takeBeforeGo (c::rest) line acc =
  if commentLine c < line then
    takeBeforeGo rest line (commentText c :: acc)
  else
    (reverseL acc, c::rest)

-- Pop the single-line comments ON `line` (a variant's TRAILING comments, e.g.
-- `| Field String  -- .foo`).  Without this they leak into the NEXT variant's
-- `takeBefore` bucket and get re-rendered as a leading comment on their own line.
takeSameLine : List Comment -> Int -> (List String, List Comment)
takeSameLine [] _ = ([], [])
takeSameLine (c::rest) line =
  if commentLine c == line && isSingleLine (commentText c) then match takeSameLine rest line
    (more, leftover) => (commentText c :: more, leftover)
  else ([], c::rest)

-- For each variant line, pop its preceding (leading) comments AND its same-line
-- (trailing) comments.  Returns per-variant (leading, trailing) lexeme lists
-- (parallel to vls) and the leftover stream.
vcommentsFor : List Comment -> List Int -> (List (List String, List String), List Comment)
vcommentsFor cs [] = ([], cs)
vcommentsFor cs (l::ls) = match takeBefore cs l
  (leading, rest1) => match takeSameLine rest1 l
    (trailing, rest2) => match vcommentsFor rest2 ls
      (more, leftover) => ((leading, trailing)::more, leftover)

allEmptyPairs : List (List String, List String) -> Bool
allEmptyPairs [] = True
allEmptyPairs ((ld, tr)::xs) = isEmptyL ld && isEmptyL tr && allEmptyPairs xs

-- ── Per-declaration rendering ─────────────────────

-- Render one declaration's Doc, consuming variant lines for a DData (always, to
-- keep vlines aligned) and interleaving any interior comment before the variant
-- it documents.  Other decls render opaquely.  Mirror of OCaml `decl_doc`.
-- Returns (renderedString, newState) — the Doc is rendered here so the comment
-- pops are threaded back into the state.
declDoc : FmtState -> Decl -> (String, FmtState)
declDoc (FmtState pieces cs vlines cursor started) (d@(DData { dataVis = vis, dataName = n, dataParams = params, dataParamKinds = kinds, dataCtors = variants, dataDerives = derives })) = match takeNVariantLines vlines (listLen variants)
  (vlinesRest, vls) => match vcommentsFor cs vls
    (vcomments, csRest) =>
      if listLen vcomments == listLen variants && not (allEmptyPairs vcomments) then
        (
          render (printDataDeclCommented vis n params kinds variants derives vcomments),
          FmtState pieces csRest vlinesRest cursor started,
        )
      else
        (render (printDecl d), FmtState pieces cs vlinesRest cursor started)
declDoc st decl = (render (printDecl decl), st)

-- ── Trailing comments ─────────────────────────────

-- A comment on the decl's final source line, single-line, is trailing: pull it
-- out of the pending stream so it renders inline.  Order-preserving partition.
-- Mirror of OCaml `take_trailing`.
isTrailing : Int -> Comment -> Bool
isTrailing endLine c = commentLine c == endLine && isSingleLine (commentText c)

takeTrailing : List Comment -> Int -> (List Comment, List Comment)
takeTrailing cs endLine = (
  filterList (isTrailing endLine) cs,
  filterList (c => not (isTrailing endLine c)) cs,
)

-- Append the inline trailing comments after the decl text.
appendTrailing : List String -> List Comment -> List String
appendTrailing pieces [] = pieces
appendTrailing pieces (c::cs) =
  appendTrailing (commentText c :: "  "::pieces) cs

-- ── Interior (inner-block) trailing comments ──────────────────────────────
-- A single-line comment on a source line strictly *inside* a multi-line decl
-- body (line < c.line < end_line) trails an INNER statement (e.g. each
-- `println …  -- note` line of a bare indented block), not the decl as a whole.
-- The decl-granular `takeTrailing` only catches the comment on `end_line`, so
-- the earlier ones used to escape to `drainAll` and flush *below* the decl. We
-- instead splice each one back inline onto the rendered output line that
-- originated at its source line.
--
-- The decl renders one output line per source line (statements keep their
-- source line breaks), so output-line index = c.line - decl.line maps a source
-- line to its rendered line.  We attach `"  " ++ text` to that output line; a
-- comment whose index is out of range (a reflowed/wrapped statement, rare) is
-- left in the stream so `drainAll` still emits it rather than dropping it.

isInterior : Int -> Int -> Comment -> Bool
isInterior startLine endLine c =
  let l = commentLine c
  l > startLine && l < endLine && isSingleLine (commentText c)

-- DData (incl. an attribute-wrapped one) routes interior comments through
-- vcommentsFor, not the generic inline splice.
isDataDeclF : Decl -> Bool
isDataDeclF (DData { dataOrigin = _ }) = True
isDataDeclF (DAttrib _ inner) = isDataDeclF inner
isDataDeclF _ = False

-- A single-variant record-style data decl (`data X = X { f : T, ... }`).  Its
-- per-field trailing comments cannot be carried by the per-VARIANT vcommentsFor
-- machinery (one variant, many field comments), and the flat one-line render
-- gives them no line to attach to — so when such a decl carries field comments
-- we render it one-field-per-line (printNamedFieldData) and route the comments
-- through the generic interior splice instead (see stepDecl).  Only the bare
-- (non-attribute-wrapped) shape, to avoid dropping `@attr` annotations.
isSingleNamedFieldData : Decl -> Bool
isSingleNamedFieldData (DData { dataCtors = [Variant _ (ConNamed _ _)] }) = True
isSingleNamedFieldData _ = False

-- Render a single-variant named-field data decl one-field-per-line, consuming its
-- one variant line (to keep vlines aligned, exactly as declDoc's DData arm does).
renderNamedFieldMulti : FmtState -> Decl -> (String, FmtState)
renderNamedFieldMulti (FmtState pieces cs vlines cursor started) (DData { dataVis = vis, dataName = n, dataParams = params, dataParamKinds = kinds, dataCtors = variants, dataDerives = derives }) = match takeNVariantLines vlines 1
  (vlinesRest, _) => (
    render (printNamedFieldData vis n params kinds variants derives),
    FmtState pieces cs vlinesRest cursor started,
  )
renderNamedFieldMulti st decl = declDoc st decl

-- Splice interior comments into the rendered decl string by output-line index.
-- Returns (newDeclStr, consumedComments) — consumed ones are removed from the
-- pending stream; any whose index fell out of range are NOT consumed.
--
-- #829: a naive `commentLine - startLine == idx` mapping assumes every SOURCE
-- line has a 1:1 OUTPUT line. That is true of a TRAILING comment (one sharing
-- its source line with the code it follows — the code already owns an output
-- line, the comment adds none) but false of a STANDALONE comment on its own
-- source line: it consumes a line but — being spliced in rather than
-- rendered on its own output line — produces none, so every comment/field
-- after the first standalone one in a block is off by the count of
-- standalone lines already eaten.
--
-- The two kinds are told apart by whether anything but whitespace precedes
-- the comment on its own SOURCE line: a trailing comment's `--` follows code
-- earlier on that line; a standalone comment's `--` is the first thing on
-- it (only whitespace precedes it — it opens its own line). This is checked
-- against the SOURCE line's own leading-space count (`isStandaloneSrc`), not
-- the RENDERED output's field indent — a two-line `data X =\n  | X { ... }`
-- header nests its fields one indent level deeper in source than the
-- collapsed single-line render uses, so comparing a source column against a
-- render-derived indent misclassified every comment there (#829 reopened).
-- Only standalone comments shift the count; a trailing comment always
-- renders inline on its own field's line, and a run of standalone comments
-- immediately preceding a field renders as its own lines ABOVE that field,
-- in source order — instead of being torn across two different fields'
-- trailing positions (the reported defect) or, worse, collapsed together
-- with an unrelated trailing comment (the PerRun-shaped case: trailing and
-- standalone comments interleaved in the same record).
spliceInterior : List String -> String -> Int -> List Comment -> (String, List Comment)
spliceInterior srcLines declStr startLine interior =
  let outLines = splitNl declStr
  let classified = classifyIdxs startLine srcLines 0 interior
  let groups = groupRuns classified
  match attachInterior outLines groups 0
    (newLines, consumed) => (joinNl newLines, consumed)

-- Fetch source line `n` (1-indexed) from the whole-file `srcLines`, or "" if
-- out of range (should not happen for a comment's own line).
nthLine : List String -> Int -> String
nthLine [] _ = ""
nthLine (l::ls) n
  | n <= 1 = l
  | otherwise = nthLine ls (n - 1)

-- A comment is STANDALONE iff nothing but whitespace precedes it on its own
-- SOURCE line — its column equals that line's own leading-space count. See
-- `spliceInterior`'s comment for why this must be measured against the
-- SOURCE line, not the rendered output's field indent.
isStandaloneSrc : List String -> Comment -> Bool
isStandaloneSrc srcLines c =
  commentCol c == leadingSpaceCount (nthLine srcLines (commentLine c))

data CKind = CTrailing | CStandalone

classifyKind : List String -> Comment -> CKind
classifyKind srcLines c =
  if isStandaloneSrc srcLines c then
    CStandalone
  else
    CTrailing

-- Map each interior comment to its OUTPUT-line index and its kind,
-- accounting for the source lines already eaten by earlier STANDALONE
-- comments in this same list (a trailing comment eats nothing — its line is
-- already accounted for by the field it trails).
classifyIdxs : Int -> List String -> Int -> List Comment -> List (Comment, Int, CKind)
classifyIdxs _ _ _ [] = []
classifyIdxs startLine srcLines eaten (c::cs) =
  let k = classifyKind srcLines c
  let idx = commentLine c - startLine - eaten
  let eaten1 = match k
    CStandalone => eaten + 1
    CTrailing => eaten
  (c, idx, k) :: classifyIdxs startLine srcLines eaten1 cs

-- Group consecutive (source-order) comments sharing the same computed index
-- into runs.  Relies on `classifyIdxs` producing a non-decreasing index
-- sequence (true for well-formed sequential source).
groupRuns : List (Comment, Int, CKind) -> List (Int, List (Comment, CKind))
groupRuns [] = []
groupRuns ((c, i, k)::rest) = match spanSameIdx i rest
  (same, rest2) => (i, (c, k) :: map dropIdx same) :: groupRuns rest2

dropIdx : (Comment, Int, CKind) -> (Comment, CKind)
dropIdx (c, _, k) = (c, k)

spanSameIdx : Int -> List (Comment, Int, CKind) -> (List (Comment, Int, CKind), List (Comment, Int, CKind))
spanSameIdx _ [] = ([], [])
spanSameIdx i ((c, j, k)::rest) =
  if i == j then match spanSameIdx i rest
    (same, rest2) => ((c, j, k)::same, rest2)
  else ([], (c, j, k)::rest)

-- Walk the output lines against the (already ordered, by index) comment
-- groups.  Within a group: every STANDALONE comment renders as its own
-- indented line immediately ABOVE the target line (source order preserved);
-- every TRAILING comment renders appended inline onto the target line.
attachInterior : List String -> List (Int, List (Comment, CKind)) -> Int -> (List String, List Comment)
attachInterior [] _ _ = ([], [])
attachInterior (ln::rest) groups idx = match takeGroupFor idx groups
  (mine, groupsRest) => match attachInterior rest groupsRest (idx + 1)
    (restLines, consumed1) => match mine
      [] => (ln::restLines, consumed1)
      _ =>
        let standalone = filterList (p => isStandaloneP p) mine
        let trailing = filterList (p => not (isStandaloneP p)) mine
        let ln1 = appendTrailingP ln trailing
        let above = standaloneLinesFor ln (map fst standalone)
        (above ++ (ln1::restLines), map fst mine ++ consumed1)

isStandaloneP : (Comment, CKind) -> Bool
isStandaloneP (_, CStandalone) = True
isStandaloneP (_, CTrailing) = False

appendTrailingP : String -> List (Comment, CKind) -> String
appendTrailingP ln [] = ln
appendTrailingP ln ((c, _)::rest) =
  appendTrailingP "\{ln}  \{commentText c}" rest

-- Pop the group at the head of `groups` if its index is `idx` (groups are in
-- non-decreasing index order, so the target group — if any remains — is
-- always at the head by the time the walk reaches its index).
takeGroupFor : Int -> List (Int, List (Comment, CKind)) -> (List (Comment, CKind), List (Int, List (Comment, CKind)))
takeGroupFor _ [] = ([], [])
takeGroupFor idx ((i, cs)::rest) =
  if i == idx then
    (cs, rest)
  else
    ([], (i, cs)::rest)

-- Render each comment in `cs` as its own line, indented to match `ln`'s own
-- leading whitespace (so a comment above a field lines up with that field).
standaloneLinesFor : String -> List Comment -> List String
standaloneLinesFor ln cs =
  let ind = leadingSpaces ln
  map (c => ind ++ commentText c) cs

leadingSpaceCount : String -> Int
leadingSpaceCount s = leadingSpaceCountGo (stringToChars s) 0 (stringLength s)

leadingSpaceCountGo : Array Char -> Int -> Int -> Int
leadingSpaceCountGo src i n
  | i >= n = i
  | charAt src i == ' ' = leadingSpaceCountGo src (i + 1) n
  | otherwise = i

leadingSpaces : String -> String
leadingSpaces s = spacesN (leadingSpaceCount s)

spacesN : Int -> String
spacesN n
  | n <= 0 = ""
  | otherwise = " " ++ spacesN (n - 1)

-- Drop the consumed comments from the pending stream (order-preserving), by
-- source line — interior comment lines are unique per output line.
dropConsumed : List Comment -> List Comment -> List Comment
dropConsumed cs consumed =
  filterList (c => not (anyLineEq (commentLine c) consumed)) cs

anyLineEq : Int -> List Comment -> Bool
anyLineEq _ [] = False
anyLineEq l (c::cs) = if commentLine c == l then True else anyLineEq l cs

-- ── Comment-interleaved continuation chains (finding "L") ──────────────────
-- A continuation-op chain RHS (`||`/`&&`/`++`/…) whose operands carry trailing
-- comments is formatted with each comment anchored to ITS operand's Doc (via
-- printer.LineComment), so reflow can't shift a comment to the wrong operand —
-- superseding the verbatim safety-net for this (the finding-"L") shape.  The
-- parser's per-decl chain operand-line side-channel (`positionsChainLines`)
-- lines the operands up with the comments; we take this path only when every
-- comment in the decl's span anchors cleanly (else fall back to verbatim).

intInList : Int -> List Int -> Bool
intInList _ [] = False
intInList x (y::ys) = if x == y then True else intInList x ys

-- The single-line comment sitting on source line `l`, if any.
commentOnLine : List Comment -> Int -> Option String
commentOnLine [] _ = None
commentOnLine (c::cs) l =
  if commentLine c == l && isSingleLine (commentText c) then
    Some (commentText c)
  else
    commentOnLine cs l

-- Comments belonging to this decl's source span [lo, hi] (flushBefore has
-- already drained everything strictly before `lo`).
spanComments : List Comment -> Int -> Int -> List Comment
spanComments cs lo hi =
  filterList (c => commentLine c >= lo && commentLine c <= hi) cs

-- Can EVERY comment in the decl's span be anchored to a chain operand line?
-- (each single-line AND on an operand line).  If not, keep the verbatim net so
-- no comment is dropped or misplaced.
chainCoversAll : List Comment -> Int -> Int -> List Int -> Bool
chainCoversAll cs lo hi ols = allList
  (c => isSingleLine (commentText c) && intInList (commentLine c) ols)
  (spanComments cs lo hi)

-- ── Verbatim safety-net (Option C) ────────────────────────────────────────
-- When a declaration carries an INTERIOR trailing comment (a single-line
-- comment strictly between its start and end line — see `isInterior`), the
-- comment-free Doc engine (printer.mdk) may REFLOW the body by width, so the
-- source-line→output-line index map that `spliceInterior` relies on no longer
-- holds and comments drift to the wrong operand (finding "L").  Rather than
-- risk misplacement, we emit that decl's ORIGINAL source lines verbatim, so a
-- hand-laid-out commented body keeps its exact layout and no comment is ever
-- moved or merged.  Data decls are EXCLUDED — their interior comments are
-- placed per-variant/per-field by `printDataDeclCommented`/`printNamedFieldData`
-- (a path that IS reflow-safe), so they keep formatting normally.
-- Conservative by design: any non-data decl with >=1 interior comment goes
-- verbatim, even in cases the old splice happened to get right.

-- Extract source lines [startLine .. endLine] (1-based, inclusive) and rejoin
-- them exactly — the decl's original text, comments and all.
verbatimSpan : List String -> Int -> Int -> String
verbatimSpan srcLines startLine endLine =
  joinNl (spanLines srcLines 1 startLine endLine)

spanLines : List String -> Int -> Int -> Int -> List String
spanLines [] _ _ _ = []
spanLines (l::ls) idx startLine endLine
  | idx > endLine = []
  | idx >= startLine = l :: spanLines ls (idx + 1) startLine endLine
  | otherwise = spanLines ls (idx + 1) startLine endLine

-- ── Main walk ─────────────────────────────────────

-- Split the (source-line-sorted) comment stream into those on/before `endLine`
-- — this decl's span — and those strictly after it.  A single early-terminating
-- walk: comments arrive ascending by line (collectComments source order, which
-- flushBefore/emitComment preserve), so the first comment past `endLine` ends the
-- prefix.  This is the perf seam: without it, every per-decl comment filter
-- (`isInterior`, `takeTrailing`, `chainCoversAll`, the DData `vcommentsFor` path)
-- rescans the ENTIRE remaining tail — every later decl's comments once per
-- preceding decl — which is O(decls × comments).  `stepDecl` narrows to `mine`
-- once and re-appends `after` to whatever survives, so the walk is O(comments).
splitByEndLine : List Comment -> Int -> (List Comment, List Comment)
splitByEndLine [] _ = ([], [])
splitByEndLine (c::rest) endLine =
  if commentLine c > endLine then ([], c::rest)
  else match splitByEndLine rest endLine
    (mine, after) => (c::mine, after)

-- Re-attach the after-span comment remainder to whatever comments survived the
-- per-decl body.  Both sublists stay in source order (survivors ⊆ span ≤ endLine
-- < after-span), so the concat is order-preserving.
appendAfterComments : FmtState -> List Comment -> FmtState
appendAfterComments (FmtState p c v cur s) after =
  FmtState p (c ++ after) v cur s

-- Process one (decl, declPos) pair.  Mirror of one OCaml `List.iter2` body.
-- Narrows the pending comment stream to this decl's span before dispatching, so
-- the span-scanning body (`stepDeclSpan`) only ever touches this decl's comments;
-- the after-span remainder is re-appended to the surviving stream on the way out.
stepDecl : FmtState -> List String -> List Int -> Decl -> DeclPos -> FmtState
stepDecl st srcLines chainOls decl dp =
  let line = declPosLine dp
  let endLine = declPosEndLine dp
  let st1 = flushBefore st line
  match st1
    FmtState pieces1 cs1 vlines1 cursor1 started1 => match splitByEndLine cs1 endLine
      (mine, after) =>
        let stSpan = FmtState pieces1 mine vlines1 cursor1 started1
        let stOut = stepDeclSpan stSpan srcLines chainOls decl line endLine
        appendAfterComments stOut after

-- The per-decl body, operating on a comment stream already narrowed to this
-- decl's span [line, endLine] (see `stepDecl`).  Every `cs1` scan below is now
-- bounded by this decl's own comments, not the whole file's remaining tail.
stepDeclSpan : FmtState -> List String -> List Int -> Decl -> Int -> Int -> FmtState
stepDeclSpan (FmtState pieces1 cs1 vlines1 cursor1 started1) srcLines chainOls decl line endLine =
      let pieces2 = blankLineIfNeeded pieces1 line cursor1 started1
      let hasInterior = isNonEmptyL (filterList (isInterior line endLine) cs1)
      -- Continuation-chain path (finding "L"): interleave each operand's
      -- trailing comment via printer.LineComment, IF the decl is a chain whose
      -- operand count matches the AST and every span comment anchors cleanly.
      let useChain = hasInterior
        && isNonEmptyL chainOls
        && declChainLen decl == listLen chainOls
        && chainCoversAll cs1 line endLine chainOls
      -- Block/do path (Stage 5): interleave each statement's trailing comment,
      -- IF the decl is a bare/do-block whose statement count matches the AST and
      -- every span comment anchors to a statement line.  (chainOls carries the
      -- statement lines for a block-bodied decl.)
      let useBlock = hasInterior
        && not useChain
        && isNonEmptyL chainOls
        && declBlockLen decl == listLen chainOls
        && chainCoversAll cs1 line endLine chainOls
      -- Verbatim safety-net: a non-data decl with an interior trailing comment
      -- keeps its original source text (reflow would misplace the comment).
      let useVerbatim = hasInterior && not (isDataDeclF decl)
      let st2 = FmtState pieces2 cs1 vlines1 cursor1 started1
      if useChain then
        -- One trailing comment per operand (in collectChain order); the parser's
        -- operand lines are in the same order, so map by line.
        let perOp = map (ol => commentOnLine cs1 ol) chainOls
        let declStr = render (printDeclChainCommented decl perOp)
        -- Every span comment was placed inline; drain the decl's prefix.
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: declStr :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else if useBlock then
        -- One trailing comment per statement (source order == parser line order).
        let perStmt = map (ol => commentOnLine cs1 ol) chainOls
        let declStr = render (printDeclBlockCommented decl perStmt)
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: declStr :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else if useVerbatim then
        -- The verbatim span [line .. endLine] already contains every comment on
        -- those lines, so consume the whole decl's pending comment prefix
        -- (flushBefore already drained everything strictly before `line`).
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: verbatimSpan srcLines line endLine :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else
        stepDeclNormal st2 srcLines decl line endLine

-- The normal (reflowing) path: render the decl's Doc, splice interior comments
-- by output-line index, and append end-line trailing comments inline.  Used for
-- every decl WITHOUT an interior trailing comment (see stepDecl's safety-net).
stepDeclNormal : FmtState -> List String -> Decl -> Int -> Int -> FmtState
stepDeclNormal (FmtState pieces2 cs1 vlines1 cursor1 started1) srcLines decl line endLine =
  -- A single-variant named-field data decl that carries field comments is
  -- rendered one-field-per-line and routed through the generic interior
  -- splice (the per-variant vcommentsFor path cannot attach per-field
  -- comments).  Other data decls keep the vcommentsFor path.
  let nfMulti = isSingleNamedFieldData decl && isNonEmptyL (filterList (isInterior line endLine) cs1)
  -- #829 (two-line header): `printNamedFieldData` always renders the header as
  -- ONE output line (`data X = X {`), but a source header can be split across
  -- TWO lines (`data X =` / `  | X { ... }`, e.g. `DriverState`). `line` is the
  -- decl's overall start (the `data X =` line) — using it as `spliceInterior`'s
  -- source→output base assumes the header is 1:1, so on a two-line header
  -- every field/comment index comes out one line short, shifting every
  -- interior comment onto the field after the one it describes. The variant's
  -- OWN line (`| X {`, the head of `vlines1` before `renderNamedFieldMulti`
  -- consumes it) is where the collapsed header line actually originated, so
  -- use that as the base instead — it equals `line` on the (already-safe)
  -- single-line header, where the ctor opens on the same line as `data X =`.
  let headerLine = if nfMulti then
      match vlines1
        (vl::_) => vl
        [] => line
    else
      line
  let st2 = FmtState pieces2 cs1 vlines1 cursor1 started1
  match (if nfMulti then renderNamedFieldMulti st2 decl else declDoc st2 decl)
    (declStr0, (FmtState pieces3 cs3 vlines3 _cursor3 _started3)) =>
      -- DData has its own interior-comment machinery (vcommentsFor); leave
      -- its comments to that path.  Every other decl (and a commented
      -- named-field data decl, nfMulti) interleaves inner-block trailing
      -- comments inline.
      let interior = if isDataDeclF decl && not nfMulti then [] else filterList (isInterior line endLine) cs3
      match spliceInterior srcLines declStr0 headerLine interior
        (declStr, consumed) =>
          let cs3b = dropConsumed cs3 consumed
          match takeTrailing cs3b endLine
            (trailing, csRest) =>
              let pieces4 = appendTrailing (declStr :: pieces3) trailing
              FmtState ("\n" :: pieces4) csRest vlines3 endLine True
-- (1) flush_before loc.line, (2) blank-line gate, (3) render decl (consumes
-- variant lines + interior comments), (4) splice inner-block trailing comments
-- back inline, (5) end-line inline trailing comment(s),
-- (6) newline + advance cursor to end_line + started := true.

-- Threads the per-decl chain operand-line side-channel (`cls`) in lockstep with
-- the decls; a decl with no entry (list exhausted) gets `[]` (non-chain).
walkDecls : FmtState -> List String -> List Decl -> List DeclPos -> List (List Int) -> FmtState
walkDecls st _ [] _ _ = st
walkDecls st _ _ [] _ = st
walkDecls st srcLines (d::ds) (p::ps) [] =
  walkDecls (stepDecl st srcLines [] d p) srcLines ds ps []
walkDecls st srcLines (d::ds) (p::ps) (c::rest) =
  walkDecls (stepDecl st srcLines c d p) srcLines ds ps rest

-- ── Public entry ──────────────────────────────────

-- format_program: interleave comments into the rendered program.  If the decl
-- position list and the decl list differ in length, fall back to the plain
-- comment-free `programToString`-equivalent (render each decl + "\n").  Mirror
-- of lib/printer.ml's length guard.
export
formatProgram : List Decl -> List DeclPos -> List Int -> List (List Int) -> List Comment -> Int -> String -> String
formatProgram decls declPositions variantLines chainLines comments _lastContentLine src =
  if listLen declPositions /= listLen decls then stringConcat (map (d => render (printDecl d) ++ "\n") decls)
  else
    let st0 = FmtState [] comments variantLines 0 False
    match drainAll (walkDecls st0 (splitNl src) decls declPositions chainLines)
      FmtState finalPieces _ _ _ _ => stringConcat (reverseL finalPieces)
-- After the walk, the final `flush_before max_int` drains EVERY remaining
-- comment; `drainAll` does that unconditionally (no max_int literal needed).

-- Drain every remaining comment (final `flush_before max_int`).
drainAll : FmtState -> FmtState
drainAll (FmtState pieces [] vlines cursor started) =
  FmtState pieces [] vlines cursor started
drainAll (FmtState pieces (c::rest) vlines cursor started) =
  drainAll (emitComment (FmtState pieces rest vlines cursor started) c)

-- Convenience: parse + collect comments + format, from source text.
export
formatSource : String -> String
formatSource src = match parseWithPositions src
  (decls, pos) => restoreTripleQuotedStrings src (formatProgram decls (positionsDecls pos) (positionsVariantLines pos) (positionsChainLines pos) (collectComments src) (positionsLastContentLine pos) src)

-- ── Triple-quoted string preservation (#1750) ────────────────────────────
-- `formatProgram` re-renders every string literal in the canonical
-- double-quoted spelling (`printLit`, tools/printer.mdk) — the AST's `Lit`
-- type has no room to remember that a literal was written `"""..."""`, and
-- giving it one would mean threading a new field through every one of
-- `LString`'s ~80 call sites across typecheck/eval/every IR pass/every
-- backend. Instead this restores the original spelling as a pure TEXT patch
-- applied AFTER formatting: a `TString` token's start offset is always its
-- opening quote (Defect B, see lexer.mdk's `scanStr`/`scanTriple`), so a
-- token whose source starts `"""` is a triple-quoted literal — no new Token
-- constructor needed. `formatProgram` never adds, removes, or reorders string
-- literals (each `ELit (LString _)` prints as exactly one literal), so the
-- Nth `TString` token in the original source is always the Nth `TString`
-- token in the freshly-formatted output; the correlation is by ORDER alone,
-- never by offset or value, so re-arranged-but-unformatted-differently
-- surrounding code cannot confuse it.
--
-- Deliberately narrow: only the non-interpolated form (`isTripleStringAt`)
-- is restored. An interpolated triple string (`"""foo \{x}"""`) never
-- produces a `TString` token at all (it lexes as `TInterpOpen`/`TInterpMid`/
-- `TInterpEnd`, `[P-DESUGAR-FIRST]`-adjacent territory) and is out of scope
-- here — untouched, same as before this change.

-- Is the source's `pos` (a `TString` token's start offset) the opening `"""`
-- of a triple-quoted literal, rather than a plain `"`?
isTripleStringAt : String -> Int -> Bool
isTripleStringAt src pos = stringSlice pos (pos + 3) src == "\"\"\""

-- Walk parallel (Token, (start, end)) lists, keeping only `TString`.
-- `info` pairs each with (isTriple, rawSourceText-if-triple-else-""); `spans`
-- keeps just (start, end) — used for the FORMATTED side, where the raw text
-- is never needed (nothing there is triple-quoted yet).
stringTokenInfo : String -> List Token -> List (Int, Int) -> List (Bool, String)
stringTokenInfo _ [] _ = []
stringTokenInfo _ _ [] = []
stringTokenInfo src ((TString _)::ts) ((s, e)::ps) =
  let triple = isTripleStringAt src s
  (triple, if triple then stringSlice s e src else "") :: stringTokenInfo src ts ps
stringTokenInfo src (_::ts) (_::ps) = stringTokenInfo src ts ps

stringTokenSpans : List Token -> List (Int, Int) -> List (Int, Int)
stringTokenSpans [] _ = []
stringTokenSpans _ [] = []
stringTokenSpans ((TString _)::ts) ((s, e)::ps) =
  (s, e) :: stringTokenSpans ts ps
stringTokenSpans (_::ts) (_::ps) = stringTokenSpans ts ps

-- Zip the original literal order against the formatted output's literal
-- spans, keeping only the ones that need restoring, as (start, end,
-- replacementText) into the FORMATTED text. Both lists are walked in
-- lockstep (one element off each per step), so a token-count mismatch is
-- ONLY handled safely when it falls at the TAIL: the final `_ _ = []`
-- clause fires once the shorter list runs out, dropping whatever's left
-- on the longer one — "some triple strings stay collapsed," never a
-- misapplied span. A mismatch introduced MID-LIST (a `TString` inserted or
-- removed before the last one) would desync every pairing after that
-- point and could splice the wrong literal's text into the wrong span. No
-- live trigger is known — formatting never reorders or drops string
-- literals, and interpolated strings are symmetrically invisible to this
-- tokenization (#1858) — but that's an invariant of the CALLER, not one
-- this function enforces on its own.
tripleStringSubs : List (Bool, String) -> List (Int, Int) -> List (Int, Int, String)
tripleStringSubs ((True, raw)::is) ((s, e)::ss) =
  (s, e, raw) :: tripleStringSubs is ss
tripleStringSubs ((False, _)::is) (_::ss) = tripleStringSubs is ss
tripleStringSubs _ _ = []

-- Apply substitutions HIGHEST-OFFSET-FIRST (`subs` arrives ascending; walk it
-- reversed) so an earlier substitution's offsets are never invalidated by a
-- later one changing the text length ahead of it.
applyTripleSubs : List (Int, Int, String) -> String -> String
applyTripleSubs [] out = out
applyTripleSubs ((s, e, raw)::rest) out =
  applyTripleSubs
    rest
    (stringSlice 0 s out ++ raw ++ stringSlice e (stringLength out) out)

-- Restore every triple-quoted string literal's original spelling in
-- `formatted` (freshly rendered from `src`'s AST).
restoreTripleQuotedStrings : String -> String -> String
restoreTripleQuotedStrings src formatted = match tokenizeWithOffsetPairs src
  (origToks, origSpans) => match tokenizeWithOffsetPairs formatted
    (fmtToks, fmtSpans) =>
      let origInfo = stringTokenInfo src origToks origSpans
      let fmtStrSpans = stringTokenSpans fmtToks fmtSpans
      applyTripleSubs
        (reverseL (tripleStringSubs origInfo fmtStrSpans))
        formatted
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "printDeclChainCommented" false) (mem "declChainLen" false) (mem "printDeclBlockCommented" false) (mem "declBlockLen" false) (mem "Doc" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false) (mem "allList" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "countNl" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))))
(DTypeSig false "countNlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countNlChars" ((PVar "src") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "isSingleLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSingleLine" ((PVar "s")) (EBinOp "==" (EApp (EVar "countNl") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "blankLineIfNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "blankLineIfNeeded" ((PVar "pieces") (PVar "targetLine") (PVar "cursor") (PVar "started")) (EIf (EBinOp "&&" (EVar "started") (EBinOp ">=" (EBinOp "-" (EVar "targetLine") (EVar "cursor")) (ELit (LInt 2)))) (EBinOp "::" (ELit (LString "\n")) (EVar "pieces")) (EVar "pieces")))
(DTypeSig false "emitComment" (TyFun (TyCon "FmtState") (TyFun (TyCon "Comment") (TyCon "FmtState"))))
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started")) PWild) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started"))))
(DTypeSig false "takeNVariantLines" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "takeNVariantLines" ((PVar "vlines") (PVar "k")) (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "vlines")) (EVar "k")) (EListLit)))
(DTypeSig false "takeNVarGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "takeNVarGo" ((PVar "vlines") (PVar "k") (PVar "acc")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EMatch (EVar "vlines") (arm (PList) () (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc")))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "rest")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "x") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeBefore" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeBefore" ((PVar "cs") (PVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "cs")) (EVar "line")) (EListLit)))
(DTypeSig false "takeBeforeGo" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "takeBeforeGo" ((PList) PWild (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "takeBeforeGo" ((PCons (PVar "c") (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "rest")) (EVar "line")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "acc"))) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "takeSameLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeSameLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeSameLine" ((PCons (PVar "c") (PVar "rest")) (PVar "line")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest")) (EVar "line")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "more")) (EVar "leftover")))) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "vcommentsFor" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "vcommentsFor" ((PVar "cs") (PList)) (ETuple (EListLit) (EVar "cs")))
(DFunDef false "vcommentsFor" ((PVar "cs") (PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EApp (EVar "takeBefore") (EVar "cs")) (EVar "l")) (arm (PTuple (PVar "leading") (PVar "rest1")) () (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest1")) (EVar "l")) (arm (PTuple (PVar "trailing") (PVar "rest2")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "rest2")) (EVar "ls")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (ETuple (EVar "leading") (EVar "trailing")) (EVar "more")) (EVar "leftover")))))))))
(DTypeSig false "allEmptyPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "allEmptyPairs" ((PList)) (EVar "True"))
(DFunDef false "allEmptyPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ld")) (EApp (EVar "isEmptyL") (EVar "tr"))) (EApp (EVar "allEmptyPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PAs "d" (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PRec "DData" ((rf "dataCtors" (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))))) false)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))))))
(DFunDef false "renderNamedFieldMulti" ((PVar "st") (PVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st")) (EVar "decl")))
(DTypeSig false "spliceInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "spliceInterior" ((PVar "srcLines") (PVar "declStr") (PVar "startLine") (PVar "interior")) (EBlock (DoLet false false (PVar "outLines") (EApp (EVar "splitNl") (EVar "declStr"))) (DoLet false false (PVar "classified") (EApp (EApp (EApp (EApp (EVar "classifyIdxs") (EVar "startLine")) (EVar "srcLines")) (ELit (LInt 0))) (EVar "interior"))) (DoLet false false (PVar "groups") (EApp (EVar "groupRuns") (EVar "classified"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "attachInterior") (EVar "outLines")) (EVar "groups")) (ELit (LInt 0))) (arm (PTuple (PVar "newLines") (PVar "consumed")) () (ETuple (EApp (EVar "joinNl") (EVar "newLines")) (EVar "consumed")))))))
(DTypeSig false "nthLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "nthLine" ((PList) PWild) (ELit (LString "")))
(DFunDef false "nthLine" ((PCons (PVar "l") (PVar "ls")) (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EVar "l") (EIf (EVar "otherwise") (EApp (EApp (EVar "nthLine") (EVar "ls")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isStandaloneSrc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isStandaloneSrc" ((PVar "srcLines") (PVar "c")) (EBinOp "==" (EApp (EVar "commentCol") (EVar "c")) (EApp (EVar "leadingSpaceCount") (EApp (EApp (EVar "nthLine") (EVar "srcLines")) (EApp (EVar "commentLine") (EVar "c"))))))
(DData Private "CKind" () ((variant "CTrailing" (ConPos)) (variant "CStandalone" (ConPos))) ())
(DTypeSig false "classifyKind" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "CKind"))))
(DFunDef false "classifyKind" ((PVar "srcLines") (PVar "c")) (EIf (EApp (EApp (EVar "isStandaloneSrc") (EVar "srcLines")) (EVar "c")) (EVar "CStandalone") (EVar "CTrailing")))
(DTypeSig false "classifyIdxs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))))))))
(DFunDef false "classifyIdxs" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "classifyIdxs" ((PVar "startLine") (PVar "srcLines") (PVar "eaten") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "classifyKind") (EVar "srcLines")) (EVar "c"))) (DoLet false false (PVar "idx") (EBinOp "-" (EBinOp "-" (EApp (EVar "commentLine") (EVar "c")) (EVar "startLine")) (EVar "eaten"))) (DoLet false false (PVar "eaten1") (EMatch (EVar "k") (arm (PCon "CStandalone") () (EBinOp "+" (EVar "eaten") (ELit (LInt 1)))) (arm (PCon "CTrailing") () (EVar "eaten")))) (DoExpr (EBinOp "::" (ETuple (EVar "c") (EVar "idx") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "classifyIdxs") (EVar "startLine")) (EVar "srcLines")) (EVar "eaten1")) (EVar "cs"))))))
(DTypeSig false "groupRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind")))))))
(DFunDef false "groupRuns" ((PList)) (EListLit))
(DFunDef false "groupRuns" ((PCons (PTuple (PVar "c") (PVar "i") (PVar "k")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "spanSameIdx") (EVar "i")) (EVar "rest")) (arm (PTuple (PVar "same") (PVar "rest2")) () (EBinOp "::" (ETuple (EVar "i") (EBinOp "::" (ETuple (EVar "c") (EVar "k")) (EApp (EApp (EVar "map") (EVar "dropIdx")) (EVar "same")))) (EApp (EVar "groupRuns") (EVar "rest2"))))))
(DTypeSig false "dropIdx" (TyFun (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind")) (TyTuple (TyCon "Comment") (TyCon "CKind"))))
(DFunDef false "dropIdx" ((PTuple (PVar "c") PWild (PVar "k"))) (ETuple (EVar "c") (EVar "k")))
(DTypeSig false "spanSameIdx" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind")))))))
(DFunDef false "spanSameIdx" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanSameIdx" ((PVar "i") (PCons (PTuple (PVar "c") (PVar "j") (PVar "k")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "j")) (EMatch (EApp (EApp (EVar "spanSameIdx") (EVar "i")) (EVar "rest")) (arm (PTuple (PVar "same") (PVar "rest2")) () (ETuple (EBinOp "::" (ETuple (EVar "c") (EVar "j") (EVar "k")) (EVar "same")) (EVar "rest2")))) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "c") (EVar "j") (EVar "k")) (EVar "rest")))))
(DTypeSig false "attachInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))))) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "attachInterior" ((PList) PWild PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "attachInterior" ((PCons (PVar "ln") (PVar "rest")) (PVar "groups") (PVar "idx")) (EMatch (EApp (EApp (EVar "takeGroupFor") (EVar "idx")) (EVar "groups")) (arm (PTuple (PVar "mine") (PVar "groupsRest")) () (EMatch (EApp (EApp (EApp (EVar "attachInterior") (EVar "rest")) (EVar "groupsRest")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (arm (PTuple (PVar "restLines") (PVar "consumed1")) () (EMatch (EVar "mine") (arm (PList) () (ETuple (EBinOp "::" (EVar "ln") (EVar "restLines")) (EVar "consumed1"))) (arm PWild () (EBlock (DoLet false false (PVar "standalone") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "isStandaloneP") (EVar "p")))) (EVar "mine"))) (DoLet false false (PVar "trailing") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isStandaloneP") (EVar "p"))))) (EVar "mine"))) (DoLet false false (PVar "ln1") (EApp (EApp (EVar "appendTrailingP") (EVar "ln")) (EVar "trailing"))) (DoLet false false (PVar "above") (EApp (EApp (EVar "standaloneLinesFor") (EVar "ln")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "standalone")))) (DoExpr (ETuple (EBinOp "++" (EVar "above") (EBinOp "::" (EVar "ln1") (EVar "restLines"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "mine")) (EVar "consumed1"))))))))))))
(DTypeSig false "isStandaloneP" (TyFun (TyTuple (TyCon "Comment") (TyCon "CKind")) (TyCon "Bool")))
(DFunDef false "isStandaloneP" ((PTuple PWild (PCon "CStandalone"))) (EVar "True"))
(DFunDef false "isStandaloneP" ((PTuple PWild (PCon "CTrailing"))) (EVar "False"))
(DTypeSig false "appendTrailingP" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))) (TyCon "String"))))
(DFunDef false "appendTrailingP" ((PVar "ln") (PList)) (EVar "ln"))
(DFunDef false "appendTrailingP" ((PVar "ln") (PCons (PTuple (PVar "c") PWild) (PVar "rest"))) (EApp (EApp (EVar "appendTrailingP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ln"))) (ELit (LString "  "))) (EApp (EVar "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString "")))) (EVar "rest")))
(DTypeSig false "takeGroupFor" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind")))))))))
(DFunDef false "takeGroupFor" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeGroupFor" ((PVar "idx") (PCons (PTuple (PVar "i") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "idx")) (ETuple (EVar "cs") (EVar "rest")) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "i") (EVar "cs")) (EVar "rest")))))
(DTypeSig false "standaloneLinesFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "standaloneLinesFor" ((PVar "ln") (PVar "cs")) (EBlock (DoLet false false (PVar "ind") (EApp (EVar "leadingSpaces") (EVar "ln"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EBinOp "++" (EVar "ind") (EApp (EVar "commentText") (EVar "c"))))) (EVar "cs")))))
(DTypeSig false "leadingSpaceCount" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "leadingSpaceCount" ((PVar "s")) (EApp (EApp (EApp (EVar "leadingSpaceCountGo") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "leadingSpaceCountGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "leadingSpaceCountGo" ((PVar "src") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "leadingSpaceCountGo") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingSpaces" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "leadingSpaces" ((PVar "s")) (EApp (EVar "spacesN") (EApp (EVar "leadingSpaceCount") (EVar "s"))))
(DTypeSig false "spacesN" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spacesN" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spacesN") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropConsumed" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "dropConsumed" ((PVar "cs") (PVar "consumed")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyLineEq") (EApp (EVar "commentLine") (EVar "c"))) (EVar "consumed"))))) (EVar "cs")))
(DTypeSig false "anyLineEq" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "Bool"))))
(DFunDef false "anyLineEq" (PWild (PList)) (EVar "False"))
(DFunDef false "anyLineEq" ((PVar "l") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EVar "True") (EApp (EApp (EVar "anyLineEq") (EVar "l")) (EVar "cs"))))
(DTypeSig false "intInList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intInList" (PWild (PList)) (EVar "False"))
(DFunDef false "intInList" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "intInList") (EVar "x")) (EVar "ys"))))
(DTypeSig false "commentOnLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "commentOnLine" ((PList) PWild) (EVar "None"))
(DFunDef false "commentOnLine" ((PCons (PVar "c") (PVar "cs")) (PVar "l")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentOnLine") (EVar "cs")) (EVar "l"))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "hi"))))) (EVar "cs")))
(DTypeSig false "chainCoversAll" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "chainCoversAll" ((PVar "cs") (PVar "lo") (PVar "hi") (PVar "ols")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "intInList") (EApp (EVar "commentLine") (EVar "c"))) (EVar "ols"))))) (EApp (EApp (EApp (EVar "spanComments") (EVar "cs")) (EVar "lo")) (EVar "hi"))))
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitByEndLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "splitByEndLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitByEndLine" ((PCons (PVar "c") (PVar "rest")) (PVar "endLine")) (EIf (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "rest")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "after"))))))
(DTypeSig false "appendAfterComments" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "FmtState"))))
(DFunDef false "appendAfterComments" ((PCon "FmtState" (PVar "p") (PVar "c") (PVar "v") (PVar "cur") (PVar "s")) (PVar "after")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "p")) (EBinOp "++" (EVar "c") (EVar "after"))) (EVar "v")) (EVar "cur")) (EVar "s")))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) () (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (EBlock (DoLet false false (PVar "stSpan") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces1")) (EVar "mine")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "stOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclSpan") (EVar "stSpan")) (EVar "srcLines")) (EVar "chainOls")) (EVar "decl")) (EVar "line")) (EVar "endLine"))) (DoExpr (EApp (EApp (EVar "appendAfterComments") (EVar "stOut")) (EVar "after")))))))))))
(DTypeSig false "stepDeclSpan" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepDeclSpan" ((PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "hasInterior") (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "useChain") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declChainLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useBlock") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EVar "useChain"))) (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declBlockLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useVerbatim") (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EApp (EVar "isDataDeclF") (EVar "decl"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EIf (EVar "useChain") (EBlock (DoLet false false (PVar "perOp") (EApp (EApp (EVar "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclChainCommented") (EVar "decl")) (EVar "perOp")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useBlock") (EBlock (DoLet false false (PVar "perStmt") (EApp (EApp (EVar "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclBlockCommented") (EVar "decl")) (EVar "perStmt")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useVerbatim") (EBlock (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclNormal") (EVar "st2")) (EVar "srcLines")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))))
(DTypeSig false "stepDeclNormal" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState")))))))
(DFunDef false "stepDeclNormal" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "srcLines") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))))) (DoLet false false (PVar "headerLine") (EIf (EVar "nfMulti") (EMatch (EVar "vlines1") (arm (PCons (PVar "vl") PWild) () (EVar "vl")) (arm (PList) () (EVar "line"))) (EVar "line"))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EBinOp "&&" (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EVar "not") (EVar "nfMulti"))) (EListLit) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "spliceInterior") (EVar "srcLines")) (EVar "declStr0")) (EVar "headerLine")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3b")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")))))))))))))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild (PList) PWild PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EListLit)) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EListLit)))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "c")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EVar "rest")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "chainLines") (PVar "comments") (PVar "_lastContentLine") (PVar "src")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))) (EVar "decls"))) (EBlock (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False"))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "decls")) (EVar "declPositions")) (EVar "chainLines"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild) () (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EApp (EApp (EVar "restoreTripleQuotedStrings") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EApp (EVar "collectComments") (EVar "src"))) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src"))))))
(DTypeSig false "isTripleStringAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isTripleStringAt" ((PVar "src") (PVar "pos")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "src")) (ELit (LString "\"\"\""))))
(DTypeSig false "stringTokenInfo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "String")))))))
(DFunDef false "stringTokenInfo" (PWild (PList) PWild) (EListLit))
(DFunDef false "stringTokenInfo" (PWild PWild (PList)) (EListLit))
(DFunDef false "stringTokenInfo" ((PVar "src") (PCons (PCon "TString" PWild) (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps"))) (EBlock (DoLet false false (PVar "triple") (EApp (EApp (EVar "isTripleStringAt") (EVar "src")) (EVar "s"))) (DoExpr (EBinOp "::" (ETuple (EVar "triple") (EIf (EVar "triple") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")) (ELit (LString "")))) (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "ts")) (EVar "ps"))))))
(DFunDef false "stringTokenInfo" ((PVar "src") (PCons PWild (PVar "ts")) (PCons PWild (PVar "ps"))) (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "ts")) (EVar "ps")))
(DTypeSig false "stringTokenSpans" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "stringTokenSpans" ((PList) PWild) (EListLit))
(DFunDef false "stringTokenSpans" (PWild (PList)) (EListLit))
(DFunDef false "stringTokenSpans" ((PCons (PCon "TString" PWild) (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps"))) (EBinOp "::" (ETuple (EVar "s") (EVar "e")) (EApp (EApp (EVar "stringTokenSpans") (EVar "ts")) (EVar "ps"))))
(DFunDef false "stringTokenSpans" ((PCons PWild (PVar "ts")) (PCons PWild (PVar "ps"))) (EApp (EApp (EVar "stringTokenSpans") (EVar "ts")) (EVar "ps")))
(DTypeSig false "tripleStringSubs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "tripleStringSubs" ((PCons (PTuple (PCon "True") (PVar "raw")) (PVar "is")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ss"))) (EBinOp "::" (ETuple (EVar "s") (EVar "e") (EVar "raw")) (EApp (EApp (EVar "tripleStringSubs") (EVar "is")) (EVar "ss"))))
(DFunDef false "tripleStringSubs" ((PCons (PTuple (PCon "False") PWild) (PVar "is")) (PCons PWild (PVar "ss"))) (EApp (EApp (EVar "tripleStringSubs") (EVar "is")) (EVar "ss")))
(DFunDef false "tripleStringSubs" (PWild PWild) (EListLit))
(DTypeSig false "applyTripleSubs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "applyTripleSubs" ((PList) (PVar "out")) (EVar "out"))
(DFunDef false "applyTripleSubs" ((PCons (PTuple (PVar "s") (PVar "e") (PVar "raw")) (PVar "rest")) (PVar "out")) (EApp (EApp (EVar "applyTripleSubs") (EVar "rest")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "s")) (EVar "out")) (EVar "raw")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "e")) (EApp (EVar "stringLength") (EVar "out"))) (EVar "out")))))
(DTypeSig false "restoreTripleQuotedStrings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "restoreTripleQuotedStrings" ((PVar "src") (PVar "formatted")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "origToks") (PVar "origSpans")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "formatted")) (arm (PTuple (PVar "fmtToks") (PVar "fmtSpans")) () (EBlock (DoLet false false (PVar "origInfo") (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "origToks")) (EVar "origSpans"))) (DoLet false false (PVar "fmtStrSpans") (EApp (EApp (EVar "stringTokenSpans") (EVar "fmtToks")) (EVar "fmtSpans"))) (DoExpr (EApp (EApp (EVar "applyTripleSubs") (EApp (EVar "reverseL") (EApp (EApp (EVar "tripleStringSubs") (EVar "origInfo")) (EVar "fmtStrSpans")))) (EVar "formatted")))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "printDeclChainCommented" false) (mem "declChainLen" false) (mem "printDeclBlockCommented" false) (mem "declBlockLen" false) (mem "Doc" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false) (mem "allList" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "countNl" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))))
(DTypeSig false "countNlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countNlChars" ((PVar "src") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "isSingleLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSingleLine" ((PVar "s")) (EBinOp "==" (EApp (EVar "countNl") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "blankLineIfNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "blankLineIfNeeded" ((PVar "pieces") (PVar "targetLine") (PVar "cursor") (PVar "started")) (EIf (EBinOp "&&" (EVar "started") (EBinOp ">=" (EBinOp "-" (EVar "targetLine") (EVar "cursor")) (ELit (LInt 2)))) (EBinOp "::" (ELit (LString "\n")) (EVar "pieces")) (EVar "pieces")))
(DTypeSig false "emitComment" (TyFun (TyCon "FmtState") (TyFun (TyCon "Comment") (TyCon "FmtState"))))
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started")) PWild) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started"))))
(DTypeSig false "takeNVariantLines" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "takeNVariantLines" ((PVar "vlines") (PVar "k")) (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "vlines")) (EVar "k")) (EListLit)))
(DTypeSig false "takeNVarGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "takeNVarGo" ((PVar "vlines") (PVar "k") (PVar "acc")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EMatch (EVar "vlines") (arm (PList) () (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc")))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "rest")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "x") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeBefore" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeBefore" ((PVar "cs") (PVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "cs")) (EVar "line")) (EListLit)))
(DTypeSig false "takeBeforeGo" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "takeBeforeGo" ((PList) PWild (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "takeBeforeGo" ((PCons (PVar "c") (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "rest")) (EVar "line")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "acc"))) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "takeSameLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeSameLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeSameLine" ((PCons (PVar "c") (PVar "rest")) (PVar "line")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest")) (EVar "line")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "more")) (EVar "leftover")))) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "vcommentsFor" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "vcommentsFor" ((PVar "cs") (PList)) (ETuple (EListLit) (EVar "cs")))
(DFunDef false "vcommentsFor" ((PVar "cs") (PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EApp (EVar "takeBefore") (EVar "cs")) (EVar "l")) (arm (PTuple (PVar "leading") (PVar "rest1")) () (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest1")) (EVar "l")) (arm (PTuple (PVar "trailing") (PVar "rest2")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "rest2")) (EVar "ls")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (ETuple (EVar "leading") (EVar "trailing")) (EVar "more")) (EVar "leftover")))))))))
(DTypeSig false "allEmptyPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "allEmptyPairs" ((PList)) (EVar "True"))
(DFunDef false "allEmptyPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ld")) (EApp (EVar "isEmptyL") (EVar "tr"))) (EApp (EVar "allEmptyPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PAs "d" (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PRec "DData" ((rf "dataCtors" (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))))) false)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))))))
(DFunDef false "renderNamedFieldMulti" ((PVar "st") (PVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st")) (EVar "decl")))
(DTypeSig false "spliceInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "spliceInterior" ((PVar "srcLines") (PVar "declStr") (PVar "startLine") (PVar "interior")) (EBlock (DoLet false false (PVar "outLines") (EApp (EVar "splitNl") (EVar "declStr"))) (DoLet false false (PVar "classified") (EApp (EApp (EApp (EApp (EVar "classifyIdxs") (EVar "startLine")) (EVar "srcLines")) (ELit (LInt 0))) (EVar "interior"))) (DoLet false false (PVar "groups") (EApp (EVar "groupRuns") (EVar "classified"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "attachInterior") (EVar "outLines")) (EVar "groups")) (ELit (LInt 0))) (arm (PTuple (PVar "newLines") (PVar "consumed")) () (ETuple (EApp (EVar "joinNl") (EVar "newLines")) (EVar "consumed")))))))
(DTypeSig false "nthLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "nthLine" ((PList) PWild) (ELit (LString "")))
(DFunDef false "nthLine" ((PCons (PVar "l") (PVar "ls")) (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EVar "l") (EIf (EVar "otherwise") (EApp (EApp (EVar "nthLine") (EVar "ls")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isStandaloneSrc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isStandaloneSrc" ((PVar "srcLines") (PVar "c")) (EBinOp "==" (EApp (EVar "commentCol") (EVar "c")) (EApp (EVar "leadingSpaceCount") (EApp (EApp (EVar "nthLine") (EVar "srcLines")) (EApp (EVar "commentLine") (EVar "c"))))))
(DData Private "CKind" () ((variant "CTrailing" (ConPos)) (variant "CStandalone" (ConPos))) ())
(DTypeSig false "classifyKind" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "CKind"))))
(DFunDef false "classifyKind" ((PVar "srcLines") (PVar "c")) (EIf (EApp (EApp (EVar "isStandaloneSrc") (EVar "srcLines")) (EVar "c")) (EVar "CStandalone") (EVar "CTrailing")))
(DTypeSig false "classifyIdxs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))))))))
(DFunDef false "classifyIdxs" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "classifyIdxs" ((PVar "startLine") (PVar "srcLines") (PVar "eaten") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "classifyKind") (EVar "srcLines")) (EVar "c"))) (DoLet false false (PVar "idx") (EBinOp "-" (EBinOp "-" (EApp (EVar "commentLine") (EVar "c")) (EVar "startLine")) (EVar "eaten"))) (DoLet false false (PVar "eaten1") (EMatch (EVar "k") (arm (PCon "CStandalone") () (EBinOp "+" (EVar "eaten") (ELit (LInt 1)))) (arm (PCon "CTrailing") () (EVar "eaten")))) (DoExpr (EBinOp "::" (ETuple (EVar "c") (EVar "idx") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "classifyIdxs") (EVar "startLine")) (EVar "srcLines")) (EVar "eaten1")) (EVar "cs"))))))
(DTypeSig false "groupRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind")))))))
(DFunDef false "groupRuns" ((PList)) (EListLit))
(DFunDef false "groupRuns" ((PCons (PTuple (PVar "c") (PVar "i") (PVar "k")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "spanSameIdx") (EVar "i")) (EVar "rest")) (arm (PTuple (PVar "same") (PVar "rest2")) () (EBinOp "::" (ETuple (EVar "i") (EBinOp "::" (ETuple (EVar "c") (EVar "k")) (EApp (EApp (EMethodRef "map") (EVar "dropIdx")) (EVar "same")))) (EApp (EVar "groupRuns") (EVar "rest2"))))))
(DTypeSig false "dropIdx" (TyFun (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind")) (TyTuple (TyCon "Comment") (TyCon "CKind"))))
(DFunDef false "dropIdx" ((PTuple (PVar "c") PWild (PVar "k"))) (ETuple (EVar "c") (EVar "k")))
(DTypeSig false "spanSameIdx" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "Int") (TyCon "CKind")))))))
(DFunDef false "spanSameIdx" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanSameIdx" ((PVar "i") (PCons (PTuple (PVar "c") (PVar "j") (PVar "k")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "j")) (EMatch (EApp (EApp (EVar "spanSameIdx") (EVar "i")) (EVar "rest")) (arm (PTuple (PVar "same") (PVar "rest2")) () (ETuple (EBinOp "::" (ETuple (EVar "c") (EVar "j") (EVar "k")) (EVar "same")) (EVar "rest2")))) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "c") (EVar "j") (EVar "k")) (EVar "rest")))))
(DTypeSig false "attachInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))))) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "attachInterior" ((PList) PWild PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "attachInterior" ((PCons (PVar "ln") (PVar "rest")) (PVar "groups") (PVar "idx")) (EMatch (EApp (EApp (EVar "takeGroupFor") (EVar "idx")) (EVar "groups")) (arm (PTuple (PVar "mine") (PVar "groupsRest")) () (EMatch (EApp (EApp (EApp (EVar "attachInterior") (EVar "rest")) (EVar "groupsRest")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (arm (PTuple (PVar "restLines") (PVar "consumed1")) () (EMatch (EVar "mine") (arm (PList) () (ETuple (EBinOp "::" (EVar "ln") (EVar "restLines")) (EVar "consumed1"))) (arm PWild () (EBlock (DoLet false false (PVar "standalone") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "isStandaloneP") (EVar "p")))) (EVar "mine"))) (DoLet false false (PVar "trailing") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isStandaloneP") (EVar "p"))))) (EVar "mine"))) (DoLet false false (PVar "ln1") (EApp (EApp (EVar "appendTrailingP") (EVar "ln")) (EVar "trailing"))) (DoLet false false (PVar "above") (EApp (EApp (EVar "standaloneLinesFor") (EVar "ln")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "standalone")))) (DoExpr (ETuple (EBinOp "++" (EVar "above") (EBinOp "::" (EVar "ln1") (EVar "restLines"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "mine")) (EVar "consumed1"))))))))))))
(DTypeSig false "isStandaloneP" (TyFun (TyTuple (TyCon "Comment") (TyCon "CKind")) (TyCon "Bool")))
(DFunDef false "isStandaloneP" ((PTuple PWild (PCon "CStandalone"))) (EVar "True"))
(DFunDef false "isStandaloneP" ((PTuple PWild (PCon "CTrailing"))) (EVar "False"))
(DTypeSig false "appendTrailingP" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))) (TyCon "String"))))
(DFunDef false "appendTrailingP" ((PVar "ln") (PList)) (EVar "ln"))
(DFunDef false "appendTrailingP" ((PVar "ln") (PCons (PTuple (PVar "c") PWild) (PVar "rest"))) (EApp (EApp (EVar "appendTrailingP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ln"))) (ELit (LString "  "))) (EApp (EMethodRef "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString "")))) (EVar "rest")))
(DTypeSig false "takeGroupFor" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Comment") (TyCon "CKind")))))))))
(DFunDef false "takeGroupFor" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeGroupFor" ((PVar "idx") (PCons (PTuple (PVar "i") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "idx")) (ETuple (EVar "cs") (EVar "rest")) (ETuple (EListLit) (EBinOp "::" (ETuple (EVar "i") (EVar "cs")) (EVar "rest")))))
(DTypeSig false "standaloneLinesFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "standaloneLinesFor" ((PVar "ln") (PVar "cs")) (EBlock (DoLet false false (PVar "ind") (EApp (EVar "leadingSpaces") (EVar "ln"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EBinOp "++" (EVar "ind") (EApp (EVar "commentText") (EVar "c"))))) (EVar "cs")))))
(DTypeSig false "leadingSpaceCount" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "leadingSpaceCount" ((PVar "s")) (EApp (EApp (EApp (EVar "leadingSpaceCountGo") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "leadingSpaceCountGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "leadingSpaceCountGo" ((PVar "src") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "leadingSpaceCountGo") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingSpaces" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "leadingSpaces" ((PVar "s")) (EApp (EVar "spacesN") (EApp (EVar "leadingSpaceCount") (EVar "s"))))
(DTypeSig false "spacesN" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spacesN" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spacesN") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropConsumed" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "dropConsumed" ((PVar "cs") (PVar "consumed")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyLineEq") (EApp (EVar "commentLine") (EVar "c"))) (EVar "consumed"))))) (EVar "cs")))
(DTypeSig false "anyLineEq" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "Bool"))))
(DFunDef false "anyLineEq" (PWild (PList)) (EVar "False"))
(DFunDef false "anyLineEq" ((PVar "l") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EVar "True") (EApp (EApp (EVar "anyLineEq") (EVar "l")) (EVar "cs"))))
(DTypeSig false "intInList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intInList" (PWild (PList)) (EVar "False"))
(DFunDef false "intInList" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "intInList") (EVar "x")) (EVar "ys"))))
(DTypeSig false "commentOnLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "commentOnLine" ((PList) PWild) (EVar "None"))
(DFunDef false "commentOnLine" ((PCons (PVar "c") (PVar "cs")) (PVar "l")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentOnLine") (EVar "cs")) (EVar "l"))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "hi"))))) (EVar "cs")))
(DTypeSig false "chainCoversAll" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "chainCoversAll" ((PVar "cs") (PVar "lo") (PVar "hi") (PVar "ols")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "intInList") (EApp (EVar "commentLine") (EVar "c"))) (EVar "ols"))))) (EApp (EApp (EApp (EVar "spanComments") (EVar "cs")) (EVar "lo")) (EVar "hi"))))
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitByEndLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "splitByEndLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitByEndLine" ((PCons (PVar "c") (PVar "rest")) (PVar "endLine")) (EIf (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "rest")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "after"))))))
(DTypeSig false "appendAfterComments" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "FmtState"))))
(DFunDef false "appendAfterComments" ((PCon "FmtState" (PVar "p") (PVar "c") (PVar "v") (PVar "cur") (PVar "s")) (PVar "after")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "p")) (EBinOp "++" (EVar "c") (EVar "after"))) (EVar "v")) (EVar "cur")) (EVar "s")))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) () (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (EBlock (DoLet false false (PVar "stSpan") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces1")) (EVar "mine")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "stOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclSpan") (EVar "stSpan")) (EVar "srcLines")) (EVar "chainOls")) (EVar "decl")) (EVar "line")) (EVar "endLine"))) (DoExpr (EApp (EApp (EVar "appendAfterComments") (EVar "stOut")) (EVar "after")))))))))))
(DTypeSig false "stepDeclSpan" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepDeclSpan" ((PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "hasInterior") (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "useChain") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declChainLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useBlock") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EVar "useChain"))) (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declBlockLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useVerbatim") (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EApp (EVar "isDataDeclF") (EVar "decl"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EIf (EVar "useChain") (EBlock (DoLet false false (PVar "perOp") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclChainCommented") (EVar "decl")) (EVar "perOp")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useBlock") (EBlock (DoLet false false (PVar "perStmt") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclBlockCommented") (EVar "decl")) (EVar "perStmt")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useVerbatim") (EBlock (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclNormal") (EVar "st2")) (EVar "srcLines")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))))
(DTypeSig false "stepDeclNormal" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState")))))))
(DFunDef false "stepDeclNormal" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "srcLines") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))))) (DoLet false false (PVar "headerLine") (EIf (EVar "nfMulti") (EMatch (EVar "vlines1") (arm (PCons (PVar "vl") PWild) () (EVar "vl")) (arm (PList) () (EVar "line"))) (EVar "line"))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EBinOp "&&" (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EVar "not") (EVar "nfMulti"))) (EListLit) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "spliceInterior") (EVar "srcLines")) (EVar "declStr0")) (EVar "headerLine")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3b")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")))))))))))))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild (PList) PWild PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EListLit)) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EListLit)))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "c")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EVar "rest")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "chainLines") (PVar "comments") (PVar "_lastContentLine") (PVar "src")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))) (EVar "decls"))) (EBlock (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False"))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "decls")) (EVar "declPositions")) (EVar "chainLines"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild) () (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EApp (EApp (EVar "restoreTripleQuotedStrings") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EApp (EVar "collectComments") (EVar "src"))) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src"))))))
(DTypeSig false "isTripleStringAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isTripleStringAt" ((PVar "src") (PVar "pos")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "src")) (ELit (LString "\"\"\""))))
(DTypeSig false "stringTokenInfo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "String")))))))
(DFunDef false "stringTokenInfo" (PWild (PList) PWild) (EListLit))
(DFunDef false "stringTokenInfo" (PWild PWild (PList)) (EListLit))
(DFunDef false "stringTokenInfo" ((PVar "src") (PCons (PCon "TString" PWild) (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps"))) (EBlock (DoLet false false (PVar "triple") (EApp (EApp (EVar "isTripleStringAt") (EVar "src")) (EVar "s"))) (DoExpr (EBinOp "::" (ETuple (EVar "triple") (EIf (EVar "triple") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")) (ELit (LString "")))) (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "ts")) (EVar "ps"))))))
(DFunDef false "stringTokenInfo" ((PVar "src") (PCons PWild (PVar "ts")) (PCons PWild (PVar "ps"))) (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "ts")) (EVar "ps")))
(DTypeSig false "stringTokenSpans" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "stringTokenSpans" ((PList) PWild) (EListLit))
(DFunDef false "stringTokenSpans" (PWild (PList)) (EListLit))
(DFunDef false "stringTokenSpans" ((PCons (PCon "TString" PWild) (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps"))) (EBinOp "::" (ETuple (EVar "s") (EVar "e")) (EApp (EApp (EVar "stringTokenSpans") (EVar "ts")) (EVar "ps"))))
(DFunDef false "stringTokenSpans" ((PCons PWild (PVar "ts")) (PCons PWild (PVar "ps"))) (EApp (EApp (EVar "stringTokenSpans") (EVar "ts")) (EVar "ps")))
(DTypeSig false "tripleStringSubs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))
(DFunDef false "tripleStringSubs" ((PCons (PTuple (PCon "True") (PVar "raw")) (PVar "is")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ss"))) (EBinOp "::" (ETuple (EVar "s") (EVar "e") (EVar "raw")) (EApp (EApp (EVar "tripleStringSubs") (EVar "is")) (EVar "ss"))))
(DFunDef false "tripleStringSubs" ((PCons (PTuple (PCon "False") PWild) (PVar "is")) (PCons PWild (PVar "ss"))) (EApp (EApp (EVar "tripleStringSubs") (EVar "is")) (EVar "ss")))
(DFunDef false "tripleStringSubs" (PWild PWild) (EListLit))
(DTypeSig false "applyTripleSubs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "applyTripleSubs" ((PList) (PVar "out")) (EVar "out"))
(DFunDef false "applyTripleSubs" ((PCons (PTuple (PVar "s") (PVar "e") (PVar "raw")) (PVar "rest")) (PVar "out")) (EApp (EApp (EVar "applyTripleSubs") (EVar "rest")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "s")) (EVar "out")) (EVar "raw")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "e")) (EApp (EVar "stringLength") (EVar "out"))) (EVar "out")))))
(DTypeSig false "restoreTripleQuotedStrings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "restoreTripleQuotedStrings" ((PVar "src") (PVar "formatted")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "origToks") (PVar "origSpans")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "formatted")) (arm (PTuple (PVar "fmtToks") (PVar "fmtSpans")) () (EBlock (DoLet false false (PVar "origInfo") (EApp (EApp (EApp (EVar "stringTokenInfo") (EVar "src")) (EVar "origToks")) (EVar "origSpans"))) (DoLet false false (PVar "fmtStrSpans") (EApp (EApp (EVar "stringTokenSpans") (EVar "fmtToks")) (EVar "fmtSpans"))) (DoExpr (EApp (EApp (EVar "applyTripleSubs") (EApp (EVar "reverseL") (EApp (EApp (EVar "tripleStringSubs") (EVar "origInfo")) (EVar "fmtStrSpans")))) (EVar "formatted")))))))))
