# META
source_lines=502
stages=DESUGAR,MARK
# SOURCE
-- Indentation-sensitive layout over raw tokens.

import frontend.lex_token.{
  Token(..), RawTok(..), isCommaTok, isThenTok, isElseTok
}

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

bumpFrame : List BracketFrame -> List BracketFrame
bumpFrame [] = []
bumpFrame ((BracketFrame f s) :: fs) = BracketFrame (f + 1) s :: fs

-- Decrement the innermost bracket frame's open-context count (no-op at top level).
dropFrame : List BracketFrame -> List BracketFrame
dropFrame [] = []
dropFrame ((BracketFrame f s) :: fs) = BracketFrame (f - 1) s :: fs

armsHeraldTok : Bool -> Token -> Bool
armsHeraldTok _ TDo = True
armsHeraldTok _ TDefer = True
armsHeraldTok _ TFatArrow = True
armsHeraldTok opener _ = opener

layoutWith : (Token -> Int -> Int -> a) ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
layoutWith project [] stack frames prev opener = closeAllPairs project stack 0
layoutWith project ((RTok t s e) :: rest) stack frames prev opener
  | bracketOpener t =
    project t s e
      :: layoutWith
        project
        rest
        stack
        (BracketFrame 0 (opener || isOpener t) :: frames)
        t
        False
  | bracketCloser t = flushClosePairs project t s e rest stack frames opener
  | isCommaTok t && frameHasLive frames =
    flushSepPairs project t s e rest stack frames opener
  | otherwise =
    project t s e
      :: layoutWith project rest stack frames t (opener || isOpener t)
layoutWith project ((RComment _ _) :: rest) stack frames prev opener =
  layoutWith project rest stack frames prev opener
layoutWith project ((RNewline col off) :: rest) stack frames prev opener =
  applyNlPairs project col off rest stack frames prev opener
layoutWith project ((RClauseNl col off) :: rest) stack frames _ opener =
  applyNlPairs project col off rest stack frames TNewline opener
layoutWith project ((RClauseOpen col off base) :: rest) stack frames _ opener =
  clauseOpenPairs project col off base rest stack frames opener

clauseOpenPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List a
clauseOpenPairs project col off base rest [] frames opener =
  applyNlPairs project col off rest [] frames TNewline opener
clauseOpenPairs project col off base rest (top :: tl) frames opener
  | top > base =
    project TNewline off off
      :: project TDedent off off
      :: clauseOpenPairs project col off base rest tl (dropFrame frames) opener
  | otherwise =
    applyNlPairs project col off rest (top :: tl) frames TNewline opener

flushSepPairs : (Token -> Int -> Int -> a) ->
  Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List a
flushSepPairs project t s e rest stack [] opener =
  project t s e :: layoutWith project rest stack [] t opener
flushSepPairs project t s e rest stack ((BracketFrame f saved) :: fs) opener =
  flushSepPairsGo project t s e rest stack f (BracketFrame 0 saved :: fs) opener

flushSepPairsGo : (Token -> Int -> Int -> a) ->
  Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List a
flushSepPairsGo project t s e rest [] _ frames opener =
  project t s e :: layoutWith project rest [] frames t opener
flushSepPairsGo project t s e rest (top :: tl) f frames opener
  | f <= 0 =
    project t s e :: layoutWith project rest (top :: tl) frames t opener
  | otherwise =
    project TNewline s s
      :: project TDedent s s
      :: flushSepPairsGo project t s e rest tl (f - 1) frames opener

flushClosePairs : (Token -> Int -> Int -> a) ->
  Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Bool ->
  List a
flushClosePairs project t s e rest stack [] opener =
  project t s e :: layoutWith project rest stack [] t (opener || isOpener t)
flushClosePairs project t s e rest stack ((BracketFrame f saved) :: fs) _ =
  flushClosePairsGo project t s e rest stack f fs saved

flushClosePairsGo : (Token -> Int -> Int -> a) ->
  Token ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  Int ->
  List BracketFrame ->
  Bool ->
  List a
flushClosePairsGo project t s e rest [] f fs opener =
  project t s e :: layoutWith project rest [] fs t (opener || isOpener t)
flushClosePairsGo project t s e rest (top :: tl) f fs opener
  | f <= 0 =
    project t s e
      :: layoutWith project rest (top :: tl) fs t (opener || isOpener t)
  | otherwise =
    project TNewline s s
      :: project TDedent s s
      :: flushClosePairsGo project t s e rest tl (f - 1) fs opener

applyNlPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  List RawTok ->
  List Int ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
