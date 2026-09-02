# META
source_lines=728
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted comment-preserving formatter — `formatProgram`, the driver over
-- compiler/tools/printer.mdk's comment-free Doc printer.
--
-- Walks the top-level declarations in source order, interleaving the lexer's
-- captured comment side-channel (compiler/frontend/lexer.mdk `collectComments`
-- → `Comment line col text`) using the parser's position side-channel
-- (compiler/frontend/parser.mdk `parseWithPositions` → `Positions`: per-decl
-- `(line, end_line)`, flat `data`-variant start lines).
--
-- Comment placement, per declaration:
--   * leading comments (`c_line < decl.line`) flush as standalone lines, with
--     a blank-line gap when `target_line - cursor >= 2`;
--   * a single-line comment on `decl.end_line` is a TRAILING comment rendered
--     inline after the decl (`"  " ++ text`);
--   * a `DData` decl consumes its variants' source lines so an interior
--     comment anchors before the variant it precedes
--     (`printDataDeclCommented`) or, for a single-variant record, before the
--     field it precedes (`printNamedFieldData`);
--   * every other interior comment is handed to the printer
--     (`setComments`), which attaches it to the layout unit it documents —
--     the statement, arm, element, argument, operand or method — so it rides
--     along with that unit through any reflow;
--   * a comment the printer could not place makes the whole declaration fall
--     back to its ORIGINAL source text (the verbatim safety net), so no
--     comment is ever moved across a boundary or dropped;
--   * every comment is accounted for at the end (`checkCommentCount`): a
--     formatter run that would lose one refuses to produce output.
--
-- Pure state threading (no refs): the cursor quartet (cs / vlines / cursor /
-- started) plus the output pieces is carried as an explicit `FmtState` and the
-- output pieces are accumulated reversed, then concatenated once at the end.

import frontend.ast.{DataVis(..), Variant(..), ConPayload(..), Decl(..)}
import tools.printer.{
  render,
  printDecl,
  printDataDeclCommented,
  printNamedFieldData,
  PComment(..),
  setComments,
  takeLeftoverComments,
  commentsPlaced,
  setTrailingCommas,
  setImportForced,
  setUnitStarts,
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
  declPosLine,
  declPosEndLine,
  trailingCommaLocs,
  unitStarts,
}
import support.util.{
  listLen,
  reverseL,
  isEmptyL,
  isNonEmptyL,
  filterList,
  splitNl,
  joinNl,
}

-- ── State ─────────────────────────────────────────
-- pieces : output fragments, REVERSED (cons-prepend, reverse+concat at end)
-- cs     : remaining captured comments, source order
-- vlines : remaining `data`-variant start lines, decl order
-- cursor : last consumed source line
-- started: whether any output has been emitted (gates the blank-line rule)
-- placed : comments emitted so far (for the final accounting)
data FmtState = FmtState (List String) (List Comment) (List Int) Int Bool Int

-- ── String helpers ────────────────────────────────

-- Count '\n' in a comment lexeme — a multi-line block comment advances the
-- cursor by that many lines.
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
-- must be single-line.
isSingleLine : String -> Bool
isSingleLine s = countNl s == 0

-- ── Blank-line / comment emission ─────────────────

-- Prepend a blank line when started and the gap to `targetLine` is >= 2.
blankLineIfNeeded : List String -> Int -> Int -> Bool -> List String
blankLineIfNeeded pieces targetLine cursor started =
  if started && targetLine - cursor >= 2 then "\n" :: pieces else pieces

-- Emit one standalone comment: blank-line gate, then the lexeme + newline;
-- advance cursor past any embedded newlines; mark started.
emitComment : FmtState -> Comment -> FmtState
emitComment (FmtState pieces cs vlines cursor started placed) c =
  let pieces1 = blankLineIfNeeded pieces (commentLine c) cursor started
  let pieces2 = "\n" :: commentText c :: pieces1
  let nls = countNl (commentText c)
  FmtState pieces2 cs vlines (commentLine c + nls) True (placed + 1)

-- Emit all pending comments strictly above `line`.
flushBefore : FmtState -> Int -> FmtState
flushBefore (FmtState pieces [] vlines cursor started placed) _ =
  FmtState pieces [] vlines cursor started placed
flushBefore (FmtState pieces (c :: rest) vlines cursor started placed) line =
  if commentLine c < line then
    flushBefore
      (emitComment (FmtState pieces rest vlines cursor started placed) c)
      line
  else
    FmtState pieces (c :: rest) vlines cursor started placed

-- ── Variant-line + interior-comment bucketing (DData) ─────

-- Take the next k variant start lines off `vlines`.
takeNVariantLines : List Int -> Int -> (List Int, List Int)
takeNVariantLines vlines k = takeNVarGo vlines k []

takeNVarGo : List Int -> Int -> List Int -> (List Int, List Int)
takeNVarGo vlines k acc
  | k <= 0 = (vlines, reverseL acc)
  | otherwise = match vlines
    [] => (vlines, reverseL acc)
    x :: rest => takeNVarGo rest (k - 1) (x :: acc)

-- Pop (WITHOUT emitting) the pending comments strictly above `line`, returning
-- their lexemes in source order plus the leftover comment stream.
takeBefore : List Comment -> Int -> (List String, List Comment)
takeBefore cs line = takeBeforeGo cs line []

