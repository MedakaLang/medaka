# META
source_lines=506
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_diagnostic.{ParseDiagnosticKind(..), UnicodeProblem(..)}
import frontend.lex_token.{Token(..), RawTok(..)}
import support.char.{isQuote, isApos, isBackslash, isNL, isCR, isHexDigit}
import support.util.{joinWith}
import list.{reverse}
import string.{concat}

public export data LiteralFlavor = PlainLiteral | TripleLiteral
public export data LiteralPart = InitialLiteral | ContinuedLiteral
public export data LexError = LexError ParseDiagnosticKind Int Int
public export data LiteralCursor = LiteralCursor {
  literalPosition : Int,
  literalQuoteOpen : Int,
  literalFlavor : LiteralFlavor,
  literalPart : LiteralPart,
  literalLeadingRawLf : Bool,
  literalInsideHole : Bool,
}
public export data LiteralStop = LiteralClose | LiteralHole
public export data LiteralRead = LiteralRead String Int LiteralStop Bool

at : Array Char -> Int -> Char
at src i = arrayGetUnsafe i src

export
copyCharRange : Array Char -> Int -> Int -> String
copyCharRange src start endp
  | endp <= start = ""
  | otherwise =
    let out = arrayMake (endp - start) (at src start)
    let _ = arrayBlit src start out 0 (endp - start)
    stringFromChars out

commonEscDecode : Char -> Option String
commonEscDecode e
  | e == 'n' = Some "\n"
  | e == 't' = Some "\t"
  | e == 'r' = Some "\r"
  | e == '0' = Some (charToStr (optionOr ' ' (charFromCode 0)))
  | isBackslash e = Some "\\"
  | isQuote e = Some "\""
  | otherwise = None

stripIndent : String -> String
stripIndent s =
  let cs = stringToChars s
  stripIndentCs s cs (arrayLength cs)

stripIndentCs : String -> Array Char -> Int -> String
stripIndentCs s cs n
  | n == 0 = s
  | at cs 0 /= '\n' = s
  | otherwise =
    let lines = splitLines cs 1 n
    let minInd = normalizeMin (minIndentGo lines indentSentinel)
    joinNlStr (stripLines minInd lines)

splitLines : Array Char -> Int -> Int -> List String
splitLines cs p n = splitRange cs p p n

indentSentinel : Int
indentSentinel = 1000000000

indentOf : String -> Int
indentOf line =
  let cs = stringToChars line
  indentOfGo cs (arrayLength cs) 0

indentOfGo : Array Char -> Int -> Int -> Int
indentOfGo cs n i
  | i >= n = indentSentinel
  | at cs i == ' ' = indentOfGo cs n (i + 1)
  | otherwise = i

minIndentGo : List String -> Int -> Int
minIndentGo [] acc = acc
minIndentGo (l :: rest) acc = minIndentGo rest (min acc (indentOf l))

normalizeMin : Int -> Int
normalizeMin m = if m == indentSentinel then 0 else m

stripLines : Int -> List String -> List String
stripLines k ls = map (stripLine k) ls

stripLine : Int -> String -> String
stripLine k line =
  let cs = stringToChars line
  let n = arrayLength cs
  dropCharsToStr cs (min k n) n

dropCharsToStr : Array Char -> Int -> Int -> String
dropCharsToStr cs k n = copyCharRange cs k n

joinNlStr : List String -> String
joinNlStr xs = joinWith "\n" xs

startsWithNl : String -> Bool
startsWithNl s =
  let cs = stringToChars s
  arrayLength cs > 0 && at cs 0 == '\n'

endsWithNl : String -> Bool
endsWithNl s =
  let cs = stringToChars s
  let n = arrayLength cs
  n > 0 && at cs (n - 1) == '\n'

computeMinIndent : String -> Int
computeMinIndent joined =
  let cs = stringToChars joined
  let n = arrayLength cs
  -- position 1: the leading '\n' (guaranteed present) is dropped, same as
  -- `stripIndentCs` does for the single-segment case.
  normalizeMin (minIndentGo (splitLines cs 1 n) indentSentinel)

dedentGroupSegs : Int -> List String -> List String
dedentGroupSegs minInd (openStr :: rest) =
  let cs = stringToChars openStr
  let openLines = splitLines cs 1 (arrayLength cs)
  let openOut = joinNlStr (stripLines minInd openLines)
  openOut :: dedentRestSegs minInd (endsWithNl openStr) rest
dedentGroupSegs _ [] = []

dedentRestSegs : Int -> Bool -> List String -> List String
dedentRestSegs _ _ [] = []
dedentRestSegs minInd atLineStart (seg :: rest) =
  let cs = stringToChars seg
  let lines = splitLines cs 0 (arrayLength cs)
  let out = joinNlStr (stripFirstAware minInd atLineStart lines)
  out :: dedentRestSegs minInd (endsWithNl seg) rest

stripFirstAware : Int -> Bool -> List String -> List String
stripFirstAware _ _ [] = []
stripFirstAware minInd True (l :: rest) =
  stripLine minInd l :: stripLines minInd rest
stripFirstAware minInd False (l :: rest) = l :: stripLines minInd rest

splitInterpGroup : List RawTok -> (List String, List RawTok, List RawTok)
splitInterpGroup [] = ([], [], [])
splitInterpGroup ((RTok (TInterpMid s) mo me) :: rest) =
  let (segs, mid, after) = splitInterpGroup rest
  (s :: segs, RTok (TInterpMid s) mo me :: mid, after)
splitInterpGroup ((RTok (TInterpEnd s) eo ee) :: rest) =
  ([s], [RTok (TInterpEnd s) eo ee], rest)
splitInterpGroup (t :: rest) =
  let (segs, mid, after) = splitInterpGroup rest
  (segs, t :: mid, after)

substituteOwn : List String -> List RawTok -> List RawTok
substituteOwn _ [] = []
substituteOwn (v :: vs) ((RTok (TInterpMid _) mo me) :: rest) =
  RTok (TInterpMid v) mo me :: substituteOwn vs rest
substituteOwn (v :: vs) ((RTok (TInterpEnd _) eo ee) :: rest) =
  RTok (TInterpEnd v) eo ee :: substituteOwn vs rest
substituteOwn vals (t :: rest) = t :: substituteOwn vals rest
substituteOwn [] (t :: rest) = t :: substituteOwn [] rest

export
dedentTripleInterp : List RawTok -> List RawTok
dedentTripleInterp toks
  | hasTripleInterpOpen toks = dedentTripleGo toks
  | otherwise = toks

hasTripleInterpOpen : List RawTok -> Bool
hasTripleInterpOpen [] = False
hasTripleInterpOpen ((RTripleInterpOpen _ _ _) :: _) = True
hasTripleInterpOpen (_ :: rest) = hasTripleInterpOpen rest

dedentTripleGo : List RawTok -> List RawTok
dedentTripleGo [] = []
dedentTripleGo ((RTripleInterpOpen s so eo) :: rest) =
  let (rawSegs, midToks, afterEnd) = splitInterpGroup rest
  dedentTripleGroup s so eo rawSegs midToks afterEnd
