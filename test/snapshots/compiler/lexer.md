# META
source_lines=1143
stages=DESUGAR,MARK
# SOURCE
-- Tokenize Medaka source and apply indentation-sensitive layout.
-- Handles literals, interpolation, comments, operators, and layout continuations.
-- Nested interpolation inside an interpolated expression is not supported.

import frontend.parse_diagnostic.{
  ParseDiagnosticKind(..), UnicodeProblem(..), renderParseProblem
}
import support.stage_count.{stageBump}
import support.char.{
  isSp,
  isTab,
  isNL,
  isCR,
  isQuote,
  isApos,
  isBackslash,
  isBacktick,
  isSpace,
  isDigit,
  isLower,
  isUpper,
  isAlnum,
  isHexDigit,
}
import support.util.{joinWith, compareDecMag, listLen, anyList}
export import frontend.lex_token.{
  Token(..), tokenToString, describeToken, isCommaTok
}
import frontend.lex_token.{RawTok(..)}
export import support.source_index.{lineStartsOf, offsetToLineColFast}

import frontend.lex_scan.{scanRawChars, scanRawUndedentedChars}
import frontend.lex_literal.{copyCharRange}

export
isThenTok : Token -> Bool
isThenTok TThen = True
isThenTok _ = False

export
isElseTok : Token -> Bool
isElseTok TElse = True
isElseTok _ = False

layout : List RawTok ->
  List Int ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
layout [] stack frames prev opener = closeAll stack 0
layout ((RTok t off _) :: rest) stack frames prev opener
  | bracketOpener t =
    (t, off)
      :: layout
        rest
        stack
        (BracketFrame 0 (opener || isOpener t) :: frames)
        (Some t)
        False
  | bracketCloser t = flushClose t off rest stack frames opener
  | isCommaTok t && frameHasLive frames =
    flushSep t off rest stack frames opener
  | otherwise =
    (t, off) :: layout rest stack frames (Some t) (opener || isOpener t)
layout ((RComment _ _) :: rest) stack frames prev opener =
  layout rest stack frames prev opener
layout ((RNewline col off) :: rest) stack frames prev opener =
  applyNl col off rest stack frames prev opener
layout ((RClauseNl col off) :: rest) stack frames _ opener =
  applyNl col off rest stack frames None opener
layout ((RClauseOpen col off base) :: rest) stack frames _ opener =
  clauseOpen col off base rest stack frames opener

-- The first `bind` clause line of an extern: close each context a wrapped
-- signature opened (`NEWLINE DEDENT`, which ends the signature's trailing-`->`
-- continuation in the parser), then open the clause block against the
-- extern's own column.
clauseOpen : Int ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int)
clauseOpen col off base rest [] frames opener =
  applyNl col off rest [] frames None opener
clauseOpen col off base rest (top :: tl) frames opener
  | top > base =
    (TNewline, off)
      :: (TDedent, off)
      :: clauseOpen col off base rest tl (dropFrame frames) opener
  | otherwise = applyNl col off rest (top :: tl) frames None opener

-- A bracket closer force-flushes every nested layout context opened in the
-- innermost bracket frame (emitting `NEWLINE DEDENT` per context, popping the
-- indent stack) BEFORE the closer token, so the bracket pair stays balanced and
-- the grammar sees `… NEWLINE DEDENT )` (the same shape a top-level block dedent
-- produces).  Then it pops the frame and emits the closer.  `opener` is threaded
-- (and OR-ed with `isOpener t`) so a same-line herald flag survives the closer
-- — e.g. `match args () \n arms`: the `(`/`)` of the `()` scrutinee must NOT
-- clear the `match` opener flag, or the arms' INDENT would be suppressed.
flushClose : Token ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int)
flushClose t off rest stack [] opener =
  (t, off) :: layout rest stack [] (Some t) (opener || isOpener t)
flushClose t off rest stack ((BracketFrame f saved) :: fs) _ =
  flushCloseGo t off rest stack f fs saved

flushCloseGo : Token ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int)
flushCloseGo t off rest [] f fs opener =
  (t, off) :: layout rest [] fs (Some t) (opener || isOpener t)
flushCloseGo t off rest (top :: tl) f fs opener
  | f <= 0 =
    (t, off) :: layout rest (top :: tl) fs (Some t) (opener || isOpener t)
  | otherwise =
    (TNewline, off)
      :: (TDedent, off)
      :: flushCloseGo t off rest tl (f - 1) fs opener

-- A `,` at the bracket's own level ends any nested layout context the bracket
-- has opened (`(x =>⏎  block,` — the block's lambda is one element; the comma
-- belongs to the enclosing bracket), exactly as the closer does, but keeps the
-- frame open for the elements that follow.
flushSep : Token ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int)
flushSep t off rest stack [] opener =
  (t, off) :: layout rest stack [] (Some t) opener
flushSep t off rest stack ((BracketFrame f saved) :: fs) opener =
  flushSepGo t off rest stack f (BracketFrame 0 saved :: fs) opener

flushSepGo : Token ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int)
flushSepGo t off rest [] _ frames opener =
  (t, off) :: layout rest [] frames (Some t) opener
flushSepGo t off rest (top :: tl) f frames opener
  | f <= 0 = (t, off) :: layout rest (top :: tl) frames (Some t) opener
  | otherwise =
    (TNewline, off)
      :: (TDedent, off)
      :: flushSepGo t off rest tl (f - 1) frames opener

frameHasLive : List BracketFrame -> Bool
frameHasLive ((BracketFrame f _) :: _) = f > 0
frameHasLive [] = False

bracketOpener : Token -> Bool
bracketOpener TLParen = True
bracketOpener TLBracket = True
bracketOpener TLBracketTight = True
bracketOpener TLArray = True
bracketOpener TLBrace = True
bracketOpener TDotLBrace = True
bracketOpener _ = False

bracketCloser : Token -> Bool
bracketCloser TRParen = True
bracketCloser TRBracket = True
bracketCloser TRArray = True
bracketCloser TRBrace = True
bracketCloser _ = False

isOpener : Token -> Bool
isOpener TMatch = True
isOpener _ = False