takeBeforeGo : List Comment -> Int -> List String -> (List String, List Comment)
takeBeforeGo [] _ acc = (reverseL acc, [])
takeBeforeGo (c :: rest) line acc =
  if commentLine c < line then
    takeBeforeGo rest line (commentText c :: acc)
  else
    (reverseL acc, c :: rest)

-- Pop the single-line comments ON `line` (a variant's TRAILING comments).
takeSameLine : List Comment -> Int -> (List String, List Comment)
takeSameLine [] _ = ([], [])
takeSameLine (c :: rest) line =
  if commentLine c == line
    && isSingleLine (commentText c) then match takeSameLine rest line
    (more, leftover) => (commentText c :: more, leftover)
  else
    ([], c :: rest)

-- For each variant line, pop its preceding (leading) comments AND its same-line
-- (trailing) comments.  Returns per-variant (leading, trailing) lexeme lists
-- (parallel to vls) and the leftover stream.
vcommentsFor : List Comment ->
  List Int ->
  (List (List String, List String), List Comment)
vcommentsFor cs [] = ([], cs)
vcommentsFor cs (l :: ls) = match takeBefore cs l
  (leading, rest1) => match takeSameLine rest1 l
    (trailing, rest2) => match vcommentsFor rest2 ls
      (more, leftover) => ((leading, trailing) :: more, leftover)

allEmptyPairs : List (List String, List String) -> Bool
allEmptyPairs [] = True
allEmptyPairs ((ld, tr) :: xs) = isEmptyL ld && isEmptyL tr && allEmptyPairs xs

countPairs : List (List String, List String) -> Int
countPairs [] = 0
countPairs ((ld, tr) :: xs) = listLen ld + listLen tr + countPairs xs

-- ── Per-declaration rendering ─────────────────────

-- Render one declaration's Doc, consuming variant lines for a DData (always,
-- to keep vlines aligned) and interleaving any interior comment before the
-- variant it documents.  Other decls render opaquely.
declDoc : FmtState -> Decl -> (String, FmtState)
declDoc (FmtState pieces cs vlines cursor started placed) (d@(DData { dataVis = vis, dataName = n, dataParams = params, dataParamKinds = kinds, dataCtors = variants, dataDerives = derives })) = match (takeNVariantLines
  vlines
  (listLen variants))
  (vlinesRest, vls) => match vcommentsFor cs vls
    (vcomments, csRest) =>
      if listLen vcomments == listLen variants
        && not (allEmptyPairs vcomments) then
        (
          render
            (printDataDeclCommented
              vis
              n
              params
              kinds
              variants
              derives
              vcomments),
          FmtState
            pieces
            csRest
            vlinesRest
            cursor
            started
            (placed + countPairs vcomments),
        )
      else
        (
          render (printDecl d),
          FmtState pieces cs vlinesRest cursor started placed,
        )
declDoc st decl = (render (printDecl decl), st)

-- ── Trailing comments ─────────────────────────────

-- A comment on the decl's final source line, single-line, is trailing: pull it
-- out of the pending stream so it renders inline.  Order-preserving partition.
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
appendTrailing pieces (c :: cs) =
  appendTrailing (commentText c :: "  " :: pieces) cs

-- ── Interior comments ─────────────────────────────

-- A comment strictly inside a multi-line decl's span (line < c.line <
-- end_line), or on the decl's own first line after its header.
isInterior : Int -> Int -> Comment -> Bool
isInterior startLine endLine c =
  let l = commentLine c
  l >= startLine && l < endLine
    || l == endLine && not (isSingleLine (commentText c))

isDataDeclF : Decl -> Bool
isDataDeclF (DData { dataOrigin = _ }) = True
isDataDeclF (DAttrib _ inner) = isDataDeclF inner
isDataDeclF _ = False

isImportDecl : Decl -> Bool
isImportDecl (DUse _ _ _) = True
isImportDecl _ = False

-- A single-variant record-style data decl (`data X = X { f : T, ... }`).  Its
-- per-field trailing comments cannot be carried by the per-VARIANT vcommentsFor
-- machinery (one variant, many field comments) — such a decl renders
-- one-field-per-line (printNamedFieldData) and the comments are spliced in by
-- source-line index.  Only the bare (non-attribute-wrapped) shape.
isSingleNamedFieldData : Decl -> Bool
isSingleNamedFieldData (DData { dataCtors = [Variant _ (ConNamed _ _)] }) = True
isSingleNamedFieldData _ = False

-- Render a single-variant named-field data decl one-field-per-line, consuming
-- its one variant line (to keep vlines aligned).
renderNamedFieldMulti : FmtState -> Decl -> (String, FmtState)
renderNamedFieldMulti (FmtState pieces cs vlines cursor started placed) (DData { dataVis = vis, dataName = n, dataParams = params, dataParamKinds = kinds, dataCtors = variants, dataDerives = derives }) = match (takeNVariantLines
  vlines
  1)
  (vlinesRest, _) => (
    render (printNamedFieldData vis n params kinds variants derives),
    FmtState pieces cs vlinesRest cursor started placed,
  )
renderNamedFieldMulti st decl = declDoc st decl

