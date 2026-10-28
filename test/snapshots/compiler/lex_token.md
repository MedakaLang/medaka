# META
source_lines=496
stages=SOURCE,DESUGAR,MARK
# SOURCE
import frontend.parse_diagnostic.{ParseDiagnosticKind(..), renderParseProblem}
import support.util.{u64HalvesHex}

public export data Token =
  -- TInt carries the parsed value AND the original source lexeme (#458): the raw
  -- span text ("0xD800", "1_000", "0b1010") so the parser can hand the printer a
  -- radix-faithful `ENumLit`.  `tokenToString`/token-dump goldens render only the
  -- value, so the lexer diff goldens are unaffected.
  | TInt Int String
  -- An integer literal above 2^62, up to 2^64 - 1: the value's high and low 32-bit
  -- halves and the source lexeme.  `Int` cannot hold it, so only a `U64` can
  -- accept it; the parser builds an `EWideLit` and the typechecker decides.
  | TWideInt Int Int String
  | TFloat Float
  | TString String
  | TChar String
  | TBool Bool
  | TInterpOpen String
  | TInterpMid String
  | TInterpEnd String
  | TIdent String
  | TUpper String
  | TBacktickIdent String
  | TLet
  | TRec
  | TWith
  | TMut
  | TIn
  | TIf
  | TThen
  | TElse
  | TMatch
  | TData
  | TInterface
  | TDefault
  | TImpl
  | TImport
  | TExport
  | TPublic
  | TWhere
  | TOf
  | TRequires
  | TDo
  | TDefer
  | TAs
  | TExtern
  | TDeriving
  | TType
  | TNewtype
  | TProp
  | TTest
  | TBench
  | TEffect
  | TFunction
  | TPlus
  | TMinus
  | TMinusTight
  | TStar
  | TSlash
  | TMod
  | TEqEq
  | TNeq
  | TBangEq
  | TLt
  | TGt
  | TLeq
  | TGeq
  | TAnd
  | TOr
  | TCons
  | TPlusPlus
  | TPipeRight
  | TRCompose
  | TLCompose
  | TFatArrow
  | TArrow
  | TLArrow
  | TAt
  | TBang
  | TAsAt
  | TEqual
  | TColon
  | TColonEq
  | TComma
  | TDot
  | TPipe
  | TUnderscore
  | TLParen
  | TRParen
  | TLBracket
  | TLBracketTight
  | TRBracket
  | TLBrace
  | TRBrace
  | TLArray
  | TRArray
  | TDotLBrace
  | TDotStar
  | TEllipsis
  | TDotDot
  | TDotDotEq
  | TNewline
  | TIndent
  | TDedent
  | TEof
  | TLexError ParseDiagnosticKind
  deriving (Eq)

-- String-bearing tokens use
-- `debugStringLit` (the `%S`-style quoted/escaped form); ints use `intToString`.
export
tokenToString : Token -> String
tokenToString (TInt n _) = "INT " ++ intToString n
tokenToString (TWideInt hi lo _) = "INT 0x" ++ u64HalvesHex hi lo
tokenToString (TFloat f) = "FLOAT " ++ floatToString f
tokenToString (TString s) = "STRING " ++ debugStringLit s
tokenToString (TChar s) = "CHAR " ++ debugStringLit s
tokenToString (TBool True) = "BOOL true"
tokenToString (TBool False) = "BOOL false"
tokenToString (TInterpOpen s) = "INTERP_OPEN " ++ debugStringLit s
tokenToString (TInterpMid s) = "INTERP_MID " ++ debugStringLit s
tokenToString (TInterpEnd s) = "INTERP_END " ++ debugStringLit s
tokenToString (TIdent s) = "IDENT " ++ debugStringLit s
tokenToString (TUpper s) = "UPPER " ++ debugStringLit s
tokenToString (TBacktickIdent s) = "BACKTICK_IDENT " ++ debugStringLit s
tokenToString TLet = "LET"
tokenToString TRec = "REC"
tokenToString TWith = "WITH"
tokenToString TMut = "MUT"
tokenToString TIn = "IN"
tokenToString TIf = "IF"
tokenToString TThen = "THEN"
tokenToString TElse = "ELSE"
tokenToString TMatch = "MATCH"
tokenToString TData = "DATA"
tokenToString TInterface = "INTERFACE"
tokenToString TDefault = "DEFAULT"
tokenToString TImpl = "IMPL"
tokenToString TImport = "IMPORT"
tokenToString TExport = "EXPORT"
tokenToString TPublic = "PUBLIC"
tokenToString TWhere = "WHERE"
tokenToString TOf = "OF"
tokenToString TRequires = "REQUIRES"
tokenToString TDo = "DO"
tokenToString TDefer = "DEFER"
tokenToString TAs = "AS"
tokenToString TExtern = "EXTERN"
tokenToString TDeriving = "DERIVING"
tokenToString TType = "TYPE"
tokenToString TNewtype = "NEWTYPE"
tokenToString TProp = "PROP"
tokenToString TTest = "TEST"
tokenToString TBench = "BENCH"
tokenToString TEffect = "EFFECT"
tokenToString TFunction = "FUNCTION"
tokenToString TPlus = "PLUS"
tokenToString TMinus = "MINUS"
tokenToString TMinusTight = "MINUS_TIGHT"
tokenToString TStar = "STAR"
tokenToString TSlash = "SLASH"
tokenToString TMod = "MOD"
tokenToString TEqEq = "EQ_EQ"
tokenToString TNeq = "NEQ"
tokenToString TBangEq = "BANGEQ"
tokenToString TLt = "LT"
tokenToString TGt = "GT"
tokenToString TLeq = "LEQ"
tokenToString TGeq = "GEQ"
tokenToString TAnd = "AND"
tokenToString TOr = "OR"
tokenToString TCons = "CONS"
tokenToString TPlusPlus = "PLUSPLUS"
tokenToString TPipeRight = "PIPE_RIGHT"
tokenToString TRCompose = "RCOMPOSE"
tokenToString TLCompose = "LCOMPOSE"
tokenToString TFatArrow = "FAT_ARROW"
tokenToString TArrow = "ARROW"
tokenToString TLArrow = "LARROW"
tokenToString TAt = "AT"
tokenToString TBang = "BANG"
tokenToString TAsAt = "AS_AT"
tokenToString TEqual = "EQUAL"
tokenToString TColon = "COLON"
tokenToString TColonEq = "COLONEQ"
tokenToString TComma = "COMMA"
tokenToString TDot = "DOT"
tokenToString TPipe = "PIPE"
tokenToString TUnderscore = "UNDERSCORE"
tokenToString TLParen = "LPAREN"
tokenToString TRParen = "RPAREN"
tokenToString TLBracket = "LBRACKET"
tokenToString TLBracketTight = "LBRACKET_TIGHT"
tokenToString TRBracket = "RBRACKET"
tokenToString TLBrace = "LBRACE"
tokenToString TRBrace = "RBRACE"
tokenToString TLArray = "LARRAY"
tokenToString TRArray = "RARRAY"
tokenToString TDotLBrace = "DOT_LBRACE"
tokenToString TDotStar = "DOT_STAR"
tokenToString TEllipsis = "ELLIPSIS"
tokenToString TDotDot = "DOTDOT"
tokenToString TDotDotEq = "DOTDOT_EQ"
tokenToString TNewline = "NEWLINE"
tokenToString TIndent = "INDENT"
tokenToString TDedent = "DEDENT"
tokenToString TEof = "EOF"
tokenToString (TLexError s) =
  "LEX_ERROR " ++ debugStringLit (renderParseProblem s)

-- User-facing rendering of a token for error messages (e.g. "unexpected
-- `println`"), as opposed to `tokenToString`'s debug format ("IDENT
-- println"). Identifier-like/punctuation tokens render their surface
-- spelling in backticks; literal categories render as a phrase (`a number`);
-- layout/synthetic tokens render as a plain phrase (`end of input`) since
-- they have no surface spelling a user typed.
export
describeToken : Token -> String
describeToken (TInt _ _) = "a number"
describeToken (TWideInt _ _ _) = "a number"
describeToken (TFloat _) = "a number"
describeToken (TString _) = "a string"
describeToken (TChar _) = "a character literal"
describeToken (TBool True) = "`true`"
describeToken (TBool False) = "`false`"
describeToken (TInterpOpen _) = "a string"
describeToken (TInterpMid _) = "a string"
describeToken (TInterpEnd _) = "a string"
describeToken (TIdent s) = "`" ++ s ++ "`"
describeToken (TUpper s) = "`" ++ s ++ "`"
describeToken (TBacktickIdent s) = "`" ++ s ++ "`"
describeToken TLet = "`let`"
describeToken TRec = "`rec`"
describeToken TWith = "`with`"
describeToken TMut = "`mut`"
describeToken TIn = "`in`"
describeToken TIf = "`if`"
describeToken TThen = "`then`"
describeToken TElse = "`else`"
describeToken TMatch = "`match`"
describeToken TData = "`data`"
describeToken TInterface = "`interface`"
describeToken TDefault = "`default`"
describeToken TImpl = "`impl`"
describeToken TImport = "`import`"
describeToken TExport = "`export`"
describeToken TPublic = "`public`"
describeToken TWhere = "`where`"
describeToken TOf = "`of`"
describeToken TRequires = "`requires`"
describeToken TDo = "`do`"
describeToken TDefer = "`defer`"
describeToken TAs = "`as`"
describeToken TExtern = "`extern`"
describeToken TDeriving = "`deriving`"
describeToken TType = "`type`"
describeToken TNewtype = "`newtype`"
describeToken TProp = "`prop`"
describeToken TTest = "`test`"
describeToken TBench = "`bench`"
describeToken TEffect = "`effect`"
describeToken TFunction = "`function`"
describeToken TPlus = "`+`"
describeToken TMinus = "`-`"
describeToken TMinusTight = "`-`"
describeToken TStar = "`*`"
describeToken TSlash = "`/`"
describeToken TMod = "`%`"
describeToken TEqEq = "`==`"
describeToken TNeq = "`/=`"
describeToken TBangEq = "`!=`"
describeToken TLt = "`<`"
describeToken TGt = "`>`"
describeToken TLeq = "`<=`"
describeToken TGeq = "`>=`"
describeToken TAnd = "`&&`"
describeToken TOr = "`||`"
describeToken TCons = "`::`"
describeToken TPlusPlus = "`++`"
describeToken TPipeRight = "`|>`"
describeToken TRCompose = "`>>`"
describeToken TLCompose = "`<<`"
describeToken TFatArrow = "`=>`"
describeToken TArrow = "`->`"
describeToken TLArrow = "`<-`"
describeToken TAt = "`@`"
describeToken TBang = "`!`"
describeToken TAsAt = "`@`"
describeToken TEqual = "`=`"
describeToken TColon = "`:`"
describeToken TColonEq = "`:=`"
describeToken TComma = "`,`"
describeToken TDot = "`.`"
describeToken TPipe = "`|`"
describeToken TUnderscore = "`_`"
describeToken TLParen = "`(`"
describeToken TRParen = "`)`"
describeToken TLBracket = "`[`"
describeToken TLBracketTight = "`[`"
describeToken TRBracket = "`]`"
describeToken TLBrace = "`{`"
describeToken TRBrace = "`}`"
describeToken TLArray = "`[|`"
describeToken TRArray = "`|]`"
describeToken TDotLBrace = "`.{`"
describeToken TDotStar = "`.*`"
describeToken TEllipsis = "`...`"
describeToken TDotDot = "`..`"
describeToken TDotDotEq = "`..=`"
describeToken TNewline = "a line break"
describeToken TIndent = "an indent"
describeToken TDedent = "a dedent"
describeToken TEof = "end of input"
describeToken (TLexError s) = renderParseProblem s

-- ── Raw scanner output ──────────────────────────────────────────────────
-- The scanner produces real tokens interleaved with `RNewline col` markers
-- (one per significant source line break, carrying the indentation of the
-- following line). A second `layout` pass turns those markers into
-- INDENT/DEDENT/NEWLINE per the OCaml `handle_indent` algorithm.
-- `RComment startPos endPos` carries a captured comment out-of-band: `startPos`
-- is the source char offset of the opening `--`/`{-`, `endPos` one past its last
-- char, so the lexeme is `[startPos, endPos)` (delimiters included).  The text
-- is materialised only by `rawToComments`; `tokenize` never builds it.  These
-- markers are produced by the comment arms of `scanAt` and
-- *skipped by the layout pass* (its `RComment` arms are no-ops), so the Token stream the
-- parser consumes is byte-identical to before — comments are purely a side
-- channel.  `collectComments` re-reads the raw stream to surface them.
-- `RTok tok startOff endOff` carries the source char offsets of the token's
-- lexeme: `startOff` is the first char (0-based), `endOff` is one past the last
-- char (= the next scan position), so `end - start = token length in chars`.
-- `tokenize` discards both offsets (token stream byte-identical). `tokenizeWithLines`
-- uses only `startOff` (to derive a 1-based line).
-- `RNewline col off` carries the offset of the newline char that ended
-- the preceding line, so synthetic NEWLINE/INDENT/DEDENT tokens inserted by the
-- layout pass get a source line too.
-- `RClauseNl col off` is an `RNewline` that `externClauseBreaks` found before an
-- extern's second or later `bind` clause line.  `RClauseOpen col off base` is
-- the one before its first: it also closes every layout context deeper than
-- `base`, the column of the extern's own line.
public export data RawTok =
  | RTok Token Int Int
  | RTripleInterpOpen String Int Int
  | RNewline Int Int
  | RComment Int Int
  | RClauseNl Int Int
  | RClauseOpen Int Int Int

export
isNoiseTok : Token -> Bool
isNoiseTok TNewline = True
isNoiseTok TIndent = True
isNoiseTok TDedent = True
isNoiseTok _ = False

export
isColonTok : Token -> Bool
isColonTok TColon = True
isColonTok _ = False

export
isConsTok : Token -> Bool
isConsTok TCons = True
isConsTok _ = False

export
isDedentTok : Token -> Bool
isDedentTok TDedent = True
isDedentTok _ = False

export
isDeferTok : Token -> Bool
isDeferTok TDefer = True
isDeferTok _ = False

export
isEofTok : Token -> Bool
isEofTok TEof = True
isEofTok _ = False

export
isEqualTok : Token -> Bool
isEqualTok TEqual = True
isEqualTok _ = False

export
isExportTok : Token -> Bool
isExportTok TExport = True
isExportTok _ = False

export
isImplTok : Token -> Bool
isImplTok TImpl = True
isImplTok _ = False

export
isInTok : Token -> Bool
isInTok TIn = True
isInTok _ = False

export
isIndentTok : Token -> Bool
isIndentTok TIndent = True
isIndentTok _ = False

export
isLBraceTok : Token -> Bool
isLBraceTok TLBrace = True
isLBraceTok _ = False

export
isLetTok : Token -> Bool
isLetTok TLet = True
isLetTok _ = False

export
isNewlineTok : Token -> Bool
isNewlineTok TNewline = True
isNewlineTok _ = False

export
isOfTok : Token -> Bool
isOfTok TOf = True
isOfTok _ = False

export
isPipeTok : Token -> Bool
isPipeTok TPipe = True
isPipeTok _ = False

export
isPublicTok : Token -> Bool
isPublicTok TPublic = True
isPublicTok _ = False

export
isRBraceTok : Token -> Bool
isRBraceTok TRBrace = True
isRBraceTok _ = False

export
isRequiresTok : Token -> Bool
isRequiresTok TRequires = True
isRequiresTok _ = False

export
isStarTok : Token -> Bool
isStarTok TStar = True
isStarTok _ = False

export
isWhereTok : Token -> Bool
isWhereTok TWhere = True
isWhereTok _ = False

export
isLayoutTok : Token -> Bool
isLayoutTok = isNoiseTok

export
isOpenDelim : Token -> Bool
isOpenDelim TLParen = True
isOpenDelim TLBracket = True
isOpenDelim TLBracketTight = True
isOpenDelim TLBrace = True
isOpenDelim TLArray = True
isOpenDelim _ = False

export
isCloseDelim : Token -> Bool
isCloseDelim TRParen = True
isCloseDelim TRBracket = True
isCloseDelim TRBrace = True
isCloseDelim TRArray = True
isCloseDelim _ = False

export
isTStringTok : Token -> Bool
isTStringTok (TString _) = True
isTStringTok _ = False

export
isTUpperTok : Token -> Bool
isTUpperTok (TUpper _) = True
isTUpperTok _ = False

export
isCommaTok : Token -> Bool
isCommaTok TComma = True
isCommaTok _ = False

export
peekTok : Array Token -> Int -> Token
peekTok toks pos
  | pos < arrayLength toks = arrayGetUnsafe pos toks
  | otherwise = TEof
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "util") ((mem "u64HalvesHex" false))))
(DData Public "Token" () ((variant "TInt" (ConPos (TyCon "Int") (TyCon "String"))) (variant "TWideInt" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String"))) (variant "TFloat" (ConPos (TyCon "Float"))) (variant "TString" (ConPos (TyCon "String"))) (variant "TChar" (ConPos (TyCon "String"))) (variant "TBool" (ConPos (TyCon "Bool"))) (variant "TInterpOpen" (ConPos (TyCon "String"))) (variant "TInterpMid" (ConPos (TyCon "String"))) (variant "TInterpEnd" (ConPos (TyCon "String"))) (variant "TIdent" (ConPos (TyCon "String"))) (variant "TUpper" (ConPos (TyCon "String"))) (variant "TBacktickIdent" (ConPos (TyCon "String"))) (variant "TLet" (ConPos)) (variant "TRec" (ConPos)) (variant "TWith" (ConPos)) (variant "TMut" (ConPos)) (variant "TIn" (ConPos)) (variant "TIf" (ConPos)) (variant "TThen" (ConPos)) (variant "TElse" (ConPos)) (variant "TMatch" (ConPos)) (variant "TData" (ConPos)) (variant "TInterface" (ConPos)) (variant "TDefault" (ConPos)) (variant "TImpl" (ConPos)) (variant "TImport" (ConPos)) (variant "TExport" (ConPos)) (variant "TPublic" (ConPos)) (variant "TWhere" (ConPos)) (variant "TOf" (ConPos)) (variant "TRequires" (ConPos)) (variant "TDo" (ConPos)) (variant "TDefer" (ConPos)) (variant "TAs" (ConPos)) (variant "TExtern" (ConPos)) (variant "TDeriving" (ConPos)) (variant "TType" (ConPos)) (variant "TNewtype" (ConPos)) (variant "TProp" (ConPos)) (variant "TTest" (ConPos)) (variant "TBench" (ConPos)) (variant "TEffect" (ConPos)) (variant "TFunction" (ConPos)) (variant "TPlus" (ConPos)) (variant "TMinus" (ConPos)) (variant "TMinusTight" (ConPos)) (variant "TStar" (ConPos)) (variant "TSlash" (ConPos)) (variant "TMod" (ConPos)) (variant "TEqEq" (ConPos)) (variant "TNeq" (ConPos)) (variant "TBangEq" (ConPos)) (variant "TLt" (ConPos)) (variant "TGt" (ConPos)) (variant "TLeq" (ConPos)) (variant "TGeq" (ConPos)) (variant "TAnd" (ConPos)) (variant "TOr" (ConPos)) (variant "TCons" (ConPos)) (variant "TPlusPlus" (ConPos)) (variant "TPipeRight" (ConPos)) (variant "TRCompose" (ConPos)) (variant "TLCompose" (ConPos)) (variant "TFatArrow" (ConPos)) (variant "TArrow" (ConPos)) (variant "TLArrow" (ConPos)) (variant "TAt" (ConPos)) (variant "TBang" (ConPos)) (variant "TAsAt" (ConPos)) (variant "TEqual" (ConPos)) (variant "TColon" (ConPos)) (variant "TColonEq" (ConPos)) (variant "TComma" (ConPos)) (variant "TDot" (ConPos)) (variant "TPipe" (ConPos)) (variant "TUnderscore" (ConPos)) (variant "TLParen" (ConPos)) (variant "TRParen" (ConPos)) (variant "TLBracket" (ConPos)) (variant "TLBracketTight" (ConPos)) (variant "TRBracket" (ConPos)) (variant "TLBrace" (ConPos)) (variant "TRBrace" (ConPos)) (variant "TLArray" (ConPos)) (variant "TRArray" (ConPos)) (variant "TDotLBrace" (ConPos)) (variant "TDotStar" (ConPos)) (variant "TEllipsis" (ConPos)) (variant "TDotDot" (ConPos)) (variant "TDotDotEq" (ConPos)) (variant "TNewline" (ConPos)) (variant "TIndent" (ConPos)) (variant "TDedent" (ConPos)) (variant "TEof" (ConPos)) (variant "TLexError" (ConPos (TyCon "ParseDiagnosticKind")))) ())
(DImpl true "Eq" ((TyCon "Token")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TInt" (PVar "__a0") (PVar "__a1")) (PCon "TInt" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TWideInt" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "TWideInt" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "TFloat" (PVar "__a0")) (PCon "TFloat" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TString" (PVar "__a0")) (PCon "TString" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TChar" (PVar "__a0")) (PCon "TChar" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBool" (PVar "__a0")) (PCon "TBool" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpOpen" (PVar "__a0")) (PCon "TInterpOpen" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpMid" (PVar "__a0")) (PCon "TInterpMid" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpEnd" (PVar "__a0")) (PCon "TInterpEnd" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TIdent" (PVar "__a0")) (PCon "TIdent" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TUpper" (PVar "__a0")) (PCon "TUpper" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBacktickIdent" (PVar "__a0")) (PCon "TBacktickIdent" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TLet") (PCon "TLet")) () (EVar "True")) (arm (PTuple (PCon "TRec") (PCon "TRec")) () (EVar "True")) (arm (PTuple (PCon "TWith") (PCon "TWith")) () (EVar "True")) (arm (PTuple (PCon "TMut") (PCon "TMut")) () (EVar "True")) (arm (PTuple (PCon "TIn") (PCon "TIn")) () (EVar "True")) (arm (PTuple (PCon "TIf") (PCon "TIf")) () (EVar "True")) (arm (PTuple (PCon "TThen") (PCon "TThen")) () (EVar "True")) (arm (PTuple (PCon "TElse") (PCon "TElse")) () (EVar "True")) (arm (PTuple (PCon "TMatch") (PCon "TMatch")) () (EVar "True")) (arm (PTuple (PCon "TData") (PCon "TData")) () (EVar "True")) (arm (PTuple (PCon "TInterface") (PCon "TInterface")) () (EVar "True")) (arm (PTuple (PCon "TDefault") (PCon "TDefault")) () (EVar "True")) (arm (PTuple (PCon "TImpl") (PCon "TImpl")) () (EVar "True")) (arm (PTuple (PCon "TImport") (PCon "TImport")) () (EVar "True")) (arm (PTuple (PCon "TExport") (PCon "TExport")) () (EVar "True")) (arm (PTuple (PCon "TPublic") (PCon "TPublic")) () (EVar "True")) (arm (PTuple (PCon "TWhere") (PCon "TWhere")) () (EVar "True")) (arm (PTuple (PCon "TOf") (PCon "TOf")) () (EVar "True")) (arm (PTuple (PCon "TRequires") (PCon "TRequires")) () (EVar "True")) (arm (PTuple (PCon "TDo") (PCon "TDo")) () (EVar "True")) (arm (PTuple (PCon "TDefer") (PCon "TDefer")) () (EVar "True")) (arm (PTuple (PCon "TAs") (PCon "TAs")) () (EVar "True")) (arm (PTuple (PCon "TExtern") (PCon "TExtern")) () (EVar "True")) (arm (PTuple (PCon "TDeriving") (PCon "TDeriving")) () (EVar "True")) (arm (PTuple (PCon "TType") (PCon "TType")) () (EVar "True")) (arm (PTuple (PCon "TNewtype") (PCon "TNewtype")) () (EVar "True")) (arm (PTuple (PCon "TProp") (PCon "TProp")) () (EVar "True")) (arm (PTuple (PCon "TTest") (PCon "TTest")) () (EVar "True")) (arm (PTuple (PCon "TBench") (PCon "TBench")) () (EVar "True")) (arm (PTuple (PCon "TEffect") (PCon "TEffect")) () (EVar "True")) (arm (PTuple (PCon "TFunction") (PCon "TFunction")) () (EVar "True")) (arm (PTuple (PCon "TPlus") (PCon "TPlus")) () (EVar "True")) (arm (PTuple (PCon "TMinus") (PCon "TMinus")) () (EVar "True")) (arm (PTuple (PCon "TMinusTight") (PCon "TMinusTight")) () (EVar "True")) (arm (PTuple (PCon "TStar") (PCon "TStar")) () (EVar "True")) (arm (PTuple (PCon "TSlash") (PCon "TSlash")) () (EVar "True")) (arm (PTuple (PCon "TMod") (PCon "TMod")) () (EVar "True")) (arm (PTuple (PCon "TEqEq") (PCon "TEqEq")) () (EVar "True")) (arm (PTuple (PCon "TNeq") (PCon "TNeq")) () (EVar "True")) (arm (PTuple (PCon "TBangEq") (PCon "TBangEq")) () (EVar "True")) (arm (PTuple (PCon "TLt") (PCon "TLt")) () (EVar "True")) (arm (PTuple (PCon "TGt") (PCon "TGt")) () (EVar "True")) (arm (PTuple (PCon "TLeq") (PCon "TLeq")) () (EVar "True")) (arm (PTuple (PCon "TGeq") (PCon "TGeq")) () (EVar "True")) (arm (PTuple (PCon "TAnd") (PCon "TAnd")) () (EVar "True")) (arm (PTuple (PCon "TOr") (PCon "TOr")) () (EVar "True")) (arm (PTuple (PCon "TCons") (PCon "TCons")) () (EVar "True")) (arm (PTuple (PCon "TPlusPlus") (PCon "TPlusPlus")) () (EVar "True")) (arm (PTuple (PCon "TPipeRight") (PCon "TPipeRight")) () (EVar "True")) (arm (PTuple (PCon "TRCompose") (PCon "TRCompose")) () (EVar "True")) (arm (PTuple (PCon "TLCompose") (PCon "TLCompose")) () (EVar "True")) (arm (PTuple (PCon "TFatArrow") (PCon "TFatArrow")) () (EVar "True")) (arm (PTuple (PCon "TArrow") (PCon "TArrow")) () (EVar "True")) (arm (PTuple (PCon "TLArrow") (PCon "TLArrow")) () (EVar "True")) (arm (PTuple (PCon "TAt") (PCon "TAt")) () (EVar "True")) (arm (PTuple (PCon "TBang") (PCon "TBang")) () (EVar "True")) (arm (PTuple (PCon "TAsAt") (PCon "TAsAt")) () (EVar "True")) (arm (PTuple (PCon "TEqual") (PCon "TEqual")) () (EVar "True")) (arm (PTuple (PCon "TColon") (PCon "TColon")) () (EVar "True")) (arm (PTuple (PCon "TColonEq") (PCon "TColonEq")) () (EVar "True")) (arm (PTuple (PCon "TComma") (PCon "TComma")) () (EVar "True")) (arm (PTuple (PCon "TDot") (PCon "TDot")) () (EVar "True")) (arm (PTuple (PCon "TPipe") (PCon "TPipe")) () (EVar "True")) (arm (PTuple (PCon "TUnderscore") (PCon "TUnderscore")) () (EVar "True")) (arm (PTuple (PCon "TLParen") (PCon "TLParen")) () (EVar "True")) (arm (PTuple (PCon "TRParen") (PCon "TRParen")) () (EVar "True")) (arm (PTuple (PCon "TLBracket") (PCon "TLBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBracketTight") (PCon "TLBracketTight")) () (EVar "True")) (arm (PTuple (PCon "TRBracket") (PCon "TRBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBrace") (PCon "TLBrace")) () (EVar "True")) (arm (PTuple (PCon "TRBrace") (PCon "TRBrace")) () (EVar "True")) (arm (PTuple (PCon "TLArray") (PCon "TLArray")) () (EVar "True")) (arm (PTuple (PCon "TRArray") (PCon "TRArray")) () (EVar "True")) (arm (PTuple (PCon "TDotLBrace") (PCon "TDotLBrace")) () (EVar "True")) (arm (PTuple (PCon "TDotStar") (PCon "TDotStar")) () (EVar "True")) (arm (PTuple (PCon "TEllipsis") (PCon "TEllipsis")) () (EVar "True")) (arm (PTuple (PCon "TDotDot") (PCon "TDotDot")) () (EVar "True")) (arm (PTuple (PCon "TDotDotEq") (PCon "TDotDotEq")) () (EVar "True")) (arm (PTuple (PCon "TNewline") (PCon "TNewline")) () (EVar "True")) (arm (PTuple (PCon "TIndent") (PCon "TIndent")) () (EVar "True")) (arm (PTuple (PCon "TDedent") (PCon "TDedent")) () (EVar "True")) (arm (PTuple (PCon "TEof") (PCon "TEof")) () (EVar "True")) (arm (PTuple (PCon "TLexError" (PVar "__a0")) (PCon "TLexError" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "tokenToString" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenToString" ((PCon "TInt" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "INT ")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "tokenToString" ((PCon "TWideInt" (PVar "hi") (PVar "lo") PWild)) (EBinOp "++" (ELit (LString "INT 0x")) (EApp (EApp (EVar "u64HalvesHex") (EVar "hi")) (EVar "lo"))))
(DFunDef false "tokenToString" ((PCon "TFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "FLOAT ")) (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "tokenToString" ((PCon "TString" (PVar "s"))) (EBinOp "++" (ELit (LString "STRING ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TChar" (PVar "s"))) (EBinOp "++" (ELit (LString "CHAR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "True"))) (ELit (LString "BOOL true")))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "False"))) (ELit (LString "BOOL false")))
(DFunDef false "tokenToString" ((PCon "TInterpOpen" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_OPEN ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpMid" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_MID ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpEnd" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_END ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (ELit (LString "UPPER ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "BACKTICK_IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TLet")) (ELit (LString "LET")))
(DFunDef false "tokenToString" ((PCon "TRec")) (ELit (LString "REC")))
(DFunDef false "tokenToString" ((PCon "TWith")) (ELit (LString "WITH")))
(DFunDef false "tokenToString" ((PCon "TMut")) (ELit (LString "MUT")))
(DFunDef false "tokenToString" ((PCon "TIn")) (ELit (LString "IN")))
(DFunDef false "tokenToString" ((PCon "TIf")) (ELit (LString "IF")))
(DFunDef false "tokenToString" ((PCon "TThen")) (ELit (LString "THEN")))
(DFunDef false "tokenToString" ((PCon "TElse")) (ELit (LString "ELSE")))
(DFunDef false "tokenToString" ((PCon "TMatch")) (ELit (LString "MATCH")))
(DFunDef false "tokenToString" ((PCon "TData")) (ELit (LString "DATA")))
(DFunDef false "tokenToString" ((PCon "TInterface")) (ELit (LString "INTERFACE")))
(DFunDef false "tokenToString" ((PCon "TDefault")) (ELit (LString "DEFAULT")))
(DFunDef false "tokenToString" ((PCon "TImpl")) (ELit (LString "IMPL")))
(DFunDef false "tokenToString" ((PCon "TImport")) (ELit (LString "IMPORT")))
(DFunDef false "tokenToString" ((PCon "TExport")) (ELit (LString "EXPORT")))
(DFunDef false "tokenToString" ((PCon "TPublic")) (ELit (LString "PUBLIC")))
(DFunDef false "tokenToString" ((PCon "TWhere")) (ELit (LString "WHERE")))
(DFunDef false "tokenToString" ((PCon "TOf")) (ELit (LString "OF")))
(DFunDef false "tokenToString" ((PCon "TRequires")) (ELit (LString "REQUIRES")))
(DFunDef false "tokenToString" ((PCon "TDo")) (ELit (LString "DO")))
(DFunDef false "tokenToString" ((PCon "TDefer")) (ELit (LString "DEFER")))
(DFunDef false "tokenToString" ((PCon "TAs")) (ELit (LString "AS")))
(DFunDef false "tokenToString" ((PCon "TExtern")) (ELit (LString "EXTERN")))
(DFunDef false "tokenToString" ((PCon "TDeriving")) (ELit (LString "DERIVING")))
(DFunDef false "tokenToString" ((PCon "TType")) (ELit (LString "TYPE")))
(DFunDef false "tokenToString" ((PCon "TNewtype")) (ELit (LString "NEWTYPE")))
(DFunDef false "tokenToString" ((PCon "TProp")) (ELit (LString "PROP")))
(DFunDef false "tokenToString" ((PCon "TTest")) (ELit (LString "TEST")))
(DFunDef false "tokenToString" ((PCon "TBench")) (ELit (LString "BENCH")))
(DFunDef false "tokenToString" ((PCon "TEffect")) (ELit (LString "EFFECT")))
(DFunDef false "tokenToString" ((PCon "TFunction")) (ELit (LString "FUNCTION")))
(DFunDef false "tokenToString" ((PCon "TPlus")) (ELit (LString "PLUS")))
(DFunDef false "tokenToString" ((PCon "TMinus")) (ELit (LString "MINUS")))
(DFunDef false "tokenToString" ((PCon "TMinusTight")) (ELit (LString "MINUS_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TStar")) (ELit (LString "STAR")))
(DFunDef false "tokenToString" ((PCon "TSlash")) (ELit (LString "SLASH")))
(DFunDef false "tokenToString" ((PCon "TMod")) (ELit (LString "MOD")))
(DFunDef false "tokenToString" ((PCon "TEqEq")) (ELit (LString "EQ_EQ")))
(DFunDef false "tokenToString" ((PCon "TNeq")) (ELit (LString "NEQ")))
(DFunDef false "tokenToString" ((PCon "TBangEq")) (ELit (LString "BANGEQ")))
(DFunDef false "tokenToString" ((PCon "TLt")) (ELit (LString "LT")))
(DFunDef false "tokenToString" ((PCon "TGt")) (ELit (LString "GT")))
(DFunDef false "tokenToString" ((PCon "TLeq")) (ELit (LString "LEQ")))
(DFunDef false "tokenToString" ((PCon "TGeq")) (ELit (LString "GEQ")))
(DFunDef false "tokenToString" ((PCon "TAnd")) (ELit (LString "AND")))
(DFunDef false "tokenToString" ((PCon "TOr")) (ELit (LString "OR")))
(DFunDef false "tokenToString" ((PCon "TCons")) (ELit (LString "CONS")))
(DFunDef false "tokenToString" ((PCon "TPlusPlus")) (ELit (LString "PLUSPLUS")))
(DFunDef false "tokenToString" ((PCon "TPipeRight")) (ELit (LString "PIPE_RIGHT")))
(DFunDef false "tokenToString" ((PCon "TRCompose")) (ELit (LString "RCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TLCompose")) (ELit (LString "LCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TFatArrow")) (ELit (LString "FAT_ARROW")))
(DFunDef false "tokenToString" ((PCon "TArrow")) (ELit (LString "ARROW")))
(DFunDef false "tokenToString" ((PCon "TLArrow")) (ELit (LString "LARROW")))
(DFunDef false "tokenToString" ((PCon "TAt")) (ELit (LString "AT")))
(DFunDef false "tokenToString" ((PCon "TBang")) (ELit (LString "BANG")))
(DFunDef false "tokenToString" ((PCon "TAsAt")) (ELit (LString "AS_AT")))
(DFunDef false "tokenToString" ((PCon "TEqual")) (ELit (LString "EQUAL")))
(DFunDef false "tokenToString" ((PCon "TColon")) (ELit (LString "COLON")))
(DFunDef false "tokenToString" ((PCon "TColonEq")) (ELit (LString "COLONEQ")))
(DFunDef false "tokenToString" ((PCon "TComma")) (ELit (LString "COMMA")))
(DFunDef false "tokenToString" ((PCon "TDot")) (ELit (LString "DOT")))
(DFunDef false "tokenToString" ((PCon "TPipe")) (ELit (LString "PIPE")))
(DFunDef false "tokenToString" ((PCon "TUnderscore")) (ELit (LString "UNDERSCORE")))
(DFunDef false "tokenToString" ((PCon "TLParen")) (ELit (LString "LPAREN")))
(DFunDef false "tokenToString" ((PCon "TRParen")) (ELit (LString "RPAREN")))
(DFunDef false "tokenToString" ((PCon "TLBracket")) (ELit (LString "LBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBracketTight")) (ELit (LString "LBRACKET_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TRBracket")) (ELit (LString "RBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBrace")) (ELit (LString "LBRACE")))
(DFunDef false "tokenToString" ((PCon "TRBrace")) (ELit (LString "RBRACE")))
(DFunDef false "tokenToString" ((PCon "TLArray")) (ELit (LString "LARRAY")))
(DFunDef false "tokenToString" ((PCon "TRArray")) (ELit (LString "RARRAY")))
(DFunDef false "tokenToString" ((PCon "TDotLBrace")) (ELit (LString "DOT_LBRACE")))
(DFunDef false "tokenToString" ((PCon "TDotStar")) (ELit (LString "DOT_STAR")))
(DFunDef false "tokenToString" ((PCon "TEllipsis")) (ELit (LString "ELLIPSIS")))
(DFunDef false "tokenToString" ((PCon "TDotDot")) (ELit (LString "DOTDOT")))
(DFunDef false "tokenToString" ((PCon "TDotDotEq")) (ELit (LString "DOTDOT_EQ")))
(DFunDef false "tokenToString" ((PCon "TNewline")) (ELit (LString "NEWLINE")))
(DFunDef false "tokenToString" ((PCon "TIndent")) (ELit (LString "INDENT")))
(DFunDef false "tokenToString" ((PCon "TDedent")) (ELit (LString "DEDENT")))
(DFunDef false "tokenToString" ((PCon "TEof")) (ELit (LString "EOF")))
(DFunDef false "tokenToString" ((PCon "TLexError" (PVar "s"))) (EBinOp "++" (ELit (LString "LEX_ERROR ")) (EApp (EVar "debugStringLit") (EApp (EVar "renderParseProblem") (EVar "s")))))
(DTypeSig true "describeToken" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "describeToken" ((PCon "TInt" PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TWideInt" PWild PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TFloat" PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TString" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TChar" PWild)) (ELit (LString "a character literal")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "True"))) (ELit (LString "`true`")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "False"))) (ELit (LString "`false`")))
(DFunDef false "describeToken" ((PCon "TInterpOpen" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpMid" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpEnd" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TLet")) (ELit (LString "`let`")))
(DFunDef false "describeToken" ((PCon "TRec")) (ELit (LString "`rec`")))
(DFunDef false "describeToken" ((PCon "TWith")) (ELit (LString "`with`")))
(DFunDef false "describeToken" ((PCon "TMut")) (ELit (LString "`mut`")))
(DFunDef false "describeToken" ((PCon "TIn")) (ELit (LString "`in`")))
(DFunDef false "describeToken" ((PCon "TIf")) (ELit (LString "`if`")))
(DFunDef false "describeToken" ((PCon "TThen")) (ELit (LString "`then`")))
(DFunDef false "describeToken" ((PCon "TElse")) (ELit (LString "`else`")))
(DFunDef false "describeToken" ((PCon "TMatch")) (ELit (LString "`match`")))
(DFunDef false "describeToken" ((PCon "TData")) (ELit (LString "`data`")))
(DFunDef false "describeToken" ((PCon "TInterface")) (ELit (LString "`interface`")))
(DFunDef false "describeToken" ((PCon "TDefault")) (ELit (LString "`default`")))
(DFunDef false "describeToken" ((PCon "TImpl")) (ELit (LString "`impl`")))
(DFunDef false "describeToken" ((PCon "TImport")) (ELit (LString "`import`")))
(DFunDef false "describeToken" ((PCon "TExport")) (ELit (LString "`export`")))
(DFunDef false "describeToken" ((PCon "TPublic")) (ELit (LString "`public`")))
(DFunDef false "describeToken" ((PCon "TWhere")) (ELit (LString "`where`")))
(DFunDef false "describeToken" ((PCon "TOf")) (ELit (LString "`of`")))
(DFunDef false "describeToken" ((PCon "TRequires")) (ELit (LString "`requires`")))
(DFunDef false "describeToken" ((PCon "TDo")) (ELit (LString "`do`")))
(DFunDef false "describeToken" ((PCon "TDefer")) (ELit (LString "`defer`")))
(DFunDef false "describeToken" ((PCon "TAs")) (ELit (LString "`as`")))
(DFunDef false "describeToken" ((PCon "TExtern")) (ELit (LString "`extern`")))
(DFunDef false "describeToken" ((PCon "TDeriving")) (ELit (LString "`deriving`")))
(DFunDef false "describeToken" ((PCon "TType")) (ELit (LString "`type`")))
(DFunDef false "describeToken" ((PCon "TNewtype")) (ELit (LString "`newtype`")))
(DFunDef false "describeToken" ((PCon "TProp")) (ELit (LString "`prop`")))
(DFunDef false "describeToken" ((PCon "TTest")) (ELit (LString "`test`")))
(DFunDef false "describeToken" ((PCon "TBench")) (ELit (LString "`bench`")))
(DFunDef false "describeToken" ((PCon "TEffect")) (ELit (LString "`effect`")))
(DFunDef false "describeToken" ((PCon "TFunction")) (ELit (LString "`function`")))
(DFunDef false "describeToken" ((PCon "TPlus")) (ELit (LString "`+`")))
(DFunDef false "describeToken" ((PCon "TMinus")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TMinusTight")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TStar")) (ELit (LString "`*`")))
(DFunDef false "describeToken" ((PCon "TSlash")) (ELit (LString "`/`")))
(DFunDef false "describeToken" ((PCon "TMod")) (ELit (LString "`%`")))
(DFunDef false "describeToken" ((PCon "TEqEq")) (ELit (LString "`==`")))
(DFunDef false "describeToken" ((PCon "TNeq")) (ELit (LString "`/=`")))
(DFunDef false "describeToken" ((PCon "TBangEq")) (ELit (LString "`!=`")))
(DFunDef false "describeToken" ((PCon "TLt")) (ELit (LString "`<`")))
(DFunDef false "describeToken" ((PCon "TGt")) (ELit (LString "`>`")))
(DFunDef false "describeToken" ((PCon "TLeq")) (ELit (LString "`<=`")))
(DFunDef false "describeToken" ((PCon "TGeq")) (ELit (LString "`>=`")))
(DFunDef false "describeToken" ((PCon "TAnd")) (ELit (LString "`&&`")))
(DFunDef false "describeToken" ((PCon "TOr")) (ELit (LString "`||`")))
(DFunDef false "describeToken" ((PCon "TCons")) (ELit (LString "`::`")))
(DFunDef false "describeToken" ((PCon "TPlusPlus")) (ELit (LString "`++`")))
(DFunDef false "describeToken" ((PCon "TPipeRight")) (ELit (LString "`|>`")))
(DFunDef false "describeToken" ((PCon "TRCompose")) (ELit (LString "`>>`")))
(DFunDef false "describeToken" ((PCon "TLCompose")) (ELit (LString "`<<`")))
(DFunDef false "describeToken" ((PCon "TFatArrow")) (ELit (LString "`=>`")))
(DFunDef false "describeToken" ((PCon "TArrow")) (ELit (LString "`->`")))
(DFunDef false "describeToken" ((PCon "TLArrow")) (ELit (LString "`<-`")))
(DFunDef false "describeToken" ((PCon "TAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TBang")) (ELit (LString "`!`")))
(DFunDef false "describeToken" ((PCon "TAsAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TEqual")) (ELit (LString "`=`")))
(DFunDef false "describeToken" ((PCon "TColon")) (ELit (LString "`:`")))
(DFunDef false "describeToken" ((PCon "TColonEq")) (ELit (LString "`:=`")))
(DFunDef false "describeToken" ((PCon "TComma")) (ELit (LString "`,`")))
(DFunDef false "describeToken" ((PCon "TDot")) (ELit (LString "`.`")))
(DFunDef false "describeToken" ((PCon "TPipe")) (ELit (LString "`|`")))
(DFunDef false "describeToken" ((PCon "TUnderscore")) (ELit (LString "`_`")))
(DFunDef false "describeToken" ((PCon "TLParen")) (ELit (LString "`(`")))
(DFunDef false "describeToken" ((PCon "TRParen")) (ELit (LString "`)`")))
(DFunDef false "describeToken" ((PCon "TLBracket")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TLBracketTight")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TRBracket")) (ELit (LString "`]`")))
(DFunDef false "describeToken" ((PCon "TLBrace")) (ELit (LString "`{`")))
(DFunDef false "describeToken" ((PCon "TRBrace")) (ELit (LString "`}`")))
(DFunDef false "describeToken" ((PCon "TLArray")) (ELit (LString "`[|`")))
(DFunDef false "describeToken" ((PCon "TRArray")) (ELit (LString "`|]`")))
(DFunDef false "describeToken" ((PCon "TDotLBrace")) (ELit (LString "`.{`")))
(DFunDef false "describeToken" ((PCon "TDotStar")) (ELit (LString "`.*`")))
(DFunDef false "describeToken" ((PCon "TEllipsis")) (ELit (LString "`...`")))
(DFunDef false "describeToken" ((PCon "TDotDot")) (ELit (LString "`..`")))
(DFunDef false "describeToken" ((PCon "TDotDotEq")) (ELit (LString "`..=`")))
(DFunDef false "describeToken" ((PCon "TNewline")) (ELit (LString "a line break")))
(DFunDef false "describeToken" ((PCon "TIndent")) (ELit (LString "an indent")))
(DFunDef false "describeToken" ((PCon "TDedent")) (ELit (LString "a dedent")))
(DFunDef false "describeToken" ((PCon "TEof")) (ELit (LString "end of input")))
(DFunDef false "describeToken" ((PCon "TLexError" (PVar "s"))) (EApp (EVar "renderParseProblem") (EVar "s")))
(DData Public "RawTok" () ((variant "RTok" (ConPos (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (variant "RTripleInterpOpen" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int"))) (variant "RNewline" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RComment" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RClauseNl" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RClauseOpen" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "isNoiseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNoiseTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isNoiseTok" (PWild) (EVar "False"))
(DTypeSig true "isColonTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isColonTok" ((PCon "TColon")) (EVar "True"))
(DFunDef false "isColonTok" (PWild) (EVar "False"))
(DTypeSig true "isConsTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isConsTok" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isConsTok" (PWild) (EVar "False"))
(DTypeSig true "isDedentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isDedentTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isDedentTok" (PWild) (EVar "False"))
(DTypeSig true "isDeferTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isDeferTok" ((PCon "TDefer")) (EVar "True"))
(DFunDef false "isDeferTok" (PWild) (EVar "False"))
(DTypeSig true "isEofTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isEofTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isEofTok" (PWild) (EVar "False"))
(DTypeSig true "isEqualTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isEqualTok" ((PCon "TEqual")) (EVar "True"))
(DFunDef false "isEqualTok" (PWild) (EVar "False"))
(DTypeSig true "isExportTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isExportTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isExportTok" (PWild) (EVar "False"))
(DTypeSig true "isImplTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isImplTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isImplTok" (PWild) (EVar "False"))
(DTypeSig true "isInTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isInTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isInTok" (PWild) (EVar "False"))
(DTypeSig true "isIndentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isIndentTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isIndentTok" (PWild) (EVar "False"))
(DTypeSig true "isLBraceTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLBraceTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isLBraceTok" (PWild) (EVar "False"))
(DTypeSig true "isLetTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLetTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isLetTok" (PWild) (EVar "False"))
(DTypeSig true "isNewlineTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNewlineTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNewlineTok" (PWild) (EVar "False"))
(DTypeSig true "isOfTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOfTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isOfTok" (PWild) (EVar "False"))
(DTypeSig true "isPipeTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPipeTok" ((PCon "TPipe")) (EVar "True"))
(DFunDef false "isPipeTok" (PWild) (EVar "False"))
(DTypeSig true "isPublicTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPublicTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isPublicTok" (PWild) (EVar "False"))
(DTypeSig true "isRBraceTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isRBraceTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isRBraceTok" (PWild) (EVar "False"))
(DTypeSig true "isRequiresTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isRequiresTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isRequiresTok" (PWild) (EVar "False"))
(DTypeSig true "isStarTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isStarTok" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isStarTok" (PWild) (EVar "False"))
(DTypeSig true "isWhereTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isWhereTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isWhereTok" (PWild) (EVar "False"))
(DTypeSig true "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" () (EVar "isNoiseTok"))
(DTypeSig true "isOpenDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpenDelim" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "isOpenDelim" (PWild) (EVar "False"))
(DTypeSig true "isCloseDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCloseDelim" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "isCloseDelim" (PWild) (EVar "False"))
(DTypeSig true "isTStringTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTStringTok" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "isTStringTok" (PWild) (EVar "False"))
(DTypeSig true "isTUpperTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTUpperTok" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "isTUpperTok" (PWild) (EVar "False"))
(DTypeSig true "isCommaTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCommaTok" ((PCon "TComma")) (EVar "True"))
(DFunDef false "isCommaTok" (PWild) (EVar "False"))
(DTypeSig true "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "util") ((mem "u64HalvesHex" false))))
(DData Public "Token" () ((variant "TInt" (ConPos (TyCon "Int") (TyCon "String"))) (variant "TWideInt" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String"))) (variant "TFloat" (ConPos (TyCon "Float"))) (variant "TString" (ConPos (TyCon "String"))) (variant "TChar" (ConPos (TyCon "String"))) (variant "TBool" (ConPos (TyCon "Bool"))) (variant "TInterpOpen" (ConPos (TyCon "String"))) (variant "TInterpMid" (ConPos (TyCon "String"))) (variant "TInterpEnd" (ConPos (TyCon "String"))) (variant "TIdent" (ConPos (TyCon "String"))) (variant "TUpper" (ConPos (TyCon "String"))) (variant "TBacktickIdent" (ConPos (TyCon "String"))) (variant "TLet" (ConPos)) (variant "TRec" (ConPos)) (variant "TWith" (ConPos)) (variant "TMut" (ConPos)) (variant "TIn" (ConPos)) (variant "TIf" (ConPos)) (variant "TThen" (ConPos)) (variant "TElse" (ConPos)) (variant "TMatch" (ConPos)) (variant "TData" (ConPos)) (variant "TInterface" (ConPos)) (variant "TDefault" (ConPos)) (variant "TImpl" (ConPos)) (variant "TImport" (ConPos)) (variant "TExport" (ConPos)) (variant "TPublic" (ConPos)) (variant "TWhere" (ConPos)) (variant "TOf" (ConPos)) (variant "TRequires" (ConPos)) (variant "TDo" (ConPos)) (variant "TDefer" (ConPos)) (variant "TAs" (ConPos)) (variant "TExtern" (ConPos)) (variant "TDeriving" (ConPos)) (variant "TType" (ConPos)) (variant "TNewtype" (ConPos)) (variant "TProp" (ConPos)) (variant "TTest" (ConPos)) (variant "TBench" (ConPos)) (variant "TEffect" (ConPos)) (variant "TFunction" (ConPos)) (variant "TPlus" (ConPos)) (variant "TMinus" (ConPos)) (variant "TMinusTight" (ConPos)) (variant "TStar" (ConPos)) (variant "TSlash" (ConPos)) (variant "TMod" (ConPos)) (variant "TEqEq" (ConPos)) (variant "TNeq" (ConPos)) (variant "TBangEq" (ConPos)) (variant "TLt" (ConPos)) (variant "TGt" (ConPos)) (variant "TLeq" (ConPos)) (variant "TGeq" (ConPos)) (variant "TAnd" (ConPos)) (variant "TOr" (ConPos)) (variant "TCons" (ConPos)) (variant "TPlusPlus" (ConPos)) (variant "TPipeRight" (ConPos)) (variant "TRCompose" (ConPos)) (variant "TLCompose" (ConPos)) (variant "TFatArrow" (ConPos)) (variant "TArrow" (ConPos)) (variant "TLArrow" (ConPos)) (variant "TAt" (ConPos)) (variant "TBang" (ConPos)) (variant "TAsAt" (ConPos)) (variant "TEqual" (ConPos)) (variant "TColon" (ConPos)) (variant "TColonEq" (ConPos)) (variant "TComma" (ConPos)) (variant "TDot" (ConPos)) (variant "TPipe" (ConPos)) (variant "TUnderscore" (ConPos)) (variant "TLParen" (ConPos)) (variant "TRParen" (ConPos)) (variant "TLBracket" (ConPos)) (variant "TLBracketTight" (ConPos)) (variant "TRBracket" (ConPos)) (variant "TLBrace" (ConPos)) (variant "TRBrace" (ConPos)) (variant "TLArray" (ConPos)) (variant "TRArray" (ConPos)) (variant "TDotLBrace" (ConPos)) (variant "TDotStar" (ConPos)) (variant "TEllipsis" (ConPos)) (variant "TDotDot" (ConPos)) (variant "TDotDotEq" (ConPos)) (variant "TNewline" (ConPos)) (variant "TIndent" (ConPos)) (variant "TDedent" (ConPos)) (variant "TEof" (ConPos)) (variant "TLexError" (ConPos (TyCon "ParseDiagnosticKind")))) ())
(DImpl true "Eq" ((TyCon "Token")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TInt" (PVar "__a0") (PVar "__a1")) (PCon "TInt" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TWideInt" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "TWideInt" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "TFloat" (PVar "__a0")) (PCon "TFloat" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TString" (PVar "__a0")) (PCon "TString" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TChar" (PVar "__a0")) (PCon "TChar" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBool" (PVar "__a0")) (PCon "TBool" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpOpen" (PVar "__a0")) (PCon "TInterpOpen" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpMid" (PVar "__a0")) (PCon "TInterpMid" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TInterpEnd" (PVar "__a0")) (PCon "TInterpEnd" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TIdent" (PVar "__a0")) (PCon "TIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TUpper" (PVar "__a0")) (PCon "TUpper" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TBacktickIdent" (PVar "__a0")) (PCon "TBacktickIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TLet") (PCon "TLet")) () (EVar "True")) (arm (PTuple (PCon "TRec") (PCon "TRec")) () (EVar "True")) (arm (PTuple (PCon "TWith") (PCon "TWith")) () (EVar "True")) (arm (PTuple (PCon "TMut") (PCon "TMut")) () (EVar "True")) (arm (PTuple (PCon "TIn") (PCon "TIn")) () (EVar "True")) (arm (PTuple (PCon "TIf") (PCon "TIf")) () (EVar "True")) (arm (PTuple (PCon "TThen") (PCon "TThen")) () (EVar "True")) (arm (PTuple (PCon "TElse") (PCon "TElse")) () (EVar "True")) (arm (PTuple (PCon "TMatch") (PCon "TMatch")) () (EVar "True")) (arm (PTuple (PCon "TData") (PCon "TData")) () (EVar "True")) (arm (PTuple (PCon "TInterface") (PCon "TInterface")) () (EVar "True")) (arm (PTuple (PCon "TDefault") (PCon "TDefault")) () (EVar "True")) (arm (PTuple (PCon "TImpl") (PCon "TImpl")) () (EVar "True")) (arm (PTuple (PCon "TImport") (PCon "TImport")) () (EVar "True")) (arm (PTuple (PCon "TExport") (PCon "TExport")) () (EVar "True")) (arm (PTuple (PCon "TPublic") (PCon "TPublic")) () (EVar "True")) (arm (PTuple (PCon "TWhere") (PCon "TWhere")) () (EVar "True")) (arm (PTuple (PCon "TOf") (PCon "TOf")) () (EVar "True")) (arm (PTuple (PCon "TRequires") (PCon "TRequires")) () (EVar "True")) (arm (PTuple (PCon "TDo") (PCon "TDo")) () (EVar "True")) (arm (PTuple (PCon "TDefer") (PCon "TDefer")) () (EVar "True")) (arm (PTuple (PCon "TAs") (PCon "TAs")) () (EVar "True")) (arm (PTuple (PCon "TExtern") (PCon "TExtern")) () (EVar "True")) (arm (PTuple (PCon "TDeriving") (PCon "TDeriving")) () (EVar "True")) (arm (PTuple (PCon "TType") (PCon "TType")) () (EVar "True")) (arm (PTuple (PCon "TNewtype") (PCon "TNewtype")) () (EVar "True")) (arm (PTuple (PCon "TProp") (PCon "TProp")) () (EVar "True")) (arm (PTuple (PCon "TTest") (PCon "TTest")) () (EVar "True")) (arm (PTuple (PCon "TBench") (PCon "TBench")) () (EVar "True")) (arm (PTuple (PCon "TEffect") (PCon "TEffect")) () (EVar "True")) (arm (PTuple (PCon "TFunction") (PCon "TFunction")) () (EVar "True")) (arm (PTuple (PCon "TPlus") (PCon "TPlus")) () (EVar "True")) (arm (PTuple (PCon "TMinus") (PCon "TMinus")) () (EVar "True")) (arm (PTuple (PCon "TMinusTight") (PCon "TMinusTight")) () (EVar "True")) (arm (PTuple (PCon "TStar") (PCon "TStar")) () (EVar "True")) (arm (PTuple (PCon "TSlash") (PCon "TSlash")) () (EVar "True")) (arm (PTuple (PCon "TMod") (PCon "TMod")) () (EVar "True")) (arm (PTuple (PCon "TEqEq") (PCon "TEqEq")) () (EVar "True")) (arm (PTuple (PCon "TNeq") (PCon "TNeq")) () (EVar "True")) (arm (PTuple (PCon "TBangEq") (PCon "TBangEq")) () (EVar "True")) (arm (PTuple (PCon "TLt") (PCon "TLt")) () (EVar "True")) (arm (PTuple (PCon "TGt") (PCon "TGt")) () (EVar "True")) (arm (PTuple (PCon "TLeq") (PCon "TLeq")) () (EVar "True")) (arm (PTuple (PCon "TGeq") (PCon "TGeq")) () (EVar "True")) (arm (PTuple (PCon "TAnd") (PCon "TAnd")) () (EVar "True")) (arm (PTuple (PCon "TOr") (PCon "TOr")) () (EVar "True")) (arm (PTuple (PCon "TCons") (PCon "TCons")) () (EVar "True")) (arm (PTuple (PCon "TPlusPlus") (PCon "TPlusPlus")) () (EVar "True")) (arm (PTuple (PCon "TPipeRight") (PCon "TPipeRight")) () (EVar "True")) (arm (PTuple (PCon "TRCompose") (PCon "TRCompose")) () (EVar "True")) (arm (PTuple (PCon "TLCompose") (PCon "TLCompose")) () (EVar "True")) (arm (PTuple (PCon "TFatArrow") (PCon "TFatArrow")) () (EVar "True")) (arm (PTuple (PCon "TArrow") (PCon "TArrow")) () (EVar "True")) (arm (PTuple (PCon "TLArrow") (PCon "TLArrow")) () (EVar "True")) (arm (PTuple (PCon "TAt") (PCon "TAt")) () (EVar "True")) (arm (PTuple (PCon "TBang") (PCon "TBang")) () (EVar "True")) (arm (PTuple (PCon "TAsAt") (PCon "TAsAt")) () (EVar "True")) (arm (PTuple (PCon "TEqual") (PCon "TEqual")) () (EVar "True")) (arm (PTuple (PCon "TColon") (PCon "TColon")) () (EVar "True")) (arm (PTuple (PCon "TColonEq") (PCon "TColonEq")) () (EVar "True")) (arm (PTuple (PCon "TComma") (PCon "TComma")) () (EVar "True")) (arm (PTuple (PCon "TDot") (PCon "TDot")) () (EVar "True")) (arm (PTuple (PCon "TPipe") (PCon "TPipe")) () (EVar "True")) (arm (PTuple (PCon "TUnderscore") (PCon "TUnderscore")) () (EVar "True")) (arm (PTuple (PCon "TLParen") (PCon "TLParen")) () (EVar "True")) (arm (PTuple (PCon "TRParen") (PCon "TRParen")) () (EVar "True")) (arm (PTuple (PCon "TLBracket") (PCon "TLBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBracketTight") (PCon "TLBracketTight")) () (EVar "True")) (arm (PTuple (PCon "TRBracket") (PCon "TRBracket")) () (EVar "True")) (arm (PTuple (PCon "TLBrace") (PCon "TLBrace")) () (EVar "True")) (arm (PTuple (PCon "TRBrace") (PCon "TRBrace")) () (EVar "True")) (arm (PTuple (PCon "TLArray") (PCon "TLArray")) () (EVar "True")) (arm (PTuple (PCon "TRArray") (PCon "TRArray")) () (EVar "True")) (arm (PTuple (PCon "TDotLBrace") (PCon "TDotLBrace")) () (EVar "True")) (arm (PTuple (PCon "TDotStar") (PCon "TDotStar")) () (EVar "True")) (arm (PTuple (PCon "TEllipsis") (PCon "TEllipsis")) () (EVar "True")) (arm (PTuple (PCon "TDotDot") (PCon "TDotDot")) () (EVar "True")) (arm (PTuple (PCon "TDotDotEq") (PCon "TDotDotEq")) () (EVar "True")) (arm (PTuple (PCon "TNewline") (PCon "TNewline")) () (EVar "True")) (arm (PTuple (PCon "TIndent") (PCon "TIndent")) () (EVar "True")) (arm (PTuple (PCon "TDedent") (PCon "TDedent")) () (EVar "True")) (arm (PTuple (PCon "TEof") (PCon "TEof")) () (EVar "True")) (arm (PTuple (PCon "TLexError" (PVar "__a0")) (PCon "TLexError" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "tokenToString" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenToString" ((PCon "TInt" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "INT ")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "tokenToString" ((PCon "TWideInt" (PVar "hi") (PVar "lo") PWild)) (EBinOp "++" (ELit (LString "INT 0x")) (EApp (EApp (EVar "u64HalvesHex") (EVar "hi")) (EVar "lo"))))
(DFunDef false "tokenToString" ((PCon "TFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "FLOAT ")) (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "tokenToString" ((PCon "TString" (PVar "s"))) (EBinOp "++" (ELit (LString "STRING ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TChar" (PVar "s"))) (EBinOp "++" (ELit (LString "CHAR ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "True"))) (ELit (LString "BOOL true")))
(DFunDef false "tokenToString" ((PCon "TBool" (PCon "False"))) (ELit (LString "BOOL false")))
(DFunDef false "tokenToString" ((PCon "TInterpOpen" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_OPEN ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpMid" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_MID ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TInterpEnd" (PVar "s"))) (EBinOp "++" (ELit (LString "INTERP_END ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (ELit (LString "UPPER ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (ELit (LString "BACKTICK_IDENT ")) (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "tokenToString" ((PCon "TLet")) (ELit (LString "LET")))
(DFunDef false "tokenToString" ((PCon "TRec")) (ELit (LString "REC")))
(DFunDef false "tokenToString" ((PCon "TWith")) (ELit (LString "WITH")))
(DFunDef false "tokenToString" ((PCon "TMut")) (ELit (LString "MUT")))
(DFunDef false "tokenToString" ((PCon "TIn")) (ELit (LString "IN")))
(DFunDef false "tokenToString" ((PCon "TIf")) (ELit (LString "IF")))
(DFunDef false "tokenToString" ((PCon "TThen")) (ELit (LString "THEN")))
(DFunDef false "tokenToString" ((PCon "TElse")) (ELit (LString "ELSE")))
(DFunDef false "tokenToString" ((PCon "TMatch")) (ELit (LString "MATCH")))
(DFunDef false "tokenToString" ((PCon "TData")) (ELit (LString "DATA")))
(DFunDef false "tokenToString" ((PCon "TInterface")) (ELit (LString "INTERFACE")))
(DFunDef false "tokenToString" ((PCon "TDefault")) (ELit (LString "DEFAULT")))
(DFunDef false "tokenToString" ((PCon "TImpl")) (ELit (LString "IMPL")))
(DFunDef false "tokenToString" ((PCon "TImport")) (ELit (LString "IMPORT")))
(DFunDef false "tokenToString" ((PCon "TExport")) (ELit (LString "EXPORT")))
(DFunDef false "tokenToString" ((PCon "TPublic")) (ELit (LString "PUBLIC")))
(DFunDef false "tokenToString" ((PCon "TWhere")) (ELit (LString "WHERE")))
(DFunDef false "tokenToString" ((PCon "TOf")) (ELit (LString "OF")))
(DFunDef false "tokenToString" ((PCon "TRequires")) (ELit (LString "REQUIRES")))
(DFunDef false "tokenToString" ((PCon "TDo")) (ELit (LString "DO")))
(DFunDef false "tokenToString" ((PCon "TDefer")) (ELit (LString "DEFER")))
(DFunDef false "tokenToString" ((PCon "TAs")) (ELit (LString "AS")))
(DFunDef false "tokenToString" ((PCon "TExtern")) (ELit (LString "EXTERN")))
(DFunDef false "tokenToString" ((PCon "TDeriving")) (ELit (LString "DERIVING")))
(DFunDef false "tokenToString" ((PCon "TType")) (ELit (LString "TYPE")))
(DFunDef false "tokenToString" ((PCon "TNewtype")) (ELit (LString "NEWTYPE")))
(DFunDef false "tokenToString" ((PCon "TProp")) (ELit (LString "PROP")))
(DFunDef false "tokenToString" ((PCon "TTest")) (ELit (LString "TEST")))
(DFunDef false "tokenToString" ((PCon "TBench")) (ELit (LString "BENCH")))
(DFunDef false "tokenToString" ((PCon "TEffect")) (ELit (LString "EFFECT")))
(DFunDef false "tokenToString" ((PCon "TFunction")) (ELit (LString "FUNCTION")))
(DFunDef false "tokenToString" ((PCon "TPlus")) (ELit (LString "PLUS")))
(DFunDef false "tokenToString" ((PCon "TMinus")) (ELit (LString "MINUS")))
(DFunDef false "tokenToString" ((PCon "TMinusTight")) (ELit (LString "MINUS_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TStar")) (ELit (LString "STAR")))
(DFunDef false "tokenToString" ((PCon "TSlash")) (ELit (LString "SLASH")))
(DFunDef false "tokenToString" ((PCon "TMod")) (ELit (LString "MOD")))
(DFunDef false "tokenToString" ((PCon "TEqEq")) (ELit (LString "EQ_EQ")))
(DFunDef false "tokenToString" ((PCon "TNeq")) (ELit (LString "NEQ")))
(DFunDef false "tokenToString" ((PCon "TBangEq")) (ELit (LString "BANGEQ")))
(DFunDef false "tokenToString" ((PCon "TLt")) (ELit (LString "LT")))
(DFunDef false "tokenToString" ((PCon "TGt")) (ELit (LString "GT")))
(DFunDef false "tokenToString" ((PCon "TLeq")) (ELit (LString "LEQ")))
(DFunDef false "tokenToString" ((PCon "TGeq")) (ELit (LString "GEQ")))
(DFunDef false "tokenToString" ((PCon "TAnd")) (ELit (LString "AND")))
(DFunDef false "tokenToString" ((PCon "TOr")) (ELit (LString "OR")))
(DFunDef false "tokenToString" ((PCon "TCons")) (ELit (LString "CONS")))
(DFunDef false "tokenToString" ((PCon "TPlusPlus")) (ELit (LString "PLUSPLUS")))
(DFunDef false "tokenToString" ((PCon "TPipeRight")) (ELit (LString "PIPE_RIGHT")))
(DFunDef false "tokenToString" ((PCon "TRCompose")) (ELit (LString "RCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TLCompose")) (ELit (LString "LCOMPOSE")))
(DFunDef false "tokenToString" ((PCon "TFatArrow")) (ELit (LString "FAT_ARROW")))
(DFunDef false "tokenToString" ((PCon "TArrow")) (ELit (LString "ARROW")))
(DFunDef false "tokenToString" ((PCon "TLArrow")) (ELit (LString "LARROW")))
(DFunDef false "tokenToString" ((PCon "TAt")) (ELit (LString "AT")))
(DFunDef false "tokenToString" ((PCon "TBang")) (ELit (LString "BANG")))
(DFunDef false "tokenToString" ((PCon "TAsAt")) (ELit (LString "AS_AT")))
(DFunDef false "tokenToString" ((PCon "TEqual")) (ELit (LString "EQUAL")))
(DFunDef false "tokenToString" ((PCon "TColon")) (ELit (LString "COLON")))
(DFunDef false "tokenToString" ((PCon "TColonEq")) (ELit (LString "COLONEQ")))
(DFunDef false "tokenToString" ((PCon "TComma")) (ELit (LString "COMMA")))
(DFunDef false "tokenToString" ((PCon "TDot")) (ELit (LString "DOT")))
(DFunDef false "tokenToString" ((PCon "TPipe")) (ELit (LString "PIPE")))
(DFunDef false "tokenToString" ((PCon "TUnderscore")) (ELit (LString "UNDERSCORE")))
(DFunDef false "tokenToString" ((PCon "TLParen")) (ELit (LString "LPAREN")))
(DFunDef false "tokenToString" ((PCon "TRParen")) (ELit (LString "RPAREN")))
(DFunDef false "tokenToString" ((PCon "TLBracket")) (ELit (LString "LBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBracketTight")) (ELit (LString "LBRACKET_TIGHT")))
(DFunDef false "tokenToString" ((PCon "TRBracket")) (ELit (LString "RBRACKET")))
(DFunDef false "tokenToString" ((PCon "TLBrace")) (ELit (LString "LBRACE")))
(DFunDef false "tokenToString" ((PCon "TRBrace")) (ELit (LString "RBRACE")))
(DFunDef false "tokenToString" ((PCon "TLArray")) (ELit (LString "LARRAY")))
(DFunDef false "tokenToString" ((PCon "TRArray")) (ELit (LString "RARRAY")))
(DFunDef false "tokenToString" ((PCon "TDotLBrace")) (ELit (LString "DOT_LBRACE")))
(DFunDef false "tokenToString" ((PCon "TDotStar")) (ELit (LString "DOT_STAR")))
(DFunDef false "tokenToString" ((PCon "TEllipsis")) (ELit (LString "ELLIPSIS")))
(DFunDef false "tokenToString" ((PCon "TDotDot")) (ELit (LString "DOTDOT")))
(DFunDef false "tokenToString" ((PCon "TDotDotEq")) (ELit (LString "DOTDOT_EQ")))
(DFunDef false "tokenToString" ((PCon "TNewline")) (ELit (LString "NEWLINE")))
(DFunDef false "tokenToString" ((PCon "TIndent")) (ELit (LString "INDENT")))
(DFunDef false "tokenToString" ((PCon "TDedent")) (ELit (LString "DEDENT")))
(DFunDef false "tokenToString" ((PCon "TEof")) (ELit (LString "EOF")))
(DFunDef false "tokenToString" ((PCon "TLexError" (PVar "s"))) (EBinOp "++" (ELit (LString "LEX_ERROR ")) (EApp (EVar "debugStringLit") (EApp (EVar "renderParseProblem") (EVar "s")))))
(DTypeSig true "describeToken" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "describeToken" ((PCon "TInt" PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TWideInt" PWild PWild PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TFloat" PWild)) (ELit (LString "a number")))
(DFunDef false "describeToken" ((PCon "TString" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TChar" PWild)) (ELit (LString "a character literal")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "True"))) (ELit (LString "`true`")))
(DFunDef false "describeToken" ((PCon "TBool" (PCon "False"))) (ELit (LString "`false`")))
(DFunDef false "describeToken" ((PCon "TInterpOpen" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpMid" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TInterpEnd" PWild)) (ELit (LString "a string")))
(DFunDef false "describeToken" ((PCon "TIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TUpper" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TBacktickIdent" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "s")) (ELit (LString "`"))))
(DFunDef false "describeToken" ((PCon "TLet")) (ELit (LString "`let`")))
(DFunDef false "describeToken" ((PCon "TRec")) (ELit (LString "`rec`")))
(DFunDef false "describeToken" ((PCon "TWith")) (ELit (LString "`with`")))
(DFunDef false "describeToken" ((PCon "TMut")) (ELit (LString "`mut`")))
(DFunDef false "describeToken" ((PCon "TIn")) (ELit (LString "`in`")))
(DFunDef false "describeToken" ((PCon "TIf")) (ELit (LString "`if`")))
(DFunDef false "describeToken" ((PCon "TThen")) (ELit (LString "`then`")))
(DFunDef false "describeToken" ((PCon "TElse")) (ELit (LString "`else`")))
(DFunDef false "describeToken" ((PCon "TMatch")) (ELit (LString "`match`")))
(DFunDef false "describeToken" ((PCon "TData")) (ELit (LString "`data`")))
(DFunDef false "describeToken" ((PCon "TInterface")) (ELit (LString "`interface`")))
(DFunDef false "describeToken" ((PCon "TDefault")) (ELit (LString "`default`")))
(DFunDef false "describeToken" ((PCon "TImpl")) (ELit (LString "`impl`")))
(DFunDef false "describeToken" ((PCon "TImport")) (ELit (LString "`import`")))
(DFunDef false "describeToken" ((PCon "TExport")) (ELit (LString "`export`")))
(DFunDef false "describeToken" ((PCon "TPublic")) (ELit (LString "`public`")))
(DFunDef false "describeToken" ((PCon "TWhere")) (ELit (LString "`where`")))
(DFunDef false "describeToken" ((PCon "TOf")) (ELit (LString "`of`")))
(DFunDef false "describeToken" ((PCon "TRequires")) (ELit (LString "`requires`")))
(DFunDef false "describeToken" ((PCon "TDo")) (ELit (LString "`do`")))
(DFunDef false "describeToken" ((PCon "TDefer")) (ELit (LString "`defer`")))
(DFunDef false "describeToken" ((PCon "TAs")) (ELit (LString "`as`")))
(DFunDef false "describeToken" ((PCon "TExtern")) (ELit (LString "`extern`")))
(DFunDef false "describeToken" ((PCon "TDeriving")) (ELit (LString "`deriving`")))
(DFunDef false "describeToken" ((PCon "TType")) (ELit (LString "`type`")))
(DFunDef false "describeToken" ((PCon "TNewtype")) (ELit (LString "`newtype`")))
(DFunDef false "describeToken" ((PCon "TProp")) (ELit (LString "`prop`")))
(DFunDef false "describeToken" ((PCon "TTest")) (ELit (LString "`test`")))
(DFunDef false "describeToken" ((PCon "TBench")) (ELit (LString "`bench`")))
(DFunDef false "describeToken" ((PCon "TEffect")) (ELit (LString "`effect`")))
(DFunDef false "describeToken" ((PCon "TFunction")) (ELit (LString "`function`")))
(DFunDef false "describeToken" ((PCon "TPlus")) (ELit (LString "`+`")))
(DFunDef false "describeToken" ((PCon "TMinus")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TMinusTight")) (ELit (LString "`-`")))
(DFunDef false "describeToken" ((PCon "TStar")) (ELit (LString "`*`")))
(DFunDef false "describeToken" ((PCon "TSlash")) (ELit (LString "`/`")))
(DFunDef false "describeToken" ((PCon "TMod")) (ELit (LString "`%`")))
(DFunDef false "describeToken" ((PCon "TEqEq")) (ELit (LString "`==`")))
(DFunDef false "describeToken" ((PCon "TNeq")) (ELit (LString "`/=`")))
(DFunDef false "describeToken" ((PCon "TBangEq")) (ELit (LString "`!=`")))
(DFunDef false "describeToken" ((PCon "TLt")) (ELit (LString "`<`")))
(DFunDef false "describeToken" ((PCon "TGt")) (ELit (LString "`>`")))
(DFunDef false "describeToken" ((PCon "TLeq")) (ELit (LString "`<=`")))
(DFunDef false "describeToken" ((PCon "TGeq")) (ELit (LString "`>=`")))
(DFunDef false "describeToken" ((PCon "TAnd")) (ELit (LString "`&&`")))
(DFunDef false "describeToken" ((PCon "TOr")) (ELit (LString "`||`")))
(DFunDef false "describeToken" ((PCon "TCons")) (ELit (LString "`::`")))
(DFunDef false "describeToken" ((PCon "TPlusPlus")) (ELit (LString "`++`")))
(DFunDef false "describeToken" ((PCon "TPipeRight")) (ELit (LString "`|>`")))
(DFunDef false "describeToken" ((PCon "TRCompose")) (ELit (LString "`>>`")))
(DFunDef false "describeToken" ((PCon "TLCompose")) (ELit (LString "`<<`")))
(DFunDef false "describeToken" ((PCon "TFatArrow")) (ELit (LString "`=>`")))
(DFunDef false "describeToken" ((PCon "TArrow")) (ELit (LString "`->`")))
(DFunDef false "describeToken" ((PCon "TLArrow")) (ELit (LString "`<-`")))
(DFunDef false "describeToken" ((PCon "TAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TBang")) (ELit (LString "`!`")))
(DFunDef false "describeToken" ((PCon "TAsAt")) (ELit (LString "`@`")))
(DFunDef false "describeToken" ((PCon "TEqual")) (ELit (LString "`=`")))
(DFunDef false "describeToken" ((PCon "TColon")) (ELit (LString "`:`")))
(DFunDef false "describeToken" ((PCon "TColonEq")) (ELit (LString "`:=`")))
(DFunDef false "describeToken" ((PCon "TComma")) (ELit (LString "`,`")))
(DFunDef false "describeToken" ((PCon "TDot")) (ELit (LString "`.`")))
(DFunDef false "describeToken" ((PCon "TPipe")) (ELit (LString "`|`")))
(DFunDef false "describeToken" ((PCon "TUnderscore")) (ELit (LString "`_`")))
(DFunDef false "describeToken" ((PCon "TLParen")) (ELit (LString "`(`")))
(DFunDef false "describeToken" ((PCon "TRParen")) (ELit (LString "`)`")))
(DFunDef false "describeToken" ((PCon "TLBracket")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TLBracketTight")) (ELit (LString "`[`")))
(DFunDef false "describeToken" ((PCon "TRBracket")) (ELit (LString "`]`")))
(DFunDef false "describeToken" ((PCon "TLBrace")) (ELit (LString "`{`")))
(DFunDef false "describeToken" ((PCon "TRBrace")) (ELit (LString "`}`")))
(DFunDef false "describeToken" ((PCon "TLArray")) (ELit (LString "`[|`")))
(DFunDef false "describeToken" ((PCon "TRArray")) (ELit (LString "`|]`")))
(DFunDef false "describeToken" ((PCon "TDotLBrace")) (ELit (LString "`.{`")))
(DFunDef false "describeToken" ((PCon "TDotStar")) (ELit (LString "`.*`")))
(DFunDef false "describeToken" ((PCon "TEllipsis")) (ELit (LString "`...`")))
(DFunDef false "describeToken" ((PCon "TDotDot")) (ELit (LString "`..`")))
(DFunDef false "describeToken" ((PCon "TDotDotEq")) (ELit (LString "`..=`")))
(DFunDef false "describeToken" ((PCon "TNewline")) (ELit (LString "a line break")))
(DFunDef false "describeToken" ((PCon "TIndent")) (ELit (LString "an indent")))
(DFunDef false "describeToken" ((PCon "TDedent")) (ELit (LString "a dedent")))
(DFunDef false "describeToken" ((PCon "TEof")) (ELit (LString "end of input")))
(DFunDef false "describeToken" ((PCon "TLexError" (PVar "s"))) (EApp (EVar "renderParseProblem") (EVar "s")))
(DData Public "RawTok" () ((variant "RTok" (ConPos (TyCon "Token") (TyCon "Int") (TyCon "Int"))) (variant "RTripleInterpOpen" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int"))) (variant "RNewline" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RComment" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RClauseNl" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "RClauseOpen" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "isNoiseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNoiseTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isNoiseTok" (PWild) (EVar "False"))
(DTypeSig true "isColonTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isColonTok" ((PCon "TColon")) (EVar "True"))
(DFunDef false "isColonTok" (PWild) (EVar "False"))
(DTypeSig true "isConsTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isConsTok" ((PCon "TCons")) (EVar "True"))
(DFunDef false "isConsTok" (PWild) (EVar "False"))
(DTypeSig true "isDedentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isDedentTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isDedentTok" (PWild) (EVar "False"))
(DTypeSig true "isDeferTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isDeferTok" ((PCon "TDefer")) (EVar "True"))
(DFunDef false "isDeferTok" (PWild) (EVar "False"))
(DTypeSig true "isEofTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isEofTok" ((PCon "TEof")) (EVar "True"))
(DFunDef false "isEofTok" (PWild) (EVar "False"))
(DTypeSig true "isEqualTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isEqualTok" ((PCon "TEqual")) (EVar "True"))
(DFunDef false "isEqualTok" (PWild) (EVar "False"))
(DTypeSig true "isExportTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isExportTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isExportTok" (PWild) (EVar "False"))
(DTypeSig true "isImplTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isImplTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isImplTok" (PWild) (EVar "False"))
(DTypeSig true "isInTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isInTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isInTok" (PWild) (EVar "False"))
(DTypeSig true "isIndentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isIndentTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isIndentTok" (PWild) (EVar "False"))
(DTypeSig true "isLBraceTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLBraceTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isLBraceTok" (PWild) (EVar "False"))
(DTypeSig true "isLetTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLetTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isLetTok" (PWild) (EVar "False"))
(DTypeSig true "isNewlineTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNewlineTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNewlineTok" (PWild) (EVar "False"))
(DTypeSig true "isOfTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOfTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isOfTok" (PWild) (EVar "False"))
(DTypeSig true "isPipeTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPipeTok" ((PCon "TPipe")) (EVar "True"))
(DFunDef false "isPipeTok" (PWild) (EVar "False"))
(DTypeSig true "isPublicTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPublicTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isPublicTok" (PWild) (EVar "False"))
(DTypeSig true "isRBraceTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isRBraceTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isRBraceTok" (PWild) (EVar "False"))
(DTypeSig true "isRequiresTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isRequiresTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isRequiresTok" (PWild) (EVar "False"))
(DTypeSig true "isStarTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isStarTok" ((PCon "TStar")) (EVar "True"))
(DFunDef false "isStarTok" (PWild) (EVar "False"))
(DTypeSig true "isWhereTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isWhereTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isWhereTok" (PWild) (EVar "False"))
(DTypeSig true "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" () (EVar "isNoiseTok"))
(DTypeSig true "isOpenDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpenDelim" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "isOpenDelim" (PWild) (EVar "False"))
(DTypeSig true "isCloseDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCloseDelim" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "isCloseDelim" (PWild) (EVar "False"))
(DTypeSig true "isTStringTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTStringTok" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "isTStringTok" (PWild) (EVar "False"))
(DTypeSig true "isTUpperTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTUpperTok" ((PCon "TUpper" PWild)) (EVar "True"))
(DFunDef false "isTUpperTok" (PWild) (EVar "False"))
(DTypeSig true "isCommaTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCommaTok" ((PCon "TComma")) (EVar "True"))
(DFunDef false "isCommaTok" (PWild) (EVar "False"))
(DTypeSig true "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