-- One open bracket on the bracket-frame stack (LAYOUT-BRACKETS §6.1): the
-- count of live nested layout contexts this bracket has opened, and the
-- `match`-opener flag as it stood when the bracket opened.  The flag is
-- SAVED here and cleared inside the bracket, then restored at the closer: a
-- `match` header's arms-block flag must survive its scrutinee's own brackets
-- (`match (a, b)⏎  arms`) but must not leak INTO them, or the first newline
-- inside a wrapped scrutinee (`match (a,⏎  b)`) would be read as opening the
-- arms block (#932).
public export data BracketFrame = BracketFrame Int Bool

-- a token that can syntactically END an expression (atom-ender whitelist)
canEndExpr : Token -> Bool
canEndExpr (TIdent _) = True
canEndExpr (TUpper _) = True
canEndExpr (TInt _ _) = True
canEndExpr (TWideInt _ _ _) = True
canEndExpr (TFloat _) = True
canEndExpr (TString _) = True
canEndExpr (TChar _) = True
canEndExpr (TBool _) = True
canEndExpr (TInterpEnd _) = True
canEndExpr TRParen = True
canEndExpr TRBracket = True
canEndExpr TRBrace = True
canEndExpr TRArray = True
canEndExpr TUnderscore = True
canEndExpr _ = False

prevCanEnd : Option Token -> Bool
prevCanEnd (Some t) = canEndExpr t
prevCanEnd None = False

-- an expression binary operator that, ending a logical line, continues the
-- expression onto the next (deeper-indented) line: the line terminator is
-- suppressed so `a ++\n  b` lexes identically to `a ++ b`.  Arrows (-> => <-) are
-- excluded deliberately; trailing `-` is always binary here.
isTrailingContinuationOp : Token -> Bool
isTrailingContinuationOp TPlus = True
isTrailingContinuationOp TMinus = True
isTrailingContinuationOp TStar = True
isTrailingContinuationOp TSlash = True
isTrailingContinuationOp TMod = True
isTrailingContinuationOp TPlusPlus = True
isTrailingContinuationOp TCons = True
isTrailingContinuationOp TEqEq = True
isTrailingContinuationOp TNeq = True
isTrailingContinuationOp TLt = True
isTrailingContinuationOp TGt = True
isTrailingContinuationOp TLeq = True
isTrailingContinuationOp TGeq = True
isTrailingContinuationOp TAnd = True
isTrailingContinuationOp TOr = True
isTrailingContinuationOp TPipeRight = True
isTrailingContinuationOp TRCompose = True
isTrailingContinuationOp TLCompose = True
isTrailingContinuationOp (TBacktickIdent _) = True
-- `let p = e in⏎  body`: a line-final `in` continues onto the deeper body line
-- (an own-line `in` stays rejected — LAYOUT-SEMANTICS.md §9).
isTrailingContinuationOp TIn = True
isTrailingContinuationOp _ = False

prevIsTrailingOp : Option Token -> Bool
prevIsTrailingOp (Some t) = isTrailingContinuationOp t
prevIsTrailingOp None = False

-- Inside a bracket (free-form), the ONLY lines that arm a nested layout context
-- are the locked herald set (LAYOUT-BRACKETS §6.1): `match` (carried by
-- the `opener` flag) and the `do` keyword (whose own next line opens the
-- block).  Crucially this is NOT the generic top-level `not prevCanEnd` rule
-- — after a `,` (or `=` etc.) `prevCanEnd` is also false, but a `,`-led
-- continuation like `[1,\n 2]` must STAY free-form, not open a block.  The
-- bare-`INDENT` block herald is DEFERRED inside brackets (no keyword to arm it
-- without regressing free-form).
armsHerald : Bool -> Option Token -> Bool
armsHerald opener (Some TDo) = True
armsHerald opener (Some TDefer) = True
-- A line-final `=>` (a lambda head, `(x =>⏎  stmts)`) arms the lambda's block
-- body — the bare-INDENT herald, keyed on the one token that always precedes it.
armsHerald opener (Some TFatArrow) = True
armsHerald opener _ = opener

-- a token that can START an application-argument atom.  `TBang` is included
-- (#1751): a Ref-deref argument (`!r`) is unambiguous in this position ever
-- since `!=` became its own token (#1739 half B), so a continuation line
-- opening with `!` continues the application exactly like the inline
-- `g "x" !r` case (`derefArg`, `compiler/frontend/parser.mdk`), rather than
-- opening a spurious nested block.  `-`/`TMinusTight` is deliberately NOT
-- included: it is head-gated (Rule C, `negLitArg`/`appArg`) so that `5 -1`
-- keeps parsing as subtraction, and folding it into this continuation
-- decision — which has no head to gate on — would risk disturbing that rule.
canStartAtom : Token -> Bool
canStartAtom (TInt _ _) = True
canStartAtom (TWideInt _ _ _) = True
canStartAtom (TFloat _) = True
canStartAtom (TString _) = True
canStartAtom (TChar _) = True
canStartAtom (TBool _) = True
canStartAtom (TIdent _) = True
canStartAtom (TUpper _) = True
canStartAtom TUnderscore = True
canStartAtom TLParen = True
canStartAtom TLBracket = True
canStartAtom TLArray = True
canStartAtom TLBrace = True
canStartAtom TAt = True
canStartAtom (TInterpOpen _) = True
canStartAtom TBang = True
canStartAtom _ = False

-- applyNl dispatches on the bracket-frame stack.  Top-level (`frames == []`)
-- and inside a bracket whose head frame already has live contexts (`f > 0`)
-- behave like ordinary layout.  Inside a bracket in free-form (`f == 0`) a
-- newline is DROPPED unless a herald arms a block on a deeper line.
applyNl : Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
applyNl col off rest [] frames prev opener =
  (TNewline, off) :: layout rest [] frames None False
applyNl col off rest (top :: tl) frames prev opener =
  applyNlFrame col off top (top :: tl) rest frames prev opener

-- frames == [] (top level) is handled by the first applyNl clause; here frames
-- is non-empty OR the indent stack is non-empty.  Decide by frame state.
applyNlFrame : Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
applyNlFrame col off top stack rest [] prev opener =
  applyNlTop col off top stack rest [] prev opener
applyNlFrame col off top stack rest ((BracketFrame f saved) :: fs) prev opener
  | f > 0 =
    applyNlTop col off top stack rest (BracketFrame f saved :: fs) prev opener
  | col > top && not (prevIsTrailingOp prev) && armsHerald opener prev =
    (TIndent, off)
      :: layout rest (col :: stack) (BracketFrame 1 saved :: fs) None False
  | otherwise = layout rest stack (BracketFrame f saved :: fs) prev opener

applyNlTop : Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
applyNlTop col off top stack rest frames prev opener
  | col > top = wouldIndent col off stack rest frames prev opener
  | col == top = (TNewline, off) :: layout rest stack frames None False
  | otherwise = (TNewline, off) :: popDedents col off stack rest frames

-- col > top: a block opener pushes INDENT; otherwise it's a candidate
-- continuation, decided by the deeper line's first token (Phase 137)
wouldIndent : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
wouldIndent col off stack rest frames prev opener
  | prevIsTrailingOp prev = layout rest stack frames prev opener
  | opener || not (prevCanEnd prev) =
    (TIndent, off) :: layout rest (col :: stack) (bumpFrame frames) None False
  | otherwise = resolveCont col off stack rest frames prev opener

-- Increment the innermost bracket frame's open-context count (no-op at top level).
bumpFrame : List BracketFrame -> List BracketFrame
bumpFrame [] = []
bumpFrame ((BracketFrame f s) :: fs) = BracketFrame (f + 1) s :: fs

-- Decrement the innermost bracket frame's open-context count (no-op at top level).
dropFrame : List BracketFrame -> List BracketFrame
dropFrame [] = []
dropFrame ((BracketFrame f s) :: fs) = BracketFrame (f - 1) s :: fs

-- conforms to LAYOUT-SEMANTICS.md §5.4 (Stage B deeper-line then/else path);
-- edits must keep both mechanisms in step (LAYOUT-CONFORMANCE-ROADMAP WS-2).
--
-- #1751: the fallback INDENT (the `otherwise` arm below) carries `toff` — the
-- offset of the deeper line's own first token — not `off` (the offset of the
-- RNewline that ended the PREVIOUS line, the convention every other
-- INDENT/DEDENT/NEWLINE synthetic token uses, per the note on `layout` above).
-- This is the one INDENT that a parse error routinely blames directly
-- (`expectTok TDedent` failing on it, "unexpected indentation; expected the
-- end of the block") because it fires when the deeper line DOESN'T look like an
-- application continuation, so misattributing it to the tail of the prior
-- line sends the reader to a line that is fine.
resolveCont : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int)
resolveCont col off stack ((RTok t toff tend) :: more) frames prev opener
  | canStartAtom t = layout (RTok t toff tend :: more) stack frames prev opener
  | isThenTok t = layout (RTok t toff tend :: more) stack frames prev opener
  | isElseTok t = layout (RTok t toff tend :: more) stack frames prev opener
  | otherwise =
    (TIndent, toff)
      :: layout
        (RTok t toff tend :: more)
        (col :: stack)
        (bumpFrame frames)
        None
        False
resolveCont col off stack rest frames prev opener =
  layout rest stack frames None False

-- Pop indent contexts down to `col`, decrementing the innermost bracket frame
-- for each context popped (so a herald block that dedents back below its column
-- returns the bracket frame to free-form).
popDedents : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  List (Token, Int)
popDedents col off [] rest frames = layout rest [] frames None False
popDedents col off (top :: tl) rest frames
  | top > col =
    (TDedent, off)
      :: (TNewline, off)
      :: popDedents col off tl rest (dropFrame frames)
  | otherwise = layout rest (top :: tl) frames None False

-- end of input: NEWLINE, then DEDENT/NEWLINE pairs back to base, then EOF.
-- `off` is the EOF char offset (source length) so the synthetic tail tokens
-- get a source line past the last content line.
closeAll : List Int -> Int -> List (Token, Int)
closeAll stack off = (TNewline, off) :: closeDedents stack off

closeDedents : List Int -> Int -> List (Token, Int)
closeDedents [] off = [(TEof, off)]
closeDedents [_] off = [(TEof, off)]
closeDedents (_ :: tl) off =
  (TDedent, off) :: (TNewline, off) :: closeDedents tl off

-- conforms to LAYOUT-SEMANTICS.md §5.4; edits must keep both mechanisms in step
-- (LAYOUT-CONFORMANCE-ROADMAP WS-2). See also resolveCont above.
-- Phase 122 else-continuation filter: drop a NEWLINE immediately before ELSE
-- or THEN (a `then`/`else` leading the next line continues the enclosing `if`).
elseFilter : List (Token, Int) -> List (Token, Int)
elseFilter ((TNewline, _) :: (TElse, eoff) :: rest) =
  (TElse, eoff) :: elseFilter rest
elseFilter ((TNewline, _) :: (TThen, eoff) :: rest) =
  (TThen, eoff) :: elseFilter rest
elseFilter (t :: rest) = t :: elseFilter rest
elseFilter [] = []

-- The layout pass over the raw stream, carrying offsets.  Shared by `tokenize`
-- (which drops offsets) and `tokenizeWithOffsets` (the position side-channel).
-- `RComment` markers pass through untouched: `layout` treats them as no-ops, and
-- no lookahead in layout can reach one (a comment never directly follows an
-- `RNewline`; `afterNl` suppresses the newline before a comment line).
layoutWithOffsets : Array Char -> Int -> List (Token, Int)
layoutWithOffsets src len =
  let _ = stageBump "lex.offsets"
  elseFilter (layout (rawStream src len) [0] [] None False)

-- The scanner's output with the two raw-stream rewrites applied, the input of
-- every layout pass.
rawStream : Array Char -> Int -> List RawTok
rawStream src len = externClauseBreaks (scanRawChars src)

-- An extern's `bind` clauses, one per line indented under its signature:
--
--   extern f : String -> <FFI "c"> String
--     bind c "f_impl"
--
-- `bind` is an ordinary identifier, so by the continuation rule
-- (LAYOUT-SEMANTICS §4, I.c) the deeper line would continue the signature as a
-- type application.  The line break before the first such line becomes
-- `RClauseOpen`, which closes whatever layout contexts a wrapped signature
-- opened and then opens the clause block against the extern's own column, so
-- the clause lines may sit at any column deeper than `extern` whatever the
-- signature's continuation lines did (LAYOUT-SEMANTICS §5.5).  The breaks
-- before later clause lines become `RClauseNl`, read as a break after a token
-- that cannot end an expression.  The rewrite applies only inside an extern
-- declaration, from its `extern` token to the first line no deeper than the
-- extern's own line, so `bind` keeps its meaning everywhere else.  A stream
-- with no line led by `bind` is returned without being rebuilt.
externClauseBreaks : List RawTok -> List RawTok
externClauseBreaks toks
  | hasBindLine toks = clauseBreaksGo toks 0 (-1) False
  | otherwise = toks

hasBindLine : List RawTok -> Bool
hasBindLine [] = False
hasBindLine ((RNewline _ _) :: (RTok (TIdent "bind") _ _) :: _) = True
hasBindLine (_ :: rest) = hasBindLine rest

-- `lineCol` is the column of the current line; `externCol` the column of the
-- line holding the enclosing `extern`, or -1 outside one; `opened` whether
-- that extern's first clause line has been seen.
clauseBreaksGo : List RawTok -> Int -> Int -> Bool -> List RawTok
clauseBreaksGo [] _ _ _ = []
clauseBreaksGo ((RTok TExtern s e) :: rest) lineCol _ _ =
  RTok TExtern s e :: clauseBreaksGo rest lineCol lineCol False
clauseBreaksGo ((RNewline col off) :: rest) _ externCol opened
  | externCol >= 0 && col > externCol && startsWithBind rest =
    clauseBreak col off externCol opened
      :: clauseBreaksGo rest col externCol True
  | col <= externCol = RNewline col off :: clauseBreaksGo rest col (-1) False
  | otherwise = RNewline col off :: clauseBreaksGo rest col externCol opened
clauseBreaksGo (t :: rest) lineCol externCol opened =
  t :: clauseBreaksGo rest lineCol externCol opened

clauseBreak : Int -> Int -> Int -> Bool -> RawTok
clauseBreak col off _ True = RClauseNl col off
clauseBreak col off externCol False = RClauseOpen col off externCol

startsWithBind : List RawTok -> Bool
startsWithBind ((RTok (TIdent "bind") _ _) :: _) = True
startsWithBind _ = False

-- Layout variant that threads both START and END offsets per token, used by
-- `tokenizeWithOffsetPairs`.  Real tokens carry their RTok start+end; synthetic
-- layout tokens (NEWLINE/INDENT/DEDENT/EOF) carry their position for both
-- (empty span, matching OCaml's zero-width synthetic positions).
layoutPairs : List RawTok ->
  List Int ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
layoutPairs [] stack frames prev opener = closeAllPairs stack 0
layoutPairs ((RTok t s e) :: rest) stack frames prev opener
  | bracketOpener t =
    (t, s, e)
      :: layoutPairs
        rest
        stack
        (BracketFrame 0 (opener || isOpener t) :: frames)
        (Some t)
        False
  | bracketCloser t = flushClosePairs t s e rest stack frames opener
  | isCommaTok t && frameHasLive frames =
    flushSepPairs t s e rest stack frames opener
  | otherwise =
    (t, s, e) :: layoutPairs rest stack frames (Some t) (opener || isOpener t)
layoutPairs ((RComment _ _) :: rest) stack frames prev opener =
  layoutPairs rest stack frames prev opener
layoutPairs ((RNewline col off) :: rest) stack frames prev opener =
  applyNlPairs col off rest stack frames prev opener
layoutPairs ((RClauseNl col off) :: rest) stack frames _ opener =
  applyNlPairs col off rest stack frames None opener
layoutPairs ((RClauseOpen col off base) :: rest) stack frames _ opener =
  clauseOpenPairs col off base rest stack frames opener

clauseOpenPairs : Int ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int, Int)
clauseOpenPairs col off base rest [] frames opener =
  applyNlPairs col off rest [] frames None opener
clauseOpenPairs col off base rest (top :: tl) frames opener
  | top > base =
    (TNewline, off, off)
      :: (TDedent, off, off)
      :: clauseOpenPairs col off base rest tl (dropFrame frames) opener
  | otherwise = applyNlPairs col off rest (top :: tl) frames None opener

flushSepPairs : Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int, Int)
flushSepPairs t s e rest stack [] opener =
  (t, s, e) :: layoutPairs rest stack [] (Some t) opener
flushSepPairs t s e rest stack ((BracketFrame f saved) :: fs) opener =
  flushSepPairsGo t s e rest stack f (BracketFrame 0 saved :: fs) opener

flushSepPairsGo : Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int, Int)
flushSepPairsGo t s e rest [] _ frames opener =
  (t, s, e) :: layoutPairs rest [] frames (Some t) opener