-- Splice interior comments into a rendered record decl by output-line index
-- (header on line 0, field i on line i+1): a STANDALONE comment renders as its
-- own line above the field it precedes; a TRAILING comment is appended to its
-- field's line.  Returns (newDeclStr, consumedComments).
spliceInterior : List String ->
  String ->
  Int ->
  List Comment ->
  (String, List Comment)
spliceInterior srcLines declStr startLine interior =
  let outLines = splitNl declStr
  let classified = classifyIdxs startLine srcLines 0 interior
  let groups = groupRuns classified
  match attachInterior outLines groups 0
    (newLines, consumed) => (joinNl newLines, consumed)

-- Fetch source line `n` (1-indexed) from the whole-file `srcLines`, or "".
nthLine : List String -> Int -> String
nthLine [] _ = ""
nthLine (l :: ls) n
  | n <= 1 = l
  | otherwise = nthLine ls (n - 1)

-- A comment is STANDALONE iff nothing but whitespace precedes it on its own
-- SOURCE line — its column equals that line's own leading-space count.
isStandaloneSrc : List String -> Comment -> Bool
isStandaloneSrc srcLines c =
  commentCol c == leadingSpaceCount (nthLine srcLines (commentLine c))

data CKind = CTrailing | CStandalone

classifyKind : List String -> Comment -> CKind
classifyKind srcLines c =
  if isStandaloneSrc srcLines c then CStandalone else CTrailing

-- Map each interior comment to its OUTPUT-line index and its kind, accounting
-- for the source lines already eaten by earlier STANDALONE comments.
classifyIdxs : Int ->
  List String ->
  Int ->
  List Comment ->
  List (Comment, Int, CKind)
classifyIdxs _ _ _ [] = []
classifyIdxs startLine srcLines eaten (c :: cs) =
  let k = classifyKind srcLines c
  let idx = commentLine c - startLine - eaten
  let eaten1 = match k
    CStandalone => eaten + 1
    CTrailing => eaten
  (c, idx, k) :: classifyIdxs startLine srcLines eaten1 cs

-- Group consecutive (source-order) comments sharing the same computed index.
groupRuns : List (Comment, Int, CKind) -> List (Int, List (Comment, CKind))
groupRuns [] = []
groupRuns ((c, i, k) :: rest) = match spanSameIdx i rest
  (same, rest2) => (i, (c, k) :: map dropIdx same) :: groupRuns rest2

dropIdx : (Comment, Int, CKind) -> (Comment, CKind)
dropIdx (c, _, k) = (c, k)

spanSameIdx : Int ->
  List (Comment, Int, CKind) ->
  (List (Comment, Int, CKind), List (Comment, Int, CKind))
spanSameIdx _ [] = ([], [])
spanSameIdx i ((c, j, k) :: rest) =
  if i == j then match spanSameIdx i rest
    (same, rest2) => ((c, j, k) :: same, rest2)
  else
    ([], (c, j, k) :: rest)

attachInterior : List String ->
  List (Int, List (Comment, CKind)) ->
  Int ->
  (List String, List Comment)
attachInterior [] _ _ = ([], [])
attachInterior (ln :: rest) groups idx = match takeGroupFor idx groups
  (mine, groupsRest) => match attachInterior rest groupsRest (idx + 1)
    (restLines, consumed1) => match mine
      [] => (ln :: restLines, consumed1)

      _ =>
        let standalone = filterList (p => isStandaloneP p) mine
        let trailing = filterList (p => not (isStandaloneP p)) mine
        let ln1 = appendTrailingP ln trailing
        let above = standaloneLinesFor ln (map fst standalone)
        (above ++ (ln1 :: restLines), map fst mine ++ consumed1)

isStandaloneP : (Comment, CKind) -> Bool
isStandaloneP (_, CStandalone) = True
isStandaloneP (_, CTrailing) = False

appendTrailingP : String -> List (Comment, CKind) -> String
appendTrailingP ln [] = ln
appendTrailingP ln ((c, _) :: rest) =
  appendTrailingP "\{ln}  \{commentText c}" rest

takeGroupFor : Int ->
  List (Int, List (Comment, CKind)) ->
  (List (Comment, CKind), List (Int, List (Comment, CKind)))
takeGroupFor _ [] = ([], [])
takeGroupFor idx ((i, cs) :: rest) =
  if i == idx then (cs, rest) else ([], (i, cs) :: rest)

-- Render each comment in `cs` as its own line, indented to match `ln`'s own
-- leading whitespace.
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
anyLineEq l (c :: cs) = if commentLine c == l then True else anyLineEq l cs

-- ── Verbatim safety-net ───────────────────────────
-- A declaration with an interior comment the printer could not attach keeps
-- its ORIGINAL source lines: no comment is ever moved or dropped.

-- Extract source lines [startLine .. endLine] (1-based, inclusive) and rejoin
-- them exactly.
verbatimSpan : List String -> Int -> Int -> String
verbatimSpan srcLines startLine endLine =
  joinNl (spanLines srcLines 1 startLine endLine)

spanLines : List String -> Int -> Int -> Int -> List String
spanLines [] _ _ _ = []
spanLines (l :: ls) idx startLine endLine
  | idx > endLine = []
  | idx >= startLine = l :: spanLines ls (idx + 1) startLine endLine
  | otherwise = spanLines ls (idx + 1) startLine endLine