applyNlPairs project col off rest [] frames prev opener =
  project TNewline off off :: layoutWith project rest [] frames TNewline False
applyNlPairs project col off rest (top :: tl) frames prev opener =
  applyNlFramePairs project col off top (top :: tl) rest frames prev opener

applyNlFramePairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
applyNlFramePairs project col off top stack rest [] prev opener =
  applyNlTopPairs project col off top stack rest [] prev opener
applyNlFramePairs project col off top stack rest ((BracketFrame f saved) :: fs) prev opener
  | f > 0 =
    applyNlTopPairs
      project
      col
      off
      top
      stack
      rest
      (BracketFrame f saved :: fs)
      prev
      opener
  | col > top
    && not (isTrailingContinuationOp prev)
    && armsHeraldTok opener prev =
    project TIndent off off
      :: layoutWith
        project
        rest
        (col :: stack)
        (BracketFrame 1 saved :: fs)
        TNewline
        False
  | otherwise =
    layoutWith project rest stack (BracketFrame f saved :: fs) prev opener

applyNlTopPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
applyNlTopPairs project col off top stack rest frames prev opener
  | col > top = wouldIndentPairs project col off stack rest frames prev opener
  | col == top =
    project TNewline off off
      :: layoutWith project rest stack frames TNewline False
  | otherwise =
    project TNewline off off
      :: popDedentsPairs project col off stack rest frames

wouldIndentPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
wouldIndentPairs project col off stack rest frames prev opener
  | isTrailingContinuationOp prev =
    layoutWith project rest stack frames prev opener
  | opener || not (canEndExpr prev) =
    project TIndent off off
      :: layoutWith
        project
        rest
        (col :: stack)
        (bumpFrame frames)
        TNewline
        False
  | otherwise = resolveContPairs project col off stack rest frames prev opener

-- #1751: mirrors `resolveCont`'s fallback-INDENT location fix — `toff`/`tend`
-- (the deeper line's own first token span), not `off` (the prior line's
-- RNewline offset). Must stay in step with `resolveCont` (WS-2, above).
resolveContPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  Token ->
  Bool ->
  List a
resolveContPairs project col off stack ((RTok t toff tend) :: more) frames prev opener
  | canStartAtom t =
    layoutWith project (RTok t toff tend :: more) stack frames prev opener
  | isThenTok t =
    layoutWith project (RTok t toff tend :: more) stack frames prev opener
  | isElseTok t =
    layoutWith project (RTok t toff tend :: more) stack frames prev opener
  | otherwise =
    project TIndent toff toff
      :: layoutWith
        project
        (RTok t toff tend :: more)
        (col :: stack)
        (bumpFrame frames)
        TNewline
        False
resolveContPairs project col off stack rest frames prev opener =
  layoutWith project rest stack frames TNewline False

popDedentsPairs : (Token -> Int -> Int -> a) ->
  Int ->
  Int ->
  List Int ->
  List RawTok ->
  List BracketFrame ->
  List a
popDedentsPairs project col off [] rest frames =
  layoutWith project rest [] frames TNewline False
popDedentsPairs project col off (top :: tl) rest frames
  | top > col =
    project TDedent off off
      :: project TNewline off off
      :: popDedentsPairs project col off tl rest (dropFrame frames)
  | otherwise = layoutWith project rest (top :: tl) frames TNewline False

closeAllPairs : (Token -> Int -> Int -> a) -> List Int -> Int -> List a
closeAllPairs project stack off =
  project TNewline off off :: closeDedentsPairs project stack off

closeDedentsPairs : (Token -> Int -> Int -> a) -> List Int -> Int -> List a
closeDedentsPairs project [] off = [project TEof off off]
closeDedentsPairs project [_] off = [project TEof off off]
closeDedentsPairs project (_ :: tl) off =
  project TDedent off off
    :: project TNewline off off
    :: closeDedentsPairs project tl off

filterWith : (a -> Token) -> List a -> List a
filterWith tokenOf (x :: rest) = match tokenOf x
  TNewline => filterAfterNl tokenOf x rest
  _ => x :: filterWith tokenOf rest
filterWith _ [] = []
filterAfterNl : (a -> Token) -> a -> List a -> List a
-- Preserve the existing tail to avoid allocating a replacement list node.
-- lint-disable-next-line rule-match-on-param
filterAfterNl tokenOf x rest = match rest
  [] => [x]
  y :: tail => match tokenOf y
    TElse => y :: filterWith tokenOf tail
    TThen => y :: filterWith tokenOf tail
    _ => x :: filterWith tokenOf rest

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