flushSepPairsGo t s e rest (top :: tl) f frames opener
  | f <= 0 = (t, s, e) :: layoutPairs rest (top :: tl) frames (Some t) opener
  | otherwise =
    (TNewline, s, s)
      :: (TDedent, s, s)
      :: flushSepPairsGo t s e rest tl (f - 1) frames opener

flushClosePairs : Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int, Int)
flushClosePairs t s e rest stack [] opener =
  (t, s, e) :: layoutPairs rest stack [] (Some t) (opener || isOpener t)
flushClosePairs t s e rest stack ((BracketFrame f saved) :: fs) _ =
  flushClosePairsGo t s e rest stack f fs saved

flushClosePairsGo : Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List (Token, Int, Int)
flushClosePairsGo t s e rest [] f fs opener =
  (t, s, e) :: layoutPairs rest [] fs (Some t) (opener || isOpener t)
flushClosePairsGo t s e rest (top :: tl) f fs opener
  | f <= 0 =
    (t, s, e) :: layoutPairs rest (top :: tl) fs (Some t) (opener || isOpener t)
  | otherwise =
    (TNewline, s, s)
      :: (TDedent, s, s)
      :: flushClosePairsGo t s e rest tl (f - 1) fs opener

applyNlPairs : Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
applyNlPairs col off rest [] frames prev opener =
  (TNewline, off, off) :: layoutPairs rest [] frames None False
applyNlPairs col off rest (top :: tl) frames prev opener =
  applyNlFramePairs col off top (top :: tl) rest frames prev opener

applyNlFramePairs : Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
applyNlFramePairs col off top stack rest [] prev opener =
  applyNlTopPairs col off top stack rest [] prev opener
applyNlFramePairs col off top stack rest ((BracketFrame f saved) :: fs) prev opener
  | f > 0 =
    applyNlTopPairs
      col
      off
      top
      stack
      rest
      (BracketFrame f saved :: fs)
      prev
      opener
  | col > top && not (prevIsTrailingOp prev) && armsHerald opener prev =
    (TIndent, off, off)
      :: layoutPairs rest (col :: stack) (BracketFrame 1 saved :: fs) None False
  | otherwise = layoutPairs rest stack (BracketFrame f saved :: fs) prev opener

applyNlTopPairs : Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
applyNlTopPairs col off top stack rest frames prev opener
  | col > top = wouldIndentPairs col off stack rest frames prev opener
  | col == top =
    (TNewline, off, off) :: layoutPairs rest stack frames None False
  | otherwise =
    (TNewline, off, off) :: popDedentsPairs col off stack rest frames

wouldIndentPairs : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
wouldIndentPairs col off stack rest frames prev opener
  | prevIsTrailingOp prev = layoutPairs rest stack frames prev opener
  | opener || not (prevCanEnd prev) =
    (TIndent, off, off)
      :: layoutPairs rest (col :: stack) (bumpFrame frames) None False
  | otherwise = resolveContPairs col off stack rest frames prev opener

-- #1751: mirrors `resolveCont`'s fallback-INDENT location fix — `toff`/`tend`
-- (the deeper line's own first token span), not `off` (the prior line's
-- RNewline offset). Must stay in step with `resolveCont` (WS-2, above).
resolveContPairs : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Option Token ->
  Bool ->
  List (Token, Int, Int)
resolveContPairs col off stack ((RTok t toff tend) :: more) frames prev opener
  | canStartAtom t =
    layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | isThenTok t =
    layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | isElseTok t =
    layoutPairs (RTok t toff tend :: more) stack frames prev opener
  | otherwise =
    (TIndent, toff, toff)
      :: layoutPairs
        (RTok t toff tend :: more)
        (col :: stack)
        (bumpFrame frames)
        None
        False
