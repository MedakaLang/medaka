# META
source_lines=1145
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_diagnostic.{ParseDiagnosticKind(..)}
import frontend.lex_token.{Token(..), RawTok(..)}
import frontend.lex_literal.{
  LiteralFlavor(..), LiteralPart(..), LiteralCursor(..), LiteralRead(..),
  LiteralStop(..), LexError(..), readLiteral, readCharacter, readByteLiteral,
  readRawLiteral, copyCharRange, dedentSegments, dedentTripleInterp
}
import support.char.{
  isSp, isTab, isNL, isCR, isQuote, isApos, isBackslash, isBacktick, isSpace,
  isDigit, isLower, isUpper, isAlnum, isHexDigit
}
import support.util.{compareDecMag, listLen, anyList}

data LexFrame = CodeFrame | HoleFrame LiteralFlavor Int Int

at : Array Char -> Int -> Char
at src i = arrayGetUnsafe i src

is2 : Array Char -> Int -> Int -> Char -> Char -> Bool
is2 src len pos a b = pos + 1 < len && at src pos == a && at src (pos + 1) == b

is3 : Array Char -> Int -> Int -> Char -> Char -> Char -> Bool
is3 src len pos a b c =
  pos + 2 < len
    && at src pos == a
    && at src (pos + 1) == b
    && at src (pos + 2) == c

collectNoUs : Array Char -> Int -> Int -> List Char
collectNoUs src p endp
  | p >= endp = []
  | at src p == '_' = collectNoUs src (p + 1) endp
  | otherwise = at src p :: collectNoUs src (p + 1) endp

substrNoUs : Array Char -> Int -> Int -> String
substrNoUs src start endp =
  stringFromChars (arrayFromList (collectNoUs src start endp))

parseIntFrom : Array Char -> Int -> Int -> Int -> Int
parseIntFrom src p endp acc = magnitudeInt (parseIntNeg src p endp acc)

-- The digits' value NEGATED: a magnitude up to 2^62 (the range guard below
-- admits no more) fits only on the negative side, and `Int` arithmetic traps.
parseIntNeg : Array Char -> Int -> Int -> Int -> Int
parseIntNeg src p endp acc
  | p >= endp = acc
  | at src p == '_' = parseIntNeg src (p + 1) endp acc
  | otherwise =
    parseIntNeg src (p + 1) endp (acc * 10 - (charCode (at src p) - 48))

-- A negated magnitude back to the literal's `Int`: 2^62 has no positive `Int`,
-- so it stays `intMinBound`, which is what the parser's `isIntMinLit` expects
-- of every spelling of 2^62 (a negated literal is `intMinBound`, a bare one is
-- refused).
magnitudeInt : Int -> Int
magnitudeInt neg = if neg == intMinBound then neg else 0 - neg