-- ── Main walk ─────────────────────────────────────

-- Split the (source-line-sorted) comment stream into those on/before
-- `endLine` — this decl's span — and those strictly after it.  The perf seam:
-- every per-decl scan below is bounded by this decl's own comments.
splitByEndLine : List Comment -> Int -> (List Comment, List Comment)
splitByEndLine [] _ = ([], [])
splitByEndLine (c :: rest) endLine =
  if commentLine c > endLine then
    ([], c :: rest)
  else match splitByEndLine rest endLine
    (mine, after) => (c :: mine, after)

appendAfterComments : FmtState -> List Comment -> FmtState
appendAfterComments (FmtState p c v cur s pl) after =
  FmtState p (c ++ after) v cur s pl

-- The printer's view of a comment: line, column, lexeme, standalone flag.
toPComment : List String -> Comment -> PComment
toPComment srcLines c =
  PComment
    (commentLine c)
    (commentCol c)
    (commentText c)
    (isStandaloneSrc srcLines c)

-- A trailing comma the parser recorded on one of the decl's lines (an import
-- member list's pin).
anyCommaWithin : Int -> Int -> List (Int, Int) -> Bool
anyCommaWithin _ _ [] = False
anyCommaWithin lo hi ((l, _) :: rest) =
  l >= lo && l <= hi || anyCommaWithin lo hi rest

-- Process one (decl, declPos) pair.  Narrows the pending comment stream to
-- this decl's span before dispatching; the after-span remainder is
-- re-appended on the way out.
stepDecl : FmtState ->
  List String ->
  List (Int, Int) ->
  Decl ->
  DeclPos ->
  FmtState
stepDecl st srcLines commas decl dp =
  let line = declPosLine dp
  let endLine = declPosEndLine dp
  let st1 = flushBefore st line
  match st1
    FmtState pieces1 cs1 vlines1 cursor1 started1 placed1 => match (splitByEndLine
      cs1
      endLine)
      (mine, after) =>
        let stSpan = FmtState pieces1 mine vlines1 cursor1 started1 placed1
        let stOut = stepDeclSpan stSpan srcLines commas decl line endLine
        appendAfterComments stOut after

-- The per-decl body, over a comment stream narrowed to [line, endLine].
stepDeclSpan : FmtState ->
  List String ->
  List (Int, Int) ->
  Decl ->
  Int ->
  Int ->
  FmtState
stepDeclSpan (FmtState pieces1 cs1 vlines1 cursor1 started1 placed1) srcLines commas decl line endLine =
  let pieces2 = blankLineIfNeeded pieces1 line cursor1 started1
  let st2 = FmtState pieces2 cs1 vlines1 cursor1 started1 placed1
  if isDataDeclF decl then
    stepDataDecl st2 srcLines decl line endLine
  else
    stepExprDecl st2 srcLines commas decl line endLine

-- A non-data declaration: the printer places every interior comment; any it
-- cannot place sends the declaration to the verbatim safety net.
stepExprDecl : FmtState ->
  List String ->
  List (Int, Int) ->
  Decl ->
  Int ->
  Int ->
  FmtState
stepExprDecl (FmtState pieces2 cs1 vlines1 _cursor1 _started1 placed1) srcLines commas decl line endLine =
  let interior = filterList (isInterior line endLine) cs1
  setComments (map (toPComment srcLines) interior) (endLine + 1)
  setImportForced (isImportDecl decl && anyCommaWithin line endLine commas)
  let declStr0 = render (printDecl decl)
  let leftover = takeLeftoverComments ()
  let placedNow = commentsPlaced ()
  if isNonEmptyL leftover then
    -- The verbatim span [line .. endLine] contains every comment on those
    -- lines; consume the decl's whole pending prefix.
    let inSpan = filterList (c => commentLine c <= endLine) cs1
    let csRest = filterList (c => commentLine c > endLine) cs1
    let pieces3 = "\n" :: verbatimSpan srcLines line endLine :: pieces2
    FmtState pieces3 csRest vlines1 endLine True (placed1 + listLen inSpan)
  else
    let cs3 = dropConsumed cs1 interior
    match takeTrailing cs3 endLine
      (trailing, csRest) =>
        let pieces4 = appendTrailing (declStr0 :: pieces2) trailing
        FmtState
          ("\n" :: pieces4)
          csRest
          vlines1
          endLine
          True
          (placed1 + placedNow + listLen trailing)

