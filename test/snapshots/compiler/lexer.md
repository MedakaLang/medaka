# META
source_lines=180
stages=DESUGAR,MARK
# SOURCE
-- Tokenize Medaka source and apply indentation-sensitive layout.
-- Handles literals, interpolation, comments, operators, and layout continuations.
-- Nested interpolation inside an interpolated expression is not supported.

import support.stage_count.{stageBump}
export import frontend.lex_token.{
  Token(..), tokenToString, describeToken, isCommaTok, isThenTok, isElseTok
}
import frontend.lex_token.{RawTok(..)}
export import support.source_index.{lineStartsOf, offsetToLineColFast}

import frontend.lex_scan.{scanRawChars, scanRawUndedentedChars}
import frontend.lex_literal.{copyCharRange}

export import frontend.lex_layout.{BracketFrame(..)}
import frontend.lex_layout.{
  applyLayoutTokens, applyLayoutStarts, applyLayoutRanges
}

layoutWithOffsets : Array Char -> Int -> List (Token, Int)
layoutWithOffsets src len =
  let _ = stageBump "lex.offsets"
  applyLayoutStarts (scanRawChars src)

layoutWithOffsetPairs : Array Char -> Int -> List (Token, Int, Int)
layoutWithOffsetPairs src len =
  let _ = stageBump "lex.pairs"
  applyLayoutRanges (scanRawChars src)

export
tokenize : String -> List Token
tokenize s =
  let _ = stageBump "lex.tokenize"
  applyLayoutTokens (scanRawChars (stringToChars s))

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
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse true (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "tokenToString" false) (mem "describeToken" false) (mem "isCommaTok" false) (mem "isThenTok" false) (mem "isElseTok" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse true (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false) (mem "scanRawUndedentedChars" false))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "copyCharRange" false))))
(DUse true (UseGroup ("frontend" "lex_layout") ((mem "BracketFrame" true))))
(DUse false (UseGroup ("frontend" "lex_layout") ((mem "applyLayoutTokens" false) (mem "applyLayoutStarts" false) (mem "applyLayoutRanges" false))))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.offsets")))) (DoExpr (EApp (EVar "applyLayoutStarts") (EApp (EVar "scanRawChars") (EVar "src"))))))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.pairs")))) (DoExpr (EApp (EVar "applyLayoutRanges") (EApp (EVar "scanRawChars") (EVar "src"))))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.tokenize")))) (DoExpr (EApp (EVar "applyLayoutTokens") (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "s")))))))
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
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse true (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "tokenToString" false) (mem "describeToken" false) (mem "isCommaTok" false) (mem "isThenTok" false) (mem "isElseTok" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true))))
(DUse true (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false) (mem "scanRawUndedentedChars" false))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "copyCharRange" false))))
(DUse true (UseGroup ("frontend" "lex_layout") ((mem "BracketFrame" true))))
(DUse false (UseGroup ("frontend" "lex_layout") ((mem "applyLayoutTokens" false) (mem "applyLayoutStarts" false) (mem "applyLayoutRanges" false))))
(DTypeSig false "layoutWithOffsets" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsets" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.offsets")))) (DoExpr (EApp (EVar "applyLayoutStarts") (EApp (EVar "scanRawChars") (EVar "src"))))))
(DTypeSig false "layoutWithOffsetPairs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Token") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "layoutWithOffsetPairs" ((PVar "src") (PVar "len")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.pairs")))) (DoExpr (EApp (EVar "applyLayoutRanges") (EApp (EVar "scanRawChars") (EVar "src"))))))
(DTypeSig true "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Token"))))
(DFunDef false "tokenize" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "lex.tokenize")))) (DoExpr (EApp (EVar "applyLayoutTokens") (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "s")))))))
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