dedentTripleGo (t :: rest) = t :: dedentTripleGo rest

dedentTripleGroup : String ->
  Int ->
  Int ->
  List String ->
  List RawTok ->
  List RawTok ->
  List RawTok
dedentTripleGroup sReal so eo rawSegs midToks afterEnd
  | startsWithNl sReal =
    let allRaw = sReal :: rawSegs
    let minInd = computeMinIndent (concat allRaw)
    match dedentGroupSegs minInd allRaw
      openStr' :: restVals =>
        RTok (TInterpOpen openStr') so eo
          :: substituteOwn restVals midToks ++ dedentTripleGo afterEnd
      [] => RTok (TInterpOpen sReal) so eo :: midToks ++ dedentTripleGo afterEnd
  | otherwise =
    RTok (TInterpOpen sReal) so eo :: midToks ++ dedentTripleGo afterEnd

finish : List String -> String
finish [] = ""
finish [s] = s
finish xs = concat (reverse xs)
firstFragNl : Bool -> List String -> Bool
firstFragNl leading [] = True
firstFragNl leading _ = leading
splitRange : Array Char -> Int -> Int -> Int -> List String
splitRange cs start p n
  | p >= n = [copyCharRange cs start n]
  | at cs p == '\n' =
    copyCharRange cs start p :: splitRange cs (p + 1) (p + 1) n
  | otherwise = splitRange cs start (p + 1) n

tripleRunEnd : Array Char -> Int -> Int -> Int
tripleRunEnd src len p
  | p >= len = len
  | isQuote (at src p) || isBackslash (at src p) || isNL (at src p) = p
  | otherwise = tripleRunEnd src len (p + 1)

uniEscWellFormed : Array Char -> Int -> Int -> Bool
uniEscWellFormed src len p =
  let s = p + 3
  let he = uHexEnd src len s
  he > s && he < len && at src he == '}'

uniHexSigLen : Array Char -> Int -> Int -> Int
uniHexSigLen src p endp
  | p >= endp = 0
  | at src p == '0' = uniHexSigLen src (p + 1) endp
  | otherwise = endp - p

uniEscCode : Array Char -> Int -> Int -> Option Int
uniEscCode src len p =
  let s = p + 3
  let he = uHexEnd src len s
  if uniHexSigLen src s he > 6 then None else Some (parseHex src s he 0)

uniEscText : Array Char -> Int -> Int -> String
uniEscText src len p = copyCharRange src p (uHexEnd src len (p + 3) + 1)

uniEscChar : Array Char -> Int -> Int -> Option Char
uniEscChar src len p
  | not (uniEscWellFormed src len p) = None
  | otherwise = match uniEscCode src len p
    None => None
    Some cp => charFromCode cp

uniIsSurrogate : Int -> Bool
uniIsSurrogate cp = cp >= 55296 && cp <= 57343

uniEscTermErr : Array Char ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Result LexError a
uniEscTermErr src len s he p endp
  | he >= len = lexFailure p endp (BadUnicodeEscape UnicodeUnterminated)
  | at src he == '_' = lexFailure p endp (BadUnicodeEscape UnicodeSeparator)
  | he == s && at src he == '}' =
    lexFailure p endp (BadUnicodeEscape UnicodeEmpty)
  | he == s =
    lexFailure
      p
      endp
      (BadUnicodeEscape (UnicodeExpectedDigit (charToStr (at src he))))
  | otherwise =
    lexFailure
      p
      endp
      (BadUnicodeEscape (UnicodeExpectedClose (charToStr (at src he))))

uniEscErr : Array Char -> Int -> Int -> Result LexError a
uniEscErr src len p =
  let endp = unicodeErrorEnd src len p
  if not (uniEscWellFormed src len p) then
    uniEscTermErr src len (p + 3) (uHexEnd src len (p + 3)) p endp
  else match uniEscCode src len p
    Some cp if uniIsSurrogate cp =>
      lexFailure
        p
        endp
        (BadUnicodeEscape (UnicodeSurrogate (uniEscText src len p)))
    _ =>
      lexFailure
        p
        endp
        (BadUnicodeEscape (UnicodeOutOfRange (uniEscText src len p)))

unicodeErrorEnd : Array Char -> Int -> Int -> Int
unicodeErrorEnd src len p = unicodeErrorEndGo src len (p + 3)

unicodeErrorEndGo : Array Char -> Int -> Int -> Int
unicodeErrorEndGo src len p
  | p >= len = len
  | at src p == '}' = p + 1
  | isQuote (at src p)
    || isApos (at src p)
    || isNL (at src p)
    || isCR (at src p) = p
  | otherwise = unicodeErrorEndGo src len (p + 1)

uHexEnd : Array Char -> Int -> Int -> Int
uHexEnd src len p
  | p < len && isHexDigit (at src p) = uHexEnd src len (p + 1)
  | otherwise = p

isBareUnicodeEsc : Array Char -> Int -> Int -> Char -> Bool
isBareUnicodeEsc src len p e =
  e == 'u'
    && p + 2 < len
    && isHexDigit (at src (p + 2))
    && uHexEnd src len (p + 2) - (p + 2) == 4

bareUnicodeEscWritten : Array Char -> Int -> Int -> String
bareUnicodeEscWritten src len p = copyCharRange src p (uHexEnd src len (p + 2))

bareUnicodeEscSuggested : Array Char -> Int -> Int -> String
bareUnicodeEscSuggested src len p =
  "\\u{\{copyCharRange src (p + 2) (uHexEnd src len (p + 2))}}"
bareUnicodeEscMsgStr : Array Char -> Int -> Int -> ParseDiagnosticKind
bareUnicodeEscMsgStr src len p =
  BareUnicodeEscape
    (bareUnicodeEscWritten src len p)
    (bareUnicodeEscSuggested src len p)

isUnicodeEsc : Array Char -> Int -> Int -> Char -> Bool
isUnicodeEsc src len p e = e == 'u' && p + 2 < len && at src (p + 2) == '{'

uniEscEnd : Array Char -> Int -> Int -> Int
uniEscEnd src len p = uHexEnd src len (p + 3) + 1

lexFailure : Int -> Int -> ParseDiagnosticKind -> Result LexError a
lexFailure start end kind = Err (LexError kind start end)

parseHex : Array Char -> Int -> Int -> Int -> Int
parseHex src p end acc
  | p >= end = acc
  | otherwise =
    let c = at src p
    let d =
      if c >= '0' && c <= '9' then
        charCode c - charCode '0'
      else if c >= 'a' && c <= 'f' then
        charCode c - charCode 'a' + 10
      else
        charCode c - charCode 'A' + 10
    parseHex src (p + 1) end (acc * 16 + d)

export
readLiteral : Array Char -> LiteralCursor -> Result LexError LiteralRead
readLiteral src (LiteralCursor p quote flavor part leading inside) =
  literalGo src (arrayLength src) p flavor part leading inside []

literalGo : Array Char ->
  Int ->
  Int ->
  LiteralFlavor ->
  LiteralPart ->
  Bool ->
  Bool ->
  List String ->
  Result LexError LiteralRead
literalGo src len p flavor part leading inside acc
  | p >= len = lexFailure p p UnterminatedString
  | isPlain flavor && isQuote (at src p) =
    Ok (LiteralRead (finish acc) (p + 1) LiteralClose leading)
  | not (isPlain flavor) && isTripleAt src len p =
    Ok (LiteralRead (finish acc) (p + 3) LiteralClose leading)
  | isBackslash (at src p) && p + 1 < len =
    literalEscape src len p flavor part leading inside acc (at src (p + 1))
  | isPlain flavor && isBackslash (at src p) && isInitial part =
    lexFailure p len UnterminatedString
  | not (isPlain flavor) && isNL (at src p) =
    literalGo
      src
      len
      (p + 1)
      flavor
      part
      (firstFragNl leading acc)
      inside
      ("\n" :: acc)
  | not (isPlain flavor) && isQuote (at src p) =
    literalGo src len (p + 1) flavor part leading inside ("\"" :: acc)
  | otherwise =
    let q =
      if isPlain flavor then
        plainRunEnd src len (p + 1)
      else
        tripleRunEnd src len (p + 1)
    literalGo
      src
      len
      q
      flavor
      part
      leading
      inside
      (copyCharRange src p q :: acc)

literalEscape : Array Char ->
  Int ->
  Int ->
  LiteralFlavor ->
  LiteralPart ->
  Bool ->
  Bool ->
  List String ->
  Char ->
  Result LexError LiteralRead
literalEscape src len p flavor part leading inside acc e
  | e == '{' && inside = lexFailure p (p + 2) NestedInterpolation
  | e == '{' = Ok (LiteralRead (finish acc) (p + 2) LiteralHole leading)
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => uniEscErr src len p
    Some c =>
      literalGo
        src
        len
        (uniEscEnd src len p)
        flavor
        part
        leading
        inside
        (charToStr c :: acc)
  | isBareUnicodeEsc src len p e =
    lexFailure p (uHexEnd src len (p + 2)) (bareUnicodeEscMsgStr src len p)
  | otherwise = match commonEscDecode e
    Some s => literalGo src len (p + 2) flavor part leading inside (s :: acc)
    None => lexFailure p (p + 2) (InvalidEscape ("\\" ++ charToStr e) False)

isTripleAt : Array Char -> Int -> Int -> Bool
isTripleAt src len p =
  p + 2 < len
    && isQuote (at src p)
    && isQuote (at src (p + 1))
    && isQuote (at src (p + 2))

plainRunEnd : Array Char -> Int -> Int -> Int
plainRunEnd src len p
  | p >= len = len
  | isQuote (at src p) || isBackslash (at src p) = p
  | otherwise = plainRunEnd src len (p + 1)

export
readCharacter : Array Char -> Int -> Result LexError (String, Int)
readCharacter src pos = charRead src (arrayLength src) (pos + 1)

charRead : Array Char -> Int -> Int -> Result LexError (String, Int)
charRead src len p
  | p >= len = lexFailure (p - 1) len UnterminatedChar
  | isBackslash (at src p) && p + 1 >= len =
    lexFailure (p - 1) len UnterminatedChar
  | isBackslash (at src p) = charEscape src len p (at src (p + 1))
  | isApos (at src p) = lexFailure (p - 1) (p + 1) EmptyChar
  | p + 1 < len && isApos (at src (p + 1)) = Ok (charToStr (at src p), p + 2)
  | otherwise =
    let e = charClose src len p
    if e >= len then
      lexFailure (p - 1) len UnterminatedChar
    else
      lexFailure (p - 1) (e + 1) (LongChar (copyCharRange src p e))

charEscape : Array Char -> Int -> Int -> Char -> Result LexError (String, Int)
charEscape src len p e
  | isUnicodeEsc src len p e = match uniEscChar src len p
    None => uniEscErr src len p
    Some c => charFinished src len p (uniEscEnd src len p) (charToStr c)
  | isBareUnicodeEsc src len p e =
    lexFailure p (uHexEnd src len (p + 2)) (bareUnicodeEscMsgStr src len p)
  | otherwise = match if isApos e then Some "'" else commonEscDecode e
    None => lexFailure p (p + 2) (InvalidEscape ("\\" ++ charToStr e) True)
    Some s => charFinished src len p (p + 2) s

charFinished : Array Char ->
  Int ->
  Int ->
  Int ->
  String ->
  Result LexError (String, Int)
charFinished src len p end s =
  if end < len && isApos (at src end) then
    Ok (s, end + 1)
  else
    lexFailure (p - 1) len UnterminatedChar

charClose : Array Char -> Int -> Int -> Int
charClose src len p
  | p >= len = p
  | isApos (at src p) = p
  | otherwise = charClose src len (p + 1)

export
dedentSegments : List String -> List String
dedentSegments [] = []
dedentSegments [s] = [stripIndent s]
dedentSegments (segs@(first :: _)) =
  if startsWithNl first then
    dedentGroupSegs (computeMinIndent (concat segs)) segs
  else
    segs

isPlain : LiteralFlavor -> Bool
isPlain PlainLiteral = True
isPlain _ = False

isInitial : LiteralPart -> Bool
isInitial InitialLiteral = True
isInitial _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "UnicodeProblem" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true))))
(DUse false (UseGroup ("support" "char") ((mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isNL" false) (mem "isCR" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "concat" false))))
(DData Public "LiteralFlavor" () ((variant "PlainLiteral" (ConPos)) (variant "TripleLiteral" (ConPos))) ())
(DData Public "LiteralPart" () ((variant "InitialLiteral" (ConPos)) (variant "ContinuedLiteral" (ConPos))) ())
(DData Public "LexError" () ((variant "LexError" (ConPos (TyCon "ParseDiagnosticKind") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "LiteralCursor" () ((variant "LiteralCursor" (ConNamed (field "literalPosition" (TyCon "Int")) (field "literalQuoteOpen" (TyCon "Int")) (field "literalFlavor" (TyCon "LiteralFlavor")) (field "literalPart" (TyCon "LiteralPart")) (field "literalLeadingRawLf" (TyCon "Bool")) (field "literalInsideHole" (TyCon "Bool"))))) ())
(DData Public "LiteralStop" () ((variant "LiteralClose" (ConPos)) (variant "LiteralHole" (ConPos))) ())
(DData Public "LiteralRead" () ((variant "LiteralRead" (ConPos (TyCon "String") (TyCon "Int") (TyCon "LiteralStop") (TyCon "Bool")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig true "copyCharRange" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "copyCharRange" ((PVar "src") (PVar "start") (PVar "endp")) (EIf (EBinOp "<=" (EVar "endp") (EVar "start")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EVar "endp") (EVar "start"))) (EApp (EApp (EVar "at") (EVar "src")) (EVar "start")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "start")) (EVar "out")) (ELit (LInt 0))) (EBinOp "-" (EVar "endp") (EVar "start")))) (DoExpr (EApp (EVar "stringFromChars") (EVar "out")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "commonEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "commonEscDecode" ((PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LString "\n"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LString "\t"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LString "\r"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EVar "Some") (EApp (EVar "charToStr") (EApp (EApp (EVar "optionOr") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0)))))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\\"))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\""))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "stripIndent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripIndent" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stripIndentCs") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "stripIndentCs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripIndentCs" ((PVar "s") (PVar "cs") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EBinOp "/=" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n"))) (EVar "s") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n"))) (DoLet false false (PVar "minInd") (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EVar "lines")) (EVar "indentSentinel")))) (DoExpr (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "lines"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitLines" ((PVar "cs") (PVar "p") (PVar "n")) (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EVar "p")) (EVar "p")) (EVar "n")))
(DTypeSig false "indentSentinel" (TyCon "Int"))
(DFunDef false "indentSentinel" () (ELit (LInt 1000000000)))
(DTypeSig false "indentOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "indentOf" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "indentOfGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indentOfGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "indentSentinel") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minIndentGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minIndentGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minIndentGo" ((PCons (PVar "l") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minIndentGo") (EVar "rest")) (EApp (EApp (EVar "min") (EVar "acc")) (EApp (EVar "indentOf") (EVar "l")))))
(DTypeSig false "normalizeMin" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "normalizeMin" ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "indentSentinel")) (ELit (LInt 0)) (EVar "m")))
(DTypeSig false "stripLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stripLines" ((PVar "k") (PVar "ls")) (EApp (EApp (EVar "map") (EApp (EVar "stripLine") (EVar "k"))) (EVar "ls")))
(DTypeSig false "stripLine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripLine" ((PVar "k") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EApp (EApp (EVar "min") (EVar "k")) (EVar "n"))) (EVar "n")))))
(DTypeSig false "dropCharsToStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "dropCharsToStr" ((PVar "cs") (PVar "k") (PVar "n")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "k")) (EVar "n")))
(DTypeSig false "joinNlStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNlStr" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig false "startsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n")))))))
(DTypeSig false "endsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LChar "\n")))))))
(DTypeSig false "computeMinIndent" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "computeMinIndent" ((PVar "joined")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "joined"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n"))) (EVar "indentSentinel"))))))
(DTypeSig false "dedentGroupSegs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dedentGroupSegs" ((PVar "minInd") (PCons (PVar "openStr") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "openStr"))) (DoLet false false (PVar "openLines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoLet false false (PVar "openOut") (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "openLines")))) (DoExpr (EBinOp "::" (EVar "openOut") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "openStr"))) (EVar "rest"))))))
(DFunDef false "dedentGroupSegs" (PWild (PList)) (EListLit))
(DTypeSig false "dedentRestSegs" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dedentRestSegs" (PWild PWild (PList)) (EListLit))
(DFunDef false "dedentRestSegs" ((PVar "minInd") (PVar "atLineStart") (PCons (PVar "seg") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "seg"))) (DoLet false false (PVar "lines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoLet false false (PVar "out") (EApp (EVar "joinNlStr") (EApp (EApp (EApp (EVar "stripFirstAware") (EVar "minInd")) (EVar "atLineStart")) (EVar "lines")))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "seg"))) (EVar "rest"))))))
(DTypeSig false "stripFirstAware" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stripFirstAware" (PWild PWild (PList)) (EListLit))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "True") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "minInd")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "False") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DTypeSig false "splitInterpGroup" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "splitInterpGroup" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpMid" (PVar "s")) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "segs")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "mo")) (EVar "me")) (EVar "mid")) (EVar "after")))))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpEnd" (PVar "s")) (PVar "eo") (PVar "ee")) (PVar "rest"))) (ETuple (EListLit (EVar "s")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "s"))) (EVar "eo")) (EVar "ee"))) (EVar "rest")))
(DFunDef false "splitInterpGroup" ((PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EVar "segs") (EBinOp "::" (EVar "t") (EVar "mid")) (EVar "after")))))
(DTypeSig false "substituteOwn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "substituteOwn" (PWild (PList)) (EListLit))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpMid" PWild) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "v"))) (EVar "mo")) (EVar "me")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpEnd" PWild) (PVar "eo") (PVar "ee")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "v"))) (EVar "eo")) (EVar "ee")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PVar "vals") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EVar "vals")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PList) (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EListLit)) (EVar "rest"))))
(DTypeSig true "dedentTripleInterp" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleInterp" ((PVar "toks")) (EIf (EApp (EVar "hasTripleInterpOpen") (EVar "toks")) (EApp (EVar "dedentTripleGo") (EVar "toks")) (EIf (EVar "otherwise") (EVar "toks") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasTripleInterpOpen" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "hasTripleInterpOpen" ((PList)) (EVar "False"))
(DFunDef false "hasTripleInterpOpen" ((PCons (PCon "RTripleInterpOpen" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTripleInterpOpen" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTripleInterpOpen") (EVar "rest")))
(DTypeSig false "dedentTripleGo" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleGo" ((PList)) (EListLit))
(DFunDef false "dedentTripleGo" ((PCons (PCon "RTripleInterpOpen" (PVar "s") (PVar "so") (PVar "eo")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dedentTripleGroup") (EVar "s")) (EVar "so")) (EVar "eo")) (EVar "rawSegs")) (EVar "midToks")) (EVar "afterEnd")))))
(DFunDef false "dedentTripleGo" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dedentTripleGo") (EVar "rest"))))
(DTypeSig false "dedentTripleGroup" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "dedentTripleGroup" ((PVar "sReal") (PVar "so") (PVar "eo") (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EIf (EApp (EVar "startsWithNl") (EVar "sReal")) (EBlock (DoLet false false (PVar "allRaw") (EBinOp "::" (EVar "sReal") (EVar "rawSegs"))) (DoLet false false (PVar "minInd") (EApp (EVar "computeMinIndent") (EApp (EVar "concat") (EVar "allRaw")))) (DoExpr (EMatch (EApp (EApp (EVar "dedentGroupSegs") (EVar "minInd")) (EVar "allRaw")) (arm (PCons (PVar "openStr'") (PVar "restVals")) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "openStr'"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EApp (EApp (EVar "substituteOwn") (EVar "restVals")) (EVar "midToks")) (EApp (EVar "dedentTripleGo") (EVar "afterEnd"))))) (arm (PList) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleGo") (EVar "afterEnd")))))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleGo") (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "finish" ((PList)) (ELit (LString "")))
(DFunDef false "finish" ((PList (PVar "s"))) (EVar "s"))
(DFunDef false "finish" ((PVar "xs")) (EApp (EVar "concat") (EApp (EVar "reverse") (EVar "xs"))))
(DTypeSig false "firstFragNl" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "firstFragNl" ((PVar "leading") (PList)) (EVar "True"))
(DFunDef false "firstFragNl" ((PVar "leading") PWild) (EVar "leading"))
(DTypeSig false "splitRange" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitRange" ((PVar "cs") (PVar "start") (PVar "p") (PVar "n")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "start")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tripleRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tripleRunEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "tripleRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscWellFormed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "uniEscWellFormed" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "he") (EVar "s")) (EBinOp "<" (EVar "he") (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))))))
(DTypeSig false "uniHexSigLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniHexSigLen" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "-" (EVar "endp") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscCode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "uniEscCode" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 6))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "parseHex") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 0))))))))
(DTypeSig false "uniEscText" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscText" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1)))))
(DTypeSig false "uniEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))))
(DFunDef false "uniEscChar" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cp")) () (EApp (EVar "charFromCode") (EVar "cp")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "uniIsSurrogate" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "uniIsSurrogate" ((PVar "cp")) (EBinOp "&&" (EBinOp ">=" (EVar "cp") (ELit (LInt 55296))) (EBinOp "<=" (EVar "cp") (ELit (LInt 57343)))))
(DTypeSig false "uniEscTermErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a")))))))))
(DFunDef false "uniEscTermErr" ((PVar "src") (PVar "len") (PVar "s") (PVar "he") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "he") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeUnterminated"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeSeparator"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeEmpty"))) (EIf (EBinOp "==" (EVar "he") (EVar "s")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeExpectedDigit") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeExpectedClose") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "uniEscErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a"))))))
(DFunDef false "uniEscErr" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "endp") (EApp (EApp (EApp (EVar "unicodeErrorEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "uniEscTermErr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (EVar "p")) (EVar "endp")) (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "Some" (PVar "cp")) ((GBool (EApp (EVar "uniIsSurrogate") (EVar "cp")))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeSurrogate") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))))) (arm PWild () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeOutOfRange") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))))))))))
(DTypeSig false "unicodeErrorEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unicodeErrorEnd" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "unicodeErrorEndGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))))
(DTypeSig false "unicodeErrorEndGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unicodeErrorEndGo" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "}"))) (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "unicodeErrorEndGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "uHexEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uHexEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isBareUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isBareUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))) (EBinOp "==" (EBinOp "-" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 4)))))
(DTypeSig false "bareUnicodeEscWritten" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "bareUnicodeEscWritten" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))))
(DTypeSig false "bareUnicodeEscSuggested" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "bareUnicodeEscSuggested" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))))) (ELit (LString "}"))))
(DTypeSig false "bareUnicodeEscMsgStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseDiagnosticKind")))))
(DFunDef false "bareUnicodeEscMsgStr" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EVar "BareUnicodeEscape") (EApp (EApp (EApp (EVar "bareUnicodeEscWritten") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EVar "bareUnicodeEscSuggested") (EVar "src")) (EVar "len")) (EVar "p"))))
(DTypeSig false "isUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))))
(DTypeSig false "uniEscEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniEscEnd" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1))))
(DTypeSig false "lexFailure" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a"))))))
(DFunDef false "lexFailure" ((PVar "start") (PVar "end") (PVar "kind")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "LexError") (EVar "kind")) (EVar "start")) (EVar "end"))))
(DTypeSig false "parseHex" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseHex" ((PVar "src") (PVar "p") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (DoLet false false (PVar "d") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "0")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "+" (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "a")))) (ELit (LInt 10))) (EBinOp "+" (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "A")))) (ELit (LInt 10)))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseHex") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "d"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "readLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "LiteralCursor") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead")))))
(DFunDef false "readLiteral" ((PVar "src") (PCon "LiteralCursor" (PVar "p") (PVar "quote") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EApp (EVar "arrayLength") (EVar "src"))) (EVar "p")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EListLit)))
(DTypeSig false "literalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead")))))))))))
(DFunDef false "literalGo" ((PVar "src") (PVar "len") (PVar "p") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "p")) (EVar "UnterminatedString")) (EIf (EBinOp "&&" (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "LiteralClose")) (EVar "leading"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "LiteralClose")) (EVar "leading"))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalEscape") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isInitial") (EVar "part"))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "len")) (EVar "UnterminatedString")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "flavor")) (EVar "part")) (EApp (EApp (EVar "firstFragNl") (EVar "leading")) (EVar "acc"))) (EVar "inside")) (EBinOp "::" (ELit (LString "\n")) (EVar "acc"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (ELit (LString "\"")) (EVar "acc"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "q") (EIf (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EApp (EApp (EVar "plainRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "tripleRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "q")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "literalEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead"))))))))))))
(DFunDef false "literalEscape" ((PVar "src") (PVar "len") (PVar "p") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside") (PVar "acc") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EVar "inside")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "NestedInterpolation")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "LiteralHole")) (EVar "leading"))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))) (EIf (EApp (EApp (EApp (EApp (EVar "isBareUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "bareUnicodeEscMsgStr") (EVar "src")) (EVar "len")) (EVar "p"))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "commonEscDecode") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EVar "s") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EVar "InvalidEscape") (EBinOp "++" (ELit (LString "\\")) (EApp (EVar "charToStr") (EVar "e")))) (EVar "False"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))))
(DTypeSig false "plainRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "plainRunEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "plainRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "readCharacter" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readCharacter" ((PVar "src") (PVar "pos")) (EApp (EApp (EApp (EVar "charRead") (EVar "src")) (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))
(DTypeSig false "charRead" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "charRead" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "charEscape") (EVar "src")) (EVar "len")) (EVar "p")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "EmptyChar")) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "Ok") (ETuple (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EBinOp ">=" (EVar "e") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EApp (EVar "LongChar") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "e"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "charEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "charEscape" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "charFinished") (EVar "src")) (EVar "len")) (EVar "p")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EVar "charToStr") (EVar "c"))))) (EIf (EApp (EApp (EApp (EApp (EVar "isBareUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "bareUnicodeEscMsgStr") (EVar "src")) (EVar "len")) (EVar "p"))) (EIf (EVar "otherwise") (EMatch (EIf (EApp (EVar "isApos") (EVar "e")) (EApp (EVar "Some") (ELit (LString "'"))) (EApp (EVar "commonEscDecode") (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EVar "InvalidEscape") (EBinOp "++" (ELit (LString "\\")) (EApp (EVar "charToStr") (EVar "e")))) (EVar "True")))) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EVar "charFinished") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charFinished" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "charFinished" ((PVar "src") (PVar "len") (PVar "p") (PVar "end") (PVar "s")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "end") (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "end")))) (EApp (EVar "Ok") (ETuple (EVar "s") (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar"))))
(DTypeSig false "charClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "charClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "dedentSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedentSegments" ((PList)) (EListLit))
(DFunDef false "dedentSegments" ((PList (PVar "s"))) (EListLit (EApp (EVar "stripIndent") (EVar "s"))))
(DFunDef false "dedentSegments" ((PAs "segs" (PCons (PVar "first") PWild))) (EIf (EApp (EVar "startsWithNl") (EVar "first")) (EApp (EApp (EVar "dedentGroupSegs") (EApp (EVar "computeMinIndent") (EApp (EVar "concat") (EVar "segs")))) (EVar "segs")) (EVar "segs")))
(DTypeSig false "isPlain" (TyFun (TyCon "LiteralFlavor") (TyCon "Bool")))
(DFunDef false "isPlain" ((PCon "PlainLiteral")) (EVar "True"))
(DFunDef false "isPlain" (PWild) (EVar "False"))
(DTypeSig false "isInitial" (TyFun (TyCon "LiteralPart") (TyCon "Bool")))
(DFunDef false "isInitial" ((PCon "InitialLiteral")) (EVar "True"))
(DFunDef false "isInitial" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "UnicodeProblem" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true))))
(DUse false (UseGroup ("support" "char") ((mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isNL" false) (mem "isCR" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "concat" false))))
(DData Public "LiteralFlavor" () ((variant "PlainLiteral" (ConPos)) (variant "TripleLiteral" (ConPos))) ())
(DData Public "LiteralPart" () ((variant "InitialLiteral" (ConPos)) (variant "ContinuedLiteral" (ConPos))) ())
(DData Public "LexError" () ((variant "LexError" (ConPos (TyCon "ParseDiagnosticKind") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "LiteralCursor" () ((variant "LiteralCursor" (ConNamed (field "literalPosition" (TyCon "Int")) (field "literalQuoteOpen" (TyCon "Int")) (field "literalFlavor" (TyCon "LiteralFlavor")) (field "literalPart" (TyCon "LiteralPart")) (field "literalLeadingRawLf" (TyCon "Bool")) (field "literalInsideHole" (TyCon "Bool"))))) ())
(DData Public "LiteralStop" () ((variant "LiteralClose" (ConPos)) (variant "LiteralHole" (ConPos))) ())
(DData Public "LiteralRead" () ((variant "LiteralRead" (ConPos (TyCon "String") (TyCon "Int") (TyCon "LiteralStop") (TyCon "Bool")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig true "copyCharRange" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "copyCharRange" ((PVar "src") (PVar "start") (PVar "endp")) (EIf (EBinOp "<=" (EVar "endp") (EVar "start")) (ELit (LString "")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "out") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EVar "endp") (EVar "start"))) (EApp (EApp (EVar "at") (EVar "src")) (EVar "start")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "start")) (EVar "out")) (ELit (LInt 0))) (EBinOp "-" (EVar "endp") (EVar "start")))) (DoExpr (EApp (EVar "stringFromChars") (EVar "out")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "commonEscDecode" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "commonEscDecode" ((PVar "e")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LString "\n"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LString "\t"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LString "\r"))) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "0"))) (EApp (EVar "Some") (EApp (EVar "charToStr") (EApp (EApp (EVar "optionOr") (ELit (LChar " "))) (EApp (EVar "charFromCode") (ELit (LInt 0)))))) (EIf (EApp (EVar "isBackslash") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\\"))) (EIf (EApp (EVar "isQuote") (EVar "e")) (EApp (EVar "Some") (ELit (LString "\""))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "stripIndent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripIndent" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stripIndentCs") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "stripIndentCs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripIndentCs" ((PVar "s") (PVar "cs") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EBinOp "/=" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n"))) (EVar "s") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n"))) (DoLet false false (PVar "minInd") (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EVar "lines")) (EVar "indentSentinel")))) (DoExpr (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "lines"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitLines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitLines" ((PVar "cs") (PVar "p") (PVar "n")) (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EVar "p")) (EVar "p")) (EVar "n")))
(DTypeSig false "indentSentinel" (TyCon "Int"))
(DFunDef false "indentSentinel" () (ELit (LInt 1000000000)))
(DTypeSig false "indentOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "indentOf" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "indentOfGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indentOfGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "indentSentinel") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "i")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "indentOfGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minIndentGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minIndentGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minIndentGo" ((PCons (PVar "l") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minIndentGo") (EVar "rest")) (EApp (EApp (EMethodRef "min") (EVar "acc")) (EApp (EVar "indentOf") (EVar "l")))))
(DTypeSig false "normalizeMin" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "normalizeMin" ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "indentSentinel")) (ELit (LInt 0)) (EVar "m")))
(DTypeSig false "stripLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stripLines" ((PVar "k") (PVar "ls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stripLine") (EVar "k"))) (EVar "ls")))
(DTypeSig false "stripLine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripLine" ((PVar "k") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "dropCharsToStr") (EVar "cs")) (EApp (EApp (EMethodRef "min") (EVar "k")) (EVar "n"))) (EVar "n")))))
(DTypeSig false "dropCharsToStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "dropCharsToStr" ((PVar "cs") (PVar "k") (PVar "n")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "k")) (EVar "n")))
(DTypeSig false "joinNlStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNlStr" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig false "startsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (ELit (LInt 0))) (ELit (LChar "\n")))))))
(DTypeSig false "endsWithNl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsWithNl" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LChar "\n")))))))
(DTypeSig false "computeMinIndent" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "computeMinIndent" ((PVar "joined")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "joined"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "normalizeMin") (EApp (EApp (EVar "minIndentGo") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EVar "n"))) (EVar "indentSentinel"))))))
(DTypeSig false "dedentGroupSegs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dedentGroupSegs" ((PVar "minInd") (PCons (PVar "openStr") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "openStr"))) (DoLet false false (PVar "openLines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoLet false false (PVar "openOut") (EApp (EVar "joinNlStr") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "openLines")))) (DoExpr (EBinOp "::" (EVar "openOut") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "openStr"))) (EVar "rest"))))))
(DFunDef false "dedentGroupSegs" (PWild (PList)) (EListLit))
(DTypeSig false "dedentRestSegs" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dedentRestSegs" (PWild PWild (PList)) (EListLit))
(DFunDef false "dedentRestSegs" ((PVar "minInd") (PVar "atLineStart") (PCons (PVar "seg") (PVar "rest"))) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "seg"))) (DoLet false false (PVar "lines") (EApp (EApp (EApp (EVar "splitLines") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoLet false false (PVar "out") (EApp (EVar "joinNlStr") (EApp (EApp (EApp (EVar "stripFirstAware") (EVar "minInd")) (EVar "atLineStart")) (EVar "lines")))) (DoExpr (EBinOp "::" (EVar "out") (EApp (EApp (EApp (EVar "dedentRestSegs") (EVar "minInd")) (EApp (EVar "endsWithNl") (EVar "seg"))) (EVar "rest"))))))
(DTypeSig false "stripFirstAware" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "stripFirstAware" (PWild PWild (PList)) (EListLit))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "True") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "stripLine") (EVar "minInd")) (EVar "l")) (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DFunDef false "stripFirstAware" ((PVar "minInd") (PCon "False") (PCons (PVar "l") (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EApp (EVar "stripLines") (EVar "minInd")) (EVar "rest"))))
(DTypeSig false "splitInterpGroup" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "splitInterpGroup" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpMid" (PVar "s")) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "segs")) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "mo")) (EVar "me")) (EVar "mid")) (EVar "after")))))
(DFunDef false "splitInterpGroup" ((PCons (PCon "RTok" (PCon "TInterpEnd" (PVar "s")) (PVar "eo") (PVar "ee")) (PVar "rest"))) (ETuple (EListLit (EVar "s")) (EListLit (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "s"))) (EVar "eo")) (EVar "ee"))) (EVar "rest")))
(DFunDef false "splitInterpGroup" ((PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "segs") (PVar "mid") (PVar "after")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (ETuple (EVar "segs") (EBinOp "::" (EVar "t") (EVar "mid")) (EVar "after")))))
(DTypeSig false "substituteOwn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))
(DFunDef false "substituteOwn" (PWild (PList)) (EListLit))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpMid" PWild) (PVar "mo") (PVar "me")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "v"))) (EVar "mo")) (EVar "me")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PCons (PVar "v") (PVar "vs")) (PCons (PCon "RTok" (PCon "TInterpEnd" PWild) (PVar "eo") (PVar "ee")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "v"))) (EVar "eo")) (EVar "ee")) (EApp (EApp (EVar "substituteOwn") (EVar "vs")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PVar "vals") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EVar "vals")) (EVar "rest"))))
(DFunDef false "substituteOwn" ((PList) (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substituteOwn") (EListLit)) (EVar "rest"))))
(DTypeSig true "dedentTripleInterp" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleInterp" ((PVar "toks")) (EIf (EApp (EVar "hasTripleInterpOpen") (EVar "toks")) (EApp (EVar "dedentTripleGo") (EVar "toks")) (EIf (EVar "otherwise") (EVar "toks") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasTripleInterpOpen" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyCon "Bool")))
(DFunDef false "hasTripleInterpOpen" ((PList)) (EVar "False"))
(DFunDef false "hasTripleInterpOpen" ((PCons (PCon "RTripleInterpOpen" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTripleInterpOpen" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTripleInterpOpen") (EVar "rest")))
(DTypeSig false "dedentTripleGo" (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "dedentTripleGo" ((PList)) (EListLit))
(DFunDef false "dedentTripleGo" ((PCons (PCon "RTripleInterpOpen" (PVar "s") (PVar "so") (PVar "eo")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EApp (EVar "splitInterpGroup") (EVar "rest"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dedentTripleGroup") (EVar "s")) (EVar "so")) (EVar "eo")) (EVar "rawSegs")) (EVar "midToks")) (EVar "afterEnd")))))
(DFunDef false "dedentTripleGo" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dedentTripleGo") (EVar "rest"))))
(DTypeSig false "dedentTripleGroup" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "RawTok")))))))))
(DFunDef false "dedentTripleGroup" ((PVar "sReal") (PVar "so") (PVar "eo") (PVar "rawSegs") (PVar "midToks") (PVar "afterEnd")) (EIf (EApp (EVar "startsWithNl") (EVar "sReal")) (EBlock (DoLet false false (PVar "allRaw") (EBinOp "::" (EVar "sReal") (EVar "rawSegs"))) (DoLet false false (PVar "minInd") (EApp (EVar "computeMinIndent") (EApp (EVar "concat") (EVar "allRaw")))) (DoExpr (EMatch (EApp (EApp (EVar "dedentGroupSegs") (EVar "minInd")) (EVar "allRaw")) (arm (PCons (PVar "openStr'") (PVar "restVals")) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "openStr'"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EApp (EApp (EVar "substituteOwn") (EVar "restVals")) (EVar "midToks")) (EApp (EVar "dedentTripleGo") (EVar "afterEnd"))))) (arm (PList) () (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleGo") (EVar "afterEnd")))))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "sReal"))) (EVar "so")) (EVar "eo")) (EBinOp "++" (EVar "midToks") (EApp (EVar "dedentTripleGo") (EVar "afterEnd")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "finish" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "finish" ((PList)) (ELit (LString "")))
(DFunDef false "finish" ((PList (PVar "s"))) (EVar "s"))
(DFunDef false "finish" ((PVar "xs")) (EApp (EVar "concat") (EApp (EVar "reverse") (EVar "xs"))))
(DTypeSig false "firstFragNl" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "firstFragNl" ((PVar "leading") (PList)) (EVar "True"))
(DFunDef false "firstFragNl" ((PVar "leading") PWild) (EVar "leading"))
(DTypeSig false "splitRange" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitRange" ((PVar "cs") (PVar "start") (PVar "p") (PVar "n")) (EIf (EBinOp ">=" (EVar "p") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "cs")) (EVar "p")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "cs")) (EVar "start")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitRange") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "tripleRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tripleRunEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "tripleRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscWellFormed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "uniEscWellFormed" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "he") (EVar "s")) (EBinOp "<" (EVar "he") (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))))))
(DTypeSig false "uniHexSigLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniHexSigLen" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "-" (EVar "endp") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "uniEscCode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "uniEscCode" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (DoLet false false (PVar "he") (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EVar "s"))) (DoExpr (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "uniHexSigLen") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 6))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "parseHex") (EVar "src")) (EVar "s")) (EVar "he")) (ELit (LInt 0))))))))
(DTypeSig false "uniEscText" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "uniEscText" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1)))))
(DTypeSig false "uniEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))))
(DFunDef false "uniEscChar" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cp")) () (EApp (EVar "charFromCode") (EVar "cp")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "uniIsSurrogate" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "uniIsSurrogate" ((PVar "cp")) (EBinOp "&&" (EBinOp ">=" (EVar "cp") (ELit (LInt 55296))) (EBinOp "<=" (EVar "cp") (ELit (LInt 57343)))))
(DTypeSig false "uniEscTermErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a")))))))))
(DFunDef false "uniEscTermErr" ((PVar "src") (PVar "len") (PVar "s") (PVar "he") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "he") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeUnterminated"))) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeSeparator"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "he") (EVar "s")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")) (ELit (LChar "}")))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EVar "UnicodeEmpty"))) (EIf (EBinOp "==" (EVar "he") (EVar "s")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeExpectedDigit") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeExpectedClose") (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "he")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "uniEscErr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a"))))))
(DFunDef false "uniEscErr" ((PVar "src") (PVar "len") (PVar "p")) (EBlock (DoLet false false (PVar "endp") (EApp (EApp (EApp (EVar "unicodeErrorEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "uniEscWellFormed") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "uniEscTermErr") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3))))) (EVar "p")) (EVar "endp")) (EMatch (EApp (EApp (EApp (EVar "uniEscCode") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "Some" (PVar "cp")) ((GBool (EApp (EVar "uniIsSurrogate") (EVar "cp")))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeSurrogate") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))))) (arm PWild () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "endp")) (EApp (EVar "BadUnicodeEscape") (EApp (EVar "UnicodeOutOfRange") (EApp (EApp (EApp (EVar "uniEscText") (EVar "src")) (EVar "len")) (EVar "p")))))))))))
(DTypeSig false "unicodeErrorEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unicodeErrorEnd" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "unicodeErrorEndGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))))
(DTypeSig false "unicodeErrorEndGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unicodeErrorEndGo" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "}"))) (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "unicodeErrorEndGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "uHexEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uHexEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isBareUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isBareUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "isHexDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))) (EBinOp "==" (EBinOp "-" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 4)))))
(DTypeSig false "bareUnicodeEscWritten" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "bareUnicodeEscWritten" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))))
(DTypeSig false "bareUnicodeEscSuggested" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "bareUnicodeEscSuggested" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))))) (ELit (LString "}"))))
(DTypeSig false "bareUnicodeEscMsgStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseDiagnosticKind")))))
(DFunDef false "bareUnicodeEscMsgStr" ((PVar "src") (PVar "len") (PVar "p")) (EApp (EApp (EVar "BareUnicodeEscape") (EApp (EApp (EApp (EVar "bareUnicodeEscWritten") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EApp (EApp (EVar "bareUnicodeEscSuggested") (EVar "src")) (EVar "len")) (EVar "p"))))
(DTypeSig false "isUnicodeEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "isUnicodeEsc" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "u"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LChar "{")))))
(DTypeSig false "uniEscEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "uniEscEnd" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "+" (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (ELit (LInt 1))))
(DTypeSig false "lexFailure" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyVar "a"))))))
(DFunDef false "lexFailure" ((PVar "start") (PVar "end") (PVar "kind")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "LexError") (EVar "kind")) (EVar "start")) (EVar "end"))))
(DTypeSig false "parseHex" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseHex" ((PVar "src") (PVar "p") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (DoLet false false (PVar "d") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "0")))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "+" (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "a")))) (ELit (LInt 10))) (EBinOp "+" (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "A")))) (ELit (LInt 10)))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseHex") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "d"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "readLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "LiteralCursor") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead")))))
(DFunDef false "readLiteral" ((PVar "src") (PCon "LiteralCursor" (PVar "p") (PVar "quote") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EApp (EVar "arrayLength") (EVar "src"))) (EVar "p")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EListLit)))
(DTypeSig false "literalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead")))))))))))
(DFunDef false "literalGo" ((PVar "src") (PVar "len") (PVar "p") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "p")) (EVar "UnterminatedString")) (EIf (EBinOp "&&" (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "LiteralClose")) (EVar "leading"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 3)))) (EVar "LiteralClose")) (EVar "leading"))) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalEscape") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EVar "acc")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isInitial") (EVar "part"))) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EVar "len")) (EVar "UnterminatedString")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "flavor")) (EVar "part")) (EApp (EApp (EVar "firstFragNl") (EVar "leading")) (EVar "acc"))) (EVar "inside")) (EBinOp "::" (ELit (LString "\n")) (EVar "acc"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPlain") (EVar "flavor"))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (ELit (LString "\"")) (EVar "acc"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "q") (EIf (EApp (EVar "isPlain") (EVar "flavor")) (EApp (EApp (EApp (EVar "plainRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "tripleRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "q")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "literalEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyCon "LiteralRead"))))))))))))
(DFunDef false "literalEscape" ((PVar "src") (PVar "len") (PVar "p") (PVar "flavor") (PVar "part") (PVar "leading") (PVar "inside") (PVar "acc") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EVar "inside")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "NestedInterpolation")) (EIf (EBinOp "==" (EVar "e") (ELit (LChar "{"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "LiteralRead") (EApp (EVar "finish") (EVar "acc"))) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "LiteralHole")) (EVar "leading"))) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))) (EIf (EApp (EApp (EApp (EApp (EVar "isBareUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "bareUnicodeEscMsgStr") (EVar "src")) (EVar "len")) (EVar "p"))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "commonEscDecode") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "literalGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "flavor")) (EVar "part")) (EVar "leading")) (EVar "inside")) (EBinOp "::" (EVar "s") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EVar "InvalidEscape") (EBinOp "++" (ELit (LString "\\")) (EApp (EVar "charToStr") (EVar "e")))) (EVar "False"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))))
(DTypeSig false "plainRunEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "plainRunEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "len") (EIf (EBinOp "||" (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "plainRunEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "readCharacter" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "readCharacter" ((PVar "src") (PVar "pos")) (EApp (EApp (EApp (EVar "charRead") (EVar "src")) (EApp (EVar "arrayLength") (EVar "src"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))
(DTypeSig false "charRead" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "charRead" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EIf (EBinOp "&&" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp ">=" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EIf (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "charEscape") (EVar "src")) (EVar "len")) (EVar "p")) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "EmptyChar")) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "Ok") (ETuple (EApp (EVar "charToStr") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EVar "p"))) (DoExpr (EIf (EBinOp ">=" (EVar "e") (EVar "len")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar")) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EApp (EVar "LongChar") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "e"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "charEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "charEscape" ((PVar "src") (PVar "len") (PVar "p") (PVar "e")) (EIf (EApp (EApp (EApp (EApp (EVar "isUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EMatch (EApp (EApp (EApp (EVar "uniEscChar") (EVar "src")) (EVar "len")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "uniEscErr") (EVar "src")) (EVar "len")) (EVar "p"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EApp (EVar "charFinished") (EVar "src")) (EVar "len")) (EVar "p")) (EApp (EApp (EApp (EVar "uniEscEnd") (EVar "src")) (EVar "len")) (EVar "p"))) (EApp (EVar "charToStr") (EVar "c"))))) (EIf (EApp (EApp (EApp (EApp (EVar "isBareUnicodeEsc") (EVar "src")) (EVar "len")) (EVar "p")) (EVar "e")) (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EApp (EApp (EApp (EVar "uHexEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "bareUnicodeEscMsgStr") (EVar "src")) (EVar "len")) (EVar "p"))) (EIf (EVar "otherwise") (EMatch (EIf (EApp (EVar "isApos") (EVar "e")) (EApp (EVar "Some") (ELit (LString "'"))) (EApp (EVar "commonEscDecode") (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lexFailure") (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EApp (EApp (EVar "InvalidEscape") (EBinOp "++" (ELit (LString "\\")) (EApp (EVar "charToStr") (EVar "e")))) (EVar "True")))) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EVar "charFinished") (EVar "src")) (EVar "len")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charFinished" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "LexError")) (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "charFinished" ((PVar "src") (PVar "len") (PVar "p") (PVar "end") (PVar "s")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "end") (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "end")))) (EApp (EVar "Ok") (ETuple (EVar "s") (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "lexFailure") (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EVar "len")) (EVar "UnterminatedChar"))))
(DTypeSig false "charClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "charClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "charClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "dedentSegments" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedentSegments" ((PList)) (EListLit))
(DFunDef false "dedentSegments" ((PList (PVar "s"))) (EListLit (EApp (EVar "stripIndent") (EVar "s"))))
(DFunDef false "dedentSegments" ((PAs "segs" (PCons (PVar "first") PWild))) (EIf (EApp (EVar "startsWithNl") (EVar "first")) (EApp (EApp (EVar "dedentGroupSegs") (EApp (EVar "computeMinIndent") (EApp (EVar "concat") (EVar "segs")))) (EVar "segs")) (EVar "segs")))
(DTypeSig false "isPlain" (TyFun (TyCon "LiteralFlavor") (TyCon "Bool")))
(DFunDef false "isPlain" ((PCon "PlainLiteral")) (EVar "True"))
(DFunDef false "isPlain" (PWild) (EVar "False"))
(DTypeSig false "isInitial" (TyFun (TyCon "LiteralPart") (TyCon "Bool")))
(DFunDef false "isInitial" ((PCon "InitialLiteral")) (EVar "True"))
(DFunDef false "isInitial" (PWild) (EVar "False"))