-- A `data` declaration: interior comments are placed per variant
-- (`printDataDeclCommented`) or, for a single-variant record with field
-- comments, per field (`printNamedFieldData` + a line-index splice).
stepDataDecl : FmtState -> List String -> Decl -> Int -> Int -> FmtState
stepDataDecl (FmtState pieces2 cs1 vlines1 cursor1 started1 placed1) srcLines decl line endLine =
  -- The variant's OWN source line (`| X {` of a two-line header, else the
  -- decl's start line).
  let variantLine = match vlines1
    vl :: _ => vl
    [] => line
  -- A comment on the variant's own line is a variant-TRAILING comment, not a
  -- field comment, so it must not route the decl onto the per-field path.
  let fieldComments =
    filterList
      (c => commentLine c /= variantLine)
      (filterList (isStrictInterior line endLine) cs1)
  let nfMulti = isSingleNamedFieldData decl && isNonEmptyL fieldComments
  -- `printNamedFieldData` renders the header as ONE output line; a two-line
  -- source header (`data X =` / `  | X { ...`) originates on the variant's
  -- line, so that is the splice's base line.
  let headerLine = if nfMulti then variantLine else line
  -- A decl-trailing comment is taken out BEFORE the variant bucketing, so a
  -- one-line `data` keeps its comment on its own line.
  match takeTrailing cs1 endLine
    (trailing, csNoTrail) =>
      let st2 = FmtState pieces2 csNoTrail vlines1 cursor1 started1 placed1
      match if nfMulti then renderNamedFieldMulti st2 decl else declDoc st2 decl
        (declStr0, FmtState pieces3 cs3 vlines3 _cursor3 _started3 placed3) =>
          let interior =
            if nfMulti then
              filterList (isStrictInterior line endLine) cs3
            else
              []
          match spliceInterior srcLines declStr0 headerLine interior
            (declStr, consumed) =>
              let cs3b = dropConsumed cs3 consumed
              let pieces4 = appendTrailing (declStr :: pieces3) trailing
              FmtState
                ("\n" :: pieces4)
                cs3b
                vlines3
                endLine
                True
                (placed3 + listLen consumed + listLen trailing)

isStrictInterior : Int -> Int -> Comment -> Bool
isStrictInterior startLine endLine c =
  let l = commentLine c
  l > startLine && l < endLine && isSingleLine (commentText c)

walkDecls : FmtState ->
  List String ->
  List (Int, Int) ->
  List Decl ->
  List DeclPos ->
  FmtState
walkDecls st _ _ [] _ = st
walkDecls st _ _ _ [] = st
walkDecls st srcLines commas (d :: ds) (p :: ps) =
  walkDecls (stepDecl st srcLines commas d p) srcLines commas ds ps

-- ── Public entry ──────────────────────────────────

-- Interleave comments into the rendered program.  Refuses (panics) rather
-- than produce output that lost a comment.
export
formatProgram : List Decl ->
  List DeclPos ->
  List Int ->
  List (Int, Int) ->
  List (Int, Int, Int) ->
  List Comment ->
  String ->
  String
formatProgram decls declPositions variantLines commas arms comments src =
  if listLen declPositions /= listLen decls then
    panic
      "medaka fmt: internal error — declaration positions do not line up with the declarations; refusing to format"
  else
    setTrailingCommas commas
    setUnitStarts arms
    let st0 = FmtState [] comments variantLines 0 False 0
    match drainAll (walkDecls st0 (splitNl src) commas decls declPositions)
      FmtState finalPieces _ _ _ _ placed =>
        checkCommentCount (listLen comments) placed
        stringConcat (reverseL finalPieces)

-- Every captured comment must have been emitted exactly once.
checkCommentCount : Int -> Int -> Unit
checkCommentCount total placed =
  if total /= placed then
    panic
      "medaka fmt: internal error — \{intToString total} comments in, \{intToString placed} placed; refusing to write output that would lose a comment"

-- Drain every remaining comment.
drainAll : FmtState -> FmtState
drainAll (FmtState pieces [] vlines cursor started placed) =
  FmtState pieces [] vlines cursor started placed
drainAll (FmtState pieces (c :: rest) vlines cursor started placed) =
  drainAll (emitComment (FmtState pieces rest vlines cursor started placed) c)

-- Convenience: parse + collect comments + format, from source text.
export
formatSource : String -> String
formatSource src = match parseWithPositions src
  (decls, pos) =>
    let commas = trailingCommaLocs ()
    let arms = unitStarts ()
    restoreTripleQuotedStrings
      src
      (formatProgram
        decls
        (positionsDecls pos)
        (positionsVariantLines pos)
        commas
        arms
        (collectComments src)
        src)

-- ── Triple-quoted string preservation ─────────────
-- `formatProgram` re-renders every string literal in the canonical
-- double-quoted spelling (`printLit`, tools/printer.mdk) — the AST's `Lit`
-- type has no room to remember that a literal was written `"""..."""`.  This
-- restores the original spelling as a pure TEXT patch applied AFTER
-- formatting: a `TString` token's start offset is always its opening quote, so
-- a token whose source starts `"""` is a triple-quoted literal.  Formatting
-- never adds, removes, or reorders string literals, so the Nth `TString` token
-- in the original source is the Nth in the formatted output; the correlation
-- is by ORDER alone.  Only the non-interpolated form is restored; an
-- interpolated triple string never produces a `TString` token and is untouched.

isTripleStringAt : String -> Int -> Bool
isTripleStringAt src pos = stringSlice pos (pos + 3) src == "\"\"\""

stringTokenInfo : String -> List Token -> List (Int, Int) -> List (Bool, String)
stringTokenInfo _ [] _ = []
stringTokenInfo _ _ [] = []
stringTokenInfo src ((TString _) :: ts) ((s, e) :: ps) =
  let triple = isTripleStringAt src s
  (triple, if triple then stringSlice s e src else "")
    :: stringTokenInfo src ts ps
stringTokenInfo src (_ :: ts) (_ :: ps) = stringTokenInfo src ts ps

