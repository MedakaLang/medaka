# META
source_lines=808
stages=DESUGAR,MARK
# SOURCE
-- Receipts are reusable values: their presence in a buffer, rather than the
-- history of writes to that buffer, determines which calls are authorized.
import backend.llvm_symbols.{
  LlvmSymbol(..),
  ModuleScope(..),
  registryScope,
  LlvmParam(..),
  Prototype(..),
  CallShape(..),
  SymbolRegistry,
  SymbolDefect(..),
  SymbolDeclaration(..),
  SymbolLinkage(..),
  checkCall,
  symbolName,
  declarations,
  isExcused,
}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omKeys, omFromNames
}
import support.symbol_origin.{SymbolOrigin(..)}
import support.util.{joinWith, reverseL}

public export data CallModifier =
  | OrdinaryCall
  | TailCall
  | MustTailCall
  | NoTailCall
  deriving (Eq, Debug)

-- Closed output and previously justified gaps are distinct audit obligations.
-- lint-disable-next-line rule-clone-type
public export data CoveragePolicy =
  | ClosedOutput
  | RecordedGaps (List LlvmSymbol)

data Token = Token String Bool SymbolOrigin
data Receipt = Receipt {
  text : String,
  sym : LlvmSymbol,
  shape : CallShape,
  modifier : CallModifier,
  origin : SymbolOrigin,
  tokens : List Token,
}

export data CallCoverage = CallCoverage Int (OrdMap Receipt)

export
emptyCoverage : CallCoverage
-- Empty ledgers have distinct nominal receipt types on the two targets.
-- lint-disable-next-line rule-duplicate-body
emptyCoverage = CallCoverage 0 omEmpty

moduleOrigin : SymbolOrigin
-- The no-binding origin keeps the documented physical diagnostic sentinel.
-- lint-disable-next-line rule-duplicate-body
moduleOrigin = SymbolOrigin "module" "" 0 0

modifierText : CallModifier -> String
modifierText OrdinaryCall = ""
modifierText TailCall = "tail "
modifierText MustTailCall = "musttail "
modifierText NoTailCall = "notail "

export
checkedCall : SymbolRegistry ->
  CallModifier ->
  LlvmSymbol ->
  String ->
  List (String, String) ->
  SymbolOrigin ->
  CallCoverage ->
  Result SymbolDefect (SymbolRegistry, CallCoverage, String)
checkedCall reg modifier sym ret ops origin (CallCoverage next entries) = do
  let shape = CallShape ret (map fst ops)
  reg2 <- checkCall sym shape origin reg
  let arguments = joinWith ", " (map ((ty, operand) => "\{ty} \{operand}") ops)
  let text =
    "\{modifierText modifier}call \{ret} @\{symbolName sym}(\{arguments})"
  tokens <- match rawTokens text
    Err (UncheckedText reason _) => Err (UncheckedText reason origin)
    result => result
  if callFacts tokens
    /= [(modifier, canonicalName ("@" ++ symbolName sym))] then
    Err
      (UncheckedText
        "checked instruction must contain exactly one matching named call"
        origin)
  else
    let key = intToString next
    let receipt = Receipt {
      text = text,
      sym = sym,
      shape = shape,
      modifier = modifier,
      origin = origin,
      tokens = tokens,
    }
    Ok (
      reg2,
      CallCoverage (next + 1) (omInsert key receipt entries),
      "\u{1e}L\{key}:\{text}\u{1f}",
    )

byte : Array Int -> Int -> Int
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
byte bytes i =
  if i < 0 || i >= arrayLength bytes then -1 else arrayGetUnsafe i bytes

space : Int -> Bool
space c = c == 0 || c == 32 || c == 9 || c == 10 || c == 13

punct : Int -> Bool
punct c =
  c == 40
    || c == 41
    || c == 91
    || c == 93
    || c == 123
    || c == 125
    || c == 60
    || c == 62
    || c == 44
    || c == 61
    || c == 58
    || c == 42

boundary : Int -> Bool
boundary c = c == -1 || space c || punct c || c == 59

wordEnd : Array Int -> Int -> Int
wordEnd bytes i =
  let c = byte bytes i
  if c == -1
    || space c
    || punct c
    || c == 59
    || c == 34
    || c == 30
    || c == 31 then
    i
  else
    wordEnd bytes (i + 1)

quotedEnd : Array Int -> Int -> Result SymbolDefect Int
quotedEnd bytes i = match byte bytes i
  c if c == -1 => Err (UncheckedText "unterminated quoted text" moduleOrigin)
  34 => Ok (i + 1)
  92 =>
    if byte bytes (i + 1) == -1 then
      Err (UncheckedText "unterminated escape" moduleOrigin)
    else
      quotedEnd bytes (i + 2)
  _ => quotedEnd bytes (i + 1)

lineEnd : Array Int -> Int -> Int
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
lineEnd bytes i =
  let c = byte bytes i
  if c == -1 || c == 10 || c == 13 then i else lineEnd bytes (i + 1)

keyEnd : Array Int -> Int -> Int
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
keyEnd bytes i =
  let c = byte bytes i
  if c >= 48 && c <= 57 then keyEnd bytes (i + 1) else i

prependChecked : List Token -> SymbolOrigin -> List Token -> List Token
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
prependChecked [] _ acc = acc
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
prependChecked ((Token text _ _) :: rest) origin acc =
  prependChecked rest origin (Token text True origin :: acc)

rawTokens : String -> Result SymbolDefect (List Token)
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
rawTokens text = do
  (tokens, _) <- scan text (stringToUtf8Bytes text) omEmpty False None 0 0 [] []
  Ok tokens

-- Byte offsets avoid a Unicode prefix walk at every token. Each copied slice
-- is disjoint; receipt comparison reads only that occurrence's exact bytes.
scan : String ->
  Array Int ->
  OrdMap Receipt ->
  Bool ->
  Option (SymbolRegistry, OrdMap Expected) ->
  Int ->
  Int ->
  List Token ->
  List String ->
  Result SymbolDefect (List Token, String)
scan text bytes entries markers registry i copied tokens chunks =
  let c = byte bytes i
  if c == -1 then
    Ok (
      reverseL tokens,
      joinWith "" (reverseL (stringSliceBytes copied i text :: chunks)),
    )
  else if c == 30 then
    if not markers
      || byte bytes (i + 1) /= 76
      || not (boundary (byte bytes (i - 1))) then
      Err (UncheckedText "malformed or nested receipt" moduleOrigin)
    else
      let endKey = keyEnd bytes (i + 2)
      let key = stringSliceBytes (i + 2) endKey text
      if key == "" || byte bytes endKey /= 58 then
        Err (UncheckedText "malformed receipt key" moduleOrigin)
      else match omLookup key entries
        None => Err (UncheckedText "unknown receipt" moduleOrigin)
        Some receipt =>
          let start = endKey + 1
          let end = start + stringByteLength receipt.text
          if end >= arrayLength bytes
            || byte bytes end /= 31
            || not (boundary (byte bytes (end + 1))) then
            Err (UncheckedText "changed or unterminated receipt" receipt.origin)
          else if stringSliceBytes start end text /= receipt.text then
            Err (UncheckedText "changed receipt text" receipt.origin)
          else match recheck registry receipt
            Err d => Err d
            Ok _ =>
              scan
                text
                bytes
                entries
                markers
                registry
                (end + 1)
                (end + 1)
                (prependChecked receipt.tokens receipt.origin tokens)
                (receipt.text :: stringSliceBytes copied i text :: chunks)
  else if c == 31 then
    Err (UncheckedText "unmatched receipt end" moduleOrigin)
  else if space c then
    scan text bytes entries markers registry (i + 1) copied tokens chunks
  else if c == 59 then
    let end = lineEnd bytes i
    if not markers && end == arrayLength bytes then
      Err (UncheckedText "receipt ends inside a line comment" moduleOrigin)
    else
      scan text bytes entries markers registry end copied tokens chunks
  else if c == 34 then do
    end <- quotedEnd bytes (i + 1)
    scan
      text
      bytes
      entries
      markers
      registry
      end
      copied
      (Token "\"\"" False moduleOrigin :: tokens)
      chunks
  else if (c == 64 || c == 37) && byte bytes (i + 1) == 34 then do
    end <- quotedEnd bytes (i + 2)
    if c == 64 && end == i + 3 then
      Err
        (UncheckedText
          "empty global name requests implicit LLVM numbering"
          moduleOrigin)
    else
      scan
        text
        bytes
        entries
        markers
        registry
        end
        copied
        (Token (canonicalName (stringSliceBytes i end text)) False moduleOrigin
          :: tokens)
        chunks
  else
    let end = if punct c then i + 1 else wordEnd bytes i
    scan
      text
      bytes
      entries
      markers
      registry
      end
      copied
      (Token
          (if c == 64 then
            canonicalName (stringSliceBytes i end text)
          else
            stringSliceBytes i end text)
          False
          moduleOrigin
        :: tokens)
      chunks

recheck : Option (SymbolRegistry, OrdMap Expected) ->
  Receipt ->
  Result SymbolDefect Unit
recheck None _ = Ok ()
recheck (Some (reg, expected)) receipt =
  let actual =
    match omLookup (canonicalName ("@" ++ symbolName receipt.sym)) expected
      Some (Expected sym _ _ _) => sym
      None => receipt.sym
  map (_ => ()) (checkCall actual receipt.shape receipt.origin reg)

tokenText : Token -> String
tokenText (Token text _ _) = text

hex : Int -> Int
hex c
  | c >= 48 && c <= 57 = c - 48
  | c >= 65 && c <= 70 = c - 55
  | c >= 97 && c <= 102 = c - 87
  | otherwise = -1

nameBytes : Array Int -> Int -> List Int -> List Int
nameBytes bytes i acc =
  if i >= arrayLength bytes - 1 then
    reverseL acc
  else if byte bytes i == 92
    && hex (byte bytes (i + 1)) >= 0
    && hex (byte bytes (i + 2)) >= 0 then
    nameBytes
      bytes
      (i + 3)
      (hex (byte bytes (i + 1)) * 16 + hex (byte bytes (i + 2)) :: acc)
  else
    nameBytes bytes (i + 1) (byte bytes i :: acc)

sameBytes : Array Int -> List Int -> Int -> Bool
sameBytes bytes [] i = i == arrayLength bytes
sameBytes bytes (c :: rest) i =
  byte bytes i == c && sameBytes bytes rest (i + 1)

escapedNameBytes : Array Int -> Int -> List String -> String
escapedNameBytes bytes i acc =
  if i >= arrayLength bytes then
    joinWith "" (reverseL acc)
  else
    let c = byte bytes i
    let digits = "0123456789abcdef"
    let hi = stringSlice (c / 16) (c / 16 + 1) digits
    let lo = stringSlice (c % 16) (c % 16 + 1) digits
    escapedNameBytes bytes (i + 1) ("\\\{hi}\{lo}" :: acc)

decimalTail : Array Int -> Int -> Bool
decimalTail bytes i =
  if i >= arrayLength bytes then
    True
  else
    byte bytes i >= 48 && byte bytes i <= 57 && decimalTail bytes (i + 1)

zeroEnd : Array Int -> Int -> Int
zeroEnd bytes i =
  if i < arrayLength bytes - 1 && byte bytes i == 48 then
    zeroEnd bytes (i + 1)
  else
    i