resolveContPairs col off stack rest frames prev opener =
  layoutPairs rest stack frames None False

popDedentsPairs : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  List (Token, Int, Int)
popDedentsPairs col off [] rest frames = layoutPairs rest [] frames None False
popDedentsPairs col off (top :: tl) rest frames
  | top > col =
    (TDedent, off, off)
      :: (TNewline, off, off)
      :: popDedentsPairs col off tl rest (dropFrame frames)
  | otherwise = layoutPairs rest (top :: tl) frames None False

closeAllPairs : List Int -> Int -> List (Token, Int, Int)
closeAllPairs stack off = (TNewline, off, off) :: closeDedentsPairs stack off

closeDedentsPairs : List Int -> Int -> List (Token, Int, Int)
closeDedentsPairs [] off = [(TEof, off, off)]
closeDedentsPairs [_] off = [(TEof, off, off)]
closeDedentsPairs (_ :: tl) off =
  (TDedent, off, off) :: (TNewline, off, off) :: closeDedentsPairs tl off

elseFilterPairs : List (Token, Int, Int) -> List (Token, Int, Int)
elseFilterPairs ((TNewline, _, _) :: (TElse, es, ee) :: rest) =
  (TElse, es, ee) :: elseFilterPairs rest
elseFilterPairs ((TNewline, _, _) :: (TThen, es, ee) :: rest) =
  (TThen, es, ee) :: elseFilterPairs rest
elseFilterPairs (t :: rest) = t :: elseFilterPairs rest
elseFilterPairs [] = []

layoutWithOffsetPairs : Array Char -> Int -> List (Token, Int, Int)
layoutWithOffsetPairs src len =
  let _ = stageBump "lex.pairs"
  elseFilterPairs (layoutPairs (rawStream src len) [0] [] None False)

export
tokenize : String -> List Token
tokenize s =
  let _ = stageBump "lex.tokenize"
  let src = stringToChars s
  let len = arrayLength src
  elseFilterToks (layoutToks (rawStream src len) [0] [] TNewline False)

-- `elseFilter` (the offset-carrying form used by `layoutWithOffsets`) with the
-- offset projection fused in, so `tokenize` builds one list instead of two.
-- The clauses must stay in step with `elseFilter`.
elseFilterToks : List Token -> List Token
elseFilterToks (TNewline :: TElse :: rest) = TElse :: elseFilterToks rest
elseFilterToks (TNewline :: TThen :: rest) = TThen :: elseFilterToks rest
elseFilterToks (t :: rest) = t :: elseFilterToks rest
elseFilterToks [] = []

-- Token-only twin of the `layout` family (no offsets): the same decisions, so
-- `tokenize` conses each token once instead of as a `(Token, Int)` pair.  Every
-- clause must stay in step with its `layout` counterpart.  `prev` is a bare
-- Token, not an `Option`, so no `Some` is allocated per token: `TNewline` plays
-- `None`.  That is sound because layout never records a TNewline as `prev`, and
-- canEndExpr / isTrailingContinuationOp / armsHeraldTok all answer for it as they
-- do for `None`.
armsHeraldTok : Bool -> Token -> Bool
armsHeraldTok _ TDo = True
armsHeraldTok _ TDefer = True
armsHeraldTok _ TFatArrow = True
armsHeraldTok opener _ = opener

layoutToks : List RawTok ->
  List Int ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
layoutToks [] stack frames prev opener = closeAllToks stack
layoutToks ((RTok t _ _) :: rest) stack frames prev opener
  | bracketOpener t =
    t
      :: layoutToks
        rest
        stack
        (BracketFrame 0 (opener || isOpener t) :: frames)
        t
        False
  | bracketCloser t = flushCloseToks t rest stack frames opener
  | isCommaTok t && frameHasLive frames =
    flushSepToks t rest stack frames opener
  | otherwise = t :: layoutToks rest stack frames t (opener || isOpener t)
layoutToks ((RComment _ _) :: rest) stack frames prev opener =
  layoutToks rest stack frames prev opener
layoutToks ((RNewline col _) :: rest) stack frames prev opener =
  applyNlToks col rest stack frames prev opener
layoutToks ((RClauseNl col _) :: rest) stack frames _ opener =
  applyNlToks col rest stack frames TNewline opener
layoutToks ((RClauseOpen col _ base) :: rest) stack frames _ opener =
  clauseOpenToks col base rest stack frames opener

clauseOpenToks : Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List Token
clauseOpenToks col base rest [] frames opener =
  applyNlToks col rest [] frames TNewline opener
clauseOpenToks col base rest (top :: tl) frames opener
  | top > base =
    TNewline
      :: TDedent
      :: clauseOpenToks col base rest tl (dropFrame frames) opener
  | otherwise = applyNlToks col rest (top :: tl) frames TNewline opener

closeAllToks : List Int -> List Token
closeAllToks stack = TNewline :: closeDedentsToks stack

closeDedentsToks : List Int -> List Token
closeDedentsToks [] = [TEof]
closeDedentsToks [_] = [TEof]
closeDedentsToks (_ :: tl) = TDedent :: TNewline :: closeDedentsToks tl

flushCloseToks : Token ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List Token
flushCloseToks t rest stack [] opener =
  t :: layoutToks rest stack [] t (opener || isOpener t)
flushCloseToks t rest stack ((BracketFrame f saved) :: fs) _ =
  flushCloseGoToks t rest stack f fs saved

flushCloseGoToks : Token ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List Token
flushCloseGoToks t rest [] f fs opener =
  t :: layoutToks rest [] fs t (opener || isOpener t)
flushCloseGoToks t rest (top :: tl) f fs opener
  | f <= 0 = t :: layoutToks rest (top :: tl) fs t (opener || isOpener t)
  | otherwise =
    TNewline :: TDedent :: flushCloseGoToks t rest tl (f - 1) fs opener

flushSepToks : Token ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List Token
flushSepToks t rest stack [] opener = t :: layoutToks rest stack [] t opener
flushSepToks t rest stack ((BracketFrame f saved) :: fs) opener =
  flushSepGoToks t rest stack f (BracketFrame 0 saved :: fs) opener

flushSepGoToks : Token ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List Token
flushSepGoToks t rest [] _ frames opener =
  t :: layoutToks rest [] frames t opener
flushSepGoToks t rest (top :: tl) f frames opener
  | f <= 0 = t :: layoutToks rest (top :: tl) frames t opener
  | otherwise =
    TNewline :: TDedent :: flushSepGoToks t rest tl (f - 1) frames opener

applyNlToks : Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
applyNlToks col rest [] frames prev opener =
  TNewline :: layoutToks rest [] frames TNewline False
applyNlToks col rest (top :: tl) frames prev opener =
  applyNlFrameToks col top (top :: tl) rest frames prev opener

applyNlFrameToks : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
applyNlFrameToks col top stack rest [] prev opener =
  applyNlTopToks col top stack rest [] prev opener
applyNlFrameToks col top stack rest ((BracketFrame f saved) :: fs) prev opener
  | f > 0 =
    applyNlTopToks col top stack rest (BracketFrame f saved :: fs) prev opener
  | col > top
    && not (isTrailingContinuationOp prev)
    && armsHeraldTok opener prev =
    TIndent
      :: layoutToks
        rest
        (col :: stack)
        (BracketFrame 1 saved :: fs)
        TNewline
        False
  | otherwise = layoutToks rest stack (BracketFrame f saved :: fs) prev opener

applyNlTopToks : Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
applyNlTopToks col top stack rest frames prev opener
  | col > top = wouldIndentToks col stack rest frames prev opener
  | col == top = TNewline :: layoutToks rest stack frames TNewline False
  | otherwise = TNewline :: popDedentsToks col stack rest frames

wouldIndentToks : Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
wouldIndentToks col stack rest frames prev opener
  | isTrailingContinuationOp prev = layoutToks rest stack frames prev opener
  | opener || not (canEndExpr prev) =
    TIndent :: layoutToks rest (col :: stack) (bumpFrame frames) TNewline False
  | otherwise = resolveContToks col stack rest frames prev opener

resolveContToks : Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List Token
resolveContToks col stack ((RTok t toff tend) :: more) frames prev opener
  | canStartAtom t =
    layoutToks (RTok t toff tend :: more) stack frames prev opener
  | isThenTok t = layoutToks (RTok t toff tend :: more) stack frames prev opener
  | isElseTok t = layoutToks (RTok t toff tend :: more) stack frames prev opener
  | otherwise =
    TIndent
      :: layoutToks
        (RTok t toff tend :: more)
        (col :: stack)
        (bumpFrame frames)
        TNewline
        False
resolveContToks col stack rest frames prev opener =
  layoutToks rest stack frames TNewline False

popDedentsToks : Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  List Token
popDedentsToks col [] rest frames = layoutToks rest [] frames TNewline False
popDedentsToks col (top :: tl) rest frames
  | top > col =
    TDedent :: TNewline :: popDedentsToks col tl rest (dropFrame frames)
  | otherwise = layoutToks rest (top :: tl) frames TNewline False

