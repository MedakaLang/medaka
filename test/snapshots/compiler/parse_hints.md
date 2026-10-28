# META
source_lines=751
stages=DESUGAR,MARK
# SOURCE
import frontend.lex_token.{
  Token(..), peekTok, isColonTok, isConsTok, isDedentTok, isEofTok, isEqualTok,
  isExportTok, isImplTok, isInTok, isIndentTok, isLBraceTok, isLetTok,
  isNewlineTok, isOfTok, isPipeTok, isPublicTok, isRBraceTok, isStarTok,
  isTUpperTok
}
import frontend.parse_locate.{locateTokenDiagnostic}
import frontend.parse_diagnostic.{ParseDiagnostic, ParseDiagnosticKind(..)}
import support.source_index.{SourceIndex}

-- The single parser rejection message for `let mut` (used at both the
-- expression-level and statement-level `let` productions). Points at `Ref`/`:=`.
export
letMutRemovedMsg : String
letMutRemovedMsg =
  "`let mut` has been removed; bindings are immutable, so use a `Ref` cell: `let x = Ref 0`, then `x := v` and `!x`"

-- `record` is no longer a keyword: a single-constructor named-field product is
-- the degenerate case of `data`, so declare a record with the `data X = { … }`
-- short form.  A pre-grammar token scan surfaces a clean, located hint (pointing
-- at `record`) for users arriving from other languages.
recordRemovedMsg : String
recordRemovedMsg =
  "`record` is not a keyword; declare a record as `data X = { field : T }`"

-- `function` is no longer a keyword: the point-free one-arg match it wrote
-- (`function\n  pat => body`) is redundant with `x => match x { pat => body }`
-- and with multi-clause definitions. A pre-grammar token scan surfaces a
-- clean, located hint (pointing at `function`).
functionRemovedMsg : String
functionRemovedMsg =
  "`function` is not a keyword; write `x => match x` with the arms indented below it"

-- A token that ends the current logical line for a token scan.
export
isLineEndTok : Token -> Bool
isLineEndTok TNewline = True
isLineEndTok TIndent = True
isLineEndTok TDedent = True
isLineEndTok TEof = True
isLineEndTok _ = False