-- Quoted names are byte strings; numeric slots and invalid UTF-8 need disjoint
-- keys. The private colon-bearing tags cannot be lexical global identifiers.
canonicalName : String -> String
canonicalName name =
  if stringSlice 0 2 name == "@\"" then
    let decoded = nameBytes (stringToUtf8Bytes name) 2 []
    let bytes = arrayFromList decoded
    let value = stringFromUtf8Bytes bytes
    if sameBytes (stringToUtf8Bytes value) decoded 0 then
      "@" ++ value
    else
      "!llvm-id:" ++ escapedNameBytes bytes 0 []
  else if stringSlice 0 1 name == "@" then
    let first = stringSlice 1 2 name
    if first >= "0" && first <= "9" then
      let bytes = stringToUtf8Bytes name
      if decimalTail bytes 1 then
        "!llvm-slot:"
          ++ stringSliceBytes (zeroEnd bytes 1) (arrayLength bytes) name
      else
        name
    else
      name
  else
    name

isGlobal : String -> Bool
isGlobal s =
  let prefix = stringSlice 0 1 s
  prefix == "@"
    || prefix == "!"
      && (stringSlice 0 9 s == "!llvm-id:"
        || stringSlice 0 11 s == "!llvm-slot:")

needsQuotes : Array Int -> Int -> Bool
needsQuotes bytes i =
  if i >= arrayLength bytes then
    arrayLength bytes == 0
  else
    let c = byte bytes i
    let digit = c >= 48 && c <= 57
    let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122
    if i == 0 && digit
      || not (digit || letter || c == 36 || c == 45 || c == 46 || c == 95) then
      True
    else
      needsQuotes bytes (i + 1)

needsEscape : Array Int -> Int -> Bool
needsEscape bytes i =
  if i >= arrayLength bytes then
    False
  else
    let c = byte bytes i
    c < 32 || c == 127 || c == 34 || c == 92 || needsEscape bytes (i + 1)

-- Render a real LLVM spelling, escaping controls rather than leaking receipt
-- bytes from a quoted identifier into a diagnostic.
errorName : String -> String
errorName name =
  if stringSlice 0 9 name == "!llvm-id:" then
    "\"" ++ stringSlice 9 (stringLength name) name ++ "\""
  else if stringSlice 0 11 name == "!llvm-slot:" then
    stringSlice 11 (stringLength name) name
  else
    let value = stringSlice 1 (stringLength name) name
    let bytes = stringToUtf8Bytes value
    if needsEscape bytes 0 then
      "\"" ++ escapedNameBytes bytes 0 [] ++ "\""
    else if needsQuotes bytes 0 then
      "\"" ++ value ++ "\""
    else
      value

isLocal : String -> Bool
isLocal s = stringSlice 0 1 s == "%"

modifierOf : String -> CallModifier
modifierOf "tail" = TailCall
modifierOf "musttail" = MustTailCall
modifierOf "notail" = NoTailCall
modifierOf _ = OrdinaryCall

namedCallee : List Token -> Option String
namedCallee [] = None
namedCallee ((Token text _ _) :: (Token "(" _ _) :: rest)
  | isLocal text = match afterParens rest 0
    after@((Token name _ _) :: _) if isGlobal name || isLocal name =>
      namedCallee after
    _ => None
namedCallee ((Token text _ _) :: rest)
  | isGlobal text = Some text
  | text == "="
    || text == ";"
    || text == "call"
    || text == "invoke"
    || text == "callbr"
    || text == "ret"
    || text == "define"
    || text == "declare" = None
  | otherwise = namedCallee rest

-- `%T (...)` may be an explicit function type returning the named type `%T`.
-- A callee register's argument list ends the call instead; its global operands
-- must not become the apparent named callee.
afterParens : List Token -> Int -> List Token
afterParens [] _ = []
afterParens ((Token text _ _) :: rest) depth =
  if text == "call" || text == "invoke" || text == "callbr" then
    []
  else if text == ")" && depth == 0 then
    rest
  else
    afterParens
      rest
      (depth + (if text == "(" then 1 else if text == ")" then -1 else 0))

callFacts : List Token -> List (CallModifier, String)
callFacts tokens = reverseL (callFactsGo tokens "" [])

callFactsGo : List Token ->
  String ->
  List (CallModifier, String) ->
  List (CallModifier, String)
callFactsGo [] _ acc = acc
callFactsGo ((Token text _ _) :: rest) previous acc =
  if text == "call"
    || text == "invoke"
    || text == "callbr" then match namedCallee rest
    Some name => callFactsGo rest text ((modifierOf previous, name) :: acc)
    None => callFactsGo rest text acc
  else
    callFactsGo rest text acc

coverageDefects : List Token -> List SymbolDefect
coverageDefects tokens = reverseL (coverageGo tokens [])

coverageGo : List Token -> List SymbolDefect -> List SymbolDefect
coverageGo [] acc = acc
coverageGo ((Token text checked origin) :: rest) acc =
  let direct =
    (text == "call" || text == "invoke" || text == "callbr")
      && isSome (namedCallee rest)
  let modifier = text == "tail" || text == "musttail" || text == "notail"
  if (direct || modifier) && not checked then
    coverageGo
      rest
      (UncheckedText "uncovered named call or call modifier" origin :: acc)
  else
    coverageGo rest acc

data Expected = Expected LlvmSymbol Prototype SymbolLinkage SymbolOrigin

expectedMap : List SymbolDeclaration ->
  OrdMap Expected ->
  Result SymbolDefect (OrdMap Expected)
expectedMap [] acc = Ok acc
expectedMap ((SymbolDeclaration sym proto linkage origin) :: rest) acc =
  let key = canonicalName ("@" ++ symbolName sym)
  if omHasKey key acc then
    Err (DuplicateDefinition (symbolName sym) origin origin)
  else
    expectedMap rest (omInsert key (Expected sym proto linkage origin) acc)

texts : List Token -> List String
texts ts = map tokenText ts

typeWords : String -> List String
-- LLVM type punctuation is significant; whitespace splitting loses array and function types.
-- lint-disable-next-line rule-stdlib-reimpl
typeWords s = match rawTokens s
  Ok ts => texts ts
  Err _ => [s]

suffix : List String -> List String -> Bool
suffix wanted actual = starts (reverseL wanted) (reverseL actual)

starts : List String -> List String -> Bool
starts [] _ = True
starts _ [] = False
starts (x :: xs) (y :: ys) = x == y && starts xs ys

-- A parameter name is optional and follows its type; a named type by itself
-- is not a parameter name.
paramWords : List String -> List String
paramWords words = match reverseL words
  last :: earlier =>
    if not (isEmpty earlier) && isLocal last then reverseL earlier else words
  _ => words

paramType : LlvmParam -> List String
paramType (LlvmParam ty _) = typeWords ty

params : List Token ->
  Int ->
  List String ->
  List (List String) ->
  Result SymbolDefect (List (List String), List Token)
params [] _ _ _ =
  Err (UncheckedText "unterminated function parameter list" moduleOrigin)
params ((Token text _ _) :: rest) depth current acc =
  if text == ")" && depth == 0 then
    Ok (
      reverseL (if isEmpty current then
        acc
      else
        paramWords (reverseL current) :: acc),
      rest,
    )
  else if text == "," && depth == 0 then
    params rest depth [] (paramWords (reverseL current) :: acc)
  else
    let delta =
      if text == "(" || text == "[" || text == "{" || text == "<" then
        1
      else if text == ")" || text == "]" || text == "}" || text == ">" then
        -1
      else
        0
    params rest (depth + delta) (text :: current) acc

functionHead : List Token ->
  List String ->
  Result SymbolDefect (String, List String, List (List String), List Token)
functionHead [] _ =
  Err (UncheckedText "function header without a name" moduleOrigin)
functionHead ((Token name _ _) :: (Token "(" _ _) :: rest) before
  | isGlobal name = do
    (ps, after) <- params rest 0 [] []
    Ok (name, reverseL before, ps, after)
functionHead ((Token text _ _) :: rest) before =
  if text == "define" || text == "declare" then
    Err (UncheckedText "nested function header" moduleOrigin)
  else
    functionHead rest (text :: before)

shapeDefect : String -> Prototype -> SymbolOrigin -> SymbolDefect
shapeDefect name proto at =
  PrototypeConflict
    (errorName name)
    (DataProto "incompatible materialized declaration")
    proto
    at
    at

admitFunction : String ->
  List String ->
  List (List String) ->
  SymbolLinkage ->
  OrdMap Expected ->
  OrdMap Unit ->
  Result SymbolDefect (OrdMap Unit)
admitFunction name ret ps linkage expected seen =
  if omHasKey name seen then
    Err (DuplicateDefinition (errorName name) moduleOrigin moduleOrigin)
  else match omLookup name expected
    None => Err (UndefinedReference (errorName name) moduleOrigin)
    Some (Expected _ proto registered at) => match proto
      FuncProto r parameters _ =>
        if not (suffix (typeWords r) ret) || ps /= map paramType parameters then
          Err (shapeDefect name proto at)
        else if linkage /= registered then
          Err (UndefinedReference (errorName name) at)
        else
          Ok (omInsert name () seen)
      _ => Err (shapeDefect name proto at)

prefixTokens : List String -> List Token -> Bool
prefixTokens [] _ = True
prefixTokens _ [] = False
prefixTokens (word :: rest) ((Token found _ _) :: after) =
  word == found && prefixTokens rest after

dataHead : List Token -> Bool -> Option (Bool, List Token)
dataHead [] _ = None
dataHead ((Token text _ _) :: rest) external
  | text == "external" = dataHead rest True
  | text == "global" || text == "constant" = Some (external, rest)
  | text == "define" || text == "declare" || isGlobal text = None
  | otherwise = dataHead rest external

inventory : List Token ->
  OrdMap Expected ->
  OrdMap Unit ->
  Result SymbolDefect (OrdMap Unit)
inventory [] _ seen = Ok seen
inventory ((Token keyword _ _) :: rest) expected seen
  | keyword == "define" || keyword == "declare" = do
    (name, ret, ps, after) <- functionHead rest []
    next <- admitFunction
      name
      ret
      ps
      (if keyword == "define" then SymbolDefined else SymbolDeclared)
      expected
      seen
    inventory after expected next
inventory ((Token name _ _) :: (Token "=" _ _) :: rest) expected seen
  | isGlobal name =
    if omHasKey name seen then
      Err (DuplicateDefinition (errorName name) moduleOrigin moduleOrigin)
    else match (omLookup name expected, dataHead rest False)
      (Some (Expected _ (proto@(DataProto ty)) linkage at), Some (external, after)) =>
        if not (prefixTokens (typeWords ty) after) then
          Err (shapeDefect name proto at)
        else if external /= (linkage == SymbolDeclared) then
          Err (UndefinedReference (errorName name) at)
        else
          inventory rest expected (omInsert name () seen)
      (Some (Expected _ proto _ at), _) => Err (shapeDefect name proto at)
      _ => Err (UndefinedReference (errorName name) moduleOrigin)
inventory (_ :: rest) expected seen = inventory rest expected seen

gapNames : CoveragePolicy -> SymbolRegistry -> OrdMap Unit
gapNames ClosedOutput _ = omEmpty
gapNames (RecordedGaps syms) reg =
  omFromNames
    (map
      (s => canonicalName ("@" ++ symbolName s))
      (filter (s => isExcused s reg) syms))
    omEmpty