-- ── Int-literal range guard ─────────────────────────────────────────────
-- The tagged-Int rep is 63-bit (`word = (n << 1) | 1`, `runtime/medaka_rt.c`),
-- so `Int` spans [-2^62, 2^62-1]. The lexer sees only the unsigned digits (the
-- `-` is a separate token, negated in the parser), and the negative minimum
-- -2^62 must stay writable, so the largest admissible magnitude is
-- 2^62 = 4611686018427387904 (19 digits). A bare positive 2^62 becomes
-- `intMinBound` (the lexer can't see the sign; `magnitudeInt`); 2^62+1 and
-- above are rejected outright. `parseIntFrom` accumulates in the compiler's own
-- 63-bit `Int`, whose arithmetic traps, so overflow is detected on the digit
-- STRING via `compareDecMag` (magnitude compare with no arithmetic), never by
-- parsing.  `substrNoUs` strips the '_'
-- separators; `compareDecMag` ignores leading zeros, so the largest admissible
-- magnitude is exactly 2^62 (anything greater overflows).
intLitOverflows : Array Char -> Int -> Int -> Bool
intLitOverflows src start endp =
  compareDecMag (substrNoUs src start endp) "4611686018427387904" == Gt

-- A literal past the `Int` bound is still a `U64` literal when it fits 64 bits
-- (INTEGER-TYPES-DESIGN §3.2 item 4).  Its value is accumulated as two 32-bit
-- halves, so no step exceeds the compiler's own 63-bit `Int`: `lo * base + d` and
-- `hi * base + carry` stay below 2^37 for any base up to 16.  `None` once the high
-- half passes 32 bits, i.e. the value passes 2^64 - 1.
wideHalves : Int -> List Char -> Option (Int, Int)
wideHalves base digits = wideHalvesGo base digits 0 0

wideHalvesGo : Int -> List Char -> Int -> Int -> Option (Int, Int)
wideHalvesGo _ [] hi lo = Some (hi, lo)
wideHalvesGo base (d :: rest) hi lo =
  let lo2 = lo * base + digitVal d
  let hi2 = hi * base + lo2 / 4294967296
  if hi2 > 4294967295 then
    None
  else
    wideHalvesGo base rest hi2 (lo2 % 4294967296)

-- Literals beyond Int become TWideInt up to 2^64 - 1, then an overflow error.
wideIntTok : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  List Char ->
  RawTok
wideIntTok ctx src pos e depth id digits =
  match wideHalves (wideBase src pos) digits
    Some (hi, lo) =>
      emitOne
        ctx
        (RTok (TWideInt hi lo (copyCharRange src pos e)) pos e)
        e
        depth
        id
    None => lexErrorTok ctx pos e IntegerOverflow

wideBase : Array Char -> Int -> Int
wideBase src pos
  | at src pos == '0'
    && pos + 1 < arrayLength src
    && radixKind (at src (pos + 1)) = radixBase (at src (pos + 1))
  | otherwise = 10

-- ── Keyword table ───────────────────────────────────────────────────────
-- True/False start uppercase, so they do not reach the lowercase keyword table.
--
-- A lexeme in the reserved-word table can never be a
-- variable, parameter, field, constructor-payload or module-path name; a lexeme
-- absent from it always can.  Derive the set, never quote a count:
--
--   grep -n '^keywordOrIdent "' compiler/frontend/lex_scan.mdk
--
-- ── Why `record` is NOT here but `mut`/`function` ARE (#62) ─────────────
-- All three named constructs that have since been REMOVED from the language
-- (`record X = { … }`, `let mut`, `function`), so none of them is reserved
-- because the grammar still needs the word.  They differ in what the word is
-- worth as an ordinary identifier, and that is the whole criterion:
--
--   `record` — a genuinely useful noun.  Users name a value, a field, a type or
--     a MODULE `record` (`import record.*`, `test/native_fixtures/
--     keyword_import_record/`), and reserving it bought nothing but a wall.  It
--     is therefore an ordinary `TIdent`, and the removed DECLARATION is caught
--     positionally instead — `recordHeadIdx` in parse_hints.mdk fires on the
--     construct's shape (`record Upper … = {` with no `|`), not on the word.
--   `mut`, `function` — kept reserved DELIBERATELY, not by omission.  Each is
--     the first token of a removed construct that is otherwise indistinguishable
--     from ordinary code: `let mut x = e` is exactly `let` applied to a binder
--     named `mut`, and `function` followed by an indented block is exactly an
--     application.  There is no positional discriminator to move the diagnostic
--     onto, so freeing them would trade a clear "this was removed, write X
--     instead" for a generic parse error one line later — a strictly worse
--     message for a construct newcomers from OCaml/JS still reach for.  The
--     cost is that `mut`/`function` cannot be identifiers; that is the price,
--     and it is paid knowingly.
--
-- If a future change gives `mut`/`function` a positional discriminator as clean
-- as `record`'s, freeing them is the same edit: drop the row here, move the
-- pre-scan in parse_hints.mdk from the bare token to the construct shape, and prove
-- the shape is never valid Medaka (see the safety proof above `recordHeadIdx`).
keywordOrIdent : String -> Token
keywordOrIdent "let" = TLet
keywordOrIdent "rec" = TRec
keywordOrIdent "with" = TWith
keywordOrIdent "mut" = TMut
keywordOrIdent "in" = TIn
keywordOrIdent "if" = TIf
keywordOrIdent "then" = TThen
keywordOrIdent "else" = TElse
keywordOrIdent "match" = TMatch
keywordOrIdent "data" = TData
keywordOrIdent "interface" = TInterface
keywordOrIdent "default" = TDefault
keywordOrIdent "impl" = TImpl
keywordOrIdent "import" = TImport
keywordOrIdent "export" = TExport
keywordOrIdent "public" = TPublic
keywordOrIdent "where" = TWhere
keywordOrIdent "of" = TOf
keywordOrIdent "do" = TDo
keywordOrIdent "defer" = TDefer
keywordOrIdent "as" = TAs
keywordOrIdent "extern" = TExtern
keywordOrIdent "requires" = TRequires
keywordOrIdent "deriving" = TDeriving
keywordOrIdent "type" = TType
keywordOrIdent "newtype" = TNewtype
keywordOrIdent "prop" = TProp
keywordOrIdent "test" = TTest
keywordOrIdent "bench" = TBench
keywordOrIdent "effect" = TEffect
keywordOrIdent "function" = TFunction
keywordOrIdent s = TIdent s

-- ── Scanner ─────────────────────────────────────────────────────────────
-- HoleFrame tracks brace depth separately from ordinary delimiter depth.
scanOne : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanOne ctx src len pos depth id
  | pos >= len = endOne ctx
  | otherwise = scanAt ctx src len pos depth id (at src pos)

scanAt : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  Char ->
  RawTok
scanAt ctx src len pos depth id c
  | isSpace c = scanOne ctx src len (pos + 1) depth id
  | isNL c || isCR c = handleNewline ctx src len pos depth id
  | c == '#' && pos == 0 && len > 1 && at src 1 == '!'
    || c == '-' && pos + 1 < len && at src (pos + 1) == '-' =
    let e = skipLineComment src len pos
    emitOne ctx (RComment pos e) e depth id
  | c == '{' && pos + 1 < len && at src (pos + 1) == '-' =
    let e = skipBlockComment src len (pos + 2) 1
    if e < 0 then
      lexErrorTok ctx pos len UnterminatedComment
    else
      emitOne ctx (RComment pos e) e depth id
  | isDigit c = scanNumber ctx src len pos depth id
  | isQuote c && isTripleAt src len pos =
    scanLiteral ctx src (pos + 3) pos depth id TripleLiteral InitialLiteral
  | isQuote c =
    scanLiteral ctx src (pos + 1) pos depth id PlainLiteral InitialLiteral
  | isApos c = scanChar ctx src pos depth id
  | c == 'b' && opensByteLiteral src len pos = scanByte ctx src len pos depth id
  | c == 'r' && opensRawLiteral src len pos =
    scanRawLiteral ctx src pos depth id
  | isLower c || c == '_' = scanLower ctx src len pos depth id
  | isUpper c = scanUpper ctx src len pos depth id
  | isBacktick c = scanBacktick ctx src len pos depth id
  | otherwise = scanOp ctx src len pos depth id c

skipLineComment : Array Char -> Int -> Int -> Int
skipLineComment src len p
  | p >= len = p
  | isNL (at src p) || isCR (at src p) = p
  | otherwise = skipLineComment src len (p + 1)

-- Emit a terminal lexer-error token instead of panicking.  The error carries the
-- offending char offset `p` (as the RTok's start offset) so `parser.parseResult`
-- can resolve it to a 1-based line / 0-based column via `offsetToLineCol` — the
-- SAME located path a structured parse error flows through (rendered `file:L:C:`
-- by the driver).  Terminates the raw stream: valid code never reaches here, so
-- the token stream for well-formed input is byte-identical.
lexErrorTok : ScanCursor -> Int -> Int -> ParseDiagnosticKind -> RawTok
lexErrorTok ctx p end kind =
  ctx.cursorPos := ctx.cursorLength
  RTok (TLexError kind) p end

-- nestable `{- … -}` block comments; `p` is just past the opening `{-`, `d` the
-- open-comment nesting depth. Returns the position just past the matching `-}`.
skipBlockComment : Array Char -> Int -> Int -> Int -> Int
-- Returns the position just past the matching `-}`, or the sentinel `-1` when
-- the comment is never closed (so the caller can emit a located lexer error
-- rather than silently swallowing the rest of the file).
skipBlockComment src len p d
  | d <= 0 = p
  | p >= len = 0 - 1
  | at src p == '{' && p + 1 < len && at src (p + 1) == '-' =
    skipBlockComment src len (p + 2) (d + 1)
  | at src p == '-' && p + 1 < len && at src (p + 1) == '}' =
    skipBlockComment src len (p + 2) (d - 1)
  | otherwise = skipBlockComment src len (p + 1) d

-- identifiers / keywords / underscore
identEnd : Array Char -> Int -> Int -> Int
identEnd src len p
  | p < len && isAlnum (at src p) = identEnd src len (p + 1)
  | otherwise = p

scanLower : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanLower ctx src len pos depth id =
  let e = identEnd src len (pos + 1)
  emitOne ctx (RTok (identToken src pos e) pos e) e depth id

identToken : Array Char -> Int -> Int -> Token
identToken src pos e
  | at src pos == '_' && e - pos == 1 = TUnderscore
  | kwCandidate src pos e = keywordOrIdent (copyCharRange src pos e)
  | otherwise = TIdent (copyCharRange src pos e)

-- Necessary condition for `keywordOrIdent` to match: every keyword spelling is
-- 2 to 9 chars and starts with one of the letters below. Identifiers failing it
-- skip the keyword chain entirely (they still get `TIdent`, as the chain's
-- fall-through would give). Keep in step with the `keywordOrIdent` clauses.
kwCandidate : Array Char -> Int -> Int -> Bool
kwCandidate src pos e =
  let n = e - pos
  n >= 2 && n <= 9 && kwStart (at src pos)

kwStart : Char -> Bool
kwStart 'a' = True
kwStart 'b' = True
kwStart 'd' = True
kwStart 'e' = True
kwStart 'f' = True
kwStart 'i' = True
kwStart 'l' = True
kwStart 'm' = True
kwStart 'n' = True
kwStart 'o' = True
kwStart 'p' = True
kwStart 'r' = True
kwStart 't' = True
kwStart 'w' = True
kwStart _ = False

scanUpper : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanUpper ctx src len pos depth id =
  let e = identEnd src len (pos + 1)
  emitOne ctx (RTok (TUpper (copyCharRange src pos e)) pos e) e depth id

scanBacktick : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
scanBacktick ctx src len pos depth id =
  let e = btClose src len (pos + 1)
  emitOne
    ctx
    (RTok (TBacktickIdent (copyCharRange src (pos + 1) e)) pos (e + 1))
    (e + 1)
    depth
    id

btClose : Array Char -> Int -> Int -> Int
btClose src len p
  | p >= len = p
  | isBacktick (at src p) = p
  | otherwise = btClose src len (p + 1)

-- numbers (int / float; underscores allowed)
digitsEnd : Array Char -> Int -> Int -> Int
digitsEnd src len p
  | p < len && (isDigit (at src p) || at src p == '_') =
    digitsEnd src len (p + 1)
  | otherwise = p

-- `0x…` / `0b…` / `0o…` radix literals (require ≥1 valid digit after the prefix).
isRadixPrefix : Array Char -> Int -> Int -> Bool
isRadixPrefix src len pos =
  at src pos == '0'
    && pos + 2 < len
    && radixKind (at src (pos + 1))
    && isRadixDigit (at src (pos + 1)) (at src (pos + 2))

radixKind : Char -> Bool
radixKind k = k == 'x' || k == 'b' || k == 'o'

radixBase : Char -> Int
radixBase 'x' = 16
radixBase 'b' = 2
radixBase _ = 8

isRadixDigit : Char -> Char -> Bool
isRadixDigit 'x' c = isHexDigit c
isRadixDigit 'b' c = c == '0' || c == '1'
isRadixDigit _ c = c >= '0' && c <= '7'

digitVal : Char -> Int
digitVal c
  | isDigit c = charCode c - 48
  | c >= 'a' && c <= 'f' = charCode c - 87
  | otherwise = charCode c - 55

radixEnd : Array Char -> Int -> Int -> Char -> Int
radixEnd src len p k
  | p < len && (isRadixDigit k (at src p) || at src p == '_') =
    radixEnd src len (p + 1) k
  | otherwise = p

parseRadix : Array Char -> Int -> Int -> Int -> Int -> Int
parseRadix src p endp base acc =
  magnitudeInt (parseRadixNeg src p endp base acc)

-- `parseIntNeg` for a radix: the value negated, so 2^62 fits.
parseRadixNeg : Array Char -> Int -> Int -> Int -> Int -> Int
parseRadixNeg src p endp base acc
  | p >= endp = acc
  | at src p == '_' = parseRadixNeg src (p + 1) endp base acc
  | otherwise =
    parseRadixNeg src (p + 1) endp base (acc * base - digitVal (at src p))

-- ── Radix-literal range guard (#556) ────────────────────────────────────
-- `parseRadix` accumulates in the compiler's own 63-bit `Int`, whose arithmetic
-- traps, so — exactly as on the decimal path (`intLitOverflows`) — the range is
-- decided on the DIGIT STRING, with no arithmetic, never by parsing.
--
-- The bound is deliberately the SAME one the decimal path uses: magnitude
-- ≤ 2^62.  The lexer sees only unsigned digits (the `-` is a separate token,
-- negated in the parser), so it must admit magnitude 2^62 to keep the negative
-- minimum -2^62 writable — `-0x4000000000000000` stays legal exactly as
-- `-4611686018427387904` does.  A BARE positive 2^62 becomes
-- `intMinBound` here (`magnitudeInt`) and is then rejected in positive
-- position by the parser's `isIntMinLit` (#171), which keys on the value and
-- so covers every spelling of 2^62 —
-- decimal and radix alike — from one rule.  Anything above 2^62 never reaches
-- the parser: it is rejected right here, in whatever base it was written.
--
-- 2^62 in each radix is one leading digit followed by zeros, so the bound is
-- described exactly by (significant-digit count, leading digit):
--   hex  2^62 = 4 * 16^15  ->  "4" ++ 15 zeros  ->  (16, 4)
--   oct  2^62 = 4 * 8^20   ->  "4" ++ 20 zeros  ->  (21, 4)
--   bin  2^62 = 1 * 2^62   ->  "1" ++ 62 zeros  ->  (63, 1)
-- Compared digit-VALUE-wise rather than by `stringCompare` (which
-- `compareDecMag` can use because decimal digits sort by ASCII): hex digits do
-- NOT, since 'A'(65) < 'a'(97) both exceed '9'(57), so a mixed-case literal
-- would compare wrong.
radixMaxLen : Char -> Int
radixMaxLen 'x' = 16
radixMaxLen 'b' = 63
radixMaxLen _ = 21

radixMaxLead : Char -> Int
radixMaxLead 'b' = 1
radixMaxLead _ = 4

-- Significant digits of [p, endp): '_' separators and leading zeros dropped.
-- Once a nonzero digit is seen the rest is taken verbatim (minus separators),
-- so interior zeros are preserved and only the LEADING run is stripped.
sigRadixDigits : Array Char -> Int -> Int -> List Char
sigRadixDigits src p endp
  | p >= endp = []
  | at src p == '_' || at src p == '0' = sigRadixDigits src (p + 1) endp
  | otherwise = collectNoUs src p endp

radixMagOverflows : List Char -> Int -> Int -> Bool
radixMagOverflows [] _ _ = False
radixMagOverflows (d :: rest) maxLen maxLead =
  let n = 1 + listLen rest
  n > maxLen
    || n == maxLen
      && (digitVal d > maxLead
        || digitVal d == maxLead && anyList (/= '0') rest)

radixLitOverflows : Array Char -> Int -> Int -> Char -> Bool
radixLitOverflows src start endp k =
  radixMagOverflows
    (sigRadixDigits src start endp)
    (radixMaxLen k)
    (radixMaxLead k)

scanRadix : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanRadix ctx src len pos depth id =
  let k = at src (pos + 1)
  let e = radixEnd src len (pos + 2) k
  radixTok ctx src len pos e k depth id

radixTok : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  Char ->
  Int ->
  LexFrame ->
  RawTok
radixTok ctx src len pos e k depth id
  | radixLitOverflows src (pos + 2) e k =
    wideIntTok ctx src pos e depth id (sigRadixDigits src (pos + 2) e)
  | otherwise =
    emitOne
      ctx
      (RTok
        (TInt
          (parseRadix src (pos + 2) e (radixBase k) 0)
          (copyCharRange src pos e))
        pos
        e)
      e
      depth
      id

scanNumber : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanNumber ctx src len pos depth id
  | isRadixPrefix src len pos = scanRadix ctx src len pos depth id
  | isMalformedRadixPrefix src len pos = malformedRadixTok ctx src len pos
  | otherwise = numFinish ctx src len pos (digitsEnd src len pos) depth id

-- `0x`/`0b`/`0o` immediately followed by the digit separator `_` (#677):
-- `isRadixPrefix` already requires a VALID digit right after the prefix, so
-- this is exactly its complementary malformed shape — the prefix is right,
-- but `_` (only legal BETWEEN digits, e.g. `0xD_EAD`) sits where the first
-- digit must be. Caught here, at the source, instead of falling through to
-- `numFinish ctx` (which stops at the lone `0`, leaving `x_FF` to be re-lexed as
-- an ordinary identifier and misreported downstream as "Unbound variable:
-- x_FF").
isMalformedRadixPrefix : Array Char -> Int -> Int -> Bool
isMalformedRadixPrefix src len pos =
  at src pos == '0'
    && pos + 2 < len
    && radixKind (at src (pos + 1))
    && at src (pos + 2) == '_'

malformedRadixTok : ScanCursor -> Array Char -> Int -> Int -> RawTok
malformedRadixTok ctx src len pos =
  let k = at src (pos + 1)
  let e = radixEnd src len (pos + 2) k
  let bad = copyCharRange src pos e
  let digits = stripLeadingUs src (pos + 2) e
  malformedRadixErr ctx pos bad (copyCharRange src pos (pos + 2)) digits

-- Skip a leading run of `_` (there may be more than one, `0x__FF`) to find
-- where the real digits start; `""` when the literal has no digits at all
-- (`0x_`, `0x___`) — that shape gets a fix-less diagnostic, since there is no
-- safe spelling to suggest.
stripLeadingUs : Array Char -> Int -> Int -> String
stripLeadingUs src p e
  | p < e && at src p == '_' = stripLeadingUs src (p + 1) e
  | otherwise = copyCharRange src p e

malformedRadixErr : ScanCursor -> Int -> String -> String -> String -> RawTok
malformedRadixErr ctx pos bad prefix digits =
  lexErrorTok
    ctx
    pos
    (pos + stringLength bad)
    (MalformedRadix bad prefix digits)

isFloatAt : Array Char -> Int -> Int -> Bool
isFloatAt src len e1 =
  e1 < len && at src e1 == '.' && e1 + 1 < len && isDigit (at src (e1 + 1))

isExpMarker : Char -> Bool
isExpMarker c = c == 'e' || c == 'E'

-- Optional decimal exponent `[eE][+-]?[0-9]+` (underscores allowed in the digits,
-- stripped later by `substrNoUs`). Returns the position AFTER the exponent, or `p`
-- unchanged when there is no valid exponent — a bare `e`/`E` NOT followed by an
-- (optionally signed) digit is left for identifier lexing, so `1e`, `x1e`, and the
-- identifier `e12` are untouched; only `<digits>[.<digits>]e[+-]?<digits>` floats.
expEnd : Array Char -> Int -> Int -> Int
expEnd src len p
  | p < len && isExpMarker (at src p) =
    let q =
      if p + 1 < len && (at src (p + 1) == '+' || at src (p + 1) == '-') then
        p + 2
      else
        p + 1
    if q < len && isDigit (at src q) then digitsEnd src len q else p
  | otherwise = p

numFinish : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
numFinish ctx src len pos e1 depth id
  | isFloatAt src len e1 = floatTok ctx src len pos e1 depth id
  | expEnd src len e1 > e1 =
    floatTokEnd ctx src pos (expEnd src len e1) depth id
  | isMalformedExpDot src len e1 = malformedExpDotTok ctx src len pos e1
  | isMalformedTrailingDot src len e1 = malformedTrailingDotTok ctx src pos e1
  | intLitOverflows src pos e1 =
    wideIntTok ctx src pos e1 depth id (collectNoUs src pos e1)
  | otherwise =
    emitOne
      ctx
      (RTok
        (TInt (parseIntFrom src pos e1 0) (copyCharRange src pos e1))
        pos
        e1)
      e1
      depth
      id

-- `<digits>.e<exp>`-shaped (#677, e.g. `5.e3`): a bare `.` right after a
-- just-scanned digit run, immediately followed by something that reads as a
-- decimal exponent (`isFloatAt` already ruled out a fractional digit here).
-- An `Int`/`Float` literal can never have a REAL field named `e3`, so —
-- unlike a generic trailing dot — there is no legitimate reading to protect;
-- this is always the fractional digit missing before the exponent.
isMalformedExpDot : Array Char -> Int -> Int -> Bool
isMalformedExpDot src len e1 =
  e1 < len && at src e1 == '.' && expEnd src len (e1 + 1) > e1 + 1

malformedExpDotTok : ScanCursor -> Array Char -> Int -> Int -> Int -> RawTok
malformedExpDotTok ctx src len pos e1 =
  let expE = expEnd src len (e1 + 1)
  let bad = copyCharRange src pos expE
  let good =
    "\{copyCharRange src pos (e1 + 1)}0\{copyCharRange src (e1 + 1) expE}"
  lexErrorTok ctx pos expE (MalformedFloat bad good False)

-- `<digits>.`-shaped (#677, e.g. `5.`): a bare `.` right after a just-scanned
-- digit run with nothing after it that could continue a (possibly ill-typed
-- but syntactically legal) postfix — a lowercase/underscore field name, `[`
-- for `.[i]` indexing, or another dot-led token (`..`, `..=`, `...`, `.{`,
-- `.*`, all matched upstream in `scanOp ctx` before a bare `.` ever reaches here).
-- Emitted only from a fresh number scan (never for a dot following an
-- already-completed literal several tokens back), so there is no risk of
-- misreading a legitimate chained `(1.5).toString` — that dot is preceded by
-- `)`, not a digit run this call is currently scanning.
isMalformedTrailingDot : Array Char -> Int -> Int -> Bool
isMalformedTrailingDot src len e1 =
  e1 < len && at src e1 == '.' && not (dotContinuesAccess src len e1)

dotContinuesAccess : Array Char -> Int -> Int -> Bool
dotContinuesAccess src len p =
  p + 1 < len
    && (isLower (at src (p + 1))
      || isUpper (at src (p + 1))
      || at src (p + 1) == '_'
      || at src (p + 1) == '['
      || at src (p + 1) == '.'
      || at src (p + 1) == '{'
      || at src (p + 1) == '*')

malformedTrailingDotTok : ScanCursor -> Array Char -> Int -> Int -> RawTok
malformedTrailingDotTok ctx src pos e1 =
  let bad = copyCharRange src pos (e1 + 1)
  lexErrorTok ctx pos (e1 + 1) (MalformedFloat bad (bad ++ "0") False)

floatTok : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
floatTok ctx src len pos e1 depth id =
  let e2 = digitsEnd src len (e1 + 1)
  floatTokEnd ctx src pos (expEnd src len e2) depth id

-- A Float is finite iff `f * 0.0 == 0.0`: for ±inf, `inf * 0.0` is NaN and
-- `NaN == 0.0` is False; for NaN, `NaN == 0.0` is likewise False. There is no
-- `isFinite` extern, so this arithmetic identity is the detection.
floatIsFinite : Float -> Bool
floatIsFinite f = f * 0.0 == 0.0

-- Emit a `TFloat` spanning [pos, endp). `substrNoUs` strips underscores across the
-- whole mantissa+exponent, and `stringToFloat` (strtod) reads the exponent form.
-- A literal whose magnitude overflows the IEEE-754 double range parses to `inf`,
-- which the native backend would emit as an invalid `store double inf`; reject it
-- at the source with a located error rather than let it reach codegen.
floatTokEnd : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
floatTokEnd ctx src pos endp depth id =
  let f = optionOr 0.0 (stringToFloat (substrNoUs src pos endp))
  if floatIsFinite f then
    emitOne ctx (RTok (TFloat f) pos endp) endp depth id
  else
    lexErrorTok ctx pos endp FloatOverflow

isTripleAt : Array Char -> Int -> Int -> Bool
isTripleAt src len p =
  p + 2 < len && isQuote (at src (p + 1)) && isQuote (at src (p + 2))

inHole : LexFrame -> Bool
inHole CodeFrame = False
inHole _ = True

scanLiteral : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  LiteralFlavor ->
  LiteralPart ->
  RawTok
scanLiteral ctx src p quote depth frame flavor part =
  match readLiteral src (LiteralCursor p quote flavor part False (inHole frame))
    Err (LexError kind start end) => lexErrorTok ctx start end kind
    Ok (LiteralRead s next stop leading) => match stop
      LiteralClose =>
        let closeStart = if not (isTriple flavor) then next - 1 else next - 3
        let value =
          if isTriple flavor && not (isContinued part) && leading then
            singleDedent s
          else
            s
        let token =
          if not (isContinued part) then
            RTok (TString value) quote next
          else
            RTok (TInterpEnd value) closeStart next
        emitOne ctx token next depth frame
      LiteralHole =>
        let start = next - 2
        let token =
          if isContinued part then
            RTok (TInterpMid s) start next
          else if isTriple flavor then
            RTripleInterpOpen s start next
          else
            RTok (TInterpOpen s) start next
        emitOne ctx token next depth (HoleFrame flavor start 1)

singleDedent : String -> String
-- Dedents one lexed segment; unrelated to string.dedent, which works on whole text.
-- lint-disable-next-line rule-stdlib-reimpl
singleDedent s = match dedentSegments [s]
  [v] => v
  _ => s

scanChar : ScanCursor -> Array Char -> Int -> Int -> LexFrame -> RawTok
scanChar ctx src pos depth frame = match readCharacter src pos
  Err (LexError kind start end) => lexErrorTok ctx start end kind
  Ok (s, next) => emitOne ctx (RTok (TChar s) (pos + 1) next) next depth frame

-- A `b'` at a token start commits to a byte literal only when a backslash
-- follows (an escape) or one character, optionally with combining marks,
-- closes with `'`.  Anything else (`b''`, `b'ab'`, `b',b'`, `b'+b'`) is a
-- primed name and lexes as an identifier.
opensByteLiteral : Array Char -> Int -> Int -> Bool
opensByteLiteral src len pos =
  pos + 2 < len
    && isApos (at src (pos + 1))
    && not (afterIdentChar src pos)
    && (isBackslash (at src (pos + 2)) || singleCharBody src len (pos + 2))

-- `r` opens a raw literal when it does not continue an identifier and the
-- `"` follows with no space.
opensRawLiteral : Array Char -> Int -> Int -> Bool
opensRawLiteral src len pos =
  pos + 1 < len && isQuote (at src (pos + 1)) && not (afterIdentChar src pos)

-- The token starts at the `r`, so a consumer reading source text at a literal's
-- span start sees the raw prefix.
scanRawLiteral : ScanCursor -> Array Char -> Int -> Int -> LexFrame -> RawTok
scanRawLiteral ctx src pos depth frame = match readRawLiteral src pos
  Ok (value, next) =>
    emitOne ctx (RTok (TString value) pos next) next depth frame
  Err (LexError kind start end) => lexErrorTok ctx start end kind

afterIdentChar : Array Char -> Int -> Bool
afterIdentChar src pos = pos > 0 && isAlnum (at src (pos - 1))

singleCharBody : Array Char -> Int -> Int -> Bool
singleCharBody src len p =
  p + 1 < len && not (isApos (at src p)) && closesAfterMarks src len (p + 1)

closesAfterMarks : Array Char -> Int -> Int -> Bool
closesAfterMarks src len p
  | p >= len = False
  | isApos (at src p) = True
  | isCombiningMark (at src p) = closesAfterMarks src len (p + 1)
  | otherwise = False

isCombiningMark : Char -> Bool
isCombiningMark c = charCode c >= 768 && charCode c <= 879

-- `b'x'` is a byte literal wherever `opensByteLiteral` commits to one; a
-- malformed committed literal is an error, never an identifier.
scanByte : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanByte ctx src len pos depth id = match readByteLiteral src pos
  Ok (value, next) =>
    if byteLiteralIsName src len pos next then
      let old = copyCharRange src pos next
      lexErrorTok ctx pos next (ByteLikeIdent old (byteRename src pos))
    else
      emitOne ctx (RTok (TByte value) pos next) next depth id
  Err (LexError kind start end) => lexErrorTok ctx start end kind

-- A name spelled like a byte literal: glued to more identifier characters, right
-- after a binder keyword, or opening a line (a top-level binding).
byteLiteralIsName : Array Char -> Int -> Int -> Int -> Bool
byteLiteralIsName src len pos next =
  next < len && isAlnum (at src next)
    || atLineStart src pos
    || afterBinderKeyword src pos

atLineStart : Array Char -> Int -> Bool
atLineStart src pos = pos == 0 || isNL (at src (pos - 1))

afterBinderKeyword : Array Char -> Int -> Bool
afterBinderKeyword src pos =
  let e = skipBlanksBack src (pos - 1)
  e >= 2
    && (wordEndsAt src e "let"
      || wordEndsAt src e "rec"
      || wordEndsAt src e "mut")

skipBlanksBack : Array Char -> Int -> Int
skipBlanksBack src p
  | p >= 0 && isSp (at src p) = skipBlanksBack src (p - 1)
  | otherwise = p

-- True when `word` occupies the three chars ending at `e` and is not the tail
-- of a longer identifier.
wordEndsAt : Array Char -> Int -> String -> Bool
wordEndsAt src e word =
  copyCharRange src (e - 2) (e + 1) == word
    && (e < 3 || not (isAlnum (at src (e - 3))))

byteRename : Array Char -> Int -> String
byteRename src pos =
  let c = at src (pos + 2)
  if isLower c || isUpper c || isDigit c then "b_" ++ charToStr c else "b_byte"

export
scanRaw : String -> List RawTok
scanRaw s = scanRawChars (stringToChars s)

export
scanRawChars : Array Char -> List RawTok
scanRawChars src = dedentTripleInterp (scanRawUndedentedChars src)

export
scanRawUndedentedChars : Array Char -> List RawTok
scanRawUndedentedChars src =
  let len = arrayLength src
  let cursor = ScanCursor {
    cursorPos = Ref 0,
    cursorDepth = Ref 0,
    cursorFrame = Ref CodeFrame,
    cursorReady = Ref True,
    cursorLength = len,
  }
  scan src len cursor
emit : ScanCursor -> Int -> Int -> LexFrame -> Token -> Int -> Int -> RawTok
emit ctx pos depth id tok length ddelta =
  emitOne ctx (RTok tok pos (pos + length)) (pos + length) (depth + ddelta) id

scanOp : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  Char ->
  RawTok
scanOp ctx src len pos depth id '.' = scanDotOp ctx src len pos depth id
scanOp ctx src len pos depth id '|' = scanBarOp ctx src len pos depth id
scanOp ctx src len pos depth id '=' = scanEqOp ctx src len pos depth id
scanOp ctx src len pos depth id '<' = scanLtOp ctx src len pos depth id
scanOp ctx src len pos depth id '>' = scanGtOp ctx src len pos depth id
scanOp ctx src len pos depth id ':' = scanColonOp ctx src len pos depth id
scanOp ctx src len pos depth id '[' =
  scanTwoOp ctx src len pos depth id '[' '|' TLArray 1
scanOp ctx src len pos depth id '-' =
  scanTwoOp ctx src len pos depth id '-' '>' TArrow 0
scanOp ctx src len pos depth id '+' =
  scanTwoOp ctx src len pos depth id '+' '+' TPlusPlus 0
scanOp ctx src len pos depth id '!' =
  scanTwoOp ctx src len pos depth id '!' '=' TBangEq 0
scanOp ctx src len pos depth id '/' =
  scanTwoOp ctx src len pos depth id '/' '=' TNeq 0
scanOp ctx src len pos depth id '&' =
  scanTwoOp ctx src len pos depth id '&' '&' TAnd 0
scanOp ctx src len pos depth id c = singleOp ctx src len pos depth id c

scanTwoOp : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  Char ->
  Char ->
  Token ->
  Int ->
  RawTok
scanTwoOp ctx src len pos depth id c b tok ddelta =
  if is2 src len pos c b then
    emit ctx pos depth id tok 2 ddelta
  else
    singleOp ctx src len pos depth id c

scanDotOp : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanDotOp ctx src len pos depth id
  | is3 src len pos '.' '.' '.' = emit ctx pos depth id TEllipsis 3 0
  | is3 src len pos '.' '.' '=' = emit ctx pos depth id TDotDotEq 3 0
  | is2 src len pos '.' '{' = emit ctx pos depth id TDotLBrace 2 1
  | is2 src len pos '.' '*' = emit ctx pos depth id TDotStar 2 0
  | is2 src len pos '.' '.' = emit ctx pos depth id TDotDot 2 0
  | otherwise = singleOp ctx src len pos depth id '.'

scanBarOp : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanBarOp ctx src len pos depth id
  | is2 src len pos '|' ']' = emit ctx pos depth id TRArray 2 (0 - 1)
  | is2 src len pos '|' '|' = emit ctx pos depth id TOr 2 0
  | is2 src len pos '|' '>' = emit ctx pos depth id TPipeRight 2 0
  | otherwise = singleOp ctx src len pos depth id '|'

scanEqOp : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanEqOp ctx src len pos depth id
  | is2 src len pos '=' '>' = emit ctx pos depth id TFatArrow 2 0
  | is2 src len pos '=' '=' = emit ctx pos depth id TEqEq 2 0
  | otherwise = singleOp ctx src len pos depth id '='

scanLtOp : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanLtOp ctx src len pos depth id
  | is2 src len pos '<' '-' = emit ctx pos depth id TLArrow 2 0
  | is2 src len pos '<' '=' = emit ctx pos depth id TLeq 2 0
  | is2 src len pos '<' '<' = emit ctx pos depth id TLCompose 2 0
  | otherwise = singleOp ctx src len pos depth id '<'

scanGtOp : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
scanGtOp ctx src len pos depth id
  | is2 src len pos '>' '=' = emit ctx pos depth id TGeq 2 0
  | is2 src len pos '>' '>' = emit ctx pos depth id TRCompose 2 0
  | otherwise = singleOp ctx src len pos depth id '>'

scanColonOp : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
scanColonOp ctx src len pos depth id
  | is2 src len pos ':' ':' = emit ctx pos depth id TCons 2 0
  | is2 src len pos ':' '=' = emit ctx pos depth id TColonEq 2 0
  | otherwise = singleOp ctx src len pos depth id ':'

singleOp : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  Char ->
  RawTok
singleOp ctx src len pos depth id '+' = emit ctx pos depth id TPlus 1 0
singleOp ctx src len pos depth id '-' =
  emit ctx pos depth id (minusTok src len pos) 1 0
singleOp ctx src len pos depth id '*' = emit ctx pos depth id TStar 1 0
singleOp ctx src len pos depth id '/' = emit ctx pos depth id TSlash 1 0
singleOp ctx src len pos depth id '<' = emit ctx pos depth id TLt 1 0
singleOp ctx src len pos depth id '>' = emit ctx pos depth id TGt 1 0
singleOp ctx src len pos depth id '=' = emit ctx pos depth id TEqual 1 0
singleOp ctx src len pos depth id ':' = emit ctx pos depth id TColon 1 0
singleOp ctx src len pos depth id ',' = emit ctx pos depth id TComma 1 0
singleOp ctx src len pos depth id '.'
  | isMalformedLeadingDot src len pos = malformedLeadingDotTok ctx src len pos
  | otherwise = emit ctx pos depth id TDot 1 0
singleOp ctx src len pos depth id '|' = emit ctx pos depth id TPipe 1 0
singleOp ctx src len pos depth id '(' = emit ctx pos depth id TLParen 1 1
singleOp ctx src len pos depth id ')' = emit ctx pos depth id TRParen 1 (0 - 1)
singleOp ctx src len pos depth id '[' =
  emit ctx pos depth id (bracketTok src pos) 1 1
singleOp ctx src len pos depth id ']' =
  emit ctx pos depth id TRBracket 1 (0 - 1)
singleOp ctx src len pos depth id '{' = openBrace ctx src len pos depth id
singleOp ctx src len pos depth id '}' = closeBrace ctx src len pos depth id
singleOp ctx src len pos depth id '!' = emit ctx pos depth id TBang 1 0
singleOp ctx src len pos depth id '%' = emit ctx pos depth id TMod 1 0
singleOp ctx src len pos depth id '@' =
  emit ctx pos depth id (atToken src pos) 1 0
singleOp ctx src len pos depth id '\\' = lexErrorTok ctx pos (pos + 1) HsLambda
singleOp ctx src len pos depth id '$' = lexErrorTok ctx pos (pos + 1) HsDollar
singleOp ctx src len pos depth id c =
  lexErrorTok ctx pos (pos + 1) (UnexpectedCharacter (charToStr c))

bracketTok : Array Char -> Int -> Token
bracketTok src pos
  | pos > 0 && isExprEnd (at src (pos - 1)) = TLBracketTight
  | otherwise = TLBracket

isExprEnd : Char -> Bool
isExprEnd c = isAlnum c || c == ')' || c == ']' || c == '"'

isMalformedLeadingDot : Array Char -> Int -> Int -> Bool
isMalformedLeadingDot src len pos =
  pos + 1 < len
    && isDigit (at src (pos + 1))
    && (pos == 0 || not (isExprEnd (at src (pos - 1))))

malformedLeadingDotTok : ScanCursor -> Array Char -> Int -> Int -> RawTok
malformedLeadingDotTok ctx src len pos =
  let d = digitsEnd src len (pos + 1)
  let e = expEnd src len d
  let bad = copyCharRange src pos e
  lexErrorTok ctx pos e (MalformedFloat bad ("0" ++ bad) True)

atToken : Array Char -> Int -> Token
atToken src pos
  | pos <= 0 = TAt
  | isAlnum (at src (pos - 1)) = TAsAt
  | otherwise = TAt

minusTok : Array Char -> Int -> Int -> Token
minusTok src len pos
  | pos > 0
    && pos + 1 < len
    && isSpace (at src (pos - 1))
    && isDigit (at src (pos + 1)) = TMinusTight
  | otherwise = TMinus

openBrace : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
openBrace ctx src len pos depth CodeFrame =
  emitOne ctx (RTok TLBrace pos (pos + 1)) (pos + 1) (depth + 1) CodeFrame
openBrace ctx src len pos depth (HoleFrame flavor opener braces) =
  emitOne
    ctx
    (RTok TLBrace pos (pos + 1))
    (pos + 1)
    depth
    (HoleFrame flavor opener (braces + 1))
closeBrace : ScanCursor -> Array Char -> Int -> Int -> Int -> LexFrame -> RawTok
closeBrace ctx src len pos depth CodeFrame =
  emitOne ctx (RTok TRBrace pos (pos + 1)) (pos + 1) (depth - 1) CodeFrame
closeBrace ctx src len pos depth (HoleFrame flavor opener braces)
  | braces > 1 =
    emitOne
      ctx
      (RTok TRBrace pos (pos + 1))
      (pos + 1)
      depth
      (HoleFrame flavor opener (braces - 1))
  | otherwise = match flavor
    PlainLiteral =>
      scanLiteral
        ctx
        src
        (pos + 1)
        pos
        depth
        CodeFrame
        PlainLiteral
        ContinuedLiteral
    TripleLiteral =>
      scanLiteral
        ctx
        src
        (pos + 1)
        pos
        depth
        CodeFrame
        TripleLiteral
        ContinuedLiteral

handleNewline : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  RawTok
handleNewline ctx src len pos depth id =
  let (indent, np) = consumeNl src len pos 0
  afterNl ctx src len np depth id indent pos

consumeNl : Array Char -> Int -> Int -> Int -> (Int, Int)
consumeNl src len p indent
  | p >= len = (indent, p)
  | isCR (at src p) && p + 1 < len && isNL (at src (p + 1)) =
    consumeNl src len (p + 2) 0
  | isNL (at src p) = consumeNl src len (p + 1) 0
  | isCR (at src p) = consumeNl src len (p + 1) 0
  | isSp (at src p) = consumeNl src len (p + 1) (indent + 1)
  | isTab (at src p) = consumeNl src len (p + 1) ((indent / 8 + 1) * 8)
  | otherwise = (indent, p)

afterNl : ScanCursor ->
  Array Char ->
  Int ->
  Int ->
  Int ->
  LexFrame ->
  Int ->
  Int ->
  RawTok
afterNl ctx src len np depth id indent nlPos
  | nextIsComment src len np = scanOne ctx src len np depth id
  | otherwise = match leadingOp src len np
    Some (tok, n) => emit ctx np depth id tok n 0
    None => emitOne ctx (RNewline indent nlPos) np depth id

nextIsComment : Array Char -> Int -> Int -> Bool
nextIsComment src len p =
  p + 1 < len
    && (at src p == '-' && at src (p + 1) == '-'
      || at src p == '{' && at src (p + 1) == '-')

leadingOp : Array Char -> Int -> Int -> Option (Token, Int)
leadingOp src len np
  | is2 src len np '|' '>' = Some (TPipeRight, 2)
  | is2 src len np '>' '>' = Some (TRCompose, 2)
  | is2 src len np '<' '<' = Some (TLCompose, 2)
  | is2 src len np '<' '=' = Some (TLeq, 2)
  | is2 src len np '>' '=' = Some (TGeq, 2)
  | is2 src len np '&' '&' = Some (TAnd, 2)
  | is2 src len np '|' '|' = Some (TOr, 2)
  | is2 src len np '+' '+' = Some (TPlusPlus, 2)
  | is2 src len np ':' ':' = Some (TCons, 2)
  | is2 src len np '=' '=' = Some (TEqEq, 2)
  | is2 src len np '/' '=' = Some (TNeq, 2)
  | is2 src len np '<' '-' = None
  | is2 src len np '-' '>' = None
  | is2 src len np '-' '-' = None
  | is2 src len np '-' '}' = None
  | np < len
    && at src np == '-'
    && np + 1 < len
    && isSp (at src (np + 1)) = Some (TMinus, 1)
  | np < len && at src np == '+' = Some (TPlus, 1)
  | np < len && at src np == '*' = Some (TStar, 1)
  | np < len && at src np == '/' = Some (TSlash, 1)
  | np < len && at src np == '%' = Some (TMod, 1)
  | np < len && at src np == '<' = Some (TLt, 1)
  | np < len && at src np == '>' = Some (TGt, 1)
  | otherwise = None

isTriple : LiteralFlavor -> Bool
isTriple TripleLiteral = True
isTriple _ = False

isContinued : LiteralPart -> Bool
isContinued ContinuedLiteral = True
isContinued _ = False

data ScanCursor = ScanCursor {
  cursorPos : Ref Int,
  cursorDepth : Ref Int,
  cursorFrame : Ref LexFrame,
  cursorReady : Ref Bool,
  cursorLength : Int,
}

scan : Array Char -> Int -> ScanCursor -> List RawTok
scan src len cursor =
  match (scanOne
    cursor
    src
    len
    !cursor.cursorPos
    !cursor.cursorDepth
    !cursor.cursorFrame)
    token => if !cursor.cursorReady then token :: scan src len cursor else []

emitOne : ScanCursor -> RawTok -> Int -> Int -> LexFrame -> RawTok
emitOne cursor token next depth frame =
  cursor.cursorPos := next
  cursor.cursorDepth := depth
  cursor.cursorFrame := frame
  token

endOne : ScanCursor -> RawTok
endOne cursor =
  cursor.cursorReady := False
  RTok TEof 0 0
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "LiteralFlavor" true) (mem "LiteralPart" true) (mem "LiteralCursor" true) (mem "LiteralRead" true) (mem "LiteralStop" true) (mem "LexError" true) (mem "readLiteral" false) (mem "readCharacter" false) (mem "readByteLiteral" false) (mem "readRawLiteral" false) (mem "copyCharRange" false) (mem "dedentSegments" false) (mem "dedentTripleInterp" false))))
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DData Private "LexFrame" () ((variant "CodeFrame" (ConPos)) (variant "HoleFrame" (ConPos (TyCon "LiteralFlavor") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "is2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool")))))))
(DFunDef false "is2" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))))
(DTypeSig false "is3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))))))
(DFunDef false "is3" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "c"))))
(DTypeSig false "collectNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "collectNoUs" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrNoUs" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "start")) (EVar "endp")))))
(DTypeSig false "parseIntFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntFrom" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EApp (EVar "magnitudeInt") (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EVar "p")) (EVar "endp")) (EVar "acc"))))
(DTypeSig false "parseIntNeg" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntNeg" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EBinOp "-" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (ELit (LInt 48))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "magnitudeInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "magnitudeInt" ((PVar "neg")) (EIf (EBinOp "==" (EVar "neg") (EVar "intMinBound")) (EVar "neg") (EBinOp "-" (ELit (LInt 0)) (EVar "neg"))))
(DTypeSig false "intLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "intLitOverflows" ((PVar "src") (PVar "start") (PVar "endp")) (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "start")) (EVar "endp"))) (ELit (LString "4611686018427387904"))) (EVar "Gt")))
(DTypeSig false "wideHalves" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "wideHalves" ((PVar "base") (PVar "digits")) (EApp (EApp (EApp (EApp (EVar "wideHalvesGo") (EVar "base")) (EVar "digits")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "wideHalvesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "wideHalvesGo" (PWild (PList) (PVar "hi") (PVar "lo")) (EApp (EVar "Some") (ETuple (EVar "hi") (EVar "lo"))))
(DFunDef false "wideHalvesGo" ((PVar "base") (PCons (PVar "d") (PVar "rest")) (PVar "hi") (PVar "lo")) (EBlock (DoLet false false (PVar "lo2") (EBinOp "+" (EBinOp "*" (EVar "lo") (EVar "base")) (EApp (EVar "digitVal") (EVar "d")))) (DoLet false false (PVar "hi2") (EBinOp "+" (EBinOp "*" (EVar "hi") (EVar "base")) (EBinOp "/" (EVar "lo2") (ELit (LInt 4294967296))))) (DoExpr (EIf (EBinOp ">" (EVar "hi2") (ELit (LInt 4294967295))) (EVar "None") (EApp (EApp (EApp (EApp (EVar "wideHalvesGo") (EVar "base")) (EVar "rest")) (EVar "hi2")) (EBinOp "%" (EVar "lo2") (ELit (LInt 4294967296))))))))
(DTypeSig false "wideIntTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "RawTok")))))))))
(DFunDef false "wideIntTok" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "e") (PVar "depth") (PVar "id") (PVar "digits")) (EMatch (EApp (EApp (EVar "wideHalves") (EApp (EApp (EVar "wideBase") (EVar "src")) (EVar "pos"))) (EVar "digits")) (arm (PCon "Some" (PTuple (PVar "hi") (PVar "lo"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "TWideInt") (EVar "hi")) (EVar "lo")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "e")) (EVar "IntegerOverflow")))))
(DTypeSig false "wideBase" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wideBase" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "src")))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "radixBase") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EIf (EVar "otherwise") (ELit (LInt 10)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "keywordOrIdent" (TyFun (TyCon "String") (TyCon "Token")))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PLit (LString "with"))) (EVar "TWith"))
(DFunDef false "keywordOrIdent" ((PLit (LString "mut"))) (EVar "TMut"))
(DFunDef false "keywordOrIdent" ((PLit (LString "in"))) (EVar "TIn"))
(DFunDef false "keywordOrIdent" ((PLit (LString "if"))) (EVar "TIf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "then"))) (EVar "TThen"))
(DFunDef false "keywordOrIdent" ((PLit (LString "else"))) (EVar "TElse"))
(DFunDef false "keywordOrIdent" ((PLit (LString "match"))) (EVar "TMatch"))
(DFunDef false "keywordOrIdent" ((PLit (LString "data"))) (EVar "TData"))
(DFunDef false "keywordOrIdent" ((PLit (LString "interface"))) (EVar "TInterface"))
(DFunDef false "keywordOrIdent" ((PLit (LString "default"))) (EVar "TDefault"))
(DFunDef false "keywordOrIdent" ((PLit (LString "impl"))) (EVar "TImpl"))
(DFunDef false "keywordOrIdent" ((PLit (LString "import"))) (EVar "TImport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "export"))) (EVar "TExport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "public"))) (EVar "TPublic"))
(DFunDef false "keywordOrIdent" ((PLit (LString "where"))) (EVar "TWhere"))
(DFunDef false "keywordOrIdent" ((PLit (LString "of"))) (EVar "TOf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "do"))) (EVar "TDo"))
(DFunDef false "keywordOrIdent" ((PLit (LString "defer"))) (EVar "TDefer"))
(DFunDef false "keywordOrIdent" ((PLit (LString "as"))) (EVar "TAs"))
(DFunDef false "keywordOrIdent" ((PLit (LString "extern"))) (EVar "TExtern"))
(DFunDef false "keywordOrIdent" ((PLit (LString "requires"))) (EVar "TRequires"))
(DFunDef false "keywordOrIdent" ((PLit (LString "deriving"))) (EVar "TDeriving"))
(DFunDef false "keywordOrIdent" ((PLit (LString "type"))) (EVar "TType"))
(DFunDef false "keywordOrIdent" ((PLit (LString "newtype"))) (EVar "TNewtype"))
(DFunDef false "keywordOrIdent" ((PLit (LString "prop"))) (EVar "TProp"))
(DFunDef false "keywordOrIdent" ((PLit (LString "test"))) (EVar "TTest"))
(DFunDef false "keywordOrIdent" ((PLit (LString "bench"))) (EVar "TBench"))
(DFunDef false "keywordOrIdent" ((PLit (LString "effect"))) (EVar "TEffect"))
(DFunDef false "keywordOrIdent" ((PLit (LString "function"))) (EVar "TFunction"))
(DFunDef false "keywordOrIdent" ((PVar "s")) (EApp (EVar "TIdent") (EVar "s")))
(DTypeSig false "scanOne" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanOne" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "pos") (EVar "len")) (EApp (EVar "endOne") (EVar "ctx")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanAt") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanAt" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "scanAt" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EVar "isSpace") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "ctx")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isNL") (EVar "c")) (EApp (EVar "isCR") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleNewline") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "#"))) (EBinOp "==" (EVar "pos") (ELit (LInt 0)))) (EBinOp ">" (EVar "len") (ELit (LInt 1)))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (ELit (LInt 1))) (ELit (LChar "!")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RComment") (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "len")) (EVar "UnterminatedComment")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RComment") (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id"))))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanNumber") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TripleLiteral")) (EVar "InitialLiteral")) (EIf (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "PlainLiteral")) (EVar "InitialLiteral")) (EIf (EApp (EVar "isApos") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanChar") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EApp (EVar "opensByteLiteral") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanByte") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EApp (EApp (EVar "opensRawLiteral") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanRawLiteral") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLower") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanUpper") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBacktick") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanBacktick") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))
(DTypeSig false "skipLineComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipLineComment" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EBinOp "||" (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lexErrorTok" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "RawTok"))))))
(DFunDef false "lexErrorTok" ((PVar "ctx") (PVar "p") (PVar "end") (PVar "kind")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "cursorPos")) (EFieldAccess (EVar "ctx") "cursorLength"))) (DoExpr (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TLexError") (EVar "kind"))) (EVar "p")) (EVar "end")))))
(DTypeSig false "skipBlockComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "skipBlockComment" ((PVar "src") (PVar "len") (PVar "p") (PVar "d")) (EIf (EBinOp "<=" (EVar "d") (ELit (LInt 0))) (EVar "p") (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "}")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanLower" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanLower" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "identToken") (EVar "src")) (EVar "pos")) (EVar "e"))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "identToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "identToken" ((PVar "src") (PVar "pos") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "_"))) (EBinOp "==" (EBinOp "-" (EVar "e") (EVar "pos")) (ELit (LInt 1)))) (EVar "TUnderscore") (EIf (EApp (EApp (EApp (EVar "kwCandidate") (EVar "src")) (EVar "pos")) (EVar "e")) (EApp (EVar "keywordOrIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (EIf (EVar "otherwise") (EApp (EVar "TIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "kwCandidate" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "kwCandidate" ((PVar "src") (PVar "pos") (PVar "e")) (EBlock (DoLet false false (PVar "n") (EBinOp "-" (EVar "e") (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "kwStart") (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")))))))
(DTypeSig false "kwStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "kwStart" ((PLit (LChar "a"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "b"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "d"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "e"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "f"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "i"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "l"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "m"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "n"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "o"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "p"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "r"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "t"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "w"))) (EVar "True"))
(DFunDef false "kwStart" (PWild) (EVar "False"))
(DTypeSig false "scanUpper" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanUpper" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TUpper") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "scanBacktick" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanBacktick" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TBacktickIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "e")))) (EVar "pos")) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "btClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "btClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isBacktick") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "digitsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "isRadixDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "radixKind" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "radixKind" ((PVar "k")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LChar "x"))) (EBinOp "==" (EVar "k") (ELit (LChar "b")))) (EBinOp "==" (EVar "k") (ELit (LChar "o")))))
(DTypeSig false "radixBase" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixBase" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixBase" ((PLit (LChar "b"))) (ELit (LInt 2)))
(DFunDef false "radixBase" (PWild) (ELit (LInt 8)))
(DTypeSig false "isRadixDigit" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isRadixDigit" ((PLit (LChar "x")) (PVar "c")) (EApp (EVar "isHexDigit") (EVar "c")))
(DFunDef false "isRadixDigit" ((PLit (LChar "b")) (PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "1")))))
(DFunDef false "isRadixDigit" (PWild (PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "7")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87))) (EIf (EVar "otherwise") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Int"))))))
(DFunDef false "radixEnd" ((PVar "src") (PVar "len") (PVar "p") (PVar "k")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EApp (EVar "isRadixDigit") (EVar "k")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "k")) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadix" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EApp (EVar "magnitudeInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EVar "p")) (EVar "endp")) (EVar "base")) (EVar "acc"))))
(DTypeSig false "parseRadixNeg" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadixNeg" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EBinOp "-" (EBinOp "*" (EVar "acc") (EVar "base")) (EApp (EVar "digitVal") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMaxLen" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLen" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixMaxLen" ((PLit (LChar "b"))) (ELit (LInt 63)))
(DFunDef false "radixMaxLen" (PWild) (ELit (LInt 21)))
(DTypeSig false "radixMaxLead" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLead" ((PLit (LChar "b"))) (ELit (LInt 1)))
(DFunDef false "radixMaxLead" (PWild) (ELit (LInt 4)))
(DTypeSig false "sigRadixDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sigRadixDigits" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0")))) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "p")) (EVar "endp")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMagOverflows" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "radixMagOverflows" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "radixMagOverflows" ((PCons (PVar "d") (PVar "rest")) (PVar "maxLen") (PVar "maxLead")) (EBlock (DoLet false false (PVar "n") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rest")))) (DoExpr (EBinOp "||" (EBinOp ">" (EVar "n") (EVar "maxLen")) (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "maxLen")) (EBinOp "||" (EBinOp ">" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LChar "0"))))) (EVar "rest")))))))))
(DTypeSig false "radixLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "radixLitOverflows" ((PVar "src") (PVar "start") (PVar "endp") (PVar "k")) (EApp (EApp (EApp (EVar "radixMagOverflows") (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EVar "start")) (EVar "endp"))) (EApp (EVar "radixMaxLen") (EVar "k"))) (EApp (EVar "radixMaxLead") (EVar "k"))))
(DTypeSig false "scanRadix" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanRadix" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "radixTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e")) (EVar "k")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "radixTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))))
(DFunDef false "radixTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e") (PVar "k") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EVar "radixLitOverflows") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wideIntTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EApp (EVar "radixBase") (EVar "k"))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanNumber" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanNumber" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanRadix") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "malformedRadixTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "numFinish") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "pos"))) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMalformedRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LChar "_")))))
(DTypeSig false "malformedRadixTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedRadixTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoLet false false (PVar "digits") (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "malformedRadixErr") (EVar "ctx")) (EVar "pos")) (EVar "bad")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "digits")))))
(DTypeSig false "stripLeadingUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripLeadingUs" ((PVar "src") (PVar "p") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))) (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "malformedRadixErr" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "RawTok")))))))
(DFunDef false "malformedRadixErr" ((PVar "ctx") (PVar "pos") (PVar "bad") (PVar "prefix") (PVar "digits")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EApp (EVar "stringLength") (EVar "bad")))) (EApp (EApp (EApp (EVar "MalformedRadix") (EVar "bad")) (EVar "prefix")) (EVar "digits"))))
(DTypeSig false "isFloatAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isFloatAt" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp "<" (EBinOp "+" (EVar "e1") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))))
(DTypeSig false "isExpMarker" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpMarker" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "expEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "expEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isExpMarker") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EBlock (DoLet false false (PVar "q") (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "+"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "q") (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "q")))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "p")))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "numFinish" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))))
(DFunDef false "numFinish" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isFloatAt") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1"))) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedExpDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "malformedExpDotTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "isMalformedTrailingDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "malformedTrailingDotTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "intLitOverflows") (EVar "src")) (EVar "pos")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wideIntTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "pos")) (EVar "e1"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EVar "pos")) (EVar "e1")) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e1")))) (EVar "pos")) (EVar "e1"))) (EVar "e1")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isMalformedExpDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedExpDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))))
(DTypeSig false "malformedExpDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok")))))))
(DFunDef false "malformedExpDotTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "expE") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "expE"))) (DoLet false false (PVar "good") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))) (ELit (LString "0"))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EVar "expE")))) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "expE")) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EVar "good")) (EVar "False"))))))
(DTypeSig false "isMalformedTrailingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedTrailingDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "dotContinuesAccess") (EVar "src")) (EVar "len")) (EVar "e1")))))
(DTypeSig false "dotContinuesAccess" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "dotContinuesAccess" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EApp (EVar "isUpper") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "[")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar ".")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "*"))))))
(DTypeSig false "malformedTrailingDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedTrailingDotTok" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EBinOp "++" (EVar "bad") (ELit (LString "0")))) (EVar "False"))))))
(DTypeSig false "floatTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))))
(DFunDef false "floatTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e2"))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "floatIsFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatIsFinite" ((PVar "f")) (EBinOp "==" (EBinOp "*" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))
(DTypeSig false "floatTokEnd" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "floatTokEnd" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "endp") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "optionOr") (ELit (LFloat 0.0))) (EApp (EVar "stringToFloat") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "pos")) (EVar "endp"))))) (DoExpr (EIf (EApp (EVar "floatIsFinite") (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TFloat") (EVar "f"))) (EVar "pos")) (EVar "endp"))) (EVar "endp")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "endp")) (EVar "FloatOverflow"))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))))
(DTypeSig false "inHole" (TyFun (TyCon "LexFrame") (TyCon "Bool")))
(DFunDef false "inHole" ((PCon "CodeFrame")) (EVar "False"))
(DFunDef false "inHole" (PWild) (EVar "True"))
(DTypeSig false "scanLiteral" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyCon "RawTok"))))))))))
(DFunDef false "scanLiteral" ((PVar "ctx") (PVar "src") (PVar "p") (PVar "quote") (PVar "depth") (PVar "frame") (PVar "flavor") (PVar "part")) (EMatch (EApp (EApp (EVar "readLiteral") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "LiteralCursor") (EVar "p")) (EVar "quote")) (EVar "flavor")) (EVar "part")) (EVar "False")) (EApp (EVar "inHole") (EVar "frame")))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind"))) (arm (PCon "Ok" (PCon "LiteralRead" (PVar "s") (PVar "next") (PVar "stop") (PVar "leading"))) () (EMatch (EVar "stop") (arm (PCon "LiteralClose") () (EBlock (DoLet false false (PVar "closeStart") (EIf (EApp (EVar "not") (EApp (EVar "isTriple") (EVar "flavor"))) (EBinOp "-" (EVar "next") (ELit (LInt 1))) (EBinOp "-" (EVar "next") (ELit (LInt 3))))) (DoLet false false (PVar "value") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isTriple") (EVar "flavor")) (EApp (EVar "not") (EApp (EVar "isContinued") (EVar "part")))) (EVar "leading")) (EApp (EVar "singleDedent") (EVar "s")) (EVar "s"))) (DoLet false false (PVar "token") (EIf (EApp (EVar "not") (EApp (EVar "isContinued") (EVar "part"))) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "value"))) (EVar "quote")) (EVar "next")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "value"))) (EVar "closeStart")) (EVar "next")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EVar "token")) (EVar "next")) (EVar "depth")) (EVar "frame"))))) (arm (PCon "LiteralHole") () (EBlock (DoLet false false (PVar "start") (EBinOp "-" (EVar "next") (ELit (LInt 2)))) (DoLet false false (PVar "token") (EIf (EApp (EVar "isContinued") (EVar "part")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "start")) (EVar "next")) (EIf (EApp (EVar "isTriple") (EVar "flavor")) (EApp (EApp (EApp (EVar "RTripleInterpOpen") (EVar "s")) (EVar "start")) (EVar "next")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "s"))) (EVar "start")) (EVar "next"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EVar "token")) (EVar "next")) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "start")) (ELit (LInt 1)))))))))))
(DTypeSig false "singleDedent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "singleDedent" ((PVar "s")) (EMatch (EApp (EVar "dedentSegments") (EListLit (EVar "s"))) (arm (PList (PVar "v")) () (EVar "v")) (arm PWild () (EVar "s"))))
(DTypeSig false "scanChar" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "scanChar" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "depth") (PVar "frame")) (EMatch (EApp (EApp (EVar "readCharacter") (EVar "src")) (EVar "pos")) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "next"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EVar "s"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "frame")))))
(DTypeSig false "opensByteLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "opensByteLiteral" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EVar "afterIdentChar") (EVar "src")) (EVar "pos")))) (EBinOp "||" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "singleCharBody") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "opensRawLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "opensRawLiteral" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EVar "afterIdentChar") (EVar "src")) (EVar "pos")))))
(DTypeSig false "scanRawLiteral" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "scanRawLiteral" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "depth") (PVar "frame")) (EMatch (EApp (EApp (EVar "readRawLiteral") (EVar "src")) (EVar "pos")) (arm (PCon "Ok" (PTuple (PVar "value") (PVar "next"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "value"))) (EVar "pos")) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "frame"))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind")))))
(DTypeSig false "afterIdentChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "afterIdentChar" ((PVar "src") (PVar "pos")) (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))
(DTypeSig false "singleCharBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "singleCharBody" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EApp (EApp (EVar "closesAfterMarks") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))))
(DTypeSig false "closesAfterMarks" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "closesAfterMarks" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "False") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "True") (EIf (EApp (EVar "isCombiningMark") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EVar "closesAfterMarks") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isCombiningMark" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCombiningMark" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 768))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 879)))))
(DTypeSig false "scanByte" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanByte" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EMatch (EApp (EApp (EVar "readByteLiteral") (EVar "src")) (EVar "pos")) (arm (PCon "Ok" (PTuple (PVar "value") (PVar "next"))) () (EIf (EApp (EApp (EApp (EApp (EVar "byteLiteralIsName") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "next")) (EBlock (DoLet false false (PVar "old") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "next"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "next")) (EApp (EApp (EVar "ByteLikeIdent") (EVar "old")) (EApp (EApp (EVar "byteRename") (EVar "src")) (EVar "pos")))))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TByte") (EVar "value"))) (EVar "pos")) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "id")))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind")))))
(DTypeSig false "byteLiteralIsName" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "byteLiteralIsName" ((PVar "src") (PVar "len") (PVar "pos") (PVar "next")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp "<" (EVar "next") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "next")))) (EApp (EApp (EVar "atLineStart") (EVar "src")) (EVar "pos"))) (EApp (EApp (EVar "afterBinderKeyword") (EVar "src")) (EVar "pos"))))
(DTypeSig false "atLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "atLineStart" ((PVar "src") (PVar "pos")) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))
(DTypeSig false "afterBinderKeyword" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "afterBinderKeyword" ((PVar "src") (PVar "pos")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EVar "skipBlanksBack") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "e") (ELit (LInt 2))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "let"))) (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "rec")))) (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "mut"))))))))
(DTypeSig false "skipBlanksBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipBlanksBack" ((PVar "src") (PVar "p")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "p") (ELit (LInt 0))) (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EVar "skipBlanksBack") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wordEndsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "wordEndsAt" ((PVar "src") (PVar "e") (PVar "word")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "-" (EVar "e") (ELit (LInt 2)))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "word")) (EBinOp "||" (EBinOp "<" (EVar "e") (ELit (LInt 3))) (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "e") (ELit (LInt 3)))))))))
(DTypeSig false "byteRename" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "byteRename" ((PVar "src") (PVar "pos")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EApp (EVar "isDigit") (EVar "c"))) (EBinOp "++" (ELit (LString "b_")) (EApp (EVar "charToStr") (EVar "c"))) (ELit (LString "b_byte"))))))
(DTypeSig true "scanRaw" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRaw" ((PVar "s")) (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig true "scanRawChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRawChars" ((PVar "src")) (EApp (EVar "dedentTripleInterp") (EApp (EVar "scanRawUndedentedChars") (EVar "src"))))
(DTypeSig true "scanRawUndedentedChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRawUndedentedChars" ((PVar "src")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "cursor") (ERecordCreate "ScanCursor" ((fa "cursorPos" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "cursorDepth" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "cursorFrame" (EApp (EVar "Ref") (EVar "CodeFrame"))) (fa "cursorReady" (EApp (EVar "Ref") (EVar "True"))) (fa "cursorLength" (EVar "len"))))) (DoExpr (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "cursor")))))
(DTypeSig false "emit" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok")))))))))
(DFunDef false "emit" ((PVar "ctx") (PVar "pos") (PVar "depth") (PVar "id") (PVar "tok") (PVar "length") (PVar "ddelta")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "tok")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "length")))) (EBinOp "+" (EVar "pos") (EVar "length"))) (EBinOp "+" (EVar "depth") (EVar "ddelta"))) (EVar "id")))
(DTypeSig false "scanOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanDotOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanBarOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanEqOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLtOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanGtOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanColonOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "["))) (ELit (LChar "|"))) (EVar "TLArray")) (ELit (LInt 1))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EVar "TArrow")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EVar "TPlusPlus")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "!"))) (ELit (LChar "="))) (EVar "TBangEq")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "/"))) (ELit (LChar "="))) (EVar "TNeq")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "&"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EVar "TAnd")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")))
(DTypeSig false "scanTwoOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyCon "RawTok"))))))))))))
(DFunDef false "scanTwoOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c") (PVar "b") (PVar "tok") (PVar "ddelta")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "c")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "tok")) (ELit (LInt 2))) (EVar "ddelta")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c"))))
(DTypeSig false "scanDotOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanDotOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEllipsis")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDotEq")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotLBrace")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotStar")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDot")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "scanBarOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanBarOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRArray")) (ELit (LInt 2))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TOr")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipeRight")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "|"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "scanEqOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanEqOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TFatArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "="))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanLtOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanLtOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "<"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "scanGtOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanGtOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar ">"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanColonOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanColonOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TCons")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColonEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar ":"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "singleOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlus")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "minusTok") (EVar "src")) (EVar "len")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TStar")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlash")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqual")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColon")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ","))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TComma")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EIf (EApp (EApp (EApp (EVar "isMalformedLeadingDot") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "malformedLeadingDotTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDot")) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipe")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "("))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLParen")) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRParen")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "bracketTok") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRBracket")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openBrace") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closeBrace") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TBang")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "%"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TMod")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "@"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "atToken") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "\\"))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "HsLambda")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "$"))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "HsDollar")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "UnexpectedCharacter") (EApp (EVar "charToStr") (EVar "c")))))
(DTypeSig false "bracketTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "bracketTok" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TLBracketTight") (EIf (EVar "otherwise") (EVar "TLBracket") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExprEnd" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExprEnd" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "\"")))))
(DTypeSig false "isMalformedLeadingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedLeadingDot" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig false "malformedLeadingDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedLeadingDotTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "d"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EBinOp "++" (ELit (LString "0")) (EVar "bad"))) (EVar "True"))))))
(DTypeSig false "atToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "atToken" ((PVar "src") (PVar "pos")) (EIf (EBinOp "<=" (EVar "pos") (ELit (LInt 0))) (EVar "TAt") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (EVar "TAsAt") (EIf (EVar "otherwise") (EVar "TAt") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minusTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "minusTok" ((PVar "src") (PVar "len") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSpace") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EVar "TMinusTight") (EIf (EVar "otherwise") (EVar "TMinus") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "openBrace" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "openBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "CodeFrame")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "CodeFrame")))
(DFunDef false "openBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "HoleFrame" (PVar "flavor") (PVar "opener") (PVar "braces"))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "opener")) (EBinOp "+" (EVar "braces") (ELit (LInt 1))))))
(DTypeSig false "closeBrace" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "closeBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "CodeFrame")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "CodeFrame")))
(DFunDef false "closeBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "HoleFrame" (PVar "flavor") (PVar "opener") (PVar "braces"))) (EIf (EBinOp ">" (EVar "braces") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "opener")) (EBinOp "-" (EVar "braces") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EMatch (EVar "flavor") (arm (PCon "PlainLiteral") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "CodeFrame")) (EVar "PlainLiteral")) (EVar "ContinuedLiteral"))) (arm (PCon "TripleLiteral") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "CodeFrame")) (EVar "TripleLiteral")) (EVar "ContinuedLiteral")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleNewline" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "handleNewline" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PTuple (PVar "indent") (PVar "np")) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "afterNl") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "indent")) (EVar "pos")))))
(DTypeSig false "consumeNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "consumeNl" ((PVar "src") (PVar "len") (PVar "p") (PVar "indent")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (ETuple (EVar "indent") (EVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 0))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "indent") (ELit (LInt 1)))) (EIf (EApp (EVar "isTab") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "*" (EBinOp "+" (EBinOp "/" (EVar "indent") (ELit (LInt 8))) (ELit (LInt 1))) (ELit (LInt 8)))) (EIf (EVar "otherwise") (ETuple (EVar "indent") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "afterNl" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))))))
(DFunDef false "afterNl" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "np") (PVar "depth") (PVar "id") (PVar "indent") (PVar "nlPos")) (EIf (EApp (EApp (EApp (EVar "nextIsComment") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "leadingOp") (EVar "src")) (EVar "len")) (EVar "np")) (arm (PCon "Some" (PTuple (PVar "tok") (PVar "n"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "tok")) (EVar "n")) (ELit (LInt 0)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RNewline") (EVar "indent")) (EVar "nlPos"))) (EVar "np")) (EVar "depth")) (EVar "id")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextIsComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextIsComment" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))))))
(DTypeSig false "leadingOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Token") (TyCon "Int")))))))
(DFunDef false "leadingOp" ((PVar "src") (PVar "len") (PVar "np")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EVar "Some") (ETuple (EVar "TPipeRight") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EVar "Some") (ETuple (EVar "TRCompose") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EVar "Some") (ETuple (EVar "TLCompose") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TLeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TGeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EApp (EVar "Some") (ETuple (EVar "TAnd") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EVar "Some") (ETuple (EVar "TOr") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EApp (EVar "Some") (ETuple (EVar "TPlusPlus") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EVar "Some") (ETuple (EVar "TCons") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TEqEq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "/"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TNeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar "-"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar "}"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "-")))) (EBinOp "<" (EBinOp "+" (EVar "np") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "np") (ELit (LInt 1)))))) (EApp (EVar "Some") (ETuple (EVar "TMinus") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "+")))) (EApp (EVar "Some") (ETuple (EVar "TPlus") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "*")))) (EApp (EVar "Some") (ETuple (EVar "TStar") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "/")))) (EApp (EVar "Some") (ETuple (EVar "TSlash") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "%")))) (EApp (EVar "Some") (ETuple (EVar "TMod") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "<")))) (EApp (EVar "Some") (ETuple (EVar "TLt") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar ">")))) (EApp (EVar "Some") (ETuple (EVar "TGt") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))))))
(DTypeSig false "isTriple" (TyFun (TyCon "LiteralFlavor") (TyCon "Bool")))
(DFunDef false "isTriple" ((PCon "TripleLiteral")) (EVar "True"))
(DFunDef false "isTriple" (PWild) (EVar "False"))
(DTypeSig false "isContinued" (TyFun (TyCon "LiteralPart") (TyCon "Bool")))
(DFunDef false "isContinued" ((PCon "ContinuedLiteral")) (EVar "True"))
(DFunDef false "isContinued" (PWild) (EVar "False"))
(DData Private "ScanCursor" () ((variant "ScanCursor" (ConNamed (field "cursorPos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "cursorDepth" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "cursorFrame" (TyApp (TyCon "Ref") (TyCon "LexFrame"))) (field "cursorReady" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "cursorLength" (TyCon "Int"))))) ())
(DTypeSig false "scan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "ScanCursor") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "scan" ((PVar "src") (PVar "len") (PVar "cursor")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "cursor")) (EVar "src")) (EVar "len")) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorPos"))) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorDepth"))) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorFrame"))) (arm (PVar "token") () (EIf (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorReady")) (EBinOp "::" (EVar "token") (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "cursor"))) (EListLit)))))
(DTypeSig false "emitOne" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "RawTok") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "emitOne" ((PVar "cursor") (PVar "token") (PVar "next") (PVar "depth") (PVar "frame")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorPos")) (EVar "next"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorDepth")) (EVar "depth"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorFrame")) (EVar "frame"))) (DoExpr (EVar "token"))))
(DTypeSig false "endOne" (TyFun (TyCon "ScanCursor") (TyCon "RawTok")))
(DFunDef false "endOne" ((PVar "cursor")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorReady")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EVar "RTok") (EVar "TEof")) (ELit (LInt 0))) (ELit (LInt 0))))))
# MARK
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "lex_literal") ((mem "LiteralFlavor" true) (mem "LiteralPart" true) (mem "LiteralCursor" true) (mem "LiteralRead" true) (mem "LiteralStop" true) (mem "LexError" true) (mem "readLiteral" false) (mem "readCharacter" false) (mem "readByteLiteral" false) (mem "readRawLiteral" false) (mem "copyCharRange" false) (mem "dedentSegments" false) (mem "dedentTripleInterp" false))))
(DUse false (UseGroup ("support" "char") ((mem "isSp" false) (mem "isTab" false) (mem "isNL" false) (mem "isCR" false) (mem "isQuote" false) (mem "isApos" false) (mem "isBackslash" false) (mem "isBacktick" false) (mem "isSpace" false) (mem "isDigit" false) (mem "isLower" false) (mem "isUpper" false) (mem "isAlnum" false) (mem "isHexDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "compareDecMag" false) (mem "listLen" false) (mem "anyList" false))))
(DData Private "LexFrame" () ((variant "CodeFrame" (ConPos)) (variant "HoleFrame" (ConPos (TyCon "LiteralFlavor") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "at" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "at" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "is2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool")))))))
(DFunDef false "is2" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))))
(DTypeSig false "is3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))))))
(DFunDef false "is3" ((PVar "src") (PVar "len") (PVar "pos") (PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (EVar "a"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "b"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "c"))))
(DTypeSig false "collectNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "collectNoUs" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "substrNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "substrNoUs" ((PVar "src") (PVar "start") (PVar "endp")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "start")) (EVar "endp")))))
(DTypeSig false "parseIntFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntFrom" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EApp (EVar "magnitudeInt") (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EVar "p")) (EVar "endp")) (EVar "acc"))))
(DTypeSig false "parseIntNeg" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseIntNeg" ((PVar "src") (PVar "p") (PVar "endp") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseIntNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EBinOp "-" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (ELit (LInt 48))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "magnitudeInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "magnitudeInt" ((PVar "neg")) (EIf (EBinOp "==" (EVar "neg") (EVar "intMinBound")) (EVar "neg") (EBinOp "-" (ELit (LInt 0)) (EVar "neg"))))
(DTypeSig false "intLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "intLitOverflows" ((PVar "src") (PVar "start") (PVar "endp")) (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "start")) (EVar "endp"))) (ELit (LString "4611686018427387904"))) (EVar "Gt")))
(DTypeSig false "wideHalves" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "wideHalves" ((PVar "base") (PVar "digits")) (EApp (EApp (EApp (EApp (EVar "wideHalvesGo") (EVar "base")) (EVar "digits")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "wideHalvesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "wideHalvesGo" (PWild (PList) (PVar "hi") (PVar "lo")) (EApp (EVar "Some") (ETuple (EVar "hi") (EVar "lo"))))
(DFunDef false "wideHalvesGo" ((PVar "base") (PCons (PVar "d") (PVar "rest")) (PVar "hi") (PVar "lo")) (EBlock (DoLet false false (PVar "lo2") (EBinOp "+" (EBinOp "*" (EVar "lo") (EVar "base")) (EApp (EVar "digitVal") (EVar "d")))) (DoLet false false (PVar "hi2") (EBinOp "+" (EBinOp "*" (EVar "hi") (EVar "base")) (EBinOp "/" (EVar "lo2") (ELit (LInt 4294967296))))) (DoExpr (EIf (EBinOp ">" (EVar "hi2") (ELit (LInt 4294967295))) (EVar "None") (EApp (EApp (EApp (EApp (EVar "wideHalvesGo") (EVar "base")) (EVar "rest")) (EVar "hi2")) (EBinOp "%" (EVar "lo2") (ELit (LInt 4294967296))))))))
(DTypeSig false "wideIntTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "RawTok")))))))))
(DFunDef false "wideIntTok" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "e") (PVar "depth") (PVar "id") (PVar "digits")) (EMatch (EApp (EApp (EVar "wideHalves") (EApp (EApp (EVar "wideBase") (EVar "src")) (EVar "pos"))) (EVar "digits")) (arm (PCon "Some" (PTuple (PVar "hi") (PVar "lo"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "TWideInt") (EVar "hi")) (EVar "lo")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "e")) (EVar "IntegerOverflow")))))
(DTypeSig false "wideBase" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wideBase" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "src")))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "radixBase") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EIf (EVar "otherwise") (ELit (LInt 10)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "keywordOrIdent" (TyFun (TyCon "String") (TyCon "Token")))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PLit (LString "with"))) (EVar "TWith"))
(DFunDef false "keywordOrIdent" ((PLit (LString "mut"))) (EVar "TMut"))
(DFunDef false "keywordOrIdent" ((PLit (LString "in"))) (EVar "TIn"))
(DFunDef false "keywordOrIdent" ((PLit (LString "if"))) (EVar "TIf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "then"))) (EVar "TThen"))
(DFunDef false "keywordOrIdent" ((PLit (LString "else"))) (EVar "TElse"))
(DFunDef false "keywordOrIdent" ((PLit (LString "match"))) (EVar "TMatch"))
(DFunDef false "keywordOrIdent" ((PLit (LString "data"))) (EVar "TData"))
(DFunDef false "keywordOrIdent" ((PLit (LString "interface"))) (EVar "TInterface"))
(DFunDef false "keywordOrIdent" ((PLit (LString "default"))) (EVar "TDefault"))
(DFunDef false "keywordOrIdent" ((PLit (LString "impl"))) (EVar "TImpl"))
(DFunDef false "keywordOrIdent" ((PLit (LString "import"))) (EVar "TImport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "export"))) (EVar "TExport"))
(DFunDef false "keywordOrIdent" ((PLit (LString "public"))) (EVar "TPublic"))
(DFunDef false "keywordOrIdent" ((PLit (LString "where"))) (EVar "TWhere"))
(DFunDef false "keywordOrIdent" ((PLit (LString "of"))) (EVar "TOf"))
(DFunDef false "keywordOrIdent" ((PLit (LString "do"))) (EVar "TDo"))
(DFunDef false "keywordOrIdent" ((PLit (LString "defer"))) (EVar "TDefer"))
(DFunDef false "keywordOrIdent" ((PLit (LString "as"))) (EVar "TAs"))
(DFunDef false "keywordOrIdent" ((PLit (LString "extern"))) (EVar "TExtern"))
(DFunDef false "keywordOrIdent" ((PLit (LString "requires"))) (EVar "TRequires"))
(DFunDef false "keywordOrIdent" ((PLit (LString "deriving"))) (EVar "TDeriving"))
(DFunDef false "keywordOrIdent" ((PLit (LString "type"))) (EVar "TType"))
(DFunDef false "keywordOrIdent" ((PLit (LString "newtype"))) (EVar "TNewtype"))
(DFunDef false "keywordOrIdent" ((PLit (LString "prop"))) (EVar "TProp"))
(DFunDef false "keywordOrIdent" ((PLit (LString "test"))) (EVar "TTest"))
(DFunDef false "keywordOrIdent" ((PLit (LString "bench"))) (EVar "TBench"))
(DFunDef false "keywordOrIdent" ((PLit (LString "effect"))) (EVar "TEffect"))
(DFunDef false "keywordOrIdent" ((PLit (LString "function"))) (EVar "TFunction"))
(DFunDef false "keywordOrIdent" ((PVar "s")) (EApp (EVar "TIdent") (EVar "s")))
(DTypeSig false "scanOne" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanOne" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EBinOp ">=" (EVar "pos") (EVar "len")) (EApp (EVar "endOne") (EVar "ctx")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanAt") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanAt" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "scanAt" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EIf (EApp (EVar "isSpace") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "ctx")) (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isNL") (EVar "c")) (EApp (EVar "isCR") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "handleNewline") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "#"))) (EBinOp "==" (EVar "pos") (ELit (LInt 0)))) (EBinOp ">" (EVar "len") (ELit (LInt 1)))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (ELit (LInt 1))) (ELit (LChar "!")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RComment") (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "e") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "len")) (EVar "UnterminatedComment")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RComment") (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id"))))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanNumber") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EVar "isTripleAt") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TripleLiteral")) (EVar "InitialLiteral")) (EIf (EApp (EVar "isQuote") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "PlainLiteral")) (EVar "InitialLiteral")) (EIf (EApp (EVar "isApos") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "scanChar") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EApp (EVar "opensByteLiteral") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanByte") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EApp (EApp (EVar "opensRawLiteral") (EVar "src")) (EVar "len")) (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanRawLiteral") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLower") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isUpper") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanUpper") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EVar "isBacktick") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanBacktick") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))
(DTypeSig false "skipLineComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipLineComment" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EBinOp "||" (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "skipLineComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lexErrorTok" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "RawTok"))))))
(DFunDef false "lexErrorTok" ((PVar "ctx") (PVar "p") (PVar "end") (PVar "kind")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "cursorPos")) (EFieldAccess (EVar "ctx") "cursorLength"))) (DoExpr (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TLexError") (EVar "kind"))) (EVar "p")) (EVar "end")))))
(DTypeSig false "skipBlockComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "skipBlockComment" ((PVar "src") (PVar "len") (PVar "p") (PVar "d")) (EIf (EBinOp "<=" (EVar "d") (ELit (LInt 0))) (EVar "p") (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "}")))) (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (EBinOp "-" (EVar "d") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "skipBlockComment") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanLower" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanLower" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EApp (EVar "identToken") (EVar "src")) (EVar "pos")) (EVar "e"))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "identToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "identToken" ((PVar "src") (PVar "pos") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "_"))) (EBinOp "==" (EBinOp "-" (EVar "e") (EVar "pos")) (ELit (LInt 1)))) (EVar "TUnderscore") (EIf (EApp (EApp (EApp (EVar "kwCandidate") (EVar "src")) (EVar "pos")) (EVar "e")) (EApp (EVar "keywordOrIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (EIf (EVar "otherwise") (EApp (EVar "TIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "kwCandidate" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "kwCandidate" ((PVar "src") (PVar "pos") (PVar "e")) (EBlock (DoLet false false (PVar "n") (EBinOp "-" (EVar "e") (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "kwStart") (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")))))))
(DTypeSig false "kwStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "kwStart" ((PLit (LChar "a"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "b"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "d"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "e"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "f"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "i"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "l"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "m"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "n"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "o"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "p"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "r"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "t"))) (EVar "True"))
(DFunDef false "kwStart" ((PLit (LChar "w"))) (EVar "True"))
(DFunDef false "kwStart" (PWild) (EVar "False"))
(DTypeSig false "scanUpper" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanUpper" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TUpper") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "scanBacktick" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanBacktick" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TBacktickIdent") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "e")))) (EVar "pos")) (EBinOp "+" (EVar "e") (ELit (LInt 1))))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "btClose" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "btClose" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "p") (EIf (EApp (EVar "isBacktick") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "btClose") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "digitsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "digitsEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "isRadixDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "radixKind" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "radixKind" ((PVar "k")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LChar "x"))) (EBinOp "==" (EVar "k") (ELit (LChar "b")))) (EBinOp "==" (EVar "k") (ELit (LChar "o")))))
(DTypeSig false "radixBase" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixBase" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixBase" ((PLit (LChar "b"))) (ELit (LInt 2)))
(DFunDef false "radixBase" (PWild) (ELit (LInt 8)))
(DTypeSig false "isRadixDigit" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isRadixDigit" ((PLit (LChar "x")) (PVar "c")) (EApp (EVar "isHexDigit") (EVar "c")))
(DFunDef false "isRadixDigit" ((PLit (LChar "b")) (PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "0"))) (EBinOp "==" (EVar "c") (ELit (LChar "1")))))
(DFunDef false "isRadixDigit" (PWild (PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "7")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f")))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87))) (EIf (EVar "otherwise") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Int"))))))
(DFunDef false "radixEnd" ((PVar "src") (PVar "len") (PVar "p") (PVar "k")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EBinOp "||" (EApp (EApp (EVar "isRadixDigit") (EVar "k")) (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))))) (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "k")) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRadix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadix" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EApp (EVar "magnitudeInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EVar "p")) (EVar "endp")) (EVar "base")) (EVar "acc"))))
(DTypeSig false "parseRadixNeg" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "parseRadixNeg" ((PVar "src") (PVar "p") (PVar "endp") (PVar "base") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadixNeg") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EVar "base")) (EBinOp "-" (EBinOp "*" (EVar "acc") (EVar "base")) (EApp (EVar "digitVal") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMaxLen" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLen" ((PLit (LChar "x"))) (ELit (LInt 16)))
(DFunDef false "radixMaxLen" ((PLit (LChar "b"))) (ELit (LInt 63)))
(DFunDef false "radixMaxLen" (PWild) (ELit (LInt 21)))
(DTypeSig false "radixMaxLead" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "radixMaxLead" ((PLit (LChar "b"))) (ELit (LInt 1)))
(DFunDef false "radixMaxLead" (PWild) (ELit (LInt 4)))
(DTypeSig false "sigRadixDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sigRadixDigits" ((PVar "src") (PVar "p") (PVar "endp")) (EIf (EBinOp ">=" (EVar "p") (EVar "endp")) (EListLit) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "0")))) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "endp")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "p")) (EVar "endp")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "radixMagOverflows" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "radixMagOverflows" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "radixMagOverflows" ((PCons (PVar "d") (PVar "rest")) (PVar "maxLen") (PVar "maxLead")) (EBlock (DoLet false false (PVar "n") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rest")))) (DoExpr (EBinOp "||" (EBinOp ">" (EVar "n") (EVar "maxLen")) (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "maxLen")) (EBinOp "||" (EBinOp ">" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "digitVal") (EVar "d")) (EVar "maxLead")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LChar "0"))))) (EVar "rest")))))))))
(DTypeSig false "radixLitOverflows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool"))))))
(DFunDef false "radixLitOverflows" ((PVar "src") (PVar "start") (PVar "endp") (PVar "k")) (EApp (EApp (EApp (EVar "radixMagOverflows") (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EVar "start")) (EVar "endp"))) (EApp (EVar "radixMaxLen") (EVar "k"))) (EApp (EVar "radixMaxLead") (EVar "k"))))
(DTypeSig false "scanRadix" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanRadix" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "radixTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e")) (EVar "k")) (EVar "depth")) (EVar "id")))))
(DTypeSig false "radixTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))))
(DFunDef false "radixTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e") (PVar "k") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EVar "radixLitOverflows") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wideIntTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "sigRadixDigits") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EApp (EVar "parseRadix") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e")) (EApp (EVar "radixBase") (EVar "k"))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e")))) (EVar "pos")) (EVar "e"))) (EVar "e")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scanNumber" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanNumber" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanRadix") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedRadixPrefix") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "malformedRadixTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "numFinish") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "pos"))) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMalformedRadixPrefix" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedRadixPrefix" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "pos")) (ELit (LChar "0"))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len"))) (EApp (EVar "radixKind") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (ELit (LChar "_")))))
(DTypeSig false "malformedRadixTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedRadixTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EApp (EVar "radixEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "k"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoLet false false (PVar "digits") (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "malformedRadixErr") (EVar "ctx")) (EVar "pos")) (EVar "bad")) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "digits")))))
(DTypeSig false "stripLeadingUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "stripLeadingUs" ((PVar "src") (PVar "p") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "_")))) (EApp (EApp (EApp (EVar "stripLeadingUs") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "p")) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "malformedRadixErr" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "RawTok")))))))
(DFunDef false "malformedRadixErr" ((PVar "ctx") (PVar "pos") (PVar "bad") (PVar "prefix") (PVar "digits")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EApp (EVar "stringLength") (EVar "bad")))) (EApp (EApp (EApp (EVar "MalformedRadix") (EVar "bad")) (EVar "prefix")) (EVar "digits"))))
(DTypeSig false "isFloatAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isFloatAt" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp "<" (EBinOp "+" (EVar "e1") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))))
(DTypeSig false "isExpMarker" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpMarker" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "expEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "expEnd" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "p") (EVar "len")) (EApp (EVar "isExpMarker") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EBlock (DoLet false false (PVar "q") (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "+"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-"))))) (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "q") (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EVar "q")))) (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EVar "q")) (EVar "p")))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "numFinish" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))))
(DFunDef false "numFinish" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EVar "isFloatAt") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EIf (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e1"))) (EVar "depth")) (EVar "id")) (EIf (EApp (EApp (EApp (EVar "isMalformedExpDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "malformedExpDotTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "isMalformedTrailingDot") (EVar "src")) (EVar "len")) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "malformedTrailingDotTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e1")) (EIf (EApp (EApp (EApp (EVar "intLitOverflows") (EVar "src")) (EVar "pos")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wideIntTok") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EVar "e1")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "collectNoUs") (EVar "src")) (EVar "pos")) (EVar "e1"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EApp (EVar "TInt") (EApp (EApp (EApp (EApp (EVar "parseIntFrom") (EVar "src")) (EVar "pos")) (EVar "e1")) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e1")))) (EVar "pos")) (EVar "e1"))) (EVar "e1")) (EVar "depth")) (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "isMalformedExpDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedExpDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EBinOp ">" (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))))
(DTypeSig false "malformedExpDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok")))))))
(DFunDef false "malformedExpDotTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "expE") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "expE"))) (DoLet false false (PVar "good") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))))) (ELit (LString "0"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EVar "expE")))) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "expE")) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EVar "good")) (EVar "False"))))))
(DTypeSig false "isMalformedTrailingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedTrailingDot" ((PVar "src") (PVar "len") (PVar "e1")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "e1") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "e1")) (ELit (LChar ".")))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "dotContinuesAccess") (EVar "src")) (EVar "len")) (EVar "e1")))))
(DTypeSig false "dotContinuesAccess" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "dotContinuesAccess" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EApp (EVar "isUpper") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "[")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar ".")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "{")))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "*"))))))
(DTypeSig false "malformedTrailingDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedTrailingDotTok" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "e1")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "e1") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EBinOp "++" (EVar "bad") (ELit (LString "0")))) (EVar "False"))))))
(DTypeSig false "floatTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))))
(DFunDef false "floatTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "e1") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "e1") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "floatTokEnd") (EVar "ctx")) (EVar "src")) (EVar "pos")) (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "e2"))) (EVar "depth")) (EVar "id")))))
(DTypeSig false "floatIsFinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatIsFinite" ((PVar "f")) (EBinOp "==" (EBinOp "*" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0))))
(DTypeSig false "floatTokEnd" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "floatTokEnd" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "endp") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "optionOr") (ELit (LFloat 0.0))) (EApp (EVar "stringToFloat") (EApp (EApp (EApp (EVar "substrNoUs") (EVar "src")) (EVar "pos")) (EVar "endp"))))) (DoExpr (EIf (EApp (EVar "floatIsFinite") (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TFloat") (EVar "f"))) (EVar "pos")) (EVar "endp"))) (EVar "endp")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "endp")) (EVar "FloatOverflow"))))))
(DTypeSig false "isTripleAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isTripleAt" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))))))
(DTypeSig false "inHole" (TyFun (TyCon "LexFrame") (TyCon "Bool")))
(DFunDef false "inHole" ((PCon "CodeFrame")) (EVar "False"))
(DFunDef false "inHole" (PWild) (EVar "True"))
(DTypeSig false "scanLiteral" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "LiteralFlavor") (TyFun (TyCon "LiteralPart") (TyCon "RawTok"))))))))))
(DFunDef false "scanLiteral" ((PVar "ctx") (PVar "src") (PVar "p") (PVar "quote") (PVar "depth") (PVar "frame") (PVar "flavor") (PVar "part")) (EMatch (EApp (EApp (EVar "readLiteral") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "LiteralCursor") (EVar "p")) (EVar "quote")) (EVar "flavor")) (EVar "part")) (EVar "False")) (EApp (EVar "inHole") (EVar "frame")))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind"))) (arm (PCon "Ok" (PCon "LiteralRead" (PVar "s") (PVar "next") (PVar "stop") (PVar "leading"))) () (EMatch (EVar "stop") (arm (PCon "LiteralClose") () (EBlock (DoLet false false (PVar "closeStart") (EIf (EApp (EVar "not") (EApp (EVar "isTriple") (EVar "flavor"))) (EBinOp "-" (EVar "next") (ELit (LInt 1))) (EBinOp "-" (EVar "next") (ELit (LInt 3))))) (DoLet false false (PVar "value") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isTriple") (EVar "flavor")) (EApp (EVar "not") (EApp (EVar "isContinued") (EVar "part")))) (EVar "leading")) (EApp (EVar "singleDedent") (EVar "s")) (EVar "s"))) (DoLet false false (PVar "token") (EIf (EApp (EVar "not") (EApp (EVar "isContinued") (EVar "part"))) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "value"))) (EVar "quote")) (EVar "next")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpEnd") (EVar "value"))) (EVar "closeStart")) (EVar "next")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EVar "token")) (EVar "next")) (EVar "depth")) (EVar "frame"))))) (arm (PCon "LiteralHole") () (EBlock (DoLet false false (PVar "start") (EBinOp "-" (EVar "next") (ELit (LInt 2)))) (DoLet false false (PVar "token") (EIf (EApp (EVar "isContinued") (EVar "part")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpMid") (EVar "s"))) (EVar "start")) (EVar "next")) (EIf (EApp (EVar "isTriple") (EVar "flavor")) (EApp (EApp (EApp (EVar "RTripleInterpOpen") (EVar "s")) (EVar "start")) (EVar "next")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TInterpOpen") (EVar "s"))) (EVar "start")) (EVar "next"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EVar "token")) (EVar "next")) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "start")) (ELit (LInt 1)))))))))))
(DTypeSig false "singleDedent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "singleDedent" ((PVar "s")) (EMatch (EApp (EVar "dedentSegments") (EListLit (EVar "s"))) (arm (PList (PVar "v")) () (EVar "v")) (arm PWild () (EVar "s"))))
(DTypeSig false "scanChar" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "scanChar" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "depth") (PVar "frame")) (EMatch (EApp (EApp (EVar "readCharacter") (EVar "src")) (EVar "pos")) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "next"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TChar") (EVar "s"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "frame")))))
(DTypeSig false "opensByteLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "opensByteLiteral" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "len")) (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EVar "afterIdentChar") (EVar "src")) (EVar "pos")))) (EBinOp "||" (EApp (EVar "isBackslash") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EApp (EApp (EApp (EVar "singleCharBody") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))))
(DTypeSig false "opensRawLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "opensRawLiteral" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isQuote") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "not") (EApp (EApp (EVar "afterIdentChar") (EVar "src")) (EVar "pos")))))
(DTypeSig false "scanRawLiteral" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "scanRawLiteral" ((PVar "ctx") (PVar "src") (PVar "pos") (PVar "depth") (PVar "frame")) (EMatch (EApp (EApp (EVar "readRawLiteral") (EVar "src")) (EVar "pos")) (arm (PCon "Ok" (PTuple (PVar "value") (PVar "next"))) () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TString") (EVar "value"))) (EVar "pos")) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "frame"))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind")))))
(DTypeSig false "afterIdentChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "afterIdentChar" ((PVar "src") (PVar "pos")) (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))
(DTypeSig false "singleCharBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "singleCharBody" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))))) (EApp (EApp (EApp (EVar "closesAfterMarks") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))))
(DTypeSig false "closesAfterMarks" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "closesAfterMarks" ((PVar "src") (PVar "len") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (EVar "False") (EIf (EApp (EVar "isApos") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EVar "True") (EIf (EApp (EVar "isCombiningMark") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EVar "closesAfterMarks") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "isCombiningMark" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCombiningMark" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 768))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 879)))))
(DTypeSig false "scanByte" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanByte" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EMatch (EApp (EApp (EVar "readByteLiteral") (EVar "src")) (EVar "pos")) (arm (PCon "Ok" (PTuple (PVar "value") (PVar "next"))) () (EIf (EApp (EApp (EApp (EApp (EVar "byteLiteralIsName") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "next")) (EBlock (DoLet false false (PVar "old") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "next"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "next")) (EApp (EApp (EVar "ByteLikeIdent") (EVar "old")) (EApp (EApp (EVar "byteRename") (EVar "src")) (EVar "pos")))))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EApp (EVar "TByte") (EVar "value"))) (EVar "pos")) (EVar "next"))) (EVar "next")) (EVar "depth")) (EVar "id")))) (arm (PCon "Err" (PCon "LexError" (PVar "kind") (PVar "start") (PVar "end"))) () (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "start")) (EVar "end")) (EVar "kind")))))
(DTypeSig false "byteLiteralIsName" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "byteLiteralIsName" ((PVar "src") (PVar "len") (PVar "pos") (PVar "next")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp "<" (EVar "next") (EVar "len")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EVar "next")))) (EApp (EApp (EVar "atLineStart") (EVar "src")) (EVar "pos"))) (EApp (EApp (EVar "afterBinderKeyword") (EVar "src")) (EVar "pos"))))
(DTypeSig false "atLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "atLineStart" ((PVar "src") (PVar "pos")) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))
(DTypeSig false "afterBinderKeyword" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "afterBinderKeyword" ((PVar "src") (PVar "pos")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EVar "skipBlanksBack") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "e") (ELit (LInt 2))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "let"))) (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "rec")))) (EApp (EApp (EApp (EVar "wordEndsAt") (EVar "src")) (EVar "e")) (ELit (LString "mut"))))))))
(DTypeSig false "skipBlanksBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipBlanksBack" ((PVar "src") (PVar "p")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "p") (ELit (LInt 0))) (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")))) (EApp (EApp (EVar "skipBlanksBack") (EVar "src")) (EBinOp "-" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wordEndsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "wordEndsAt" ((PVar "src") (PVar "e") (PVar "word")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EBinOp "-" (EVar "e") (ELit (LInt 2)))) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EVar "word")) (EBinOp "||" (EBinOp "<" (EVar "e") (ELit (LInt 3))) (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "e") (ELit (LInt 3)))))))))
(DTypeSig false "byteRename" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "byteRename" ((PVar "src") (PVar "pos")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EApp (EVar "isDigit") (EVar "c"))) (EBinOp "++" (ELit (LString "b_")) (EApp (EVar "charToStr") (EVar "c"))) (ELit (LString "b_byte"))))))
(DTypeSig true "scanRaw" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRaw" ((PVar "s")) (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig true "scanRawChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRawChars" ((PVar "src")) (EApp (EVar "dedentTripleInterp") (EApp (EVar "scanRawUndedentedChars") (EVar "src"))))
(DTypeSig true "scanRawUndedentedChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "RawTok"))))
(DFunDef false "scanRawUndedentedChars" ((PVar "src")) (EBlock (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoLet false false (PVar "cursor") (ERecordCreate "ScanCursor" ((fa "cursorPos" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "cursorDepth" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "cursorFrame" (EApp (EVar "Ref") (EVar "CodeFrame"))) (fa "cursorReady" (EApp (EVar "Ref") (EVar "True"))) (fa "cursorLength" (EVar "len"))))) (DoExpr (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "cursor")))))
(DTypeSig false "emit" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok")))))))))
(DFunDef false "emit" ((PVar "ctx") (PVar "pos") (PVar "depth") (PVar "id") (PVar "tok") (PVar "length") (PVar "ddelta")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "tok")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EMethodRef "length")))) (EBinOp "+" (EVar "pos") (EMethodRef "length"))) (EBinOp "+" (EVar "depth") (EVar "ddelta"))) (EVar "id")))
(DTypeSig false "scanOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanDotOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanBarOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanEqOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLtOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanGtOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanColonOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "["))) (ELit (LChar "|"))) (EVar "TLArray")) (ELit (LInt 1))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EVar "TArrow")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EVar "TPlusPlus")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "!"))) (ELit (LChar "="))) (EVar "TBangEq")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "/"))) (ELit (LChar "="))) (EVar "TNeq")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "&"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanTwoOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EVar "TAnd")) (ELit (LInt 0))))
(DFunDef false "scanOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c")))
(DTypeSig false "scanTwoOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyCon "RawTok"))))))))))))
(DFunDef false "scanTwoOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c") (PVar "b") (PVar "tok") (PVar "ddelta")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "c")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "tok")) (ELit (LInt 2))) (EVar "ddelta")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "c"))))
(DTypeSig false "scanDotOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanDotOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEllipsis")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "is3") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDotEq")) (ELit (LInt 3))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotLBrace")) (ELit (LInt 2))) (ELit (LInt 1))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotStar")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "."))) (ELit (LChar "."))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDotDot")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "."))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "scanBarOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanBarOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRArray")) (ELit (LInt 2))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TOr")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipeRight")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "|"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "scanEqOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanEqOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TFatArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "="))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanLtOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanLtOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLArrow")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar "<"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "scanGtOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanGtOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGeq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRCompose")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar ">"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanColonOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "scanColonOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TCons")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LChar ":"))) (ELit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColonEq")) (ELit (LInt 2))) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "singleOp") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")) (ELit (LChar ":"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "singleOp" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Char") (TyCon "RawTok")))))))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPlus")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EApp (EVar "minusTok") (EVar "src")) (EVar "len")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TStar")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "/"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TSlash")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "<"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ">"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TGt")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "="))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TEqual")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ":"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TColon")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ","))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TComma")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "."))) (EIf (EApp (EApp (EApp (EVar "isMalformedLeadingDot") (EVar "src")) (EVar "len")) (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "malformedLeadingDotTok") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TDot")) (ELit (LInt 1))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "|"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TPipe")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "("))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TLParen")) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar ")"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRParen")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "["))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "bracketTok") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 1))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "]"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TRBracket")) (ELit (LInt 1))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "openBrace") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closeBrace") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "pos")) (EVar "depth")) (EVar "id")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "!"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TBang")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "%"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EVar "TMod")) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "@"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "pos")) (EVar "depth")) (EVar "id")) (EApp (EApp (EVar "atToken") (EVar "src")) (EVar "pos"))) (ELit (LInt 1))) (ELit (LInt 0))))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "\\"))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "HsLambda")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PLit (LChar "$"))) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "HsDollar")))
(DFunDef false "singleOp" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "UnexpectedCharacter") (EApp (EVar "charToStr") (EVar "c")))))
(DTypeSig false "bracketTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "bracketTok" ((PVar "src") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EVar "TLBracketTight") (EIf (EVar "otherwise") (EVar "TLBracket") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExprEnd" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExprEnd" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "\"")))))
(DTypeSig false "isMalformedLeadingDot" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "isMalformedLeadingDot" ((PVar "src") (PVar "len") (PVar "pos")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len")) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EBinOp "||" (EBinOp "==" (EVar "pos") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isExprEnd") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig false "malformedLeadingDotTok" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))
(DFunDef false "malformedLeadingDotTok" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "digitsEnd") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "expEnd") (EVar "src")) (EVar "len")) (EVar "d"))) (DoLet false false (PVar "bad") (EApp (EApp (EApp (EVar "copyCharRange") (EVar "src")) (EVar "pos")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "lexErrorTok") (EVar "ctx")) (EVar "pos")) (EVar "e")) (EApp (EApp (EApp (EVar "MalformedFloat") (EVar "bad")) (EBinOp "++" (ELit (LString "0")) (EVar "bad"))) (EVar "True"))))))
(DTypeSig false "atToken" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "atToken" ((PVar "src") (PVar "pos")) (EIf (EBinOp "<=" (EVar "pos") (ELit (LInt 0))) (EVar "TAt") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1))))) (EVar "TAsAt") (EIf (EVar "otherwise") (EVar "TAt") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "minusTok" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Token")))))
(DFunDef false "minusTok" ((PVar "src") (PVar "len") (PVar "pos")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSpace") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isDigit") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EVar "TMinusTight") (EIf (EVar "otherwise") (EVar "TMinus") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "openBrace" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "openBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "CodeFrame")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "CodeFrame")))
(DFunDef false "openBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "HoleFrame" (PVar "flavor") (PVar "opener") (PVar "braces"))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TLBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "opener")) (EBinOp "+" (EVar "braces") (ELit (LInt 1))))))
(DTypeSig false "closeBrace" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "closeBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "CodeFrame")) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "CodeFrame")))
(DFunDef false "closeBrace" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PCon "HoleFrame" (PVar "flavor") (PVar "opener") (PVar "braces"))) (EIf (EBinOp ">" (EVar "braces") (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EApp (EVar "RTok") (EVar "TRBrace")) (EVar "pos")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EApp (EVar "HoleFrame") (EVar "flavor")) (EVar "opener")) (EBinOp "-" (EVar "braces") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EMatch (EVar "flavor") (arm (PCon "PlainLiteral") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "CodeFrame")) (EVar "PlainLiteral")) (EVar "ContinuedLiteral"))) (arm (PCon "TripleLiteral") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanLiteral") (EVar "ctx")) (EVar "src")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "pos")) (EVar "depth")) (EVar "CodeFrame")) (EVar "TripleLiteral")) (EVar "ContinuedLiteral")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleNewline" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok"))))))))
(DFunDef false "handleNewline" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "pos") (PVar "depth") (PVar "id")) (EBlock (DoLet false false (PTuple (PVar "indent") (PVar "np")) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "afterNl") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "indent")) (EVar "pos")))))
(DTypeSig false "consumeNl" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "consumeNl" ((PVar "src") (PVar "len") (PVar "p") (PVar "indent")) (EIf (EBinOp ">=" (EVar "p") (EVar "len")) (ETuple (EVar "indent") (EVar "p")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 2)))) (ELit (LInt 0))) (EIf (EApp (EVar "isNL") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isCR") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LInt 0))) (EIf (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "+" (EVar "indent") (ELit (LInt 1)))) (EIf (EApp (EVar "isTab") (EApp (EApp (EVar "at") (EVar "src")) (EVar "p"))) (EApp (EApp (EApp (EApp (EVar "consumeNl") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EBinOp "*" (EBinOp "+" (EBinOp "/" (EVar "indent") (ELit (LInt 8))) (ELit (LInt 1))) (ELit (LInt 8)))) (EIf (EVar "otherwise") (ETuple (EVar "indent") (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "afterNl" (TyFun (TyCon "ScanCursor") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "RawTok"))))))))))
(DFunDef false "afterNl" ((PVar "ctx") (PVar "src") (PVar "len") (PVar "np") (PVar "depth") (PVar "id") (PVar "indent") (PVar "nlPos")) (EIf (EApp (EApp (EApp (EVar "nextIsComment") (EVar "src")) (EVar "len")) (EVar "np")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "ctx")) (EVar "src")) (EVar "len")) (EVar "np")) (EVar "depth")) (EVar "id")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "leadingOp") (EVar "src")) (EVar "len")) (EVar "np")) (arm (PCon "Some" (PTuple (PVar "tok") (PVar "n"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "ctx")) (EVar "np")) (EVar "depth")) (EVar "id")) (EVar "tok")) (EVar "n")) (ELit (LInt 0)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "emitOne") (EVar "ctx")) (EApp (EApp (EVar "RNewline") (EVar "indent")) (EVar "nlPos"))) (EVar "np")) (EVar "depth")) (EVar "id")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextIsComment" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextIsComment" ((PVar "src") (PVar "len") (PVar "p")) (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "p") (ELit (LInt 1))) (EVar "len")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "-"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "p")) (ELit (LChar "{"))) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (ELit (LChar "-")))))))
(DTypeSig false "leadingOp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Token") (TyCon "Int")))))))
(DFunDef false "leadingOp" ((PVar "src") (PVar "len") (PVar "np")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar ">"))) (EApp (EVar "Some") (ETuple (EVar "TPipeRight") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar ">"))) (EApp (EVar "Some") (ETuple (EVar "TRCompose") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "<"))) (EApp (EVar "Some") (ETuple (EVar "TLCompose") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TLeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ">"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TGeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "&"))) (ELit (LChar "&"))) (EApp (EVar "Some") (ETuple (EVar "TAnd") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "|"))) (ELit (LChar "|"))) (EApp (EVar "Some") (ETuple (EVar "TOr") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "+"))) (ELit (LChar "+"))) (EApp (EVar "Some") (ETuple (EVar "TPlusPlus") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar ":"))) (ELit (LChar ":"))) (EApp (EVar "Some") (ETuple (EVar "TCons") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "="))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TEqEq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "/"))) (ELit (LChar "="))) (EApp (EVar "Some") (ETuple (EVar "TNeq") (ELit (LInt 2)))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "<"))) (ELit (LChar "-"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar ">"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar "-"))) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "is2") (EVar "src")) (EVar "len")) (EVar "np")) (ELit (LChar "-"))) (ELit (LChar "}"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "-")))) (EBinOp "<" (EBinOp "+" (EVar "np") (ELit (LInt 1))) (EVar "len"))) (EApp (EVar "isSp") (EApp (EApp (EVar "at") (EVar "src")) (EBinOp "+" (EVar "np") (ELit (LInt 1)))))) (EApp (EVar "Some") (ETuple (EVar "TMinus") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "+")))) (EApp (EVar "Some") (ETuple (EVar "TPlus") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "*")))) (EApp (EVar "Some") (ETuple (EVar "TStar") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "/")))) (EApp (EVar "Some") (ETuple (EVar "TSlash") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "%")))) (EApp (EVar "Some") (ETuple (EVar "TMod") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar "<")))) (EApp (EVar "Some") (ETuple (EVar "TLt") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "np") (EVar "len")) (EBinOp "==" (EApp (EApp (EVar "at") (EVar "src")) (EVar "np")) (ELit (LChar ">")))) (EApp (EVar "Some") (ETuple (EVar "TGt") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))))))
(DTypeSig false "isTriple" (TyFun (TyCon "LiteralFlavor") (TyCon "Bool")))
(DFunDef false "isTriple" ((PCon "TripleLiteral")) (EVar "True"))
(DFunDef false "isTriple" (PWild) (EVar "False"))
(DTypeSig false "isContinued" (TyFun (TyCon "LiteralPart") (TyCon "Bool")))
(DFunDef false "isContinued" ((PCon "ContinuedLiteral")) (EVar "True"))
(DFunDef false "isContinued" (PWild) (EVar "False"))
(DData Private "ScanCursor" () ((variant "ScanCursor" (ConNamed (field "cursorPos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "cursorDepth" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "cursorFrame" (TyApp (TyCon "Ref") (TyCon "LexFrame"))) (field "cursorReady" (TyApp (TyCon "Ref") (TyCon "Bool"))) (field "cursorLength" (TyCon "Int"))))) ())
(DTypeSig false "scan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "ScanCursor") (TyApp (TyCon "List") (TyCon "RawTok"))))))
(DFunDef false "scan" ((PVar "src") (PVar "len") (PVar "cursor")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOne") (EVar "cursor")) (EVar "src")) (EVar "len")) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorPos"))) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorDepth"))) (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorFrame"))) (arm (PVar "token") () (EIf (EUnOp "!" (EFieldAccess (EVar "cursor") "cursorReady")) (EBinOp "::" (EVar "token") (EApp (EApp (EApp (EVar "scan") (EVar "src")) (EVar "len")) (EVar "cursor"))) (EListLit)))))
(DTypeSig false "emitOne" (TyFun (TyCon "ScanCursor") (TyFun (TyCon "RawTok") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "LexFrame") (TyCon "RawTok")))))))
(DFunDef false "emitOne" ((PVar "cursor") (PVar "token") (PVar "next") (PVar "depth") (PVar "frame")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorPos")) (EVar "next"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorDepth")) (EVar "depth"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorFrame")) (EVar "frame"))) (DoExpr (EVar "token"))))
(DTypeSig false "endOne" (TyFun (TyCon "ScanCursor") (TyCon "RawTok")))
(DFunDef false "endOne" ((PVar "cursor")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cursor") "cursorReady")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EVar "RTok") (EVar "TEof")) (ELit (LInt 0))) (ELit (LInt 0))))))