-- Tokenize and return each token paired with the 1-based source line of its
-- char offset.  The position side-channel (`compiler/frontend/parser.mdk`) consults the
-- line array to record per-decl / per-variant source lines.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export
tokenizeWithLines : String -> (List Token, List Int)
tokenizeWithLines s =
  let src = stringToChars s
  let len = arrayLength src
  let pairs = layoutWithOffsets src len
  let toks = map fst pairs
  let lines = offsetsToLines src (map snd pairs)
  (toks, lines)

-- Tokenize and return each token paired with the 0-based char OFFSET of its
-- first character.  Parallel to `tokenizeWithLines` but exposes the raw offset
-- (not the derived line) so a consumer can recover both line AND column for a
-- token index — the structured parse-error path (`parser.mdk`'s `parseResult`)
-- needs the column to mirror the OCaml oracle's `L:C` format.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export
tokenizeWithOffsets : String -> (List Token, List Int)
tokenizeWithOffsets s =
  let src = stringToChars s
  let len = arrayLength src
  let pairs = layoutWithOffsets src len
  let toks = map fst pairs
  let offs = map snd pairs
  (toks, offs)

-- Tokenize and return each token paired with a (start, end) OFFSET pair where
-- `start` is the 0-based char offset of the token's first character and `end`
-- is one past its last character (= the next scan position).  Used by the LSP
-- path (`parseLocated`) to give `locOfSpan` a true end offset so ELoc ranges
-- match OCaml's `$endpos`-derived end_line/end_col exactly.  The Token stream
-- (`map fst`) is byte-identical to `tokenize`.
export
tokenizeWithOffsetPairs : String -> (List Token, List (Int, Int))
tokenizeWithOffsetPairs s =
  let src = stringToChars s
  let len = arrayLength src
  let triples = layoutWithOffsetPairs src len
  let toks = map ((t, _s, _e) => t) triples
  let pairs = map ((t, s, e) => (s, e)) triples
  (toks, pairs)

-- Convert a 0-based char offset into `s` to a (1-based line, 0-based column)
-- pair, mirroring the OCaml `pos_lnum` / `pos_cnum - pos_bol` reported by the
-- parse-error oracle.  Reuses `posLineColFrom` (the comment side-channel's
-- offset→line/col walk).  Used by `parseResult` to locate a structured error.
export
offsetToLineCol : String -> Int -> (Int, Int)
offsetToLineCol s off = posLineColFrom (stringToChars s) off 0 1 0

-- Convert a list of char offsets (in non-decreasing-ish source order — the
-- synthetic tail tokens all share the EOF offset, which is monotone) to 1-based
-- source lines in a single left-to-right walk over the source, mirroring
-- `posToLineCol`'s amortized-linear strategy for comments.
export
offsetsToLines : Array Char -> List Int -> List Int
offsetsToLines src offs = offsetsToLinesGo src offs 0 1

offsetsToLinesGo : Array Char -> List Int -> Int -> Int -> List Int
offsetsToLinesGo src [] p line = []
offsetsToLinesGo src (off :: rest) p line = match advanceLine src off p line
  (line2, p2) => line2 :: offsetsToLinesGo src rest p2 line2

isLineBreakAt : Array Char -> Int -> Bool
isLineBreakAt src p =
  p < arrayLength src
    && (arrayGetUnsafe p src == '\n'
      || arrayGetUnsafe p src == '\r'
        && (p + 1 >= arrayLength src || arrayGetUnsafe (p + 1) src /= '\n'))

-- Walk forward from char `p` (1-based `line`) to `target`, counting newlines.
-- Offsets arrive in non-decreasing order so each call resumes from the last.
advanceLine : Array Char -> Int -> Int -> Int -> (Int, Int)
advanceLine src target p line
  | p >= target = (line, p)
  | p >= arrayLength src = (line, p)
  | isLineBreakAt src p = advanceLine src target (p + 1) (line + 1)
  | otherwise = advanceLine src target (p + 1) line

-- ── Comment side channel ─────────────────────────────────────────────────
-- Each captured
-- comment carries its 1-based start line, 0-based start column, and full
-- lexeme text (the `--…` / `{- … -}`, delimiters included).  Surfaced in
-- SOURCE ORDER.
-- `format_program`/the comment-preserving printer consume this
-- list keyed by position; the parser is unaffected (the layout pass skips
-- comment markers — see `layout`).
export data Comment = Comment Int Int String

export
commentLine : Comment -> Int
commentLine (Comment l _ _) = l

export
commentCol : Comment -> Int
commentCol (Comment _ c _) = c

export
commentText : Comment -> String
commentText (Comment _ _ t) = t

-- Convert a source char offset to (1-based line, 0-based column) by scanning
-- the preceding characters.  `lineStart` is the offset of the current line's
-- first char; `line` its 1-based number.  O(pos) per call, but only invoked
-- once per comment in a single left-to-right walk (see `posToLineCol`).
posLineColFrom : Array Char -> Int -> Int -> Int -> Int -> (Int, Int)
posLineColFrom src target p line lineStart
  | p >= target = (line, target - lineStart)
  | isLineBreakAt src p = posLineColFrom src target (p + 1) (line + 1) (p + 1)
  | otherwise = posLineColFrom src target (p + 1) line lineStart

-- Turn each `RComment startPos endPos` into a `Comment line col text`.
-- `RComment` tokens arrive in strictly-ascending `startPos` order (scan is a
-- single left-to-right pass), so a running `(p, line, lineStart)` cursor lets
-- `posLineColFrom` resume from the previous comment instead of rescanning from
-- offset 0 every time — turning what was O(comments × filesize) (a fresh scan
-- per comment; the dominant cost of `medaka fmt` on a comment-dense file) into
-- one O(filesize) walk.  `lineStart` for the next hop is `startPos - col`, since
-- `posLineColFrom` returns `col = startPos - lineStart`.
rawToComments : Array Char -> List RawTok -> List Comment
rawToComments src toks = rawToCommentsGo src toks 0 1 0

rawToCommentsGo : Array Char -> List RawTok -> Int -> Int -> Int -> List Comment
rawToCommentsGo _ [] _ _ _ = []
rawToCommentsGo src ((RComment startPos endPos) :: rest) p line lineStart =
  match posLineColFrom src startPos p line lineStart
    (line2, col) =>
      Comment line2 col (copyCharRange src startPos endPos)
        :: rawToCommentsGo src rest startPos line2 (startPos - col)
rawToCommentsGo src (_ :: rest) p line lineStart =
  rawToCommentsGo src rest p line lineStart

-- Tokenize-and-collect the comment side channel, in source order.
export
collectComments : String -> List Comment
collectComments s =
  -- Valid only while lint is the single caller; a second caller must move this bump.
  let _ = stageBump "lint.comments"
  let src = stringToChars s
  let len = arrayLength src
  rawToComments src (scanRawUndedentedChars src)
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "UnicodeProblem" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DUse true (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "tokenToString" false) (mem "describeToken" false) (mem "isCommaTok" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse true (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false) (mem "scanRawUndedentedChars" false))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "copyCharRange" false))))
(DTypeSig true "isThenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isThenTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isThenTok" (PWild) (EVar "False"))
(DTypeSig true "isElseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isElseTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isElseTok" (PWild) (EVar "False"))
(DTypeSig false "layout" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "layout" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAll") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layout" ((PCons (PCon "RTok" (PVar "t") (PVar "off") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClose") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSep") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layout" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpen") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpen" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "clauseOpen" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "clauseOpen" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpen") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClose" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushCloseGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSep" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushSep" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSep" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushSepGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "frameHasLive" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyCon "Bool")))
(DFunDef false "frameHasLive" ((PCons (PCon "BracketFrame" (PVar "f") PWild) PWild)) (EBinOp ">" (EVar "f") (ELit (LInt 0))))
(DFunDef false "frameHasLive" ((PList)) (EVar "False"))
(DTypeSig false "bracketOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketOpener" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TDotLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" (PWild) (EVar "False"))
(DTypeSig false "bracketCloser" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketCloser" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "bracketCloser" (PWild) (EVar "False"))
(DTypeSig false "isOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpener" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isOpener" (PWild) (EVar "False"))
(DData Public "BracketFrame" () ((variant "BracketFrame" (ConPos (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "canEndExpr" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canEndExpr" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TWideInt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInterpEnd" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canEndExpr" (PWild) (EVar "False"))
(DTypeSig false "prevCanEnd" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevCanEnd" ((PCon "Some" (PVar "t"))) (EApp (EVar "canEndExpr") (EVar "t")))
(DFunDef false "prevCanEnd" ((PCon "None")) (EVar "False"))
(DTypeSig false "isTrailingContinuationOp" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMinus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TSlash")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMod")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TEqEq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TNeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TAnd")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TOr")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPipeRight")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TRCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TBacktickIdent" PWild)) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" (PWild) (EVar "False"))
(DTypeSig false "prevIsTrailingOp" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevIsTrailingOp" ((PCon "Some" (PVar "t"))) (EApp (EVar "isTrailingContinuationOp") (EVar "t")))
(DFunDef false "prevIsTrailingOp" ((PCon "None")) (EVar "False"))
(DTypeSig false "armsHerald" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDo"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDefer"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TFatArrow"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "canStartAtom" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canStartAtom" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TWideInt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TAt")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TInterpOpen" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBang")) (EVar "True"))
(DFunDef false "canStartAtom" (PWild) (EVar "False"))
(DTypeSig false "applyNl" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrame") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrame" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTop" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTop" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndent") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndent" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "wouldIndent" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveCont") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "+" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "resolveCont" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedents" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeAll" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedents" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeDedents" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilter" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TElse") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TThen") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.offsets")))) (DoExpr (EApp (EVar "elseFilter") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))))
(DTypeSig false "rawStream" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "rawStream" ((PVar "src") (PVar "len")) (EApp (EVar "externClauseBreaks") (EApp (EVar "scanRawChars") (EVar "src"))))
(DTypeSig false "externClauseBreaks" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "externClauseBreaks" ((PVar "toks")) (EIf (EApp (EVar "hasBindLine") (EVar "toks")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "toks")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "False")) (EIf (EVar "otherwise") (EVar "toks") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasBindLine" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "hasBindLine" ((PList)) (EVar "False"))
(DFunDef false "hasBindLine" ((PCons (PCon "RNewline" PWild PWild) (PCons (PCon "RTok" (PCon "TIdent" (PLit (LString "bind"))) PWild PWild) PWild))) (EVar "True"))
(DFunDef false "hasBindLine" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasBindLine") (EVar "rest")))
(DTypeSig false "clauseBreaksGo" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "clauseBreaksGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "clauseBreaksGo" ((PCons (PCon "RTok" (PCon "TExtern") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "lineCol") PWild PWild) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TExtern")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "lineCol")) (EVar "lineCol")) (EVar "False"))))
(DFunDef false "clauseBreaksGo" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) PWild (PVar "externCol") (PVar "opened")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "externCol") (ELit (LInt 0))) (EBinOp ">" (EVar "col") (EVar "externCol"))) (EApp (EVar "startsWithBind") (EVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "clauseBreak") (EVar "col")) (EVar "off")) (EVar "externCol")) (EVar "opened")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EVar "externCol")) (EVar "True"))) (EIf (EBinOp "<=" (EVar "col") (EVar "externCol")) (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "col")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EUnOp "-" (ELit (LInt 1)))) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "col")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EVar "externCol")) (EVar "opened"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "clauseBreaksGo" ((PCons (PVar "t") (PVar "rest")) (PVar "lineCol") (PVar "externCol") (PVar "opened")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "lineCol")) (EVar "externCol")) (EVar "opened"))))
(DTypeSig false "clauseBreak" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "RawTok"))))))
(DFunDef false "clauseBreak" ((PVar "col") (PVar "off") PWild (PCon "True")) (EApp (EApp (EVar "RClauseNl") (EVar "col")) (EVar "off")))
(DFunDef false "clauseBreak" ((PVar "col") (PVar "off") (PVar "externCol") (PCon "False")) (EApp (EApp (EApp (EVar "RClauseOpen") (EVar "col")) (EVar "off")) (EVar "externCol")))
(DTypeSig false "startsWithBind" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "startsWithBind" ((PCons (PCon "RTok" (PCon "TIdent" (PLit (LString "bind"))) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "startsWithBind" (PWild) (EVar "False"))
(DTypeSig false "layoutPairs" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "layoutPairs" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAllPairs") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutPairs" ((PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutPairs" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "clauseOpenPairs" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "clauseOpenPairs" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepPairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushSepPairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepPairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepPairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushSepPairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepPairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClosePairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "toff") (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeAllPairs" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeDedentsPairs" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilterPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TElse") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TThen") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.pairs")))) (DoExpr (EApp (EVar "elseFilterPairs") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.tokenize")))) (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "elseFilterToks") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))))
(DTypeSig false "elseFilterToks" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "elseFilterToks" ((PCons (PCon "TNewline") (PCons (PCon "TElse") (PVar "rest")))) (EBinOp "::" (EVar "TElse") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PCons (PCon "TNewline") (PCons (PCon "TThen") (PVar "rest")))) (EBinOp "::" (EVar "TThen") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PList)) (EListLit))
(DTypeSig false "armsHeraldTok" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDo")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDefer")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TFatArrow")) (EVar "True"))
(DFunDef false "armsHeraldTok" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "layoutToks" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "layoutToks" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EVar "closeAllToks") (EVar "stack")))
(DFunDef false "layoutToks" ((PCons (PCon "RTok" (PVar "t") PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EVar "t")) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EVar "flushSepToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutToks" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RNewline" (PVar "col") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RClauseNl" (PVar "col") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RClauseOpen" (PVar "col") PWild (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenToks") (EVar "col")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "clauseOpenToks" ((PVar "col") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "clauseOpenToks" ((PVar "col") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenToks") (EVar "col")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "closeAllToks" ((PVar "stack")) (EBinOp "::" (EVar "TNewline") (EApp (EVar "closeDedentsToks") (EVar "stack"))))
(DTypeSig false "closeDedentsToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "closeDedentsToks" ((PList)) (EListLit (EVar "TEof")))
(DFunDef false "closeDedentsToks" ((PList PWild)) (EListLit (EVar "TEof")))
(DFunDef false "closeDedentsToks" ((PCons PWild (PVar "tl"))) (EBinOp "::" (EVar "TDedent") (EBinOp "::" (EVar "TNewline") (EApp (EVar "closeDedentsToks") (EVar "tl")))))
(DTypeSig false "flushCloseToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "flushCloseToks" ((PVar "t") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseToks" ((PVar "t") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGoToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushCloseGoToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "flushCloseGoToks" ((PVar "t") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGoToks" ((PVar "t") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGoToks") (EVar "t")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "flushSepToks" ((PVar "t") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepToks" ((PVar "t") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGoToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepGoToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "flushSepGoToks" ((PVar "t") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepGoToks" ((PVar "t") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "t")) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGoToks") (EVar "t")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "applyNlToks" ((PVar "col") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False"))))
(DFunDef false "applyNlToks" ((PVar "col") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrameToks") (EVar "col")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrameToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))))
(DFunDef false "applyNlFrameToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopToks") (EVar "col")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrameToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopToks") (EVar "col")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "isTrailingContinuationOp") (EVar "prev")))) (EApp (EApp (EVar "armsHeraldTok") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))))
(DFunDef false "applyNlTopToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EVar "popDedentsToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "wouldIndentToks" ((PVar "col") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "isTrailingContinuationOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "canEndExpr") (EVar "prev")))) (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "resolveContToks" ((PVar "col") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContToks" ((PVar "col") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DTypeSig false "popDedentsToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "popDedentsToks" ((PVar "col") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DFunDef false "popDedentsToks" ((PVar "col") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (EVar "TDedent") (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EVar "popDedentsToks") (EVar "col")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tokenizeWithLines" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithLines" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "lines") (EApp (EApp (EVar "offsetsToLines") (EVar "src")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "pairs")))) (DoExpr (ETuple (EVar "toks") (EVar "lines")))))
(DTypeSig true "tokenizeWithOffsets" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithOffsets" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "offs") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "pairs"))) (DoExpr (ETuple (EVar "toks") (EVar "offs")))))
(DTypeSig true "tokenizeWithOffsetPairs" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "tokenizeWithOffsetPairs" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "layoutWithOffsetPairs") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "t") (PVar "_s") (PVar "_e"))) (EVar "t"))) (EVar "triples"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "t") (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "triples"))) (DoExpr (ETuple (EVar "toks") (EVar "pairs")))))
(DTypeSig true "offsetToLineCol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineCol" ((PVar "s") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig true "offsetsToLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "offsetsToLines" ((PVar "src") (PVar "offs")) (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "offs")) (ELit (LInt 0))) (ELit (LInt 1))))
(DTypeSig false "offsetsToLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PList) (PVar "p") (PVar "line")) (EListLit))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PCons (PVar "off") (PVar "rest")) (PVar "p") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "off")) (EVar "p")) (EVar "line")) (arm (PTuple (PVar "line2") (PVar "p2")) () (EBinOp "::" (EVar "line2") (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "rest")) (EVar "p2")) (EVar "line2"))))))
(DTypeSig false "isLineBreakAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isLineBreakAt" ((PVar "src") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "src")) (ELit (LChar "\n"))))))))
(DTypeSig false "advanceLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "advanceLine" ((PVar "src") (PVar "target") (PVar "p") (PVar "line")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (ETuple (EVar "line") (EVar "p")) (EIf (EApp (EApp (EVar "isLineBreakAt") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Abstract "Comment" () ((variant "Comment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "commentLine" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentLine" ((PCon "Comment" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "commentCol" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentCol" ((PCon "Comment" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "commentText" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "commentText" ((PCon "Comment" PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "posLineColFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posLineColFrom" ((PVar "src") (PVar "target") (PVar "p") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EBinOp "-" (EVar "target") (EVar "lineStart"))) (EIf (EApp (EApp (EVar "isLineBreakAt") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rawToComments" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "rawToComments" ((PVar "src") (PVar "toks")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "rawToCommentsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "rawToCommentsGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons (PCon "RComment" (PVar "startPos") (PVar "endPos")) (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "startPos")) (EVar "p")) (EVar "line")) (EVar "lineStart")) (arm (PTuple (PVar "line2") (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "Comment") (EVar "line2")) (EVar "col")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "startPos")) (EVar "endPos"))) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "startPos")) (EVar "line2")) (EBinOp "-" (EVar "startPos") (EVar "col")))))))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons PWild (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "p")) (EVar "line")) (EVar "lineStart")))
(DTypeSig true "collectComments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "collectComments" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lint.comments")))) (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EVar "rawToComments") (EVar "src")) (EApp (EVar "scanRawUndedentedChars") (EVar "src"))))))
# MARK
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "UnicodeProblem" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DUse true (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "tokenToString" false) (mem "describeToken" false) (mem "isCommaTok" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse true (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false) (mem "scanRawUndedentedChars" false))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "copyCharRange" false))))
(DTypeSig true "isThenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isThenTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isThenTok" (PWild) (EVar "False"))
(DTypeSig true "isElseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isElseTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isElseTok" (PWild) (EVar "False"))
(DTypeSig false "layout" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "layout" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAll") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layout" ((PCons (PCon "RTok" (PVar "t") (PVar "off") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClose") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSep") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layout" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "layout" ((PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpen") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpen" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "clauseOpen" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "clauseOpen" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpen") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNl") (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClose" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClose" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushCloseGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSep" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))
(DFunDef false "flushSep" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSep" ((PVar "t") (PVar "off") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "flushSepGo" ((PVar "t") (PVar "off") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepGo" ((PVar "t") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGo") (EVar "t")) (EVar "off")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "frameHasLive" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyCon "Bool")))
(DFunDef false "frameHasLive" ((PCons (PCon "BracketFrame" (PVar "f") PWild) PWild)) (EBinOp ">" (EVar "f") (ELit (LInt 0))))
(DFunDef false "frameHasLive" ((PList)) (EVar "False"))
(DTypeSig false "bracketOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketOpener" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" ((PCon "TDotLBrace")) (EVar "True"))
(DFunDef false "bracketOpener" (PWild) (EVar "False"))
(DTypeSig false "bracketCloser" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "bracketCloser" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "bracketCloser" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "bracketCloser" (PWild) (EVar "False"))
(DTypeSig false "isOpener" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpener" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isOpener" (PWild) (EVar "False"))
(DData Public "BracketFrame" () ((variant "BracketFrame" (ConPos (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "canEndExpr" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canEndExpr" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TWideInt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TInterpEnd" PWild)) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "canEndExpr" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canEndExpr" (PWild) (EVar "False"))
(DTypeSig false "prevCanEnd" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevCanEnd" ((PCon "Some" (PVar "t"))) (EApp (EVar "canEndExpr") (EVar "t")))
(DFunDef false "prevCanEnd" ((PCon "None")) (EVar "False"))
(DTypeSig false "isTrailingContinuationOp" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMinus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TSlash")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TMod")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TEqEq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TNeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGt")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TGeq")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TAnd")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TOr")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TPipeRight")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TRCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TLCompose")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TBacktickIdent" PWild)) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isTrailingContinuationOp" (PWild) (EVar "False"))
(DTypeSig false "prevIsTrailingOp" (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool")))
(DFunDef false "prevIsTrailingOp" ((PCon "Some" (PVar "t"))) (EApp (EVar "isTrailingContinuationOp") (EVar "t")))
(DFunDef false "prevIsTrailingOp" ((PCon "None")) (EVar "False"))
(DTypeSig false "armsHerald" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDo"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TDefer"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") (PCon "Some" (PCon "TFatArrow"))) (EVar "True"))
(DFunDef false "armsHerald" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "canStartAtom" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "canStartAtom" ((PCon "TInt" PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TWideInt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TFloat" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TChar" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBool" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TUnderscore")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TAt")) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TInterpOpen" PWild)) (EVar "True"))
(DFunDef false "canStartAtom" ((PCon "TBang")) (EVar "True"))
(DFunDef false "canStartAtom" (PWild) (EVar "False"))
(DTypeSig false "applyNl" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNl" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrame") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrame" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrame" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTop") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTop" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTop" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndent") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndent" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "wouldIndent" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveCont") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "+" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "resolveCont" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveCont" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedents" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))))))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedents" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedents") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeAll" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedents" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "closeDedents" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off"))))
(DFunDef false "closeDedents" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off")) (EApp (EApp (EVar "closeDedents") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilter" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TElse") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PTuple (PCon "TNewline") PWild) (PCons (PTuple (PCon "TThen") (PVar "eoff")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "eoff")) (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilter") (EVar "rest"))))
(DFunDef false "elseFilter" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.offsets")))) (DoExpr (EApp (EVar "elseFilter") (EApp (EApp (EApp (EApp (EApp (EVar "layout") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))))
(DTypeSig false "rawStream" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "rawStream" ((PVar "src") (PVar "len")) (EApp (EVar "externClauseBreaks") (EApp (EVar "scanRawChars") (EVar "src"))))
(DTypeSig false "externClauseBreaks" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "externClauseBreaks" ((PVar "toks")) (EIf (EApp (EVar "hasBindLine") (EVar "toks")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "toks")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "False")) (EIf (EVar "otherwise") (EVar "toks") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasBindLine" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "hasBindLine" ((PList)) (EVar "False"))
(DFunDef false "hasBindLine" ((PCons (PCon "RNewline" PWild PWild) (PCons (PCon "RTok" (PCon "TIdent" (PLit (LString "bind"))) PWild PWild) PWild))) (EVar "True"))
(DFunDef false "hasBindLine" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasBindLine") (EVar "rest")))
(DTypeSig false "clauseBreaksGo" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "RawTok")))))))
(DFunDef false "clauseBreaksGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "clauseBreaksGo" ((PCons (PCon "RTok" (PCon "TExtern") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "lineCol") PWild PWild) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "TExtern")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "lineCol")) (EVar "lineCol")) (EVar "False"))))
(DFunDef false "clauseBreaksGo" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) PWild (PVar "externCol") (PVar "opened")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "externCol") (ELit (LInt 0))) (EBinOp ">" (EVar "col") (EVar "externCol"))) (EApp (EVar "startsWithBind") (EVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "clauseBreak") (EVar "col")) (EVar "off")) (EVar "externCol")) (EVar "opened")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EVar "externCol")) (EVar "True"))) (EIf (EBinOp "<=" (EVar "col") (EVar "externCol")) (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "col")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EUnOp "-" (ELit (LInt 1)))) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "RNewline") (EVar "col")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "col")) (EVar "externCol")) (EVar "opened"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "clauseBreaksGo" ((PCons (PVar "t") (PVar "rest")) (PVar "lineCol") (PVar "externCol") (PVar "opened")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EVar "clauseBreaksGo") (EVar "rest")) (EVar "lineCol")) (EVar "externCol")) (EVar "opened"))))
(DTypeSig false "clauseBreak" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "RawTok"))))))
(DFunDef false "clauseBreak" ((PVar "col") (PVar "off") PWild (PCon "True")) (EApp (EApp (EVar "RClauseNl") (EVar "col")) (EVar "off")))
(DFunDef false "clauseBreak" ((PVar "col") (PVar "off") (PVar "externCol") (PCon "False")) (EApp (EApp (EApp (EVar "RClauseOpen") (EVar "col")) (EVar "off")) (EVar "externCol")))
(DTypeSig false "startsWithBind" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "startsWithBind" ((PCons (PCon "RTok" (PCon "TIdent" (PLit (LString "bind"))) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "startsWithBind" (PWild) (EVar "False"))
(DTypeSig false "layoutPairs" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "layoutPairs" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EVar "closeAllPairs") (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutPairs" ((PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EApp (EVar "Some") (EVar "t"))) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairs") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutPairs" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "layoutPairs" ((PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "clauseOpenPairs" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "opener")))
(DFunDef false "clauseOpenPairs" ((PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepPairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushSepPairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepPairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepPairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushSepPairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))))
(DFunDef false "flushSepPairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EApp (EVar "Some") (EVar "t"))) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClosePairs" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EListLit)) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "t") (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EApp (EVar "Some") (EVar "t"))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "s") (EVar "s")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "s") (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "prevIsTrailingOp") (EVar "prev")))) (EApp (EApp (EVar "armsHerald") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "prevIsTrailingOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "prevCanEnd") (EVar "prev")))) (EBinOp "::" (ETuple (EVar "TIndent") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyApp (TyCon "Option") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "TIndent") (EVar "toff") (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "None")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "None")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "None")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "None")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeAllPairs" ((PVar "stack") (PVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "closeDedentsPairs" ((PList) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PList PWild) (PVar "off")) (EListLit (ETuple (EVar "TEof") (EVar "off") (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (ETuple (EVar "TDedent") (EVar "off") (EVar "off")) (EBinOp "::" (ETuple (EVar "TNewline") (EVar "off") (EVar "off")) (EApp (EApp (EVar "closeDedentsPairs") (EVar "tl")) (EVar "off")))))
(DTypeSig false "elseFilterPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TElse") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TElse") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PTuple (PCon "TNewline") PWild PWild) (PCons (PTuple (PCon "TThen") (PVar "es") (PVar "ee")) (PVar "rest")))) (EBinOp "::" (ETuple (EVar "TThen") (EVar "es") (EVar "ee")) (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterPairs") (EVar "rest"))))
(DFunDef false "elseFilterPairs" ((PList)) (EListLit))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.pairs")))) (DoExpr (EApp (EVar "elseFilterPairs") (EApp (EApp (EApp (EApp (EApp (EVar "layoutPairs") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "None")) (EVar "False"))))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.tokenize")))) (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "elseFilterToks") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EApp (EApp (EVar "rawStream") (EVar "src")) (EVar "len"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))))
(DTypeSig false "elseFilterToks" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "elseFilterToks" ((PCons (PCon "TNewline") (PCons (PCon "TElse") (PVar "rest")))) (EBinOp "::" (EVar "TElse") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PCons (PCon "TNewline") (PCons (PCon "TThen") (PVar "rest")))) (EBinOp "::" (EVar "TThen") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "elseFilterToks") (EVar "rest"))))
(DFunDef false "elseFilterToks" ((PList)) (EListLit))
(DTypeSig false "armsHeraldTok" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDo")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDefer")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TFatArrow")) (EVar "True"))
(DFunDef false "armsHeraldTok" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "layoutToks" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "layoutToks" ((PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EVar "closeAllToks") (EVar "stack")))
(DFunDef false "layoutToks" ((PCons (PCon "RTok" (PVar "t") PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EVar "t")) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EVar "flushSepToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutToks" ((PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RNewline" (PVar "col") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RClauseNl" (PVar "col") PWild) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "layoutToks" ((PCons (PCon "RClauseOpen" (PVar "col") PWild (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenToks") (EVar "col")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "clauseOpenToks" ((PVar "col") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "clauseOpenToks" ((PVar "col") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenToks") (EVar "col")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlToks") (EVar "col")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "closeAllToks" ((PVar "stack")) (EBinOp "::" (EVar "TNewline") (EApp (EVar "closeDedentsToks") (EVar "stack"))))
(DTypeSig false "closeDedentsToks" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "closeDedentsToks" ((PList)) (EListLit (EVar "TEof")))
(DFunDef false "closeDedentsToks" ((PList PWild)) (EListLit (EVar "TEof")))
(DFunDef false "closeDedentsToks" ((PCons PWild (PVar "tl"))) (EBinOp "::" (EVar "TDedent") (EBinOp "::" (EVar "TNewline") (EApp (EVar "closeDedentsToks") (EVar "tl")))))
(DTypeSig false "flushCloseToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "flushCloseToks" ((PVar "t") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseToks" ((PVar "t") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGoToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushCloseGoToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "flushCloseGoToks" ((PVar "t") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushCloseGoToks" ((PVar "t") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushCloseGoToks") (EVar "t")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "flushSepToks" ((PVar "t") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepToks" ((PVar "t") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGoToks") (EVar "t")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepGoToks" (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "flushSepGoToks" ((PVar "t") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepGoToks" ((PVar "t") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EVar "t") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "t")) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EBinOp "::" (EVar "TDedent") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepGoToks") (EVar "t")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "applyNlToks" ((PVar "col") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False"))))
(DFunDef false "applyNlToks" ((PVar "col") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFrameToks") (EVar "col")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFrameToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))))
(DFunDef false "applyNlFrameToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopToks") (EVar "col")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFrameToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopToks") (EVar "col")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "isTrailingContinuationOp") (EVar "prev")))) (EApp (EApp (EVar "armsHeraldTok") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token"))))))))))
(DFunDef false "applyNlTopToks" ((PVar "col") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EVar "popDedentsToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "wouldIndentToks" ((PVar "col") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "isTrailingContinuationOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "canEndExpr") (EVar "prev")))) (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContToks") (EVar "col")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "resolveContToks" ((PVar "col") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "TIndent") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContToks" ((PVar "col") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DTypeSig false "popDedentsToks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "popDedentsToks" ((PVar "col") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DFunDef false "popDedentsToks" ((PVar "col") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (EVar "TDedent") (EBinOp "::" (EVar "TNewline") (EApp (EApp (EApp (EApp (EVar "popDedentsToks") (EVar "col")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "layoutToks") (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tokenizeWithLines" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithLines" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "lines") (EApp (EApp (EVar "offsetsToLines") (EVar "src")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "pairs")))) (DoExpr (ETuple (EVar "toks") (EVar "lines")))))
(DTypeSig true "tokenizeWithOffsets" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "tokenizeWithOffsets" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "layoutWithOffsets") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (DoLet false false (PVar "offs") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "pairs"))) (DoExpr (ETuple (EVar "toks") (EVar "offs")))))
(DTypeSig true "tokenizeWithOffsetPairs" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "tokenizeWithOffsetPairs" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "layoutWithOffsetPairs") (EVar "src")) (EVar "len"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "t") (PVar "_s") (PVar "_e"))) (EVar "t"))) (EVar "triples"))) (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "t") (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "triples"))) (DoExpr (ETuple (EVar "toks") (EVar "pairs")))))
(DTypeSig true "offsetToLineCol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineCol" ((PVar "s") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig true "offsetsToLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "offsetsToLines" ((PVar "src") (PVar "offs")) (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "offs")) (ELit (LInt 0))) (ELit (LInt 1))))
(DTypeSig false "offsetsToLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PList) (PVar "p") (PVar "line")) (EListLit))
(DFunDef false "offsetsToLinesGo" ((PVar "src") (PCons (PVar "off") (PVar "rest")) (PVar "p") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "off")) (EVar "p")) (EVar "line")) (arm (PTuple (PVar "line2") (PVar "p2")) () (EBinOp "::" (EVar "line2") (EApp (EApp (EApp (EApp (EVar "offsetsToLinesGo") (EVar "src")) (EVar "rest")) (EVar "p2")) (EVar "line2"))))))
(DTypeSig false "isLineBreakAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isLineBreakAt" ((PVar "src") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "src")) (ELit (LChar "\n"))))))))
(DTypeSig false "advanceLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "advanceLine" ((PVar "src") (PVar "target") (PVar "p") (PVar "line")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "src"))) (ETuple (EVar "line") (EVar "p")) (EIf (EApp (EApp (EVar "isLineBreakAt") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "advanceLine") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DData Abstract "Comment" () ((variant "Comment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "commentLine" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentLine" ((PCon "Comment" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "commentCol" (TyFun (TyCon "Comment") (TyCon "Int")))
(DFunDef false "commentCol" ((PCon "Comment" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "commentText" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "commentText" ((PCon "Comment" PWild PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "posLineColFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posLineColFrom" ((PVar "src") (PVar "target") (PVar "p") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "p") (EVar "target")) (ETuple (EVar "line") (EBinOp "-" (EVar "target") (EVar "lineStart"))) (EIf (EApp (EApp (EVar "isLineBreakAt") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "target")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rawToComments" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "rawToComments" ((PVar "src") (PVar "toks")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0))))
(DTypeSig false "rawToCommentsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "rawToCommentsGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons (PCon "RComment" (PVar "startPos") (PVar "endPos")) (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "posLineColFrom") (EVar "src")) (EVar "startPos")) (EVar "p")) (EVar "line")) (EVar "lineStart")) (arm (PTuple (PVar "line2") (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "Comment") (EVar "line2")) (EVar "col")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "startPos")) (EVar "endPos"))) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "startPos")) (EVar "line2")) (EBinOp "-" (EVar "startPos") (EVar "col")))))))
(DFunDef false "rawToCommentsGo" ((PVar "src") (PCons PWild (PVar "rest")) (PVar "p") (PVar "line") (PVar "lineStart")) (EApp (EApp (EApp (EApp (EApp (EVar "rawToCommentsGo") (EVar "src")) (EVar "rest")) (EVar "p")) (EVar "line")) (EVar "lineStart")))
(DTypeSig true "collectComments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))
(DFunDef false "collectComments" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lint.comments")))) (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EApp (EVar "rawToComments") (EVar "src")) (EApp (EVar "scanRawUndedentedChars") (EVar "src"))))))