missingDeclarations : OrdMap Expected ->
  OrdMap Unit ->
  OrdMap Unit ->
  List SymbolDefect
missingDeclarations expected seen gaps =
  flatMap
    (name =>
      if omHasKey name seen || omHasKey name gaps then
        []
      else match omLookup name expected
        Some (Expected sym _ _ at) => [UndefinedReference (symbolName sym) at]
        None => [])
    (omKeys expected)

referenceDefects : List Token -> OrdMap Unit -> OrdMap Unit -> List SymbolDefect
referenceDefects tokens seen gaps = reverseL (referencesGo tokens seen gaps [])

wholeDeclarations : ModuleScope ->
  List SymbolDeclaration ->
  OrdMap Unit ->
  List SymbolDefect
wholeDeclarations ModuleHalf _ _ = []
wholeDeclarations WholeModule entries gaps =
  flatMap
    (entry => match entry
      SymbolDeclaration (sym@(Generated _)) _ SymbolDeclared at =>
        if omHasKey (canonicalName ("@" ++ symbolName sym)) gaps then
          []
        else
          [UndefinedReference (symbolName sym) at]
      _ => [])
    entries

referencesGo : List Token ->
  OrdMap Unit ->
  OrdMap Unit ->
  List SymbolDefect ->
  List SymbolDefect
referencesGo [] _ _ acc = acc
referencesGo ((Token name _ at) :: rest) seen gaps acc =
  if isGlobal name && not (omHasKey name seen || omHasKey name gaps) then
    referencesGo rest seen gaps (UndefinedReference (errorName name) at :: acc)
  else
    referencesGo rest seen gaps acc

attributeOrigins : List Token ->
  OrdMap Expected ->
  SymbolOrigin ->
  List Token ->
  List Token
-- Origin attribution preserves each target’s nominal token type.
-- lint-disable-next-line rule-duplicate-body
attributeOrigins [] _ _ acc = reverseL acc
attributeOrigins ((Token "define" covered origin) :: rest) expected current acc =
  let next = match functionHead rest []
    Ok (name, _, _, _) => match omLookup name expected
      Some (Expected _ _ _ at) => at
      None => moduleOrigin
    Err _ => current
  attributeOrigins
    rest
    expected
    next
    (Token "define" covered (if covered then origin else next) :: acc)
attributeOrigins ((Token name covered origin) :: (equals@(Token "=" _ _)) :: rest) expected current acc
  | isGlobal name =
    let next = match omLookup name expected
      Some (Expected _ _ _ at) => at
      None => moduleOrigin
    attributeOrigins
      (equals :: rest)
      expected
      next
      (Token name covered (if covered then origin else next) :: acc)
-- Origin attribution preserves each target’s nominal token type.
-- lint-disable-next-line rule-duplicate-body
attributeOrigins ((Token text covered origin) :: rest) expected current acc =
  attributeOrigins
    rest
    expected
    current
    (Token text covered (if covered then origin else current) :: acc)

export
finishCheckedText : CoveragePolicy ->
  SymbolRegistry ->
  CallCoverage ->
  String ->
  Result (List SymbolDefect) String
finishCheckedText policy reg (CallCoverage _ entries) text =
  match expectedMap (declarations reg) omEmpty
    Err d => Err [d]
    Ok expected =>
      match (scan
        text
        (stringToUtf8Bytes text)
        entries
        True
        (Some (reg, expected))
        0
        0
        []
        [])
        Err d => Err [d]
        Ok (raw, stripped) =>
          let tokens = attributeOrigins raw expected moduleOrigin []
          match inventory tokens expected omEmpty
            Err d => Err [d]
            Ok seen =>
              let gaps = gapNames policy reg
              let defects =
                coverageDefects tokens
                  ++ missingDeclarations expected seen gaps
                  ++ referenceDefects tokens seen gaps
                  ++ wholeDeclarations
                    (registryScope reg)
                    (declarations reg)
                    gaps
              if isEmpty defects then Ok stripped else Err defects