stringTokenSpans : List Token -> List (Int, Int) -> List (Int, Int)
stringTokenSpans [] _ = []
stringTokenSpans _ [] = []
stringTokenSpans ((TString _) :: ts) ((s, e) :: ps) =
  (s, e) :: stringTokenSpans ts ps
stringTokenSpans (_ :: ts) (_ :: ps) = stringTokenSpans ts ps

-- Zip the original literal order against the formatted output's literal
-- spans, keeping only the ones that need restoring.  A token-count mismatch
-- is only safe at the TAIL (the final clause drops whatever is left).
tripleStringSubs : List (Bool, String) ->
  List (Int, Int) ->
  List (Int, Int, String)
tripleStringSubs ((True, raw) :: is) ((s, e) :: ss) =
  (s, e, raw) :: tripleStringSubs is ss
tripleStringSubs ((False, _) :: is) (_ :: ss) = tripleStringSubs is ss
tripleStringSubs _ _ = []

-- Apply substitutions HIGHEST-OFFSET-FIRST so an earlier substitution's
-- offsets are never invalidated by a later one.
applyTripleSubs : List (Int, Int, String) -> String -> String
applyTripleSubs [] out = out
applyTripleSubs ((s, e, raw) :: rest) out =
  applyTripleSubs
    rest
    (stringSlice 0 s out ++ raw ++ stringSlice e (stringLength out) out)

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
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "PComment" true) (mem "setComments" false) (mem "takeLeftoverComments" false) (mem "commentsPlaced" false) (mem "setTrailingCommas" false) (mem "setImportForced" false) (mem "setUnitStarts" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "trailingCommaLocs" false) (mem "unitStarts" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool") (TyCon "Int")))) ())
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
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")) (EBinOp "+" (EVar "placed") (ELit (LInt 1)))))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))))
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
(DTypeSig false "countPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "countPairs" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "ld")) (EApp (EVar "listLen") (EVar "tr"))) (EApp (EVar "countPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PAs "d" (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EBinOp "+" (EVar "placed") (EApp (EVar "countPairs") (EVar "vcomments"))))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EVar "placed")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "endLine")) (EApp (EVar "not") (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isImportDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isImportDecl" ((PCon "DUse" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isImportDecl" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PRec "DData" ((rf "dataCtors" (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))))) false)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EVar "placed"))))))
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
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitByEndLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "splitByEndLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitByEndLine" ((PCons (PVar "c") (PVar "rest")) (PVar "endLine")) (EIf (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "rest")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "after"))))))
(DTypeSig false "appendAfterComments" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "FmtState"))))
(DFunDef false "appendAfterComments" ((PCon "FmtState" (PVar "p") (PVar "c") (PVar "v") (PVar "cur") (PVar "s") (PVar "pl")) (PVar "after")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "p")) (EBinOp "++" (EVar "c") (EVar "after"))) (EVar "v")) (EVar "cur")) (EVar "s")) (EVar "pl")))
(DTypeSig false "toPComment" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "PComment"))))
(DFunDef false "toPComment" ((PVar "srcLines") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "PComment") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "commentCol") (EVar "c"))) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "isStandaloneSrc") (EVar "srcLines")) (EVar "c"))))
(DTypeSig false "anyCommaWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))))
(DFunDef false "anyCommaWithin" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyCommaWithin" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "l") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EVar "lo")) (EBinOp "<=" (EVar "l") (EVar "hi"))) (EApp (EApp (EApp (EVar "anyCommaWithin") (EVar "lo")) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) () (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (EBlock (DoLet false false (PVar "stSpan") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces1")) (EVar "mine")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoLet false false (PVar "stOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclSpan") (EVar "stSpan")) (EVar "srcLines")) (EVar "commas")) (EVar "decl")) (EVar "line")) (EVar "endLine"))) (DoExpr (EApp (EApp (EVar "appendAfterComments") (EVar "stOut")) (EVar "after")))))))))))
(DTypeSig false "stepDeclSpan" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepDeclSpan" ((PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoExpr (EIf (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EApp (EApp (EApp (EApp (EVar "stepDataDecl") (EVar "st2")) (EVar "srcLines")) (EVar "decl")) (EVar "line")) (EVar "endLine")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepExprDecl") (EVar "st2")) (EVar "srcLines")) (EVar "commas")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))
(DTypeSig false "stepExprDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepExprDecl" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "_cursor1") (PVar "_started1") (PVar "placed1")) (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "interior") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))) (DoExpr (EApp (EApp (EVar "setComments") (EApp (EApp (EVar "map") (EApp (EVar "toPComment") (EVar "srcLines"))) (EVar "interior"))) (EBinOp "+" (EVar "endLine") (ELit (LInt 1))))) (DoExpr (EApp (EVar "setImportForced") (EBinOp "&&" (EApp (EVar "isImportDecl") (EVar "decl")) (EApp (EApp (EApp (EVar "anyCommaWithin") (EVar "line")) (EVar "endLine")) (EVar "commas"))))) (DoLet false false (PVar "declStr0") (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl")))) (DoLet false false (PVar "leftover") (EApp (EVar "takeLeftoverComments") (ELit LUnit))) (DoLet false false (PVar "placedNow") (EApp (EVar "commentsPlaced") (ELit LUnit))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "leftover")) (EBlock (DoLet false false (PVar "inSpan") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EVar "placed1") (EApp (EVar "listLen") (EVar "inSpan")))))) (EBlock (DoLet false false (PVar "cs3") (EApp (EApp (EVar "dropConsumed") (EVar "cs1")) (EVar "interior"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr0") (EVar "pieces2"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EBinOp "+" (EVar "placed1") (EVar "placedNow")) (EApp (EVar "listLen") (EVar "trailing"))))))))))))))
(DTypeSig false "stepDataDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState")))))))
(DFunDef false "stepDataDecl" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) (PVar "srcLines") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "variantLine") (EMatch (EVar "vlines1") (arm (PCons (PVar "vl") PWild) () (EVar "vl")) (arm (PList) () (EVar "line")))) (DoLet false false (PVar "fieldComments") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EVar "commentLine") (EVar "c")) (EVar "variantLine")))) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isStrictInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EVar "fieldComments")))) (DoLet false false (PVar "headerLine") (EIf (EVar "nfMulti") (EVar "variantLine") (EVar "line"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csNoTrail")) () (EBlock (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "csNoTrail")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3") (PVar "placed3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EVar "nfMulti") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isStrictInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "spliceInterior") (EVar "srcLines")) (EVar "declStr0")) (EVar "headerLine")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "cs3b")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EBinOp "+" (EVar "placed3") (EApp (EVar "listLen") (EVar "consumed"))) (EApp (EVar "listLen") (EVar "trailing")))))))))))))))))))
(DTypeSig false "isStrictInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isStrictInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild PWild (PList)) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PVar "commas") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "commas")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "commas")) (EVar "ds")) (EVar "ps")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "commas") (PVar "arms") (PVar "comments") (PVar "src")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "panic") (ELit (LString "medaka fmt: internal error — declaration positions do not line up with the declarations; refusing to format"))) (EBlock (DoExpr (EApp (EVar "setTrailingCommas") (EVar "commas"))) (DoExpr (EApp (EVar "setUnitStarts") (EVar "arms"))) (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False")) (ELit (LInt 0)))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "commas")) (EVar "decls")) (EVar "declPositions"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild (PVar "placed")) () (EBlock (DoExpr (EApp (EApp (EVar "checkCommentCount") (EApp (EVar "listLen") (EVar "comments"))) (EVar "placed"))) (DoExpr (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))))
(DTypeSig false "checkCommentCount" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "checkCommentCount" ((PVar "total") (PVar "placed")) (EIf (EBinOp "/=" (EVar "total") (EVar "placed")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka fmt: internal error — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " comments in, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "placed")))) (ELit (LString " placed; refusing to write output that would lose a comment")))) (ELit LUnit)))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EBlock (DoLet false false (PVar "commas") (EApp (EVar "trailingCommaLocs") (ELit LUnit))) (DoLet false false (PVar "arms") (EApp (EVar "unitStarts") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "restoreTripleQuotedStrings") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EVar "commas")) (EVar "arms")) (EApp (EVar "collectComments") (EVar "src"))) (EVar "src"))))))))
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
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "PComment" true) (mem "setComments" false) (mem "takeLeftoverComments" false) (mem "commentsPlaced" false) (mem "setTrailingCommas" false) (mem "setImportForced" false) (mem "setUnitStarts" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false) (mem "collectComments" false) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "trailingCommaLocs" false) (mem "unitStarts" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool") (TyCon "Int")))) ())
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
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")) (EBinOp "+" (EVar "placed") (ELit (LInt 1)))))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))))
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
(DTypeSig false "countPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Int")))
(DFunDef false "countPairs" ((PList)) (ELit (LInt 0)))
(DFunDef false "countPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "ld")) (EApp (EVar "listLen") (EVar "tr"))) (EApp (EVar "countPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PAs "d" (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EBinOp "+" (EVar "placed") (EApp (EVar "countPairs") (EVar "vcomments"))))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EVar "placed")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "endLine")) (EApp (EVar "not") (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isImportDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isImportDecl" ((PCon "DUse" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isImportDecl" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PRec "DData" ((rf "dataCtors" (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))))) false)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed")) (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")) (EVar "placed"))))))
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
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitByEndLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "splitByEndLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitByEndLine" ((PCons (PVar "c") (PVar "rest")) (PVar "endLine")) (EIf (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "rest")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "after"))))))
(DTypeSig false "appendAfterComments" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "FmtState"))))
(DFunDef false "appendAfterComments" ((PCon "FmtState" (PVar "p") (PVar "c") (PVar "v") (PVar "cur") (PVar "s") (PVar "pl")) (PVar "after")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "p")) (EBinOp "++" (EVar "c") (EVar "after"))) (EVar "v")) (EVar "cur")) (EVar "s")) (EVar "pl")))
(DTypeSig false "toPComment" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Comment") (TyCon "PComment"))))
(DFunDef false "toPComment" ((PVar "srcLines") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "PComment") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "commentCol") (EVar "c"))) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "isStandaloneSrc") (EVar "srcLines")) (EVar "c"))))
(DTypeSig false "anyCommaWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))))
(DFunDef false "anyCommaWithin" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyCommaWithin" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "l") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EVar "lo")) (EBinOp "<=" (EVar "l") (EVar "hi"))) (EApp (EApp (EApp (EVar "anyCommaWithin") (EVar "lo")) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) () (EMatch (EApp (EApp (EVar "splitByEndLine") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "mine") (PVar "after")) () (EBlock (DoLet false false (PVar "stSpan") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces1")) (EVar "mine")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoLet false false (PVar "stOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepDeclSpan") (EVar "stSpan")) (EVar "srcLines")) (EVar "commas")) (EVar "decl")) (EVar "line")) (EVar "endLine"))) (DoExpr (EApp (EApp (EVar "appendAfterComments") (EVar "stOut")) (EVar "after")))))))))))
(DTypeSig false "stepDeclSpan" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepDeclSpan" ((PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoExpr (EIf (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EApp (EApp (EApp (EApp (EVar "stepDataDecl") (EVar "st2")) (EVar "srcLines")) (EVar "decl")) (EVar "line")) (EVar "endLine")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stepExprDecl") (EVar "st2")) (EVar "srcLines")) (EVar "commas")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))
(DTypeSig false "stepExprDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))))
(DFunDef false "stepExprDecl" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "_cursor1") (PVar "_started1") (PVar "placed1")) (PVar "srcLines") (PVar "commas") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "interior") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))) (DoExpr (EApp (EApp (EVar "setComments") (EApp (EApp (EMethodRef "map") (EApp (EVar "toPComment") (EVar "srcLines"))) (EVar "interior"))) (EBinOp "+" (EVar "endLine") (ELit (LInt 1))))) (DoExpr (EApp (EVar "setImportForced") (EBinOp "&&" (EApp (EVar "isImportDecl") (EVar "decl")) (EApp (EApp (EApp (EVar "anyCommaWithin") (EVar "line")) (EVar "endLine")) (EVar "commas"))))) (DoLet false false (PVar "declStr0") (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl")))) (DoLet false false (PVar "leftover") (EApp (EVar "takeLeftoverComments") (ELit LUnit))) (DoLet false false (PVar "placedNow") (EApp (EVar "commentsPlaced") (ELit LUnit))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "leftover")) (EBlock (DoLet false false (PVar "inSpan") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EVar "placed1") (EApp (EVar "listLen") (EVar "inSpan")))))) (EBlock (DoLet false false (PVar "cs3") (EApp (EApp (EVar "dropConsumed") (EVar "cs1")) (EVar "interior"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr0") (EVar "pieces2"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EBinOp "+" (EVar "placed1") (EVar "placedNow")) (EApp (EVar "listLen") (EVar "trailing"))))))))))))))
(DTypeSig false "stepDataDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState")))))))
(DFunDef false "stepDataDecl" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1") (PVar "placed1")) (PVar "srcLines") (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "variantLine") (EMatch (EVar "vlines1") (arm (PCons (PVar "vl") PWild) () (EVar "vl")) (arm (PList) () (EVar "line")))) (DoLet false false (PVar "fieldComments") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EVar "commentLine") (EVar "c")) (EVar "variantLine")))) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isStrictInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EVar "fieldComments")))) (DoLet false false (PVar "headerLine") (EIf (EVar "nfMulti") (EVar "variantLine") (EVar "line"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs1")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csNoTrail")) () (EBlock (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "csNoTrail")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1")) (EVar "placed1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3") (PVar "placed3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EVar "nfMulti") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isStrictInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "spliceInterior") (EVar "srcLines")) (EVar "declStr0")) (EVar "headerLine")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "cs3b")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")) (EBinOp "+" (EBinOp "+" (EVar "placed3") (EApp (EVar "listLen") (EVar "consumed"))) (EApp (EVar "listLen") (EVar "trailing")))))))))))))))))))
(DTypeSig false "isStrictInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isStrictInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild PWild (PList)) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PVar "commas") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "commas")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "commas")) (EVar "ds")) (EVar "ps")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "commas") (PVar "arms") (PVar "comments") (PVar "src")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "panic") (ELit (LString "medaka fmt: internal error — declaration positions do not line up with the declarations; refusing to format"))) (EBlock (DoExpr (EApp (EVar "setTrailingCommas") (EVar "commas"))) (DoExpr (EApp (EVar "setUnitStarts") (EVar "arms"))) (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False")) (ELit (LInt 0)))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "commas")) (EVar "decls")) (EVar "declPositions"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild (PVar "placed")) () (EBlock (DoExpr (EApp (EApp (EVar "checkCommentCount") (EApp (EVar "listLen") (EVar "comments"))) (EVar "placed"))) (DoExpr (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))))
(DTypeSig false "checkCommentCount" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "checkCommentCount" ((PVar "total") (PVar "placed")) (EIf (EBinOp "/=" (EVar "total") (EVar "placed")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka fmt: internal error — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " comments in, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "placed")))) (ELit (LString " placed; refusing to write output that would lose a comment")))) (ELit LUnit)))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started") (PVar "placed"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started")) (EVar "placed"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EBlock (DoLet false false (PVar "commas") (EApp (EVar "trailingCommaLocs") (ELit LUnit))) (DoLet false false (PVar "arms") (EApp (EVar "unitStarts") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "restoreTripleQuotedStrings") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EVar "commas")) (EVar "arms")) (EApp (EVar "collectComments") (EVar "src"))) (EVar "src"))))))))
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