-- `record` has been removed as a declaration keyword (records are now the
-- `data X = { … }` short form), but — unlike `mut`/`function` above — the WORD
-- is an ordinary identifier again (#62; `keywordOrIdent`, lexer.mdk, carries the
-- reasoning for the split).  So the rule cannot key on the token: `recordHeadIdx`
-- (run at line starts by `prescanLineStart`) keys on the removed CONSTRUCT'S
-- SHAPE, the same way the `for`/`while`/`def` rule keys (also plain `TIdent`s).
--
-- Shape: a TOP-LEVEL logical line that starts `record Upper` (after any
-- `export`/`public` modifier) and then either
--   (a) has a depth-0 `=` followed by `{` — allowing ONE `INDENT`/`NEWLINE`
--       between them, which is how the multi-line form lexes — with no `|` at
--       that brace's own depth before its `}`; or
--   (b) reaches the end of its logical line with NO depth-0 `=` at all, having
--       seen a depth-0 `:` or such a `{`.
--
-- Arm (b) is not an extra: it is the form
-- `docs/spec/language-design.md` still documents as THE product-type syntax —
--     record Person
--       name : String
--       age  : Int
-- — which lexes as ONE logical line (`Person` `canEndExpr`, so the deeper lines
-- are absorbed as application continuations and no INDENT is ever emitted), and
-- is therefore the shape a reader migrating from that doc actually types.
--
-- SAFETY (why this can never fire on valid Medaka).  Two independent proofs,
-- one per arm.
--
-- (a) A `{` that STARTS an expression has exactly one production in this
-- grammar — `parseRecordUpdate` (`parseAtomRaw`'s `TLBrace =>
-- parseRecordUpdate`), which is `{ expr | field = val, … }` and therefore
-- ALWAYS contains a `|` at the brace's own depth (it `expectTok TPipe`
-- unconditionally).  A constructor record literal (`P { x = 1 }`) has no `|`,
-- but it is `TUpper`-led (`upperAtomRest c TLBrace`), so its `{` is never the
-- token right after `=`.  Hence `= {` with no depth-1 `|` is not a parseable
-- expression under any arm.  Verified on the binary: `f Point = { x : Int, y :
-- Int }` fails with `unexpected ','; expected '|'`, while `f Pat = { r | x = 1
-- }` and `f Pat = P { x = 1 }` both compile — and neither matches this shape,
-- one-line or multi-line (the `|` is inside the braces either way).
--
-- (b) A top-level declaration line ALWAYS contains a depth-0 `=`, unless it is
-- a type signature — and a signature's LHS is a single lowercase name, so it
-- cannot be `record Upper …`.  Every other decl form starts with its own
-- keyword (`data`/`interface`/`impl`/`import`/…), not with an identifier.  So
-- "starts `record Upper` and has no depth-0 `=` on the whole logical line" is
-- already never-valid on its own; the `:`/`{` evidence is required on top of
-- that only to keep the RECORD message off unrelated broken lines.
--
-- The `Upper` requirement keeps the scan off ordinary code that merely binds
-- the name (`record = 1`, `record r = { r | x = 1 }`, `record : Int`): the
-- removed construct always named an uppercase type.  Located at `record`, not
-- at the modifier — that is the word the message is about.

-- Is there a `|` at THIS brace's own depth before it closes?  `i` points just
-- past the `{`; `depth` counts nested brackets opened since.  True also on a
-- malformed/unclosed brace (fail safe: don't claim the construct).
braceHasBarAtTop : Array Token -> Int -> Int -> Bool
braceHasBarAtTop toks i depth
  | i >= arrayLength toks = True
  | isEofTok (peekTok toks i) = True
  | isPipeTok (peekTok toks i) && depth == 0 = True
  | isRBraceTok (peekTok toks i) && depth == 0 = False
  | isBracketOpenTok (peekTok toks i) =
    braceHasBarAtTop toks (i + 1) (depth + 1)
  | isBracketCloseTok (peekTok toks i) =
    braceHasBarAtTop toks (i + 1) (depth - 1)
  | otherwise = braceHasBarAtTop toks (i + 1) depth

-- Index of the `{` a depth-0 `=` at `i` introduces, tolerating ONE layout token
-- between them (`record Person =⏎  { … }` lexes as `= INDENT {`), or -1.
braceAfterEq : Array Token -> Int -> Int
braceAfterEq toks i
  | isLBraceTok (peekTok toks (i + 1)) = i + 1
  | isLineEndTok (peekTok toks (i + 1)) && isLBraceTok (peekTok toks (i + 2)) =
    i + 2
  | otherwise = 0 - 1

-- Walk the logical line from `i`.  Arm (a) commits at the first depth-0 `=`;
-- arm (b) commits at the line's end, having seen no such `=`.  `sawField` is
-- the (b) evidence: a depth-0 `:` or a depth-0 brace with no top-level `|`.
lineIsRecordBody : Array Token -> Int -> Int -> Bool -> Bool
lineIsRecordBody toks i depth sawField
  | i >= arrayLength toks = sawField
  | depth == 0 && isLineEndTok (peekTok toks i) = sawField
  | depth == 0 && isEqualTok (peekTok toks i) =
    let b = braceAfterEq toks i
    if b < 0 then False else not (braceHasBarAtTop toks (b + 1) 0)
  | depth == 0 && isColonTok (peekTok toks i) =
    lineIsRecordBody toks (i + 1) depth True
  | depth == 0 && isLBraceTok (peekTok toks i) =
    lineIsRecordBody
      toks
      (i + 1)
      (depth + 1)
      (not (braceHasBarAtTop toks (i + 1) 0))
  | isBracketOpenTok (peekTok toks i) =
    lineIsRecordBody toks (i + 1) (depth + 1) sawField
  | isBracketCloseTok (peekTok toks i) =
    lineIsRecordBody toks (i + 1) (depth - 1) sawField
  | otherwise = lineIsRecordBody toks (i + 1) depth sawField

-- `record` may be preceded by an export modifier (`export record X = { … }` was
-- as writable as the bare form).  Index of the `record` token at a decl head
-- starting at `i`, or -1 if this head does not start one.
recordHeadIdx : Array Token -> Int -> Int
recordHeadIdx toks i
  | isExportTok (peekTok toks i) || isPublicTok (peekTok toks i) =
    recordHeadIdx toks (i + 1)
  | peekTok toks i == TIdent "record"
    && isTUpperTok (peekTok toks (i + 1))
    && lineIsRecordBody toks (i + 2) 0 False = i
  | otherwise = 0 - 1

-- #935.  `let`/`rec`/`if`/`then`/`else` are reserved, but they are deliberately
-- absent from `reservedIdentKeyword` (see its comment: a fatal there would
-- break match-arm guards and every `let rec`), so binding one would otherwise produce a
-- grammar-internal error that never names the real problem — `let = 5` reports
-- ``unexpected `=`; expected `rec` ``, and `if = 5` reports ``unexpected `if` ``.
--
-- A TOP-LEVEL logical line whose FIRST token is one of these five and whose
-- SECOND is `=` or `:` is unambiguously an attempted top-level binding or type
-- signature named by a keyword — the position issue #935 asks for.
--
-- SAFETY.  Depth 0 excludes every position where these words are legal: a
-- match-arm guard (`pat if cond => body`) and an `if`/`then`/`else` statement
-- both live inside an INDENT, and `rec` only ever follows `let`, never starting
-- a line.  Requiring `=`/`:` as the very next token excludes the remaining
-- top-level shapes outright — no valid Medaka has `if =`, `then :`, `let =`,
-- `rec =` or `else :`, because each of these keywords must be followed by an
-- expression or a binder.  Located at the keyword, and worded with
-- `ReservedKeyword` so the driver maps it to `P-RESERVED-KEYWORD` and offers
-- the same machine-applicable `append _` fix the 22 fully-reserved words get.
contextualKwName : Token -> String
contextualKwName TLet = "let"
contextualKwName TRec = "rec"
contextualKwName TIf = "if"
contextualKwName TThen = "then"
contextualKwName TElse = "else"
contextualKwName _ = ""

isContextualKw : Token -> Bool
isContextualKw t = contextualKwName t /= ""

isBinderTok : Token -> Bool
isBinderTok TEqual = True
isBinderTok TColon = True
isBinderTok _ = False

-- Scan forward from token index `i` (depth=accumulated INDENT/DEDENT) looking
-- for `TIn` at depth=0 before the enclosing block exits (a `TDedent` that would
-- take depth below 0, or `TEof`).  Returns True if the inline `let` is
-- well-formed (has a matching `in`), False if it is missing one.
scanForLetIn : Array Token -> Int -> Int -> Bool
scanForLetIn toks i depth
  | i >= arrayLength toks = False
  | isInTok (peekTok toks i) && depth == 0 = True
  | isIndentTok (peekTok toks i) = scanForLetIn toks (i + 1) (depth + 1)
  | isDedentTok (peekTok toks i) && depth == 0 = False
  | isDedentTok (peekTok toks i) = scanForLetIn toks (i + 1) (depth - 1)
  | isEofTok (peekTok toks i) = False
  | otherwise = scanForLetIn toks (i + 1) depth

inlineLetMissingInMsg : String
inlineLetMissingInMsg =
  "inline `let` requires `in`, as in `else let x = e in body`; for a multi-line body put `else` on its own line and indent the block"

-- `case … of` is a Haskell-ism: Medaka spells pattern matching `match e` with
-- indented `pattern => body` arms and has no `of` keyword after a bare `case`
-- ident (`case` itself is not reserved — it lexes as a plain `TIdent`).
-- Discriminator: a `TIdent "case"` followed by a `TOf` before the enclosing
-- block exits, with NO intervening `TImpl` — `of` is otherwise only valid
-- right after `impl X Y of …`, so if an `impl`/`TImpl` appears first, the
-- `TOf` we'd find belongs to THAT construct, not this `case`, and we must not
-- match. Depth-tracked the same way `scanForLetIn` bounds its search.
caseHasOfBeforeBoundary : Array Token -> Int -> Int -> Bool
caseHasOfBeforeBoundary toks i depth
  | i >= arrayLength toks = False
  | isOfTok (peekTok toks i) = True
  | isImplTok (peekTok toks i) = False
  | isIndentTok (peekTok toks i) =
    caseHasOfBeforeBoundary toks (i + 1) (depth + 1)
  | isDedentTok (peekTok toks i) && depth == 0 = False
  | isDedentTok (peekTok toks i) =
    caseHasOfBeforeBoundary toks (i + 1) (depth - 1)
  | isEofTok (peekTok toks i) = False
  | otherwise = caseHasOfBeforeBoundary toks (i + 1) depth

hsCaseOfMsg : ParseDiagnosticKind
hsCaseOfMsg = HsCase

-- Backtick infix application (``x `f` y``) has been removed.  `TBacktickIdent`
-- is a sentinel with no remaining valid use, so its presence is always the
-- removed construct.  A pre-grammar token scan surfaces a located hint.
backtickInfixMsg : String
backtickInfixMsg = "Medaka has no infix backticks; write `f x y`"

-- `let rec … with …` mutual-recursion grouping has been removed: each
-- recursive binding is its own `let rec`.  `with` (TWith) has no live use in
-- the grammar, but OCaml's `match e with` also spells it, so a `with` is
-- classified by whether a `match` opened earlier on the same logical line.
-- The match flag is set at `TMatch` and cleared by any layout token.
matchWithMsg : ParseDiagnosticKind
matchWithMsg = MatchWith

-- `**` is two adjacent `TStar` tokens (the lexer has no power operator).
-- Adjacency is checked on source offsets, so `* *` and `(*)` are untouched.
starStarMsg : ParseDiagnosticKind
starStarMsg = NoPow

-- `for` is a plain identifier, so a `for <pattern> in …` loop is recognised only
-- when `for` starts a line and the same line continues with pattern tokens
-- (idents, `_`, tuple punctuation) and then `in`, with no `=` before it.
forLoopHeadTail : Array Token -> Int -> Bool -> Bool
forLoopHeadTail toks i sawPat
  | i >= arrayLength toks = False
  | isInTok (peekTok toks i) = sawPat
  | isForPatTok (peekTok toks i) = forLoopHeadTail toks (i + 1) True
  | otherwise = False

isForPatTok : Token -> Bool
isForPatTok (TIdent _) = True
isForPatTok TUnderscore = True
isForPatTok TComma = True
isForPatTok TLParen = True
isForPatTok TRParen = True
isForPatTok _ = False

forLoopMsg : ParseDiagnosticKind
forLoopMsg = ForeignKeyword "for"

letRecWithRemovedMsg : String
letRecWithRemovedMsg =
  "`let rec ... with` has been removed; define each binding as its own `let rec`"

-- Haskell type signature (`f :: T`) vs Medaka's single-colon `f : T`: `::` is
-- Medaka's CONS operator (`x :: xs`), a legitimate infix op that appears all
-- over real bodies/guards (`f = 1 :: [2,3]`, `f x | y :: z = …`) AND in match-
-- arm cons patterns (`x :: rest => …`), which sit right after the INDENT that
-- opens the match body — so "immediately after any INDENT" is NOT a safe
-- boundary (that regressed on exactly this shape). The only position that is
-- NEVER legal Medaka is a TOP-LEVEL decl-head ident (depth 0 — outside every
-- block) IMMEDIATELY followed by `::`: no valid grammar production puts `::`
-- right after a fresh top-level decl head. Discriminator: `depth == 0` AND
-- `boundary` (true at the very start of the stream, right after a NEWLINE
-- seen at depth 0, or right after a DEDENT that returns to depth 0 — i.e. the
-- position a new top-level decl can start) AND `TIdent` immediately followed
-- by `TCons`. `depth` is the same INDENT/DEDENT counter `scanForLetIn` uses.
hsSigMsg : ParseDiagnosticKind
hsSigMsg = HsSignature

-- ── Stage-2 foreign-syntax pre-scans (PARSE-ERROR-LOCATION-DESIGN §3) ─────────
-- Each mirrors the existing `/=`/`case…of`/`::` hints: a pure token scan that
-- fires ONLY on shapes that are never valid Medaka, returning the offending token
-- index so the located `ParseError` dodges the `1:0` collapse.  The risk is a
-- false positive on VALID code (esp. records vs braces — see `braceBlockFrom`);
-- each rule's safety argument sits beside its helper or its `prescanTokHit` arm.

-- A bracket opener / closer (paren, bracket, brace) tracks nesting so a
-- scan only reasons about tokens at its own bracket level.
export
isBracketOpenTok : Token -> Bool
isBracketOpenTok TLParen = True
isBracketOpenTok TLBracket = True
isBracketOpenTok TLBracketTight = True
isBracketOpenTok TLBrace = True
isBracketOpenTok _ = False

export
isBracketCloseTok : Token -> Bool
isBracketCloseTok TRParen = True
isBracketCloseTok TRBracket = True
isBracketCloseTok TRBrace = True
isBracketCloseTok _ = False

-- `/* … */`: Medaka's block comments are `{- … -}` and its line comments `--`.
-- The lexer tags `/` `*` as two ordinary operator tokens (`TSlash`, `TStar`);
-- an adjacent `TSlash TStar` (`/*`) is NEVER valid Medaka — `/` is binary divide
-- and `*` has no prefix form, so `1 / *x` cannot parse.  Located at the `/`.
blockCommentMsg : ParseDiagnosticKind
blockCommentMsg = BlockComment

-- Brace-block `if` (`if cond { … } else { … }`) uses C-style bodies.
-- A top-level fat arrow may end a match guard or a lambda, so it is not
-- safe to infer that a preceding `if` needs a `then` past that boundary.
-- A `then` at the same bracket level also exempts record conditions.
braceBlockFrom : Array Token -> Int -> Int -> Int -> Int
braceBlockFrom toks i depth cand
  | i >= arrayLength toks = if depth == 0 then cand else 0 - 1
  | (peekTok toks i == TThen || peekTok toks i == TFatArrow) && depth == 0 =
    0 - 1
  | peekTok toks i == TElse && depth == 0 = cand
  | (isNewlineTok (peekTok toks i) || isEofTok (peekTok toks i)) && depth == 0 =
    cand
  | isLBraceTok (peekTok toks i) && depth == 0 && cand < 0 =
    braceBlockFrom toks (i + 1) (depth + 1) i
  | isBracketOpenTok (peekTok toks i) =
    braceBlockFrom toks (i + 1) (depth + 1) cand
  | isBracketCloseTok (peekTok toks i) =
    braceBlockFrom toks (i + 1) (depth - 1) cand
  | otherwise = braceBlockFrom toks (i + 1) depth cand
braceBlockMsg : ParseDiagnosticKind
braceBlockMsg = BraceBlock

-- `for`/`while` loops and `def`/`function`-style headers: these lex as plain
-- `TIdent`s (`for`, `while`, `def` are NOT reserved).  A foreign loop/def is
-- recognised by a line that STARTS with one of these words and ENDS in a trailing
-- `:` (C/Python statement colon) with NO `=` on that line.  SAFETY: a valid decl
-- named `for`/`while`/`def` is a binding or function head — it ALWAYS has `=`
-- (`for = e`, `for x = e`), so `sawEq` excludes it; a valid TYPE SIGNATURE
-- (`for : Int`) has its type AFTER the colon, so the colon is not trailing
-- (`lastColon` is False at the line break).  A trailing `:` with no `=` is never
-- valid Medaka.  Located at the keyword.
isForeignKwTok : Token -> Bool
isForeignKwTok (TIdent "for") = True
isForeignKwTok (TIdent "while") = True
isForeignKwTok (TIdent "def") = True
isForeignKwTok (TIdent "elif") = True
isForeignKwTok (TIdent "class") = True
isForeignKwTok (TIdent "try") = True
isForeignKwTok (TIdent "except") = True
isForeignKwTok (TIdent "finally") = True
isForeignKwTok _ = False

lineTrailingColonNoEq : Array Token -> Int -> Int -> Bool -> Bool -> Bool
lineTrailingColonNoEq toks i depth lastColon sawEq
  | i >= arrayLength toks = lastColon && not sawEq
  | depth == 0
    && (isNewlineTok (peekTok toks i)
      || isEofTok (peekTok toks i)
      || isIndentTok (peekTok toks i)
      || isDedentTok (peekTok toks i)) = lastColon && not sawEq
  | isEqualTok (peekTok toks i) && depth == 0 =
    lineTrailingColonNoEq toks (i + 1) depth False True
  | isColonTok (peekTok toks i) && depth == 0 =
    lineTrailingColonNoEq toks (i + 1) depth True sawEq
  | isBracketOpenTok (peekTok toks i) =
    lineTrailingColonNoEq toks (i + 1) (depth + 1) False sawEq
  | isBracketCloseTok (peekTok toks i) =
    lineTrailingColonNoEq toks (i + 1) (depth - 1) False sawEq
  | otherwise = lineTrailingColonNoEq toks (i + 1) depth False sawEq

foreignKwMsg : Token -> ParseDiagnosticKind
foreignKwMsg token = ForeignKeyword (foreignKwName token)

-- A stray semicolon has its own hint; selection inspects the lexer kind.
semicolonMsg : ParseDiagnosticKind
semicolonMsg = Semicolon

foreignKwName : Token -> String
foreignKwName (TIdent word) = word
foreignKwName _ = "for"
-- First-hit index per pre-scan rule (-1 = not hit), filled by one walk over the
-- token stream.  `phWith` / `phMatchWith` split `with` by whether a `match`
-- opened earlier on the same logical line.
data PrescanHits = {
  phLex : Int,
  phBangEq : Int,
  phMut : Int,
  phRecord : Int,
  phCtxKw : Int,
  phFunction : Int,
  phInlineLet : Int,
  phCaseOf : Int,
  phBacktick : Int,
  phWith : Int,
  phMatchWith : Int,
  phStarStar : Int,
  phForLoop : Int,
  phHsSig : Int,
  phBlockComment : Int,
  phBraceBlock : Int,
  phForeignKw : Int,
}

prescanLexError : Array Token -> Int -> Option (Int, ParseDiagnosticKind)
prescanLexError toks i
  | i < 0 = None
  | otherwise = match peekTok toks i
    TLexError msg => Some (i, msg)
    _ => None

prescanNoHits : PrescanHits
prescanNoHits = PrescanHits {
  phLex = 0 - 1,
  phBangEq = 0 - 1,
  phMut = 0 - 1,
  phRecord = 0 - 1,
  phCtxKw = 0 - 1,
  phFunction = 0 - 1,
  phInlineLet = 0 - 1,
  phCaseOf = 0 - 1,
  phBacktick = 0 - 1,
  phWith = 0 - 1,
  phMatchWith = 0 - 1,
  phStarStar = 0 - 1,
  phForLoop = 0 - 1,
  phHsSig = 0 - 1,
  phBlockComment = 0 - 1,
  phBraceBlock = 0 - 1,
  phForeignKw = 0 - 1,
}

-- Rules keyed on the start of a logical line; `depth` is the INDENT nesting,
-- so the declaration-position rules fire only at depth 0.
prescanLineStart : Array Token ->
  Int ->
  Token ->
  Int ->
  PrescanHits ->
  PrescanHits
prescanLineStart toks i t depth h0 =
  let h1 =
    if depth == 0 && h0.phRecord < 0 && recordHeadIdx toks i >= 0 then
      { h0 | phRecord = recordHeadIdx toks i }
    else
      h0
  let h2 =
    if depth == 0
      && h1.phCtxKw < 0
      && isContextualKw t
      && isBinderTok (peekTok toks (i + 1)) then
      { h1 | phCtxKw = i }
    else
      h1
  let h3 =
    if h2.phForLoop < 0
      && t == TIdent "for"
      && forLoopHeadTail toks (i + 1) False then
      { h2 | phForLoop = i }
    else
      h2
  if h3.phForeignKw < 0
    && isForeignKwTok t
    && lineTrailingColonNoEq toks i 0 False False then
    { h3 | phForeignKw = i }
  else
    h3

-- Rules keyed on the token itself (or a short lookahead from it).  `sb` is the
-- top-level declaration boundary for the Haskell-signature rule and `im` says a
-- `match` opened earlier on this logical line.
--
-- Tokens that are always the removed construct, so presence alone is the hit:
-- `TBangEq` (`!=`; once `!` means Ref-dereference nothing in the negation family
-- is spelled with `!`, and the lexer tags it so it is located precisely rather
-- than split into `!` `=`), `TMut` (`let mut`: `mut` has no remaining valid use,
-- and the grammar's own fallback swallows the failed statement's error, so only
-- a pre-grammar hit gives a located message), `TFunction` (a point-free match is
-- `x => match x { … }`), `TBacktickIdent`.
prescanTokHit : Array Token ->
  Array Int ->
  Int ->
  Token ->
  Int ->
  Bool ->
  Bool ->
  PrescanHits ->
  PrescanHits
-- lint-disable-next-line rule-match-on-param -- the arms need all eight arguments; `t` is matched, not a parameter pattern
prescanTokHit toks offs i t depth sb im h = match t
  TLexError _ => if h.phLex < 0 then { h | phLex = i } else h
  TBangEq => if h.phBangEq < 0 then { h | phBangEq = i } else h
  TMut => if h.phMut < 0 then { h | phMut = i } else h
  TFunction => if h.phFunction < 0 then { h | phFunction = i } else h
  TBacktickIdent _ => if h.phBacktick < 0 then { h | phBacktick = i } else h
  TSlash =>
    if h.phBlockComment < 0 && isStarTok (peekTok toks (i + 1)) then
      { h | phBlockComment = i }
    else
      h
  TStar =>
    if h.phStarStar < 0
      && isStarTok (peekTok toks (i + 1))
      && arrayGetUnsafe (i + 1) offs == arrayGetUnsafe i offs + 1 then
      { h | phStarStar = i }
    else
      h
  TWith =>
    if im then
      if h.phMatchWith < 0 then { h | phMatchWith = i } else h
    else if h.phWith < 0 then
      { h | phWith = i }
    else
      h
  TIf =>
    if h.phBraceBlock < 0 && braceBlockFrom toks (i + 1) 0 (0 - 1) >= 0 then
      { h | phBraceBlock = braceBlockFrom toks (i + 1) 0 (0 - 1) }
    else
      h
  TThen => prescanInlineLet toks i h
  TElse => prescanInlineLet toks i h
  TIdent s => prescanIdentHit toks i s depth sb h
  _ => h

prescanInlineLet : Array Token -> Int -> PrescanHits -> PrescanHits
prescanInlineLet toks i h =
  if h.phInlineLet < 0
    && isLetTok (peekTok toks (i + 1))
    && not (scanForLetIn toks (i + 2) 0) then
    { h | phInlineLet = i + 1 }
  else
    h

prescanIdentHit : Array Token ->
  Int ->
  String ->
  Int ->
  Bool ->
  PrescanHits ->
  PrescanHits
prescanIdentHit toks i s depth sb h0 =
  let h1 =
    if s == "case"
      && h0.phCaseOf < 0
      && caseHasOfBeforeBoundary toks (i + 1) 0 then
      { h0 | phCaseOf = i }
    else
      h0
  if sb && depth == 0 && h1.phHsSig < 0 && isConsTok (peekTok toks (i + 1)) then
    { h1 | phHsSig = i + 1 }
  else
    h1

-- One walk over the token stream, recording each pre-scan rule's first hit.
-- `depth`, `ls` (line start), `sb` (signature boundary) and `im` (a `match`
-- opened on this line) are the states the rules share; a hit never changes them.
prescanWalk : Array Token ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Bool ->
  Bool ->
  PrescanHits ->
  PrescanHits
prescanWalk toks offs n i depth ls sb im h
  | i >= n = h
  | otherwise =
    let t = peekTok toks i
    let h1 = if ls then prescanLineStart toks i t depth h else h
    let h2 = prescanTokHit toks offs i t depth sb im h1
    match t
      TIndent => prescanWalk toks offs n (i + 1) (depth + 1) True False False h2
      TDedent =>
        prescanWalk toks offs n (i + 1) (depth - 1) True (depth == 1) False h2
      TNewline =>
        prescanWalk toks offs n (i + 1) depth True (depth == 0) False h2
      TMatch => prescanWalk toks offs n (i + 1) depth False False True h2
      TWith => prescanWalk toks offs n (i + 1) depth False False False h2
      _ => prescanWalk toks offs n (i + 1) depth False False im h2

-- The removed-construct and lex-error pre-scans over an ALREADY-tokenized
-- stream, in the order the diagnostics take precedence: the first one that
-- fires is the error.  `None` means no pre-scan fired and the grammar decides.
-- Exported so `medaka fmt` can run the same pre-scans without the separate
-- grammar pass of `parseResultWith` (see `formatSourceChecked`).
export
prescanDiagnostic : (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Int ->
  Option ParseDiagnostic
prescanDiagnostic index toks offs ends srcLen =
  let hits =
    prescanWalk toks offs (arrayLength toks) 0 0 True True False prescanNoHits
  let beIdx = hits.phBangEq
  let lmIdx = hits.phMut
  let recIdx = hits.phRecord
  let ckIdx = hits.phCtxKw
  let fnIdx = hits.phFunction
  let ilIdx = hits.phInlineLet
  let coIdx = hits.phCaseOf
  let btIdx = hits.phBacktick
  let wiIdx = hits.phWith
  let mwIdx = hits.phMatchWith
  let ssIdx = hits.phStarStar
  let forIdx = hits.phForLoop
  let sigIdx = hits.phHsSig
  let bcIdx = hits.phBlockComment
  let bbIdx = hits.phBraceBlock
  let fkwIdx = hits.phForeignKw
  match prescanLexError toks hits.phLex
    Some (leIdx, leMsg) =>
      let leMsg2 = match leMsg
        UnexpectedCharacter ";" => semicolonMsg
        _ => leMsg
      Some (locateTokenDiagnostic index toks offs ends srcLen leMsg2 leIdx)
    None =>
      if beIdx >= 0 then
        Some (locateTokenDiagnostic index toks offs ends srcLen BadNeq beIdx)
      else if lmIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse letMutRemovedMsg)
            lmIdx)
      else if recIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse recordRemovedMsg)
            recIdx)
      else if ckIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (ReservedKeyword (contextualKwName (peekTok toks ckIdx)))
            ckIdx)
      else if fnIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse functionRemovedMsg)
            fnIdx)
      else if ilIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse inlineLetMissingInMsg)
            ilIdx)
      else if coIdx >= 0 then
        Some
          (locateTokenDiagnostic index toks offs ends srcLen hsCaseOfMsg coIdx)
      else if btIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse backtickInfixMsg)
            btIdx)
      else if mwIdx >= 0 then
        Some
          (locateTokenDiagnostic index toks offs ends srcLen matchWithMsg mwIdx)
      else if wiIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (GenericParse letRecWithRemovedMsg)
            wiIdx)
      else if bcIdx >= 0 then
        -- Before the `**` hint: a `/**` or `(**` comment opener lexes as a
        -- `**` token, and the comment diagnosis is the true one.
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            blockCommentMsg
            bcIdx)
      else if ssIdx >= 0 then
        Some
          (locateTokenDiagnostic index toks offs ends srcLen starStarMsg ssIdx)
      else if sigIdx >= 0 then
        Some (locateTokenDiagnostic index toks offs ends srcLen hsSigMsg sigIdx)
      else if bbIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            braceBlockMsg
            bbIdx)
      else if fkwIdx >= 0 then
        Some
          (locateTokenDiagnostic
            index
            toks
            offs
            ends
            srcLen
            (foreignKwMsg (peekTok toks fkwIdx))
            fkwIdx)
      else if forIdx >= 0 then
        Some
          (locateTokenDiagnostic index toks offs ends srcLen forLoopMsg forIdx)
      else
        None
# DESUGAR
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "peekTok" false) (mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isStarTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("frontend" "parse_locate") ((mem "locateTokenDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DTypeSig true "letMutRemovedMsg" (TyCon "String"))
(DFunDef false "letMutRemovedMsg" () (ELit (LString "`let mut` has been removed; bindings are immutable, so use a `Ref` cell: `let x = Ref 0`, then `x := v` and `!x`")))
(DTypeSig false "recordRemovedMsg" (TyCon "String"))
(DFunDef false "recordRemovedMsg" () (ELit (LString "`record` is not a keyword; declare a record as `data X = { field : T }`")))
(DTypeSig false "functionRemovedMsg" (TyCon "String"))
(DFunDef false "functionRemovedMsg" () (ELit (LString "`function` is not a keyword; write `x => match x` with the arms indented below it")))
(DTypeSig true "isLineEndTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLineEndTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isLineEndTok" (PWild) (EVar "False"))
(DTypeSig false "braceHasBarAtTop" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "braceHasBarAtTop" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "True") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "True") (EIf (EBinOp "&&" (EApp (EVar "isPipeTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EBinOp "&&" (EApp (EVar "isRBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "braceAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "braceAfterEq" ((PVar "toks") (PVar "i")) (EIf (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EBinOp "&&" (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EIf (EVar "otherwise") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineIsRecordBody" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "lineIsRecordBody" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "sawField")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "sawField") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "sawField") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "braceAfterEq") (EVar "toks")) (EVar "i"))) (DoExpr (EIf (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EVar "False") (EApp (EVar "not") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (ELit (LInt 0))))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isColonTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))))) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "sawField")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "sawField")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "sawField")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "recordHeadIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "recordHeadIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp "||" (EApp (EVar "isExportTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isPublicTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EApp (EVar "TIdent") (ELit (LString "record")))) (EApp (EVar "isTUpperTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))) (EVar "False"))) (EVar "i") (EIf (EVar "otherwise") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "contextualKwName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "contextualKwName" ((PCon "TLet")) (ELit (LString "let")))
(DFunDef false "contextualKwName" ((PCon "TRec")) (ELit (LString "rec")))
(DFunDef false "contextualKwName" ((PCon "TIf")) (ELit (LString "if")))
(DFunDef false "contextualKwName" ((PCon "TThen")) (ELit (LString "then")))
(DFunDef false "contextualKwName" ((PCon "TElse")) (ELit (LString "else")))
(DFunDef false "contextualKwName" (PWild) (ELit (LString "")))
(DTypeSig false "isContextualKw" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isContextualKw" ((PVar "t")) (EBinOp "/=" (EApp (EVar "contextualKwName") (EVar "t")) (ELit (LString ""))))
(DTypeSig false "isBinderTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBinderTok" ((PCon "TEqual")) (EVar "True"))
(DFunDef false "isBinderTok" ((PCon "TColon")) (EVar "True"))
(DFunDef false "isBinderTok" (PWild) (EVar "False"))
(DTypeSig false "scanForLetIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "scanForLetIn" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EApp (EVar "isInTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "inlineLetMissingInMsg" (TyCon "String"))
(DFunDef false "inlineLetMissingInMsg" () (ELit (LString "inline `let` requires `in`, as in `else let x = e in body`; for a multi-line body put `else` on its own line and indent the block")))
(DTypeSig false "caseHasOfBeforeBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "caseHasOfBeforeBoundary" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EApp (EVar "isOfTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "True") (EIf (EApp (EVar "isImplTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "hsCaseOfMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "hsCaseOfMsg" () (EVar "HsCase"))
(DTypeSig false "backtickInfixMsg" (TyCon "String"))
(DFunDef false "backtickInfixMsg" () (ELit (LString "Medaka has no infix backticks; write `f x y`")))
(DTypeSig false "matchWithMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "matchWithMsg" () (EVar "MatchWith"))
(DTypeSig false "starStarMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "starStarMsg" () (EVar "NoPow"))
(DTypeSig false "forLoopHeadTail" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "forLoopHeadTail" ((PVar "toks") (PVar "i") (PVar "sawPat")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EApp (EVar "isInTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "sawPat") (EIf (EApp (EVar "isForPatTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "forLoopHeadTail") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isForPatTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForPatTok" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TComma")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isForPatTok" (PWild) (EVar "False"))
(DTypeSig false "forLoopMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "forLoopMsg" () (EApp (EVar "ForeignKeyword") (ELit (LString "for"))))
(DTypeSig false "letRecWithRemovedMsg" (TyCon "String"))
(DFunDef false "letRecWithRemovedMsg" () (ELit (LString "`let rec ... with` has been removed; define each binding as its own `let rec`")))
(DTypeSig false "hsSigMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "hsSigMsg" () (EVar "HsSignature"))
(DTypeSig true "isBracketOpenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketOpenTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isBracketOpenTok" (PWild) (EVar "False"))
(DTypeSig true "isBracketCloseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketCloseTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isBracketCloseTok" (PWild) (EVar "False"))
(DTypeSig false "blockCommentMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "blockCommentMsg" () (EVar "BlockComment"))
(DTypeSig false "braceBlockFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "braceBlockFrom" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "cand")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "cand") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TFatArrow"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EVar "cand") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "i")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "cand")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "braceBlockMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "braceBlockMsg" () (EVar "BraceBlock"))
(DTypeSig false "isForeignKwTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "for")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "while")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "def")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "elif")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "class")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "try")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "except")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "finally")))) (EVar "True"))
(DFunDef false "isForeignKwTok" (PWild) (EVar "False"))
(DTypeSig false "lineTrailingColonNoEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "lineTrailingColonNoEq" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "lastColon") (PVar "sawEq")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "True")) (EIf (EBinOp "&&" (EApp (EVar "isColonTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "sawEq")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "foreignKwMsg" (TyFun (TyCon "Token") (TyCon "ParseDiagnosticKind")))
(DFunDef false "foreignKwMsg" ((PVar "token")) (EApp (EVar "ForeignKeyword") (EApp (EVar "foreignKwName") (EVar "token"))))
(DTypeSig false "semicolonMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "semicolonMsg" () (EVar "Semicolon"))
(DTypeSig false "foreignKwName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "foreignKwName" ((PCon "TIdent" (PVar "word"))) (EVar "word"))
(DFunDef false "foreignKwName" (PWild) (ELit (LString "for")))
(DData Private "PrescanHits" () ((variant "PrescanHits" (ConNamed (field "phLex" (TyCon "Int")) (field "phBangEq" (TyCon "Int")) (field "phMut" (TyCon "Int")) (field "phRecord" (TyCon "Int")) (field "phCtxKw" (TyCon "Int")) (field "phFunction" (TyCon "Int")) (field "phInlineLet" (TyCon "Int")) (field "phCaseOf" (TyCon "Int")) (field "phBacktick" (TyCon "Int")) (field "phWith" (TyCon "Int")) (field "phMatchWith" (TyCon "Int")) (field "phStarStar" (TyCon "Int")) (field "phForLoop" (TyCon "Int")) (field "phHsSig" (TyCon "Int")) (field "phBlockComment" (TyCon "Int")) (field "phBraceBlock" (TyCon "Int")) (field "phForeignKw" (TyCon "Int"))))) ())
(DTypeSig false "prescanLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "ParseDiagnosticKind"))))))
(DFunDef false "prescanLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prescanNoHits" (TyCon "PrescanHits"))
(DFunDef false "prescanNoHits" () (ERecordCreate "PrescanHits" ((fa "phLex" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBangEq" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phMut" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phRecord" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phCtxKw" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phFunction" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phInlineLet" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phCaseOf" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBacktick" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phWith" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phMatchWith" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phStarStar" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phForLoop" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phHsSig" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBlockComment" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBraceBlock" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phForeignKw" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))))
(DTypeSig false "prescanLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))))
(DFunDef false "prescanLineStart" ((PVar "toks") (PVar "i") (PVar "t") (PVar "depth") (PVar "h0")) (EBlock (DoLet false false (PVar "h1") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "h0") "phRecord") (ELit (LInt 0)))) (EBinOp ">=" (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EVar "i")) (ELit (LInt 0)))) (ERecordUpdate (EVar "h0") ((fa "phRecord" (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EVar "i"))))) (EVar "h0"))) (DoLet false false (PVar "h2") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "h1") "phCtxKw") (ELit (LInt 0)))) (EApp (EVar "isContextualKw") (EVar "t"))) (EApp (EVar "isBinderTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h1") ((fa "phCtxKw" (EVar "i")))) (EVar "h1"))) (DoLet false false (PVar "h3") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h2") "phForLoop") (ELit (LInt 0))) (EBinOp "==" (EVar "t") (EApp (EVar "TIdent") (ELit (LString "for"))))) (EApp (EApp (EApp (EVar "forLoopHeadTail") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False"))) (ERecordUpdate (EVar "h2") ((fa "phForLoop" (EVar "i")))) (EVar "h2"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h3") "phForeignKw") (ELit (LInt 0))) (EApp (EVar "isForeignKwTok") (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EVar "i")) (ELit (LInt 0))) (EVar "False")) (EVar "False"))) (ERecordUpdate (EVar "h3") ((fa "phForeignKw" (EVar "i")))) (EVar "h3")))))
(DTypeSig false "prescanTokHit" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits"))))))))))
(DFunDef false "prescanTokHit" ((PVar "toks") (PVar "offs") (PVar "i") (PVar "t") (PVar "depth") (PVar "sb") (PVar "im") (PVar "h")) (EMatch (EVar "t") (arm (PCon "TLexError" PWild) () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phLex") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phLex" (EVar "i")))) (EVar "h"))) (arm (PCon "TBangEq") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phBangEq") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phBangEq" (EVar "i")))) (EVar "h"))) (arm (PCon "TMut") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phMut") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phMut" (EVar "i")))) (EVar "h"))) (arm (PCon "TFunction") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phFunction") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phFunction" (EVar "i")))) (EVar "h"))) (arm (PCon "TBacktickIdent" PWild) () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phBacktick") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phBacktick" (EVar "i")))) (EVar "h"))) (arm (PCon "TSlash") () (EIf (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phBlockComment") (ELit (LInt 0))) (EApp (EVar "isStarTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h") ((fa "phBlockComment" (EVar "i")))) (EVar "h"))) (arm (PCon "TStar") () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phStarStar") (ELit (LInt 0))) (EApp (EVar "isStarTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "offs")) (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (ELit (LInt 1))))) (ERecordUpdate (EVar "h") ((fa "phStarStar" (EVar "i")))) (EVar "h"))) (arm (PCon "TWith") () (EIf (EVar "im") (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phMatchWith") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phMatchWith" (EVar "i")))) (EVar "h")) (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phWith") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phWith" (EVar "i")))) (EVar "h")))) (arm (PCon "TIf") () (EIf (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phBraceBlock") (ELit (LInt 0))) (EBinOp ">=" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LInt 0)))) (ERecordUpdate (EVar "h") ((fa "phBraceBlock" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))) (EVar "h"))) (arm (PCon "TThen") () (EApp (EApp (EApp (EVar "prescanInlineLet") (EVar "toks")) (EVar "i")) (EVar "h"))) (arm (PCon "TElse") () (EApp (EApp (EApp (EVar "prescanInlineLet") (EVar "toks")) (EVar "i")) (EVar "h"))) (arm (PCon "TIdent" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanIdentHit") (EVar "toks")) (EVar "i")) (EVar "s")) (EVar "depth")) (EVar "sb")) (EVar "h"))) (arm PWild () (EVar "h"))))
(DTypeSig false "prescanInlineLet" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))
(DFunDef false "prescanInlineLet" ((PVar "toks") (PVar "i") (PVar "h")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phInlineLet") (ELit (LInt 0))) (EApp (EVar "isLetTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))))) (ERecordUpdate (EVar "h") ((fa "phInlineLet" (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "h")))
(DTypeSig false "prescanIdentHit" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits"))))))))
(DFunDef false "prescanIdentHit" ((PVar "toks") (PVar "i") (PVar "s") (PVar "depth") (PVar "sb") (PVar "h0")) (EBlock (DoLet false false (PVar "h1") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "s") (ELit (LString "case"))) (EBinOp "<" (EFieldAccess (EVar "h0") "phCaseOf") (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0)))) (ERecordUpdate (EVar "h0") ((fa "phCaseOf" (EVar "i")))) (EVar "h0"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sb") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EFieldAccess (EVar "h1") "phHsSig") (ELit (LInt 0)))) (EApp (EVar "isConsTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h1") ((fa "phHsSig" (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "h1")))))
(DTypeSig false "prescanWalk" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))))))))
(DFunDef false "prescanWalk" ((PVar "toks") (PVar "offs") (PVar "n") (PVar "i") (PVar "depth") (PVar "ls") (PVar "sb") (PVar "im") (PVar "h")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "h") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (DoLet false false (PVar "h1") (EIf (EVar "ls") (EApp (EApp (EApp (EApp (EApp (EVar "prescanLineStart") (EVar "toks")) (EVar "i")) (EVar "t")) (EVar "depth")) (EVar "h")) (EVar "h"))) (DoLet false false (PVar "h2") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanTokHit") (EVar "toks")) (EVar "offs")) (EVar "i")) (EVar "t")) (EVar "depth")) (EVar "sb")) (EVar "im")) (EVar "h1"))) (DoExpr (EMatch (EVar "t") (arm (PCon "TIndent") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "h2"))) (arm (PCon "TDedent") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "True")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "h2"))) (arm (PCon "TNewline") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False")) (EVar "h2"))) (arm (PCon "TMatch") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "True")) (EVar "h2"))) (arm (PCon "TWith") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "False")) (EVar "h2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "im")) (EVar "h2")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "prescanDiagnostic" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "ParseDiagnostic"))))))))
(DFunDef false "prescanDiagnostic" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EApp (EVar "arrayLength") (EVar "toks"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "True")) (EVar "True")) (EVar "False")) (EVar "prescanNoHits"))) (DoLet false false (PVar "beIdx") (EFieldAccess (EVar "hits") "phBangEq")) (DoLet false false (PVar "lmIdx") (EFieldAccess (EVar "hits") "phMut")) (DoLet false false (PVar "recIdx") (EFieldAccess (EVar "hits") "phRecord")) (DoLet false false (PVar "ckIdx") (EFieldAccess (EVar "hits") "phCtxKw")) (DoLet false false (PVar "fnIdx") (EFieldAccess (EVar "hits") "phFunction")) (DoLet false false (PVar "ilIdx") (EFieldAccess (EVar "hits") "phInlineLet")) (DoLet false false (PVar "coIdx") (EFieldAccess (EVar "hits") "phCaseOf")) (DoLet false false (PVar "btIdx") (EFieldAccess (EVar "hits") "phBacktick")) (DoLet false false (PVar "wiIdx") (EFieldAccess (EVar "hits") "phWith")) (DoLet false false (PVar "mwIdx") (EFieldAccess (EVar "hits") "phMatchWith")) (DoLet false false (PVar "ssIdx") (EFieldAccess (EVar "hits") "phStarStar")) (DoLet false false (PVar "forIdx") (EFieldAccess (EVar "hits") "phForLoop")) (DoLet false false (PVar "sigIdx") (EFieldAccess (EVar "hits") "phHsSig")) (DoLet false false (PVar "bcIdx") (EFieldAccess (EVar "hits") "phBlockComment")) (DoLet false false (PVar "bbIdx") (EFieldAccess (EVar "hits") "phBraceBlock")) (DoLet false false (PVar "fkwIdx") (EFieldAccess (EVar "hits") "phForeignKw")) (DoExpr (EMatch (EApp (EApp (EVar "prescanLexError") (EVar "toks")) (EFieldAccess (EVar "hits") "phLex")) (arm (PCon "Some" (PTuple (PVar "leIdx") (PVar "leMsg"))) () (EBlock (DoLet false false (PVar "leMsg2") (EMatch (EVar "leMsg") (arm (PCon "UnexpectedCharacter" (PLit (LString ";"))) () (EVar "semicolonMsg")) (arm PWild () (EVar "leMsg")))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "leMsg2")) (EVar "leIdx")))))) (arm (PCon "None") () (EIf (EBinOp ">=" (EVar "beIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "BadNeq")) (EVar "beIdx"))) (EIf (EBinOp ">=" (EVar "lmIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "letMutRemovedMsg"))) (EVar "lmIdx"))) (EIf (EBinOp ">=" (EVar "recIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "recordRemovedMsg"))) (EVar "recIdx"))) (EIf (EBinOp ">=" (EVar "ckIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "ReservedKeyword") (EApp (EVar "contextualKwName") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "ckIdx"))))) (EVar "ckIdx"))) (EIf (EBinOp ">=" (EVar "fnIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "functionRemovedMsg"))) (EVar "fnIdx"))) (EIf (EBinOp ">=" (EVar "ilIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "inlineLetMissingInMsg"))) (EVar "ilIdx"))) (EIf (EBinOp ">=" (EVar "coIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "hsCaseOfMsg")) (EVar "coIdx"))) (EIf (EBinOp ">=" (EVar "btIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "backtickInfixMsg"))) (EVar "btIdx"))) (EIf (EBinOp ">=" (EVar "mwIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "matchWithMsg")) (EVar "mwIdx"))) (EIf (EBinOp ">=" (EVar "wiIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "letRecWithRemovedMsg"))) (EVar "wiIdx"))) (EIf (EBinOp ">=" (EVar "bcIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "blockCommentMsg")) (EVar "bcIdx"))) (EIf (EBinOp ">=" (EVar "ssIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "starStarMsg")) (EVar "ssIdx"))) (EIf (EBinOp ">=" (EVar "sigIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "hsSigMsg")) (EVar "sigIdx"))) (EIf (EBinOp ">=" (EVar "bbIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "braceBlockMsg")) (EVar "bbIdx"))) (EIf (EBinOp ">=" (EVar "fkwIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "foreignKwMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "fkwIdx")))) (EVar "fkwIdx"))) (EIf (EBinOp ">=" (EVar "forIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "forLoopMsg")) (EVar "forIdx"))) (EVar "None"))))))))))))))))))))))
# MARK
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "peekTok" false) (mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isStarTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("frontend" "parse_locate") ((mem "locateTokenDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DTypeSig true "letMutRemovedMsg" (TyCon "String"))
(DFunDef false "letMutRemovedMsg" () (ELit (LString "`let mut` has been removed; bindings are immutable, so use a `Ref` cell: `let x = Ref 0`, then `x := v` and `!x`")))
(DTypeSig false "recordRemovedMsg" (TyCon "String"))
(DFunDef false "recordRemovedMsg" () (ELit (LString "`record` is not a keyword; declare a record as `data X = { field : T }`")))
(DTypeSig false "functionRemovedMsg" (TyCon "String"))
(DFunDef false "functionRemovedMsg" () (ELit (LString "`function` is not a keyword; write `x => match x` with the arms indented below it")))
(DTypeSig true "isLineEndTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLineEndTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLineEndTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isLineEndTok" (PWild) (EVar "False"))
(DTypeSig false "braceHasBarAtTop" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "braceHasBarAtTop" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "True") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "True") (EIf (EBinOp "&&" (EApp (EVar "isPipeTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EBinOp "&&" (EApp (EVar "isRBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "braceAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "braceAfterEq" ((PVar "toks") (PVar "i")) (EIf (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EBinOp "&&" (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EIf (EVar "otherwise") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineIsRecordBody" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "lineIsRecordBody" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "sawField")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "sawField") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "sawField") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "braceAfterEq") (EVar "toks")) (EVar "i"))) (DoExpr (EIf (EBinOp "<" (EVar "b") (ELit (LInt 0))) (EVar "False") (EApp (EVar "not") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (ELit (LInt 0))))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isColonTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "braceHasBarAtTop") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))))) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "sawField")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "sawField")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "sawField")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "recordHeadIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "recordHeadIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp "||" (EApp (EVar "isExportTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isPublicTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EApp (EVar "TIdent") (ELit (LString "record")))) (EApp (EVar "isTUpperTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "lineIsRecordBody") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))) (EVar "False"))) (EVar "i") (EIf (EVar "otherwise") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "contextualKwName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "contextualKwName" ((PCon "TLet")) (ELit (LString "let")))
(DFunDef false "contextualKwName" ((PCon "TRec")) (ELit (LString "rec")))
(DFunDef false "contextualKwName" ((PCon "TIf")) (ELit (LString "if")))
(DFunDef false "contextualKwName" ((PCon "TThen")) (ELit (LString "then")))
(DFunDef false "contextualKwName" ((PCon "TElse")) (ELit (LString "else")))
(DFunDef false "contextualKwName" (PWild) (ELit (LString "")))
(DTypeSig false "isContextualKw" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isContextualKw" ((PVar "t")) (EBinOp "/=" (EApp (EVar "contextualKwName") (EVar "t")) (ELit (LString ""))))
(DTypeSig false "isBinderTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBinderTok" ((PCon "TEqual")) (EVar "True"))
(DFunDef false "isBinderTok" ((PCon "TColon")) (EVar "True"))
(DFunDef false "isBinderTok" (PWild) (EVar "False"))
(DTypeSig false "scanForLetIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "scanForLetIn" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EApp (EVar "isInTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "inlineLetMissingInMsg" (TyCon "String"))
(DFunDef false "inlineLetMissingInMsg" () (ELit (LString "inline `let` requires `in`, as in `else let x = e in body`; for a multi-line body put `else` on its own line and indent the block")))
(DTypeSig false "caseHasOfBeforeBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "caseHasOfBeforeBoundary" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EApp (EVar "isOfTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "True") (EIf (EApp (EVar "isImplTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "hsCaseOfMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "hsCaseOfMsg" () (EVar "HsCase"))
(DTypeSig false "backtickInfixMsg" (TyCon "String"))
(DFunDef false "backtickInfixMsg" () (ELit (LString "Medaka has no infix backticks; write `f x y`")))
(DTypeSig false "matchWithMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "matchWithMsg" () (EVar "MatchWith"))
(DTypeSig false "starStarMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "starStarMsg" () (EVar "NoPow"))
(DTypeSig false "forLoopHeadTail" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "forLoopHeadTail" ((PVar "toks") (PVar "i") (PVar "sawPat")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EApp (EVar "isInTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EVar "sawPat") (EIf (EApp (EVar "isForPatTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "forLoopHeadTail") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isForPatTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForPatTok" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TComma")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isForPatTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isForPatTok" (PWild) (EVar "False"))
(DTypeSig false "forLoopMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "forLoopMsg" () (EApp (EVar "ForeignKeyword") (ELit (LString "for"))))
(DTypeSig false "letRecWithRemovedMsg" (TyCon "String"))
(DFunDef false "letRecWithRemovedMsg" () (ELit (LString "`let rec ... with` has been removed; define each binding as its own `let rec`")))
(DTypeSig false "hsSigMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "hsSigMsg" () (EVar "HsSignature"))
(DTypeSig true "isBracketOpenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketOpenTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isBracketOpenTok" (PWild) (EVar "False"))
(DTypeSig true "isBracketCloseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketCloseTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isBracketCloseTok" (PWild) (EVar "False"))
(DTypeSig false "blockCommentMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "blockCommentMsg" () (EVar "BlockComment"))
(DTypeSig false "braceBlockFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "braceBlockFrom" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "cand")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "cand") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TFatArrow"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isLBraceTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EVar "cand") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "i")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "cand")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "braceBlockMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "braceBlockMsg" () (EVar "BraceBlock"))
(DTypeSig false "isForeignKwTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "for")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "while")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "def")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "elif")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "class")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "try")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "except")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "finally")))) (EVar "True"))
(DFunDef false "isForeignKwTok" (PWild) (EVar "False"))
(DTypeSig false "lineTrailingColonNoEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "lineTrailingColonNoEq" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "lastColon") (PVar "sawEq")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EVar "isIndentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EVar "isDedentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "True")) (EIf (EBinOp "&&" (EApp (EVar "isColonTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "sawEq")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "foreignKwMsg" (TyFun (TyCon "Token") (TyCon "ParseDiagnosticKind")))
(DFunDef false "foreignKwMsg" ((PVar "token")) (EApp (EVar "ForeignKeyword") (EApp (EVar "foreignKwName") (EVar "token"))))
(DTypeSig false "semicolonMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "semicolonMsg" () (EVar "Semicolon"))
(DTypeSig false "foreignKwName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "foreignKwName" ((PCon "TIdent" (PVar "word"))) (EVar "word"))
(DFunDef false "foreignKwName" (PWild) (ELit (LString "for")))
(DData Private "PrescanHits" () ((variant "PrescanHits" (ConNamed (field "phLex" (TyCon "Int")) (field "phBangEq" (TyCon "Int")) (field "phMut" (TyCon "Int")) (field "phRecord" (TyCon "Int")) (field "phCtxKw" (TyCon "Int")) (field "phFunction" (TyCon "Int")) (field "phInlineLet" (TyCon "Int")) (field "phCaseOf" (TyCon "Int")) (field "phBacktick" (TyCon "Int")) (field "phWith" (TyCon "Int")) (field "phMatchWith" (TyCon "Int")) (field "phStarStar" (TyCon "Int")) (field "phForLoop" (TyCon "Int")) (field "phHsSig" (TyCon "Int")) (field "phBlockComment" (TyCon "Int")) (field "phBraceBlock" (TyCon "Int")) (field "phForeignKw" (TyCon "Int"))))) ())
(DTypeSig false "prescanLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "ParseDiagnosticKind"))))))
(DFunDef false "prescanLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prescanNoHits" (TyCon "PrescanHits"))
(DFunDef false "prescanNoHits" () (ERecordCreate "PrescanHits" ((fa "phLex" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBangEq" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phMut" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phRecord" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phCtxKw" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phFunction" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phInlineLet" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phCaseOf" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBacktick" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phWith" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phMatchWith" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phStarStar" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phForLoop" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phHsSig" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBlockComment" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phBraceBlock" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (fa "phForeignKw" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))))
(DTypeSig false "prescanLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))))
(DFunDef false "prescanLineStart" ((PVar "toks") (PVar "i") (PVar "t") (PVar "depth") (PVar "h0")) (EBlock (DoLet false false (PVar "h1") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "h0") "phRecord") (ELit (LInt 0)))) (EBinOp ">=" (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EVar "i")) (ELit (LInt 0)))) (ERecordUpdate (EVar "h0") ((fa "phRecord" (EApp (EApp (EVar "recordHeadIdx") (EVar "toks")) (EVar "i"))))) (EVar "h0"))) (DoLet false false (PVar "h2") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "h1") "phCtxKw") (ELit (LInt 0)))) (EApp (EVar "isContextualKw") (EVar "t"))) (EApp (EVar "isBinderTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h1") ((fa "phCtxKw" (EVar "i")))) (EVar "h1"))) (DoLet false false (PVar "h3") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h2") "phForLoop") (ELit (LInt 0))) (EBinOp "==" (EVar "t") (EApp (EVar "TIdent") (ELit (LString "for"))))) (EApp (EApp (EApp (EVar "forLoopHeadTail") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False"))) (ERecordUpdate (EVar "h2") ((fa "phForLoop" (EVar "i")))) (EVar "h2"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h3") "phForeignKw") (ELit (LInt 0))) (EApp (EVar "isForeignKwTok") (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EVar "i")) (ELit (LInt 0))) (EVar "False")) (EVar "False"))) (ERecordUpdate (EVar "h3") ((fa "phForeignKw" (EVar "i")))) (EVar "h3")))))
(DTypeSig false "prescanTokHit" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits"))))))))))
(DFunDef false "prescanTokHit" ((PVar "toks") (PVar "offs") (PVar "i") (PVar "t") (PVar "depth") (PVar "sb") (PVar "im") (PVar "h")) (EMatch (EVar "t") (arm (PCon "TLexError" PWild) () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phLex") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phLex" (EVar "i")))) (EVar "h"))) (arm (PCon "TBangEq") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phBangEq") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phBangEq" (EVar "i")))) (EVar "h"))) (arm (PCon "TMut") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phMut") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phMut" (EVar "i")))) (EVar "h"))) (arm (PCon "TFunction") () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phFunction") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phFunction" (EVar "i")))) (EVar "h"))) (arm (PCon "TBacktickIdent" PWild) () (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phBacktick") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phBacktick" (EVar "i")))) (EVar "h"))) (arm (PCon "TSlash") () (EIf (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phBlockComment") (ELit (LInt 0))) (EApp (EVar "isStarTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h") ((fa "phBlockComment" (EVar "i")))) (EVar "h"))) (arm (PCon "TStar") () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phStarStar") (ELit (LInt 0))) (EApp (EVar "isStarTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "offs")) (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (ELit (LInt 1))))) (ERecordUpdate (EVar "h") ((fa "phStarStar" (EVar "i")))) (EVar "h"))) (arm (PCon "TWith") () (EIf (EVar "im") (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phMatchWith") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phMatchWith" (EVar "i")))) (EVar "h")) (EIf (EBinOp "<" (EFieldAccess (EVar "h") "phWith") (ELit (LInt 0))) (ERecordUpdate (EVar "h") ((fa "phWith" (EVar "i")))) (EVar "h")))) (arm (PCon "TIf") () (EIf (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phBraceBlock") (ELit (LInt 0))) (EBinOp ">=" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LInt 0)))) (ERecordUpdate (EVar "h") ((fa "phBraceBlock" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))) (EVar "h"))) (arm (PCon "TThen") () (EApp (EApp (EApp (EVar "prescanInlineLet") (EVar "toks")) (EVar "i")) (EVar "h"))) (arm (PCon "TElse") () (EApp (EApp (EApp (EVar "prescanInlineLet") (EVar "toks")) (EVar "i")) (EVar "h"))) (arm (PCon "TIdent" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanIdentHit") (EVar "toks")) (EVar "i")) (EVar "s")) (EVar "depth")) (EVar "sb")) (EVar "h"))) (arm PWild () (EVar "h"))))
(DTypeSig false "prescanInlineLet" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))
(DFunDef false "prescanInlineLet" ((PVar "toks") (PVar "i") (PVar "h")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EFieldAccess (EVar "h") "phInlineLet") (ELit (LInt 0))) (EApp (EVar "isLetTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))))) (ERecordUpdate (EVar "h") ((fa "phInlineLet" (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "h")))
(DTypeSig false "prescanIdentHit" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits"))))))))
(DFunDef false "prescanIdentHit" ((PVar "toks") (PVar "i") (PVar "s") (PVar "depth") (PVar "sb") (PVar "h0")) (EBlock (DoLet false false (PVar "h1") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "s") (ELit (LString "case"))) (EBinOp "<" (EFieldAccess (EVar "h0") "phCaseOf") (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0)))) (ERecordUpdate (EVar "h0") ((fa "phCaseOf" (EVar "i")))) (EVar "h0"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sb") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EFieldAccess (EVar "h1") "phHsSig") (ELit (LInt 0)))) (EApp (EVar "isConsTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ERecordUpdate (EVar "h1") ((fa "phHsSig" (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "h1")))))
(DTypeSig false "prescanWalk" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "PrescanHits") (TyCon "PrescanHits")))))))))))
(DFunDef false "prescanWalk" ((PVar "toks") (PVar "offs") (PVar "n") (PVar "i") (PVar "depth") (PVar "ls") (PVar "sb") (PVar "im") (PVar "h")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "h") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (DoLet false false (PVar "h1") (EIf (EVar "ls") (EApp (EApp (EApp (EApp (EApp (EVar "prescanLineStart") (EVar "toks")) (EVar "i")) (EVar "t")) (EVar "depth")) (EVar "h")) (EVar "h"))) (DoLet false false (PVar "h2") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanTokHit") (EVar "toks")) (EVar "offs")) (EVar "i")) (EVar "t")) (EVar "depth")) (EVar "sb")) (EVar "im")) (EVar "h1"))) (DoExpr (EMatch (EVar "t") (arm (PCon "TIndent") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "True")) (EVar "False")) (EVar "False")) (EVar "h2"))) (arm (PCon "TDedent") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "True")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "h2"))) (arm (PCon "TNewline") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False")) (EVar "h2"))) (arm (PCon "TMatch") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "True")) (EVar "h2"))) (arm (PCon "TWith") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "False")) (EVar "h2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "False")) (EVar "im")) (EVar "h2")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "prescanDiagnostic" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "ParseDiagnostic"))))))))
(DFunDef false "prescanDiagnostic" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prescanWalk") (EVar "toks")) (EVar "offs")) (EApp (EVar "arrayLength") (EVar "toks"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "True")) (EVar "True")) (EVar "False")) (EVar "prescanNoHits"))) (DoLet false false (PVar "beIdx") (EFieldAccess (EVar "hits") "phBangEq")) (DoLet false false (PVar "lmIdx") (EFieldAccess (EVar "hits") "phMut")) (DoLet false false (PVar "recIdx") (EFieldAccess (EVar "hits") "phRecord")) (DoLet false false (PVar "ckIdx") (EFieldAccess (EVar "hits") "phCtxKw")) (DoLet false false (PVar "fnIdx") (EFieldAccess (EVar "hits") "phFunction")) (DoLet false false (PVar "ilIdx") (EFieldAccess (EVar "hits") "phInlineLet")) (DoLet false false (PVar "coIdx") (EFieldAccess (EVar "hits") "phCaseOf")) (DoLet false false (PVar "btIdx") (EFieldAccess (EVar "hits") "phBacktick")) (DoLet false false (PVar "wiIdx") (EFieldAccess (EVar "hits") "phWith")) (DoLet false false (PVar "mwIdx") (EFieldAccess (EVar "hits") "phMatchWith")) (DoLet false false (PVar "ssIdx") (EFieldAccess (EVar "hits") "phStarStar")) (DoLet false false (PVar "forIdx") (EFieldAccess (EVar "hits") "phForLoop")) (DoLet false false (PVar "sigIdx") (EFieldAccess (EVar "hits") "phHsSig")) (DoLet false false (PVar "bcIdx") (EFieldAccess (EVar "hits") "phBlockComment")) (DoLet false false (PVar "bbIdx") (EFieldAccess (EVar "hits") "phBraceBlock")) (DoLet false false (PVar "fkwIdx") (EFieldAccess (EVar "hits") "phForeignKw")) (DoExpr (EMatch (EApp (EApp (EVar "prescanLexError") (EVar "toks")) (EFieldAccess (EVar "hits") "phLex")) (arm (PCon "Some" (PTuple (PVar "leIdx") (PVar "leMsg"))) () (EBlock (DoLet false false (PVar "leMsg2") (EMatch (EVar "leMsg") (arm (PCon "UnexpectedCharacter" (PLit (LString ";"))) () (EVar "semicolonMsg")) (arm PWild () (EVar "leMsg")))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "leMsg2")) (EVar "leIdx")))))) (arm (PCon "None") () (EIf (EBinOp ">=" (EVar "beIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "BadNeq")) (EVar "beIdx"))) (EIf (EBinOp ">=" (EVar "lmIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "letMutRemovedMsg"))) (EVar "lmIdx"))) (EIf (EBinOp ">=" (EVar "recIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "recordRemovedMsg"))) (EVar "recIdx"))) (EIf (EBinOp ">=" (EVar "ckIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "ReservedKeyword") (EApp (EVar "contextualKwName") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "ckIdx"))))) (EVar "ckIdx"))) (EIf (EBinOp ">=" (EVar "fnIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "functionRemovedMsg"))) (EVar "fnIdx"))) (EIf (EBinOp ">=" (EVar "ilIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "inlineLetMissingInMsg"))) (EVar "ilIdx"))) (EIf (EBinOp ">=" (EVar "coIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "hsCaseOfMsg")) (EVar "coIdx"))) (EIf (EBinOp ">=" (EVar "btIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "backtickInfixMsg"))) (EVar "btIdx"))) (EIf (EBinOp ">=" (EVar "mwIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "matchWithMsg")) (EVar "mwIdx"))) (EIf (EBinOp ">=" (EVar "wiIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EVar "letRecWithRemovedMsg"))) (EVar "wiIdx"))) (EIf (EBinOp ">=" (EVar "bcIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "blockCommentMsg")) (EVar "bcIdx"))) (EIf (EBinOp ">=" (EVar "ssIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "starStarMsg")) (EVar "ssIdx"))) (EIf (EBinOp ">=" (EVar "sigIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "hsSigMsg")) (EVar "sigIdx"))) (EIf (EBinOp ">=" (EVar "bbIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "braceBlockMsg")) (EVar "bbIdx"))) (EIf (EBinOp ">=" (EVar "fkwIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "foreignKwMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "fkwIdx")))) (EVar "fkwIdx"))) (EIf (EBinOp ">=" (EVar "forIdx") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "forLoopMsg")) (EVar "forIdx"))) (EVar "None"))))))))))))))))))))))