# DESUGAR
(DUse false (UseGroup ("backend" "llvm_symbols") ((mem "LlvmSymbol" true) (mem "ModuleScope" true) (mem "registryScope" false) (mem "LlvmParam" true) (mem "Prototype" true) (mem "CallShape" true) (mem "SymbolRegistry" false) (mem "SymbolDefect" true) (mem "SymbolDeclaration" true) (mem "SymbolLinkage" true) (mem "checkCall" false) (mem "symbolName" false) (mem "declarations" false) (mem "isExcused" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "CallModifier" () ((variant "OrdinaryCall" (ConPos)) (variant "TailCall" (ConPos)) (variant "MustTailCall" (ConPos)) (variant "NoTailCall" (ConPos))) ())
(DImpl true "Eq" ((TyCon "CallModifier")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "OrdinaryCall") (PCon "OrdinaryCall")) () (EVar "True")) (arm (PTuple (PCon "TailCall") (PCon "TailCall")) () (EVar "True")) (arm (PTuple (PCon "MustTailCall") (PCon "MustTailCall")) () (EVar "True")) (arm (PTuple (PCon "NoTailCall") (PCon "NoTailCall")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "CallModifier")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "OrdinaryCall") () (ELit (LString "OrdinaryCall"))) (arm (PCon "TailCall") () (ELit (LString "TailCall"))) (arm (PCon "MustTailCall") () (ELit (LString "MustTailCall"))) (arm (PCon "NoTailCall") () (ELit (LString "NoTailCall")))))))
(DData Public "CoveragePolicy" () ((variant "ClosedOutput" (ConPos)) (variant "RecordedGaps" (ConPos (TyApp (TyCon "List") (TyCon "LlvmSymbol"))))) ())
(DData Private "Token" () ((variant "Token" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "SymbolOrigin")))) ())
(DData Private "Receipt" () ((variant "Receipt" (ConNamed (field "text" (TyCon "String")) (field "sym" (TyCon "LlvmSymbol")) (field "shape" (TyCon "CallShape")) (field "modifier" (TyCon "CallModifier")) (field "origin" (TyCon "SymbolOrigin")) (field "tokens" (TyApp (TyCon "List") (TyCon "Token")))))) ())
(DData Abstract "CallCoverage" () ((variant "CallCoverage" (ConPos (TyCon "Int") (TyApp (TyCon "OrdMap") (TyCon "Receipt"))))) ())
(DTypeSig true "emptyCoverage" (TyCon "CallCoverage"))
(DFunDef false "emptyCoverage" () (EApp (EApp (EVar "CallCoverage") (ELit (LInt 0))) (EVar "omEmpty")))
(DTypeSig false "moduleOrigin" (TyCon "SymbolOrigin"))
(DFunDef false "moduleOrigin" () (EApp (EApp (EApp (EApp (EVar "SymbolOrigin") (ELit (LString "module"))) (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "modifierText" (TyFun (TyCon "CallModifier") (TyCon "String")))
(DFunDef false "modifierText" ((PCon "OrdinaryCall")) (ELit (LString "")))
(DFunDef false "modifierText" ((PCon "TailCall")) (ELit (LString "tail ")))
(DFunDef false "modifierText" ((PCon "MustTailCall")) (ELit (LString "musttail ")))
(DFunDef false "modifierText" ((PCon "NoTailCall")) (ELit (LString "notail ")))
(DTypeSig true "checkedCall" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallModifier") (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "CallCoverage") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "SymbolRegistry") (TyCon "CallCoverage") (TyCon "String")))))))))))
(DFunDef false "checkedCall" ((PVar "reg") (PVar "modifier") (PVar "sym") (PVar "ret") (PVar "ops") (PVar "origin") (PCon "CallCoverage" (PVar "next") (PVar "entries"))) (ELet false (PVar "shape") (EApp (EApp (EVar "CallShape") (EVar "ret")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ops"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg"))) (ELam ((PVar "reg2")) (ELet false (PVar "arguments") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "ty") (PVar "operand"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "operand"))) (ELit (LString ""))))) (EVar "ops"))) (ELet false (PVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "modifierText") (EVar "modifier")))) (ELit (LString "call "))) (EApp (EVar "display") (EVar "ret"))) (ELit (LString " @"))) (EApp (EVar "display") (EApp (EVar "symbolName") (EVar "sym")))) (ELit (LString "("))) (EApp (EVar "display") (EVar "arguments"))) (ELit (LString ")"))) (EApp (EApp (EVar "andThen") (EMatch (EApp (EVar "rawTokens") (EVar "text")) (arm (PCon "Err" (PCon "UncheckedText" (PVar "reason") PWild)) () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (EVar "reason")) (EVar "origin")))) (arm (PVar "result") () (EVar "result")))) (ELam ((PVar "tokens")) (EIf (EBinOp "/=" (EApp (EVar "callFacts") (EVar "tokens")) (EListLit (ETuple (EVar "modifier") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "checked instruction must contain exactly one matching named call"))) (EVar "origin"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "intToString") (EVar "next"))) (DoLet false false (PVar "receipt") (ERecordCreate "Receipt" ((fa "text" (EVar "text")) (fa "sym" (EVar "sym")) (fa "shape" (EVar "shape")) (fa "modifier" (EVar "modifier")) (fa "origin" (EVar "origin")) (fa "tokens" (EVar "tokens"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "reg2") (EApp (EApp (EVar "CallCoverage") (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "receipt")) (EVar "entries"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\u{1e}L")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "text"))) (ELit (LString "\u{1f}"))))))))))))))))
(DTypeSig false "byte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes")))) (EUnOp "-" (ELit (LInt 1))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))))
(DTypeSig false "space" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "space" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 0))) (EBinOp "==" (EVar "c") (ELit (LInt 32)))) (EBinOp "==" (EVar "c") (ELit (LInt 9)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))))
(DTypeSig false "punct" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "punct" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "==" (EVar "c") (ELit (LInt 91)))) (EBinOp "==" (EVar "c") (ELit (LInt 93)))) (EBinOp "==" (EVar "c") (ELit (LInt 123)))) (EBinOp "==" (EVar "c") (ELit (LInt 125)))) (EBinOp "==" (EVar "c") (ELit (LInt 60)))) (EBinOp "==" (EVar "c") (ELit (LInt 62)))) (EBinOp "==" (EVar "c") (ELit (LInt 44)))) (EBinOp "==" (EVar "c") (ELit (LInt 61)))) (EBinOp "==" (EVar "c") (ELit (LInt 58)))) (EBinOp "==" (EVar "c") (ELit (LInt 42)))))
(DTypeSig false "boundary" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "boundary" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EApp (EVar "punct") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))))
(DTypeSig false "wordEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EApp (EVar "punct") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 30)))) (EBinOp "==" (EVar "c") (ELit (LInt 31)))) (EVar "i") (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "quotedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int")))))
(DFunDef false "quotedEnd" ((PVar "bytes") (PVar "i")) (EMatch (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (arm (PVar "c") ((GBool (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated quoted text"))) (EVar "moduleOrigin")))) (arm (PLit (LInt 34)) () (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PLit (LInt 92)) () (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated escape"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (arm PWild () (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "lineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))) (EVar "i") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "keyEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "keyEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))))
(DTypeSig false "prependChecked" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))))
(DFunDef false "prependChecked" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChecked" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "origin") (PVar "acc")) (EApp (EApp (EApp (EVar "prependChecked") (EVar "rest")) (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "True")) (EVar "origin")) (EVar "acc"))))
(DTypeSig false "rawTokens" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "rawTokens" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "omEmpty")) (EVar "False")) (EVar "None")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "tokens") PWild) () (EApp (EVar "Ok") (EVar "tokens")))))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Receipt")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Expected")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyCon "String")))))))))))))
(DFunDef false "scan" ((PVar "text") (PVar "bytes") (PVar "entries") (PVar "markers") (PVar "registry") (PVar "i") (PVar "copied") (PVar "tokens") (PVar "chunks")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "tokens")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 30))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EVar "markers")) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 76)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed or nested receipt"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "endKey") (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "stringSliceBytes") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "endKey")) (EVar "text"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString ""))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "endKey")) (ELit (LInt 58)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed receipt key"))) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "entries")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unknown receipt"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PVar "receipt")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "endKey") (ELit (LInt 1)))) (DoLet false false (PVar "end") (EBinOp "+" (EVar "start") (EApp (EVar "stringByteLength") (EFieldAccess (EVar "receipt") "text")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "end")) (ELit (LInt 31)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed or unterminated receipt"))) (EFieldAccess (EVar "receipt") "origin"))) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "start")) (EVar "end")) (EVar "text")) (EFieldAccess (EVar "receipt") "text")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed receipt text"))) (EFieldAccess (EVar "receipt") "origin"))) (EMatch (EApp (EApp (EVar "recheck") (EVar "registry")) (EVar "receipt")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "prependChecked") (EFieldAccess (EVar "receipt") "tokens")) (EFieldAccess (EVar "receipt") "origin")) (EVar "tokens"))) (EBinOp "::" (EFieldAccess (EVar "receipt") "text") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))))))))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 31))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched receipt end"))) (EVar "moduleOrigin"))) (EIf (EApp (EVar "space") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "markers")) (EBinOp "==" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "receipt ends inside a line comment"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EVar "tokens")) (EVar "chunks"))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "\"\""))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EBinOp "==" (EVar "c") (ELit (LInt 37)))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 34)))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELam ((PVar "end")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EBinOp "==" (EVar "end") (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "empty global name requests implicit LLVM numbering"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EApp (EVar "canonicalName") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text")))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks"))))) (EBlock (DoLet false false (PVar "end") (EIf (EApp (EVar "punct") (EVar "c")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EVar "i")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EApp (EVar "canonicalName") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text"))) (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text")))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks"))))))))))))))
(DTypeSig false "recheck" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Expected")))) (TyFun (TyCon "Receipt") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Unit")))))
(DFunDef false "recheck" ((PCon "None") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "recheck" ((PCon "Some" (PTuple (PVar "reg") (PVar "expected"))) (PVar "receipt")) (EBlock (DoLet false false (PVar "actual") (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EFieldAccess (EVar "receipt") "sym"))))) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" (PVar "sym") PWild PWild PWild)) () (EVar "sym")) (arm (PCon "None") () (EFieldAccess (EVar "receipt") "sym")))) (DoExpr (EApp (EApp (EVar "map") (ELam (PWild) (ELit LUnit))) (EApp (EApp (EApp (EApp (EVar "checkCall") (EVar "actual")) (EFieldAccess (EVar "receipt") "shape")) (EFieldAccess (EVar "receipt") "origin")) (EVar "reg"))))))
(DTypeSig false "tokenText" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenText" ((PCon "Token" (PVar "text") PWild PWild)) (EVar "text"))
(DTypeSig false "hex" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "hex" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EBinOp "-" (EVar "c") (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 70)))) (EBinOp "-" (EVar "c") (ELit (LInt 55))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 102)))) (EBinOp "-" (EVar "c") (ELit (LInt 87))) (EIf (EVar "otherwise") (EUnOp "-" (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "nameBytes" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EApp (EVar "reverseL") (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 92))) (EBinOp ">=" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 0)))) (EBinOp ">=" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "nameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EBinOp "::" (EBinOp "+" (EBinOp "*" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 16))) (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EVar "acc"))) (EApp (EApp (EApp (EVar "nameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EVar "acc"))))))
(DTypeSig false "sameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "sameBytes" ((PVar "bytes") (PList) (PVar "i")) (EBinOp "==" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))))
(DFunDef false "sameBytes" ((PVar "bytes") (PCons (PVar "c") (PVar "rest")) (PVar "i")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EVar "c")) (EApp (EApp (EApp (EVar "sameBytes") (EVar "bytes")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "escapedNameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "escapedNameBytes" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EVar "acc"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "digits") (ELit (LString "0123456789abcdef"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "/" (EVar "c") (ELit (LInt 16)))) (EBinOp "+" (EBinOp "/" (EVar "c") (ELit (LInt 16))) (ELit (LInt 1)))) (EVar "digits"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "%" (EVar "c") (ELit (LInt 16)))) (EBinOp "+" (EBinOp "%" (EVar "c") (ELit (LInt 16))) (ELit (LInt 1)))) (EVar "digits"))) (DoExpr (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\\")) (EApp (EVar "display") (EVar "hi"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString ""))) (EVar "acc")))))))
(DTypeSig false "decimalTail" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "decimalTail" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 57)))) (EApp (EApp (EVar "decimalTail") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "zeroEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "zeroEnd" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 48)))) (EApp (EApp (EVar "zeroEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))
(DTypeSig false "canonicalName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "canonicalName" ((PVar "name")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "name")) (ELit (LString "@\""))) (EBlock (DoLet false false (PVar "decoded") (EApp (EApp (EApp (EVar "nameBytes") (EApp (EVar "stringToUtf8Bytes") (EVar "name"))) (ELit (LInt 2))) (EListLit))) (DoLet false false (PVar "bytes") (EApp (EVar "arrayFromList") (EVar "decoded"))) (DoLet false false (PVar "value") (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "sameBytes") (EApp (EVar "stringToUtf8Bytes") (EVar "value"))) (EVar "decoded")) (ELit (LInt 0))) (EBinOp "++" (ELit (LString "@")) (EVar "value")) (EBinOp "++" (ELit (LString "!llvm-id:")) (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (ELit (LInt 0))) (EListLit)))))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "name")) (ELit (LString "@"))) (EBlock (DoLet false false (PVar "first") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "name"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "first") (ELit (LString "0"))) (EBinOp "<=" (EVar "first") (ELit (LString "9")))) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "name"))) (DoExpr (EIf (EApp (EApp (EVar "decimalTail") (EVar "bytes")) (ELit (LInt 1))) (EBinOp "++" (ELit (LString "!llvm-slot:")) (EApp (EApp (EApp (EVar "stringSliceBytes") (EApp (EApp (EVar "zeroEnd") (EVar "bytes")) (ELit (LInt 1)))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "name"))) (EVar "name")))) (EVar "name")))) (EVar "name"))))
(DTypeSig false "isGlobal" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isGlobal" ((PVar "s")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (DoExpr (EBinOp "||" (EBinOp "==" (EVar "prefix") (ELit (LString "@"))) (EBinOp "&&" (EBinOp "==" (EVar "prefix") (ELit (LString "!"))) (EBinOp "||" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "!llvm-id:"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 11))) (EVar "s")) (ELit (LString "!llvm-slot:")))))))))
(DTypeSig false "needsQuotes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "needsQuotes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "==" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "digit") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57))))) (DoLet false false (PVar "letter") (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 90)))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 122)))))) (DoExpr (EIf (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "digit")) (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EVar "digit") (EVar "letter")) (EBinOp "==" (EVar "c") (ELit (LInt 36)))) (EBinOp "==" (EVar "c") (ELit (LInt 45)))) (EBinOp "==" (EVar "c") (ELit (LInt 46)))) (EBinOp "==" (EVar "c") (ELit (LInt 95)))))) (EVar "True") (EApp (EApp (EVar "needsQuotes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "needsEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "needsEscape" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "False") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 32))) (EBinOp "==" (EVar "c") (ELit (LInt 127)))) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 92)))) (EApp (EApp (EVar "needsEscape") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "errorName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "errorName" ((PVar "name")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "name")) (ELit (LString "!llvm-id:"))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (ELit (LString "\""))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 11))) (EVar "name")) (ELit (LString "!llvm-slot:"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 11))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name")) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "value"))) (DoExpr (EIf (EApp (EApp (EVar "needsEscape") (EVar "bytes")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (ELit (LInt 0))) (EListLit))) (ELit (LString "\""))) (EIf (EApp (EApp (EVar "needsQuotes") (EVar "bytes")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "value")) (ELit (LString "\""))) (EVar "value"))))))))
(DTypeSig false "isLocal" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isLocal" ((PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "%"))))
(DTypeSig false "modifierOf" (TyFun (TyCon "String") (TyCon "CallModifier")))
(DFunDef false "modifierOf" ((PLit (LString "tail"))) (EVar "TailCall"))
(DFunDef false "modifierOf" ((PLit (LString "musttail"))) (EVar "MustTailCall"))
(DFunDef false "modifierOf" ((PLit (LString "notail"))) (EVar "NoTailCall"))
(DFunDef false "modifierOf" (PWild) (EVar "OrdinaryCall"))
(DTypeSig false "namedCallee" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "namedCallee" ((PList)) (EVar "None"))
(DFunDef false "namedCallee" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PVar "rest")))) (EIf (EApp (EVar "isLocal") (EVar "text")) (EMatch (EApp (EApp (EVar "afterParens") (EVar "rest")) (ELit (LInt 0))) (arm (PAs "after" (PCons (PCon "Token" (PVar "name") PWild PWild) PWild)) ((GBool (EBinOp "||" (EApp (EVar "isGlobal") (EVar "name")) (EApp (EVar "isLocal") (EVar "name"))))) (EApp (EVar "namedCallee") (EVar "after"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "namedCallee" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest"))) (EIf (EApp (EVar "isGlobal") (EVar "text")) (EApp (EVar "Some") (EVar "text")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "="))) (EBinOp "==" (EVar "text") (ELit (LString ";")))) (EBinOp "==" (EVar "text") (ELit (LString "call")))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EBinOp "==" (EVar "text") (ELit (LString "ret")))) (EBinOp "==" (EVar "text") (ELit (LString "define")))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "namedCallee") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "afterParens" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "afterParens" ((PList) PWild) (EListLit))
(DFunDef false "afterParens" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EListLit) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "rest") (EApp (EApp (EVar "afterParens") (EVar "rest")) (EBinOp "+" (EVar "depth") (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (ELit (LInt 1)) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0)))))))))
(DTypeSig false "callFacts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String")))))
(DFunDef false "callFacts" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "callFactsGo") (EVar "tokens")) (ELit (LString ""))) (EListLit))))
(DTypeSig false "callFactsGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String")))))))
(DFunDef false "callFactsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "callFactsGo" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "previous") (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EMatch (EApp (EVar "namedCallee") (EVar "rest")) (arm (PCon "Some" (PVar "name")) () (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EBinOp "::" (ETuple (EApp (EVar "modifierOf") (EVar "previous")) (EVar "name")) (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EVar "acc")))) (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EVar "acc"))))
(DTypeSig false "coverageDefects" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "coverageDefects" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "coverageGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "coverageGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "coverageGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "coverageGo" ((PCons (PCon "Token" (PVar "text") (PVar "checked") (PVar "origin")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "direct") (EBinOp "&&" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EApp (EVar "isSome") (EApp (EVar "namedCallee") (EVar "rest"))))) (DoLet false false (PVar "modifier") (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "tail"))) (EBinOp "==" (EVar "text") (ELit (LString "musttail")))) (EBinOp "==" (EVar "text") (ELit (LString "notail"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "||" (EVar "direct") (EVar "modifier")) (EApp (EVar "not") (EVar "checked"))) (EApp (EApp (EVar "coverageGo") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered named call or call modifier"))) (EVar "origin")) (EVar "acc"))) (EApp (EApp (EVar "coverageGo") (EVar "rest")) (EVar "acc"))))))
(DData Private "Expected" () ((variant "Expected" (ConPos (TyCon "LlvmSymbol") (TyCon "Prototype") (TyCon "SymbolLinkage") (TyCon "SymbolOrigin")))) ())
(DTypeSig false "expectedMap" (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Expected"))))))
(DFunDef false "expectedMap" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "expectedMap" ((PCons (PCon "SymbolDeclaration" (PVar "sym") (PVar "proto") (PVar "linkage") (PVar "origin")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "acc")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "origin")) (EVar "origin"))) (EApp (EApp (EVar "expectedMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EApp (EApp (EApp (EApp (EVar "Expected") (EVar "sym")) (EVar "proto")) (EVar "linkage")) (EVar "origin"))) (EVar "acc")))))))
(DTypeSig false "texts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "texts" ((PVar "ts")) (EApp (EApp (EVar "map") (EVar "tokenText")) (EVar "ts")))
(DTypeSig false "typeWords" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "typeWords" ((PVar "s")) (EMatch (EApp (EVar "rawTokens") (EVar "s")) (arm (PCon "Ok" (PVar "ts")) () (EApp (EVar "texts") (EVar "ts"))) (arm (PCon "Err" PWild) () (EListLit (EVar "s")))))
(DTypeSig false "suffix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "suffix" ((PVar "wanted") (PVar "actual")) (EApp (EApp (EVar "starts") (EApp (EVar "reverseL") (EVar "wanted"))) (EApp (EVar "reverseL") (EVar "actual"))))
(DTypeSig false "starts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "starts" ((PList) PWild) (EVar "True"))
(DFunDef false "starts" (PWild (PList)) (EVar "False"))
(DFunDef false "starts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "starts") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "paramWords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramWords" ((PVar "words")) (EMatch (EApp (EVar "reverseL") (EVar "words")) (arm (PCons (PVar "last") (PVar "earlier")) () (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "earlier"))) (EApp (EVar "isLocal") (EVar "last"))) (EApp (EVar "reverseL") (EVar "earlier")) (EVar "words"))) (arm PWild () (EVar "words"))))
(DTypeSig false "paramType" (TyFun (TyCon "LlvmParam") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramType" ((PCon "LlvmParam" (PVar "ty") PWild)) (EApp (EVar "typeWords") (EVar "ty")))
(DTypeSig false "params" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "params" ((PList) PWild PWild PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated function parameter list"))) (EVar "moduleOrigin"))))
(DFunDef false "params" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth") (PVar "current") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EIf (EApp (EVar "isEmpty") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "paramWords") (EApp (EVar "reverseL") (EVar "current"))) (EVar "acc")))) (EVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (EVar "depth")) (EListLit)) (EBinOp "::" (EApp (EVar "paramWords") (EApp (EVar "reverseL") (EVar "current"))) (EVar "acc"))) (EBlock (DoLet false false (PVar "delta") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "("))) (EBinOp "==" (EVar "text") (ELit (LString "[")))) (EBinOp "==" (EVar "text") (ELit (LString "{")))) (EBinOp "==" (EVar "text") (ELit (LString "<")))) (ELit (LInt 1)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "text") (ELit (LString "]")))) (EBinOp "==" (EVar "text") (ELit (LString "}")))) (EBinOp "==" (EVar "text") (ELit (LString ">")))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (EBinOp "+" (EVar "depth") (EVar "delta"))) (EBinOp "::" (EVar "text") (EVar "current"))) (EVar "acc")))))))
(DTypeSig false "functionHead" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "functionHead" ((PList) PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "function header without a name"))) (EVar "moduleOrigin"))))
(DFunDef false "functionHead" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PVar "rest"))) (PVar "before")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ps") (PVar "after")) () (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "reverseL") (EVar "before")) (EVar "ps") (EVar "after"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionHead" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "before")) (EIf (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "define"))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "nested function header"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "functionHead") (EVar "rest")) (EBinOp "::" (EVar "text") (EVar "before")))))
(DTypeSig false "shapeDefect" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect")))))
(DFunDef false "shapeDefect" ((PVar "name") (PVar "proto") (PVar "at")) (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EApp (EVar "errorName") (EVar "name"))) (EApp (EVar "DataProto") (ELit (LString "incompatible materialized declaration")))) (EVar "proto")) (EVar "at")) (EVar "at")))
(DTypeSig false "admitFunction" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "SymbolLinkage") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))))
(DFunDef false "admitFunction" ((PVar "name") (PVar "ret") (PVar "ps") (PVar "linkage") (PVar "expected") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PCon "Expected" PWild (PVar "proto") (PVar "registered") (PVar "at"))) () (EMatch (EVar "proto") (arm (PCon "FuncProto" (PVar "r") (PVar "parameters") PWild) () (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "suffix") (EApp (EVar "typeWords") (EVar "r"))) (EVar "ret"))) (EBinOp "/=" (EVar "ps") (EApp (EApp (EVar "map") (EVar "paramType")) (EVar "parameters")))) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at"))) (EIf (EBinOp "/=" (EVar "linkage") (EVar "registered")) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at")))))))))
(DTypeSig false "prefixTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "prefixTokens" ((PList) PWild) (EVar "True"))
(DFunDef false "prefixTokens" (PWild (PList)) (EVar "False"))
(DFunDef false "prefixTokens" ((PCons (PVar "word") (PVar "rest")) (PCons (PCon "Token" (PVar "found") PWild PWild) (PVar "after"))) (EBinOp "&&" (EBinOp "==" (EVar "word") (EVar "found")) (EApp (EApp (EVar "prefixTokens") (EVar "rest")) (EVar "after"))))
(DTypeSig false "dataHead" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "dataHead" ((PList) PWild) (EVar "None"))
(DFunDef false "dataHead" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "external")) (EIf (EBinOp "==" (EVar "text") (ELit (LString "external"))) (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "True")) (EIf (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "global"))) (EBinOp "==" (EVar "text") (ELit (LString "constant")))) (EApp (EVar "Some") (ETuple (EVar "external") (EVar "rest"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "define"))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EApp (EVar "isGlobal") (EVar "text"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "external")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inventory" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "inventory" ((PList) PWild (PVar "seen")) (EApp (EVar "Ok") (EVar "seen")))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "keyword") PWild PWild) (PVar "rest")) (PVar "expected") (PVar "seen")) (EIf (EBinOp "||" (EBinOp "==" (EVar "keyword") (ELit (LString "define"))) (EBinOp "==" (EVar "keyword") (ELit (LString "declare")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "functionHead") (EVar "rest")) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "name") (PVar "ret") (PVar "ps") (PVar "after")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "admitFunction") (EVar "name")) (EVar "ret")) (EVar "ps")) (EIf (EBinOp "==" (EVar "keyword") (ELit (LString "define"))) (EVar "SymbolDefined") (EVar "SymbolDeclared"))) (EVar "expected")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EVar "inventory") (EVar "after")) (EVar "expected")) (EVar "next")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PCons (PCon "Token" (PLit (LString "=")) PWild PWild) (PVar "rest"))) (PVar "expected") (PVar "seen")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EMatch (ETuple (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "False"))) (arm (PTuple (PCon "Some" (PCon "Expected" PWild (PAs "proto" (PCon "DataProto" (PVar "ty"))) (PVar "linkage") (PVar "at"))) (PCon "Some" (PTuple (PVar "external") (PVar "after")))) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "prefixTokens") (EApp (EVar "typeWords") (EVar "ty"))) (EVar "after"))) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at"))) (EIf (EBinOp "/=" (EVar "external") (EBinOp "==" (EVar "linkage") (EVar "SymbolDeclared"))) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at"))) (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "expected")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))) (arm (PTuple (PCon "Some" (PCon "Expected" PWild (PVar "proto") PWild (PVar "at"))) PWild) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at")))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons PWild (PVar "rest")) (PVar "expected") (PVar "seen")) (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "expected")) (EVar "seen")))
(DTypeSig false "gapNames" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "gapNames" ((PCon "ClosedOutput") PWild) (EVar "omEmpty"))
(DFunDef false "gapNames" ((PCon "RecordedGaps" (PVar "syms")) (PVar "reg")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "s")))))) (EApp (EApp (EVar "filter") (ELam ((PVar "s")) (EApp (EApp (EVar "isExcused") (EVar "s")) (EVar "reg")))) (EVar "syms")))) (EVar "omEmpty")))
(DTypeSig false "missingDeclarations" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "missingDeclarations" ((PVar "expected") (PVar "seen") (PVar "gaps")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "gaps"))) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" (PVar "sym") PWild PWild (PVar "at"))) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "at")))) (arm (PCon "None") () (EListLit)))))) (EApp (EVar "omKeys") (EVar "expected"))))
(DTypeSig false "referenceDefects" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "referenceDefects" ((PVar "tokens") (PVar "seen") (PVar "gaps")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "tokens")) (EVar "seen")) (EVar "gaps")) (EListLit))))
(DTypeSig false "wholeDeclarations" (TyFun (TyCon "ModuleScope") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "wholeDeclarations" ((PCon "ModuleHalf") PWild PWild) (EListLit))
(DFunDef false "wholeDeclarations" ((PCon "WholeModule") (PVar "entries") (PVar "gaps")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "entry")) (EMatch (EVar "entry") (arm (PCon "SymbolDeclaration" (PAs "sym" (PCon "Generated" PWild)) PWild (PCon "SymbolDeclared") (PVar "at")) () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))) (EVar "gaps")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "at"))))) (arm PWild () (EListLit))))) (EVar "entries")))
(DTypeSig false "referencesGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "referencesGo" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "referencesGo" ((PCons (PCon "Token" (PVar "name") PWild (PVar "at")) (PVar "rest")) (PVar "seen") (PVar "gaps") (PVar "acc")) (EIf (EBinOp "&&" (EApp (EVar "isGlobal") (EVar "name")) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "gaps"))))) (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EBinOp "::" (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EVar "acc"))))
(DTypeSig false "attributeOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "attributeOrigins" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PLit (LString "define")) (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "functionHead") (EVar "rest")) (EListLit)) (arm (PCon "Ok" (PTuple (PVar "name") PWild PWild PWild)) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "moduleOrigin")))) (arm (PCon "Err" PWild) () (EVar "current")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "define"))) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "name") (PVar "covered") (PVar "origin")) (PCons (PAs "equals" (PCon "Token" (PLit (LString "=")) PWild PWild)) (PVar "rest"))) (PVar "expected") (PVar "current") (PVar "acc")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "moduleOrigin")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EBinOp "::" (EVar "equals") (EVar "rest"))) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "name")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "text") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "current")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "current"))) (EVar "acc"))))
(DTypeSig true "finishCheckedText" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "String")))))))
(DFunDef false "finishCheckedText" ((PVar "policy") (PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PVar "expected")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (ETuple (EVar "reg") (EVar "expected")))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "raw") (PVar "stripped"))) () (EBlock (DoLet false false (PVar "tokens") (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "raw")) (EVar "expected")) (EVar "moduleOrigin")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "inventory") (EVar "tokens")) (EVar "expected")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PVar "seen")) () (EBlock (DoLet false false (PVar "gaps") (EApp (EApp (EVar "gapNames") (EVar "policy")) (EVar "reg"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "coverageDefects") (EVar "tokens")) (EApp (EApp (EApp (EVar "missingDeclarations") (EVar "expected")) (EVar "seen")) (EVar "gaps"))) (EApp (EApp (EApp (EVar "referenceDefects") (EVar "tokens")) (EVar "seen")) (EVar "gaps"))) (EApp (EApp (EApp (EVar "wholeDeclarations") (EApp (EVar "registryScope") (EVar "reg"))) (EApp (EVar "declarations") (EVar "reg"))) (EVar "gaps")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (EVar "stripped")) (EApp (EVar "Err") (EVar "defects"))))))))))))))
# MARK
(DUse false (UseGroup ("backend" "llvm_symbols") ((mem "LlvmSymbol" true) (mem "ModuleScope" true) (mem "registryScope" false) (mem "LlvmParam" true) (mem "Prototype" true) (mem "CallShape" true) (mem "SymbolRegistry" false) (mem "SymbolDefect" true) (mem "SymbolDeclaration" true) (mem "SymbolLinkage" true) (mem "checkCall" false) (mem "symbolName" false) (mem "declarations" false) (mem "isExcused" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false))))
(DData Public "CallModifier" () ((variant "OrdinaryCall" (ConPos)) (variant "TailCall" (ConPos)) (variant "MustTailCall" (ConPos)) (variant "NoTailCall" (ConPos))) ())
(DImpl true "Eq" ((TyCon "CallModifier")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "OrdinaryCall") (PCon "OrdinaryCall")) () (EVar "True")) (arm (PTuple (PCon "TailCall") (PCon "TailCall")) () (EVar "True")) (arm (PTuple (PCon "MustTailCall") (PCon "MustTailCall")) () (EVar "True")) (arm (PTuple (PCon "NoTailCall") (PCon "NoTailCall")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "CallModifier")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "OrdinaryCall") () (ELit (LString "OrdinaryCall"))) (arm (PCon "TailCall") () (ELit (LString "TailCall"))) (arm (PCon "MustTailCall") () (ELit (LString "MustTailCall"))) (arm (PCon "NoTailCall") () (ELit (LString "NoTailCall")))))))
(DData Public "CoveragePolicy" () ((variant "ClosedOutput" (ConPos)) (variant "RecordedGaps" (ConPos (TyApp (TyCon "List") (TyCon "LlvmSymbol"))))) ())
(DData Private "Token" () ((variant "Token" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "SymbolOrigin")))) ())
(DData Private "Receipt" () ((variant "Receipt" (ConNamed (field "text" (TyCon "String")) (field "sym" (TyCon "LlvmSymbol")) (field "shape" (TyCon "CallShape")) (field "modifier" (TyCon "CallModifier")) (field "origin" (TyCon "SymbolOrigin")) (field "tokens" (TyApp (TyCon "List") (TyCon "Token")))))) ())
(DData Abstract "CallCoverage" () ((variant "CallCoverage" (ConPos (TyCon "Int") (TyApp (TyCon "OrdMap") (TyCon "Receipt"))))) ())
(DTypeSig true "emptyCoverage" (TyCon "CallCoverage"))
(DFunDef false "emptyCoverage" () (EApp (EApp (EVar "CallCoverage") (ELit (LInt 0))) (EVar "omEmpty")))
(DTypeSig false "moduleOrigin" (TyCon "SymbolOrigin"))
(DFunDef false "moduleOrigin" () (EApp (EApp (EApp (EApp (EVar "SymbolOrigin") (ELit (LString "module"))) (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "modifierText" (TyFun (TyCon "CallModifier") (TyCon "String")))
(DFunDef false "modifierText" ((PCon "OrdinaryCall")) (ELit (LString "")))
(DFunDef false "modifierText" ((PCon "TailCall")) (ELit (LString "tail ")))
(DFunDef false "modifierText" ((PCon "MustTailCall")) (ELit (LString "musttail ")))
(DFunDef false "modifierText" ((PCon "NoTailCall")) (ELit (LString "notail ")))
(DTypeSig true "checkedCall" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallModifier") (TyFun (TyCon "LlvmSymbol") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "CallCoverage") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "SymbolRegistry") (TyCon "CallCoverage") (TyCon "String")))))))))))
(DFunDef false "checkedCall" ((PVar "reg") (PVar "modifier") (PVar "sym") (PVar "ret") (PVar "ops") (PVar "origin") (PCon "CallCoverage" (PVar "next") (PVar "entries"))) (ELet false (PVar "shape") (EApp (EApp (EVar "CallShape") (EVar "ret")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ops"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EVar "sym")) (EVar "shape")) (EVar "origin")) (EVar "reg"))) (ELam ((PVar "reg2")) (ELet false (PVar "arguments") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "ty") (PVar "operand"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "operand"))) (ELit (LString ""))))) (EVar "ops"))) (ELet false (PVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "modifierText") (EVar "modifier")))) (ELit (LString "call "))) (EApp (EMethodRef "display") (EVar "ret"))) (ELit (LString " @"))) (EApp (EMethodRef "display") (EApp (EVar "symbolName") (EVar "sym")))) (ELit (LString "("))) (EApp (EMethodRef "display") (EVar "arguments"))) (ELit (LString ")"))) (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EVar "rawTokens") (EVar "text")) (arm (PCon "Err" (PCon "UncheckedText" (PVar "reason") PWild)) () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (EVar "reason")) (EVar "origin")))) (arm (PVar "result") () (EVar "result")))) (ELam ((PVar "tokens")) (EIf (EBinOp "/=" (EApp (EVar "callFacts") (EVar "tokens")) (EListLit (ETuple (EVar "modifier") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "checked instruction must contain exactly one matching named call"))) (EVar "origin"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "intToString") (EVar "next"))) (DoLet false false (PVar "receipt") (ERecordCreate "Receipt" ((fa "text" (EVar "text")) (fa "sym" (EVar "sym")) (fa "shape" (EVar "shape")) (fa "modifier" (EVar "modifier")) (fa "origin" (EVar "origin")) (fa "tokens" (EVar "tokens"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "reg2") (EApp (EApp (EVar "CallCoverage") (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "receipt")) (EVar "entries"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\u{1e}L")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "\u{1f}"))))))))))))))))
(DTypeSig false "byte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes")))) (EUnOp "-" (ELit (LInt 1))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))))
(DTypeSig false "space" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "space" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 0))) (EBinOp "==" (EVar "c") (ELit (LInt 32)))) (EBinOp "==" (EVar "c") (ELit (LInt 9)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))))
(DTypeSig false "punct" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "punct" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "==" (EVar "c") (ELit (LInt 91)))) (EBinOp "==" (EVar "c") (ELit (LInt 93)))) (EBinOp "==" (EVar "c") (ELit (LInt 123)))) (EBinOp "==" (EVar "c") (ELit (LInt 125)))) (EBinOp "==" (EVar "c") (ELit (LInt 60)))) (EBinOp "==" (EVar "c") (ELit (LInt 62)))) (EBinOp "==" (EVar "c") (ELit (LInt 44)))) (EBinOp "==" (EVar "c") (ELit (LInt 61)))) (EBinOp "==" (EVar "c") (ELit (LInt 58)))) (EBinOp "==" (EVar "c") (ELit (LInt 42)))))
(DTypeSig false "boundary" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "boundary" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EApp (EVar "punct") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))))
(DTypeSig false "wordEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EApp (EVar "punct") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 30)))) (EBinOp "==" (EVar "c") (ELit (LInt 31)))) (EVar "i") (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "quotedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int")))))
(DFunDef false "quotedEnd" ((PVar "bytes") (PVar "i")) (EMatch (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (arm (PVar "c") ((GBool (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated quoted text"))) (EVar "moduleOrigin")))) (arm (PLit (LInt 34)) () (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PLit (LInt 92)) () (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated escape"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (arm PWild () (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "lineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))) (EVar "i") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "keyEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "keyEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))))
(DTypeSig false "prependChecked" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))))
(DFunDef false "prependChecked" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChecked" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "origin") (PVar "acc")) (EApp (EApp (EApp (EVar "prependChecked") (EVar "rest")) (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "True")) (EVar "origin")) (EVar "acc"))))
(DTypeSig false "rawTokens" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "rawTokens" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "omEmpty")) (EVar "False")) (EVar "None")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "tokens") PWild) () (EApp (EVar "Ok") (EVar "tokens")))))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Receipt")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Expected")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyCon "String")))))))))))))
(DFunDef false "scan" ((PVar "text") (PVar "bytes") (PVar "entries") (PVar "markers") (PVar "registry") (PVar "i") (PVar "copied") (PVar "tokens") (PVar "chunks")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "tokens")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 30))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EVar "markers")) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 76)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed or nested receipt"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "endKey") (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "stringSliceBytes") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "endKey")) (EVar "text"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString ""))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "endKey")) (ELit (LInt 58)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed receipt key"))) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "entries")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unknown receipt"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PVar "receipt")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "endKey") (ELit (LInt 1)))) (DoLet false false (PVar "end") (EBinOp "+" (EVar "start") (EApp (EVar "stringByteLength") (EFieldAccess (EVar "receipt") "text")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "end")) (ELit (LInt 31)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed or unterminated receipt"))) (EFieldAccess (EVar "receipt") "origin"))) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "start")) (EVar "end")) (EVar "text")) (EFieldAccess (EVar "receipt") "text")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed receipt text"))) (EFieldAccess (EVar "receipt") "origin"))) (EMatch (EApp (EApp (EVar "recheck") (EVar "registry")) (EVar "receipt")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "prependChecked") (EFieldAccess (EVar "receipt") "tokens")) (EFieldAccess (EVar "receipt") "origin")) (EVar "tokens"))) (EBinOp "::" (EFieldAccess (EVar "receipt") "text") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))))))))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 31))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched receipt end"))) (EVar "moduleOrigin"))) (EIf (EApp (EVar "space") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "markers")) (EBinOp "==" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "receipt ends inside a line comment"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EVar "tokens")) (EVar "chunks"))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "\"\""))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EBinOp "==" (EVar "c") (ELit (LInt 37)))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 34)))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELam ((PVar "end")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EBinOp "==" (EVar "end") (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "empty global name requests implicit LLVM numbering"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EApp (EVar "canonicalName") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text")))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks"))))) (EBlock (DoLet false false (PVar "end") (EIf (EApp (EVar "punct") (EVar "c")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EVar "i")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 64))) (EApp (EVar "canonicalName") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text"))) (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text")))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks"))))))))))))))
(DTypeSig false "recheck" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Expected")))) (TyFun (TyCon "Receipt") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Unit")))))
(DFunDef false "recheck" ((PCon "None") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "recheck" ((PCon "Some" (PTuple (PVar "reg") (PVar "expected"))) (PVar "receipt")) (EBlock (DoLet false false (PVar "actual") (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EFieldAccess (EVar "receipt") "sym"))))) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" (PVar "sym") PWild PWild PWild)) () (EVar "sym")) (arm (PCon "None") () (EFieldAccess (EVar "receipt") "sym")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam (PWild) (ELit LUnit))) (EApp (EApp (EApp (EApp (EVar "checkCall") (EVar "actual")) (EFieldAccess (EVar "receipt") "shape")) (EFieldAccess (EVar "receipt") "origin")) (EVar "reg"))))))
(DTypeSig false "tokenText" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "tokenText" ((PCon "Token" (PVar "text") PWild PWild)) (EVar "text"))
(DTypeSig false "hex" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "hex" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EBinOp "-" (EVar "c") (ELit (LInt 48))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 70)))) (EBinOp "-" (EVar "c") (ELit (LInt 55))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 102)))) (EBinOp "-" (EVar "c") (ELit (LInt 87))) (EIf (EVar "otherwise") (EUnOp "-" (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "nameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "nameBytes" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EApp (EVar "reverseL") (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 92))) (EBinOp ">=" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 0)))) (EBinOp ">=" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 0)))) (EApp (EApp (EApp (EVar "nameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EBinOp "::" (EBinOp "+" (EBinOp "*" (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 16))) (EApp (EVar "hex") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EVar "acc"))) (EApp (EApp (EApp (EVar "nameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EVar "acc"))))))
(DTypeSig false "sameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "sameBytes" ((PVar "bytes") (PList) (PVar "i")) (EBinOp "==" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))))
(DFunDef false "sameBytes" ((PVar "bytes") (PCons (PVar "c") (PVar "rest")) (PVar "i")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EVar "c")) (EApp (EApp (EApp (EVar "sameBytes") (EVar "bytes")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "escapedNameBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "escapedNameBytes" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EVar "acc"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "digits") (ELit (LString "0123456789abcdef"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "/" (EVar "c") (ELit (LInt 16)))) (EBinOp "+" (EBinOp "/" (EVar "c") (ELit (LInt 16))) (ELit (LInt 1)))) (EVar "digits"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "%" (EVar "c") (ELit (LInt 16)))) (EBinOp "+" (EBinOp "%" (EVar "c") (ELit (LInt 16))) (ELit (LInt 1)))) (EVar "digits"))) (DoExpr (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\\")) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString ""))) (EVar "acc")))))))
(DTypeSig false "decimalTail" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "decimalTail" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 57)))) (EApp (EApp (EVar "decimalTail") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "zeroEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "zeroEnd" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 48)))) (EApp (EApp (EVar "zeroEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))
(DTypeSig false "canonicalName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "canonicalName" ((PVar "name")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "name")) (ELit (LString "@\""))) (EBlock (DoLet false false (PVar "decoded") (EApp (EApp (EApp (EVar "nameBytes") (EApp (EVar "stringToUtf8Bytes") (EVar "name"))) (ELit (LInt 2))) (EListLit))) (DoLet false false (PVar "bytes") (EApp (EVar "arrayFromList") (EVar "decoded"))) (DoLet false false (PVar "value") (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "sameBytes") (EApp (EVar "stringToUtf8Bytes") (EVar "value"))) (EVar "decoded")) (ELit (LInt 0))) (EBinOp "++" (ELit (LString "@")) (EVar "value")) (EBinOp "++" (ELit (LString "!llvm-id:")) (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (ELit (LInt 0))) (EListLit)))))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "name")) (ELit (LString "@"))) (EBlock (DoLet false false (PVar "first") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "name"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "first") (ELit (LString "0"))) (EBinOp "<=" (EVar "first") (ELit (LString "9")))) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "name"))) (DoExpr (EIf (EApp (EApp (EVar "decimalTail") (EVar "bytes")) (ELit (LInt 1))) (EBinOp "++" (ELit (LString "!llvm-slot:")) (EApp (EApp (EApp (EVar "stringSliceBytes") (EApp (EApp (EVar "zeroEnd") (EVar "bytes")) (ELit (LInt 1)))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "name"))) (EVar "name")))) (EVar "name")))) (EVar "name"))))
(DTypeSig false "isGlobal" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isGlobal" ((PVar "s")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (DoExpr (EBinOp "||" (EBinOp "==" (EVar "prefix") (ELit (LString "@"))) (EBinOp "&&" (EBinOp "==" (EVar "prefix") (ELit (LString "!"))) (EBinOp "||" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "!llvm-id:"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 11))) (EVar "s")) (ELit (LString "!llvm-slot:")))))))))
(DTypeSig false "needsQuotes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "needsQuotes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "==" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "digit") (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57))))) (DoLet false false (PVar "letter") (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 90)))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 122)))))) (DoExpr (EIf (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "digit")) (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EVar "digit") (EVar "letter")) (EBinOp "==" (EVar "c") (ELit (LInt 36)))) (EBinOp "==" (EVar "c") (ELit (LInt 45)))) (EBinOp "==" (EVar "c") (ELit (LInt 46)))) (EBinOp "==" (EVar "c") (ELit (LInt 95)))))) (EVar "True") (EApp (EApp (EVar "needsQuotes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "needsEscape" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "needsEscape" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "False") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "c") (ELit (LInt 32))) (EBinOp "==" (EVar "c") (ELit (LInt 127)))) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 92)))) (EApp (EApp (EVar "needsEscape") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "errorName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "errorName" ((PVar "name")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "name")) (ELit (LString "!llvm-id:"))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (ELit (LString "\""))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 11))) (EVar "name")) (ELit (LString "!llvm-slot:"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 11))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name")) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (DoLet false false (PVar "bytes") (EApp (EVar "stringToUtf8Bytes") (EVar "value"))) (DoExpr (EIf (EApp (EApp (EVar "needsEscape") (EVar "bytes")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "escapedNameBytes") (EVar "bytes")) (ELit (LInt 0))) (EListLit))) (ELit (LString "\""))) (EIf (EApp (EApp (EVar "needsQuotes") (EVar "bytes")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "value")) (ELit (LString "\""))) (EVar "value"))))))))
(DTypeSig false "isLocal" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isLocal" ((PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "%"))))
(DTypeSig false "modifierOf" (TyFun (TyCon "String") (TyCon "CallModifier")))
(DFunDef false "modifierOf" ((PLit (LString "tail"))) (EVar "TailCall"))
(DFunDef false "modifierOf" ((PLit (LString "musttail"))) (EVar "MustTailCall"))
(DFunDef false "modifierOf" ((PLit (LString "notail"))) (EVar "NoTailCall"))
(DFunDef false "modifierOf" (PWild) (EVar "OrdinaryCall"))
(DTypeSig false "namedCallee" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "namedCallee" ((PList)) (EVar "None"))
(DFunDef false "namedCallee" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PVar "rest")))) (EIf (EApp (EVar "isLocal") (EVar "text")) (EMatch (EApp (EApp (EVar "afterParens") (EVar "rest")) (ELit (LInt 0))) (arm (PAs "after" (PCons (PCon "Token" (PVar "name") PWild PWild) PWild)) ((GBool (EBinOp "||" (EApp (EVar "isGlobal") (EVar "name")) (EApp (EVar "isLocal") (EVar "name"))))) (EApp (EVar "namedCallee") (EVar "after"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "namedCallee" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest"))) (EIf (EApp (EVar "isGlobal") (EVar "text")) (EApp (EVar "Some") (EVar "text")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "="))) (EBinOp "==" (EVar "text") (ELit (LString ";")))) (EBinOp "==" (EVar "text") (ELit (LString "call")))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EBinOp "==" (EVar "text") (ELit (LString "ret")))) (EBinOp "==" (EVar "text") (ELit (LString "define")))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "namedCallee") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "afterParens" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "afterParens" ((PList) PWild) (EListLit))
(DFunDef false "afterParens" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EListLit) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "rest") (EApp (EApp (EVar "afterParens") (EVar "rest")) (EBinOp "+" (EVar "depth") (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (ELit (LInt 1)) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0)))))))))
(DTypeSig false "callFacts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String")))))
(DFunDef false "callFacts" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "callFactsGo") (EVar "tokens")) (ELit (LString ""))) (EListLit))))
(DTypeSig false "callFactsGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "CallModifier") (TyCon "String")))))))
(DFunDef false "callFactsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "callFactsGo" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "previous") (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EMatch (EApp (EVar "namedCallee") (EVar "rest")) (arm (PCon "Some" (PVar "name")) () (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EBinOp "::" (ETuple (EApp (EVar "modifierOf") (EVar "previous")) (EVar "name")) (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EVar "acc")))) (EApp (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "text")) (EVar "acc"))))
(DTypeSig false "coverageDefects" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "coverageDefects" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "coverageGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "coverageGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "coverageGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "coverageGo" ((PCons (PCon "Token" (PVar "text") (PVar "checked") (PVar "origin")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "direct") (EBinOp "&&" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "call"))) (EBinOp "==" (EVar "text") (ELit (LString "invoke")))) (EBinOp "==" (EVar "text") (ELit (LString "callbr")))) (EApp (EVar "isSome") (EApp (EVar "namedCallee") (EVar "rest"))))) (DoLet false false (PVar "modifier") (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "tail"))) (EBinOp "==" (EVar "text") (ELit (LString "musttail")))) (EBinOp "==" (EVar "text") (ELit (LString "notail"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp "||" (EVar "direct") (EVar "modifier")) (EApp (EVar "not") (EVar "checked"))) (EApp (EApp (EVar "coverageGo") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered named call or call modifier"))) (EVar "origin")) (EVar "acc"))) (EApp (EApp (EVar "coverageGo") (EVar "rest")) (EVar "acc"))))))
(DData Private "Expected" () ((variant "Expected" (ConPos (TyCon "LlvmSymbol") (TyCon "Prototype") (TyCon "SymbolLinkage") (TyCon "SymbolOrigin")))) ())
(DTypeSig false "expectedMap" (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Expected"))))))
(DFunDef false "expectedMap" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "expectedMap" ((PCons (PCon "SymbolDeclaration" (PVar "sym") (PVar "proto") (PVar "linkage") (PVar "origin")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "acc")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "origin")) (EVar "origin"))) (EApp (EApp (EVar "expectedMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EApp (EApp (EApp (EApp (EVar "Expected") (EVar "sym")) (EVar "proto")) (EVar "linkage")) (EVar "origin"))) (EVar "acc")))))))
(DTypeSig false "texts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "texts" ((PVar "ts")) (EApp (EApp (EMethodRef "map") (EVar "tokenText")) (EVar "ts")))
(DTypeSig false "typeWords" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "typeWords" ((PVar "s")) (EMatch (EApp (EVar "rawTokens") (EVar "s")) (arm (PCon "Ok" (PVar "ts")) () (EApp (EVar "texts") (EVar "ts"))) (arm (PCon "Err" PWild) () (EListLit (EVar "s")))))
(DTypeSig false "suffix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "suffix" ((PVar "wanted") (PVar "actual")) (EApp (EApp (EVar "starts") (EApp (EVar "reverseL") (EVar "wanted"))) (EApp (EVar "reverseL") (EVar "actual"))))
(DTypeSig false "starts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "starts" ((PList) PWild) (EVar "True"))
(DFunDef false "starts" (PWild (PList)) (EVar "False"))
(DFunDef false "starts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "starts") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "paramWords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramWords" ((PVar "words")) (EMatch (EApp (EVar "reverseL") (EVar "words")) (arm (PCons (PVar "last") (PVar "earlier")) () (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "earlier"))) (EApp (EVar "isLocal") (EVar "last"))) (EApp (EVar "reverseL") (EVar "earlier")) (EVar "words"))) (arm PWild () (EVar "words"))))
(DTypeSig false "paramType" (TyFun (TyCon "LlvmParam") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramType" ((PCon "LlvmParam" (PVar "ty") PWild)) (EApp (EVar "typeWords") (EVar "ty")))
(DTypeSig false "params" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Token")))))))))
(DFunDef false "params" ((PList) PWild PWild PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated function parameter list"))) (EVar "moduleOrigin"))))
(DFunDef false "params" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth") (PVar "current") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EIf (EApp (EMethodRef "isEmpty") (EVar "current")) (EVar "acc") (EBinOp "::" (EApp (EVar "paramWords") (EApp (EVar "reverseL") (EVar "current"))) (EVar "acc")))) (EVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (EVar "depth")) (EListLit)) (EBinOp "::" (EApp (EVar "paramWords") (EApp (EVar "reverseL") (EVar "current"))) (EVar "acc"))) (EBlock (DoLet false false (PVar "delta") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "("))) (EBinOp "==" (EVar "text") (ELit (LString "[")))) (EBinOp "==" (EVar "text") (ELit (LString "{")))) (EBinOp "==" (EVar "text") (ELit (LString "<")))) (ELit (LInt 1)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "text") (ELit (LString "]")))) (EBinOp "==" (EVar "text") (ELit (LString "}")))) (EBinOp "==" (EVar "text") (ELit (LString ">")))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (EBinOp "+" (EVar "depth") (EVar "delta"))) (EBinOp "::" (EVar "text") (EVar "current"))) (EVar "acc")))))))
(DTypeSig false "functionHead" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "functionHead" ((PList) PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "function header without a name"))) (EVar "moduleOrigin"))))
(DFunDef false "functionHead" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PVar "rest"))) (PVar "before")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "params") (EVar "rest")) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ps") (PVar "after")) () (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "reverseL") (EVar "before")) (EVar "ps") (EVar "after"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionHead" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "before")) (EIf (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "define"))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "nested function header"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "functionHead") (EVar "rest")) (EBinOp "::" (EVar "text") (EVar "before")))))
(DTypeSig false "shapeDefect" (TyFun (TyCon "String") (TyFun (TyCon "Prototype") (TyFun (TyCon "SymbolOrigin") (TyCon "SymbolDefect")))))
(DFunDef false "shapeDefect" ((PVar "name") (PVar "proto") (PVar "at")) (EApp (EApp (EApp (EApp (EApp (EVar "PrototypeConflict") (EApp (EVar "errorName") (EVar "name"))) (EApp (EVar "DataProto") (ELit (LString "incompatible materialized declaration")))) (EVar "proto")) (EVar "at")) (EVar "at")))
(DTypeSig false "admitFunction" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "SymbolLinkage") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))))
(DFunDef false "admitFunction" ((PVar "name") (PVar "ret") (PVar "ps") (PVar "linkage") (PVar "expected") (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PCon "Expected" PWild (PVar "proto") (PVar "registered") (PVar "at"))) () (EMatch (EVar "proto") (arm (PCon "FuncProto" (PVar "r") (PVar "parameters") PWild) () (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "suffix") (EApp (EVar "typeWords") (EVar "r"))) (EVar "ret"))) (EBinOp "/=" (EVar "ps") (EApp (EApp (EMethodRef "map") (EVar "paramType")) (EVar "parameters")))) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at"))) (EIf (EBinOp "/=" (EVar "linkage") (EVar "registered")) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at")))))))))
(DTypeSig false "prefixTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyCon "Bool"))))
(DFunDef false "prefixTokens" ((PList) PWild) (EVar "True"))
(DFunDef false "prefixTokens" (PWild (PList)) (EVar "False"))
(DFunDef false "prefixTokens" ((PCons (PVar "word") (PVar "rest")) (PCons (PCon "Token" (PVar "found") PWild PWild) (PVar "after"))) (EBinOp "&&" (EBinOp "==" (EVar "word") (EVar "found")) (EApp (EApp (EVar "prefixTokens") (EVar "rest")) (EVar "after"))))
(DTypeSig false "dataHead" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "dataHead" ((PList) PWild) (EVar "None"))
(DFunDef false "dataHead" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "external")) (EIf (EBinOp "==" (EVar "text") (ELit (LString "external"))) (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "True")) (EIf (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "global"))) (EBinOp "==" (EVar "text") (ELit (LString "constant")))) (EApp (EVar "Some") (ETuple (EVar "external") (EVar "rest"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "text") (ELit (LString "define"))) (EBinOp "==" (EVar "text") (ELit (LString "declare")))) (EApp (EVar "isGlobal") (EVar "text"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "external")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inventory" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "inventory" ((PList) PWild (PVar "seen")) (EApp (EVar "Ok") (EVar "seen")))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "keyword") PWild PWild) (PVar "rest")) (PVar "expected") (PVar "seen")) (EIf (EBinOp "||" (EBinOp "==" (EVar "keyword") (ELit (LString "define"))) (EBinOp "==" (EVar "keyword") (ELit (LString "declare")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "functionHead") (EVar "rest")) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "name") (PVar "ret") (PVar "ps") (PVar "after")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "admitFunction") (EVar "name")) (EVar "ret")) (EVar "ps")) (EIf (EBinOp "==" (EVar "keyword") (ELit (LString "define"))) (EVar "SymbolDefined") (EVar "SymbolDeclared"))) (EVar "expected")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EVar "inventory") (EVar "after")) (EVar "expected")) (EVar "next")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PCons (PCon "Token" (PLit (LString "=")) PWild PWild) (PVar "rest"))) (PVar "expected") (PVar "seen")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EMatch (ETuple (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (EApp (EApp (EVar "dataHead") (EVar "rest")) (EVar "False"))) (arm (PTuple (PCon "Some" (PCon "Expected" PWild (PAs "proto" (PCon "DataProto" (PVar "ty"))) (PVar "linkage") (PVar "at"))) (PCon "Some" (PTuple (PVar "external") (PVar "after")))) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "prefixTokens") (EApp (EVar "typeWords") (EVar "ty"))) (EVar "after"))) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at"))) (EIf (EBinOp "/=" (EVar "external") (EBinOp "==" (EVar "linkage") (EVar "SymbolDeclared"))) (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at"))) (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "expected")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))) (arm (PTuple (PCon "Some" (PCon "Expected" PWild (PVar "proto") PWild (PVar "at"))) PWild) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "shapeDefect") (EVar "name")) (EVar "proto")) (EVar "at")))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "moduleOrigin")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons PWild (PVar "rest")) (PVar "expected") (PVar "seen")) (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "expected")) (EVar "seen")))
(DTypeSig false "gapNames" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "gapNames" ((PCon "ClosedOutput") PWild) (EVar "omEmpty"))
(DFunDef false "gapNames" ((PCon "RecordedGaps" (PVar "syms")) (PVar "reg")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "s")))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "s")) (EApp (EApp (EVar "isExcused") (EVar "s")) (EVar "reg")))) (EVar "syms")))) (EVar "omEmpty")))
(DTypeSig false "missingDeclarations" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "missingDeclarations" ((PVar "expected") (PVar "seen") (PVar "gaps")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "gaps"))) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" (PVar "sym") PWild PWild (PVar "at"))) () (EListLit (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "at")))) (arm (PCon "None") () (EListLit)))))) (EApp (EVar "omKeys") (EVar "expected"))))
(DTypeSig false "referenceDefects" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "referenceDefects" ((PVar "tokens") (PVar "seen") (PVar "gaps")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "tokens")) (EVar "seen")) (EVar "gaps")) (EListLit))))
(DTypeSig false "wholeDeclarations" (TyFun (TyCon "ModuleScope") (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "wholeDeclarations" ((PCon "ModuleHalf") PWild PWild) (EListLit))
(DFunDef false "wholeDeclarations" ((PCon "WholeModule") (PVar "entries") (PVar "gaps")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "entry")) (EMatch (EVar "entry") (arm (PCon "SymbolDeclaration" (PAs "sym" (PCon "Generated" PWild)) PWild (PCon "SymbolDeclared") (PVar "at")) () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "canonicalName") (EBinOp "++" (ELit (LString "@")) (EApp (EVar "symbolName") (EVar "sym"))))) (EVar "gaps")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "at"))))) (arm PWild () (EListLit))))) (EVar "entries")))
(DTypeSig false "referencesGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "referencesGo" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "referencesGo" ((PCons (PCon "Token" (PVar "name") PWild (PVar "at")) (PVar "rest")) (PVar "seen") (PVar "gaps") (PVar "acc")) (EIf (EBinOp "&&" (EApp (EVar "isGlobal") (EVar "name")) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "gaps"))))) (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EBinOp "::" (EApp (EApp (EVar "UndefinedReference") (EApp (EVar "errorName") (EVar "name"))) (EVar "at")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "referencesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EVar "acc"))))
(DTypeSig false "attributeOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Expected")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "attributeOrigins" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PLit (LString "define")) (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "functionHead") (EVar "rest")) (EListLit)) (arm (PCon "Ok" (PTuple (PVar "name") PWild PWild PWild)) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "moduleOrigin")))) (arm (PCon "Err" PWild) () (EVar "current")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "define"))) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "name") (PVar "covered") (PVar "origin")) (PCons (PAs "equals" (PCon "Token" (PLit (LString "=")) PWild PWild)) (PVar "rest"))) (PVar "expected") (PVar "current") (PVar "acc")) (EIf (EApp (EVar "isGlobal") (EVar "name")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "moduleOrigin")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EBinOp "::" (EVar "equals") (EVar "rest"))) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "name")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "text") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "current")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "current"))) (EVar "acc"))))
(DTypeSig true "finishCheckedText" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "String")))))))
(DFunDef false "finishCheckedText" ((PVar "policy") (PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PVar "expected")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (ETuple (EVar "reg") (EVar "expected")))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "raw") (PVar "stripped"))) () (EBlock (DoLet false false (PVar "tokens") (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "raw")) (EVar "expected")) (EVar "moduleOrigin")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "inventory") (EVar "tokens")) (EVar "expected")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PVar "seen")) () (EBlock (DoLet false false (PVar "gaps") (EApp (EApp (EVar "gapNames") (EVar "policy")) (EVar "reg"))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "coverageDefects") (EVar "tokens")) (EApp (EApp (EApp (EVar "missingDeclarations") (EVar "expected")) (EVar "seen")) (EVar "gaps"))) (EApp (EApp (EApp (EVar "referenceDefects") (EVar "tokens")) (EVar "seen")) (EVar "gaps"))) (EApp (EApp (EApp (EVar "wholeDeclarations") (EApp (EVar "registryScope") (EVar "reg"))) (EApp (EVar "declarations") (EVar "reg"))) (EVar "gaps")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (EVar "stripped")) (EApp (EVar "Err") (EVar "defects"))))))))))))))