export
applyLayoutTokens : List RawTok -> List Token
applyLayoutTokens raw =
  filterWith
    (t => t)
    (layoutWith (t _ _ => t) (externClauseBreaks raw) [0] [] TNewline False)

export
applyLayoutStarts : List RawTok -> List (Token, Int)
applyLayoutStarts raw =
  filterWith
    ((t, _) => t)
    (layoutWith
      (t s _ => (t, s))
      (externClauseBreaks raw)
      [0]
      []
      TNewline
      False)

export
applyLayoutRanges : List RawTok -> List (Token, Int, Int)
applyLayoutRanges raw =
  filterWith
    ((t, _, _) => t)
    (layoutWith
      (t s e => (t, s, e))
      (externClauseBreaks raw)
      [0]
      []
      TNewline
      False)
# DESUGAR
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true) (mem "isCommaTok" false) (mem "isThenTok" false) (mem "isElseTok" false))))
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
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "+" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "armsHeraldTok" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDo")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDefer")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TFatArrow")) (EVar "True"))
(DFunDef false "armsHeraldTok" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "layoutWith" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "layoutWith" ((PVar "project") (PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EVar "closeAllPairs") (EVar "project")) (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EVar "t")) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairs") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "clauseOpenPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "clauseOpenPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "flushSepPairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepPairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepPairsGo" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "flushSepPairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepPairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "t")) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "s")) (EVar "s")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "s")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClosePairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "flushClosePairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "s")) (EVar "s")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "s")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "applyNlPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "isTrailingContinuationOp") (EVar "prev")))) (EApp (EApp (EVar "armsHeraldTok") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "isTrailingContinuationOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "canEndExpr") (EVar "prev")))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "resolveContPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "toff")) (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "popDedentsPairs" ((PVar "project") (PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "project") (PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "closeAllPairs" ((PVar "project") (PVar "stack") (PVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EVar "closeDedentsPairs") (EVar "project")) (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PList) (PVar "off")) (EListLit (EApp (EApp (EApp (EVar "project") (EVar "TEof")) (EVar "off")) (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PList PWild) (PVar "off")) (EListLit (EApp (EApp (EApp (EVar "project") (EVar "TEof")) (EVar "off")) (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EVar "closeDedentsPairs") (EVar "project")) (EVar "tl")) (EVar "off")))))
(DTypeSig false "filterWith" (TyFun (TyFun (TyVar "a") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterWith" ((PVar "tokenOf") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "tokenOf") (EVar "x")) (arm (PCon "TNewline") () (EApp (EApp (EApp (EVar "filterAfterNl") (EVar "tokenOf")) (EVar "x")) (EVar "rest"))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "rest"))))))
(DFunDef false "filterWith" (PWild (PList)) (EListLit))
(DTypeSig false "filterAfterNl" (TyFun (TyFun (TyVar "a") (TyCon "Token")) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "filterAfterNl" ((PVar "tokenOf") (PVar "x") (PVar "rest")) (EMatch (EVar "rest") (arm (PList) () (EListLit (EVar "x"))) (arm (PCons (PVar "y") (PVar "tail")) () (EMatch (EApp (EVar "tokenOf") (EVar "y")) (arm (PCon "TElse") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "tail")))) (arm (PCon "TThen") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "tail")))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "rest"))))))))
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
(DTypeSig true "applyLayoutTokens" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "applyLayoutTokens" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PVar "t")) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") PWild PWild) (EVar "t"))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
(DTypeSig true "applyLayoutStarts" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "applyLayoutStarts" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PTuple (PVar "t") PWild)) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") (PVar "s") PWild) (ETuple (EVar "t") (EVar "s")))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
(DTypeSig true "applyLayoutRanges" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "applyLayoutRanges" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PTuple (PVar "t") PWild PWild)) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") (PVar "s") (PVar "e")) (ETuple (EVar "t") (EVar "s") (EVar "e")))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
# MARK
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true) (mem "isCommaTok" false) (mem "isThenTok" false) (mem "isElseTok" false))))
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
(DTypeSig false "bumpFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "bumpFrame" ((PList)) (EListLit))
(DFunDef false "bumpFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "+" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "dropFrame" (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyCon "BracketFrame"))))
(DFunDef false "dropFrame" ((PList)) (EListLit))
(DFunDef false "dropFrame" ((PCons (PCon "BracketFrame" (PVar "f") (PVar "s")) (PVar "fs"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "s")) (EVar "fs")))
(DTypeSig false "armsHeraldTok" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDo")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TDefer")) (EVar "True"))
(DFunDef false "armsHeraldTok" (PWild (PCon "TFatArrow")) (EVar "True"))
(DFunDef false "armsHeraldTok" ((PVar "opener") PWild) (EVar "opener"))
(DTypeSig false "layoutWith" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "layoutWith" ((PVar "project") (PList) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EVar "closeAllPairs") (EVar "project")) (EVar "stack")) (ELit (LInt 0))))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RTok" (PVar "t") (PVar "s") (PVar "e")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "bracketOpener") (EVar "t")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t")))) (EVar "frames"))) (EVar "t")) (EVar "False"))) (EIf (EApp (EVar "bracketCloser") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairs") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EBinOp "&&" (EApp (EVar "isCommaTok") (EVar "t")) (EApp (EVar "frameHasLive") (EVar "frames"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairs") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RComment" PWild PWild) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RNewline" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RClauseNl" (PVar "col") (PVar "off")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "layoutWith" ((PVar "project") (PCons (PCon "RClauseOpen" (PVar "col") (PVar "off") (PVar "base")) (PVar "rest")) (PVar "stack") (PVar "frames") PWild (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "opener")))
(DTypeSig false "clauseOpenPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "clauseOpenPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PList) (PVar "frames") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "opener")))
(DFunDef false "clauseOpenPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "base") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "opener")) (EIf (EBinOp ">" (EVar "top") (EVar "base")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clauseOpenPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "base")) (EVar "rest")) (EVar "tl")) (EApp (EVar "dropFrame") (EVar "frames"))) (EVar "opener")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushSepPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "flushSepPairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepPairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 0))) (EVar "saved")) (EVar "fs"))) (EVar "opener")))
(DTypeSig false "flushSepPairsGo" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "flushSepPairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) PWild (PVar "frames") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "t")) (EVar "opener"))))
(DFunDef false "flushSepPairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "frames") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "t")) (EVar "opener"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "s")) (EVar "s")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "s")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushSepPairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "frames")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "flushClosePairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "flushClosePairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PList) (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EListLit)) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairs" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PVar "stack") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "stack")) (EVar "f")) (EVar "fs")) (EVar "saved")))
(DTypeSig false "flushClosePairsGo" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "flushClosePairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PList) (PVar "f") (PVar "fs") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))))
(DFunDef false "flushClosePairsGo" ((PVar "project") (PVar "t") (PVar "s") (PVar "e") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "f") (PVar "fs") (PVar "opener")) (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "t")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "fs")) (EVar "t")) (EBinOp "||" (EVar "opener") (EApp (EVar "isOpener") (EVar "t"))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "s")) (EVar "s")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "s")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "flushClosePairsGo") (EVar "project")) (EVar "t")) (EVar "s")) (EVar "e")) (EVar "rest")) (EVar "tl")) (EBinOp "-" (EVar "f") (ELit (LInt 1)))) (EVar "fs")) (EVar "opener")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyNlPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "applyNlPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "rest") (PList) (PVar "frames") (PVar "prev") (PVar "opener")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False"))))
(DFunDef false "applyNlPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "rest") (PCons (PVar "top") (PVar "tl")) (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlFramePairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")))
(DTypeSig false "applyNlFramePairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "applyNlFramePairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PList) (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EListLit)) (EVar "prev")) (EVar "opener")))
(DFunDef false "applyNlFramePairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PCons (PCon "BracketFrame" (PVar "f") (PVar "saved")) (PVar "fs")) (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "f") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyNlTopPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "top")) (EVar "stack")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EVar "not") (EApp (EVar "isTrailingContinuationOp") (EVar "prev")))) (EApp (EApp (EVar "armsHeraldTok") (EVar "opener")) (EVar "prev"))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (ELit (LInt 1))) (EVar "saved")) (EVar "fs"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EBinOp "::" (EApp (EApp (EVar "BracketFrame") (EVar "f")) (EVar "saved")) (EVar "fs"))) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyNlTopPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "applyNlTopPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "top") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EBinOp ">" (EVar "col") (EVar "top")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wouldIndentPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "==" (EVar "col") (EVar "top")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wouldIndentPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "wouldIndentPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "isTrailingContinuationOp") (EVar "prev")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EBinOp "||" (EVar "opener") (EApp (EVar "not") (EApp (EVar "canEndExpr") (EVar "prev")))) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveContPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "stack")) (EVar "rest")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resolveContPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyVar "a")))))))))))
(DFunDef false "resolveContPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PCons (PCon "RTok" (PVar "t") (PVar "toff") (PVar "tend")) (PVar "more")) (PVar "frames") (PVar "prev") (PVar "opener")) (EIf (EApp (EVar "canStartAtom") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isThenTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EApp (EVar "isElseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EVar "stack")) (EVar "frames")) (EVar "prev")) (EVar "opener")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TIndent")) (EVar "toff")) (EVar "toff")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EVar "t")) (EVar "toff")) (EVar "tend")) (EVar "more"))) (EBinOp "::" (EVar "col") (EVar "stack"))) (EApp (EVar "bumpFrame") (EVar "frames"))) (EVar "TNewline")) (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "resolveContPairs" ((PVar "project") (PVar "col") (PVar "off") (PVar "stack") (PVar "rest") (PVar "frames") (PVar "prev") (PVar "opener")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EVar "stack")) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DTypeSig false "popDedentsPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "BracketFrame")) (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "popDedentsPairs" ((PVar "project") (PVar "col") (PVar "off") (PList) (PVar "rest") (PVar "frames")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EListLit)) (EVar "frames")) (EVar "TNewline")) (EVar "False")))
(DFunDef false "popDedentsPairs" ((PVar "project") (PVar "col") (PVar "off") (PCons (PVar "top") (PVar "tl")) (PVar "rest") (PVar "frames")) (EIf (EBinOp ">" (EVar "top") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "popDedentsPairs") (EVar "project")) (EVar "col")) (EVar "off")) (EVar "tl")) (EVar "rest")) (EApp (EVar "dropFrame") (EVar "frames"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (EVar "project")) (EVar "rest")) (EBinOp "::" (EVar "top") (EVar "tl"))) (EVar "frames")) (EVar "TNewline")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeAllPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "closeAllPairs" ((PVar "project") (PVar "stack") (PVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EVar "closeDedentsPairs") (EVar "project")) (EVar "stack")) (EVar "off"))))
(DTypeSig false "closeDedentsPairs" (TyFun (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PList) (PVar "off")) (EListLit (EApp (EApp (EApp (EVar "project") (EVar "TEof")) (EVar "off")) (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PList PWild) (PVar "off")) (EListLit (EApp (EApp (EApp (EVar "project") (EVar "TEof")) (EVar "off")) (EVar "off"))))
(DFunDef false "closeDedentsPairs" ((PVar "project") (PCons PWild (PVar "tl")) (PVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TDedent")) (EVar "off")) (EVar "off")) (EBinOp "::" (EApp (EApp (EApp (EVar "project") (EVar "TNewline")) (EVar "off")) (EVar "off")) (EApp (EApp (EApp (EVar "closeDedentsPairs") (EVar "project")) (EVar "tl")) (EVar "off")))))
(DTypeSig false "filterWith" (TyFun (TyFun (TyVar "a") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterWith" ((PVar "tokenOf") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "tokenOf") (EVar "x")) (arm (PCon "TNewline") () (EApp (EApp (EApp (EVar "filterAfterNl") (EVar "tokenOf")) (EVar "x")) (EVar "rest"))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "rest"))))))
(DFunDef false "filterWith" (PWild (PList)) (EListLit))
(DTypeSig false "filterAfterNl" (TyFun (TyFun (TyVar "a") (TyCon "Token")) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "filterAfterNl" ((PVar "tokenOf") (PVar "x") (PVar "rest")) (EMatch (EVar "rest") (arm (PList) () (EListLit (EVar "x"))) (arm (PCons (PVar "y") (PVar "tail")) () (EMatch (EApp (EVar "tokenOf") (EVar "y")) (arm (PCon "TElse") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "tail")))) (arm (PCon "TThen") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "tail")))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterWith") (EVar "tokenOf")) (EVar "rest"))))))))
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
(DTypeSig true "applyLayoutTokens" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "applyLayoutTokens" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PVar "t")) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") PWild PWild) (EVar "t"))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
(DTypeSig true "applyLayoutStarts" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int")))))
(DFunDef false "applyLayoutStarts" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PTuple (PVar "t") PWild)) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") (PVar "s") PWild) (ETuple (EVar "t") (EVar "s")))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
(DTypeSig true "applyLayoutRanges" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "applyLayoutRanges" ((PVar "raw")) (EApp (EApp (EVar "filterWith") (ELam ((PTuple (PVar "t") PWild PWild)) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "layoutWith") (ELam ((PVar "t") (PVar "s") (PVar "e")) (ETuple (EVar "t") (EVar "s") (EVar "e")))) (EApp (EVar "externClauseBreaks") (EVar "raw"))) (EListLit (ELit (LInt 0)))) (EListLit)) (EVar "TNewline")) (EVar "False"))))
