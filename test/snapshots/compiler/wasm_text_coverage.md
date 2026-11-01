# META
source_lines=747
stages=DESUGAR,MARK
# SOURCE
-- This audits named identities and checked descriptors. It does not reconstruct
-- the operand stack; validation and execution still judge that realization.
import backend.wasm_symbols.{
  WasmSymbol(..),
  WasmShape(..),
  SymbolRegistry,
  SymbolDefect(..),
  SymbolDeclaration(..),
  checkCall,
  declarations,
  isExcused,
  symbolName,
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}
import support.symbol_origin.{SymbolOrigin(..)}
import support.util.{joinWith, reverseL, startsWith}

-- Closed output and previously justified gaps are distinct audit obligations.
-- lint-disable-next-line rule-clone-type
public export data CoveragePolicy =
  | ClosedOutput
  | RecordedGaps (List WasmSymbol)

data Token = Token String Bool SymbolOrigin
data Receipt = Receipt {
  text : String,
  name : String,
  operands : Int,
  tailCall : Bool,
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

export
checkedCall : SymbolRegistry ->
  Bool ->
  String ->
  Int ->
  SymbolOrigin ->
  CallCoverage ->
  Result SymbolDefect (SymbolRegistry, CallCoverage, String)
checkedCall reg tailCall name operands origin (CallCoverage next entries) = do
  reg2 <- checkCall (WasmFunc name) operands origin reg
  let instruction = if tailCall then "return_call" else "call"
  let text = "\{instruction} $\{name}"
  tokens <- match rawTokens text
    Err (UncheckedText reason _) => Err (UncheckedText reason origin)
    result => result
  if callFacts tokens /= [(instruction, "$" ++ name)] then
    Err
      (UncheckedText
        "checked instruction must contain exactly one matching named call"
        origin)
  else
    let key = intToString next
    let receipt = Receipt {
      text = text,
      name = name,
      operands = operands,
      tailCall = tailCall,
      origin = origin,
      tokens = tokens,
    }
    Ok (
      reg2,
      CallCoverage (next + 1) (omInsert key receipt entries),
      "\u{1e}W\{key}:\{text}\u{1f}",
    )

byte : Array Int -> Int -> Int
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
byte bytes i =
  if i < 0 || i >= arrayLength bytes then -1 else arrayGetUnsafe i bytes

space : Int -> Bool
space c = c == 32 || c == 9 || c == 10 || c == 13

boundary : Int -> Bool
boundary c = c == -1 || space c || c == 40 || c == 41 || c == 59

wordEnd : Array Int -> Int -> Int
wordEnd bytes i =
  let c = byte bytes i
  if boundary c || c == 34 || c == 30 || c == 31 then
    i
  else
    wordEnd bytes (i + 1)

quotedEnd : Array Int -> Int -> Result SymbolDefect Int
quotedEnd bytes i = match byte bytes i
  c if c == -1 => Err (UncheckedText "unterminated string" moduleOrigin)
  34 => Ok (i + 1)
  92 =>
    if byte bytes (i + 1) == -1 then
      Err (UncheckedText "unterminated string escape" moduleOrigin)
    else
      quotedEnd bytes (i + 2)
  _ => quotedEnd bytes (i + 1)

lineEnd : Array Int -> Int -> Int
-- Target-local scanners retain independent token and receipt operations.
-- lint-disable-next-line rule-duplicate-body
lineEnd bytes i =
  let c = byte bytes i
  if c == -1 || c == 10 || c == 13 then i else lineEnd bytes (i + 1)

commentEnd : Array Int -> Int -> Int -> Result SymbolDefect Int
commentEnd bytes i depth =
  if byte bytes i == -1 then
    Err (UncheckedText "unterminated block comment" moduleOrigin)
  else if byte bytes i == 40 && byte bytes (i + 1) == 59 then
    commentEnd bytes (i + 2) (depth + 1)
  else if byte bytes i == 59 && byte bytes (i + 1) == 41 then
    if depth == 1 then Ok (i + 2) else commentEnd bytes (i + 2) (depth - 1)
  else
    commentEnd bytes (i + 1) depth

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

scan : String ->
  Array Int ->
  OrdMap Receipt ->
  Bool ->
  Option SymbolRegistry ->
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
      || byte bytes (i + 1) /= 87
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
  else if c == 59 && byte bytes (i + 1) == 59 then
    scan
      text
      bytes
      entries
      markers
      registry
      (lineEnd bytes i)
      copied
      tokens
      chunks
  else if c == 40 && byte bytes (i + 1) == 59 then do
    end <- commentEnd bytes (i + 2) 1
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
  else if c == 59 then
    Err (UncheckedText "invalid comment delimiter" moduleOrigin)
  else
    let end = if c == 40 || c == 41 then i + 1 else wordEnd bytes i
    scan
      text
      bytes
      entries
      markers
      registry
      end
      copied
      (Token (stringSliceBytes i end text) False moduleOrigin :: tokens)
      chunks

recheck : Option SymbolRegistry -> Receipt -> Result SymbolDefect Unit
recheck None _ = Ok ()
recheck (Some reg) receipt = do
  _ <- checkCall (WasmFunc receipt.name) receipt.operands receipt.origin reg
  Ok ()

named : String -> Bool
named s = startsWith "$" s

bare : String -> String
bare s = stringSlice 1 (stringLength s) s

callFacts : List Token -> List (String, String)
callFacts tokens = reverseL (callFactsGo tokens [])

callFactsGo : List Token -> List (String, String) -> List (String, String)
callFactsGo [] acc = acc
callFactsGo ((Token op _ _) :: (Token name _ _) :: rest) acc
  | (op == "call" || op == "return_call") && named name =
    callFactsGo rest ((op, name) :: acc)
callFactsGo (_ :: rest) acc = callFactsGo rest acc

type SymbolIndex a = OrdMap (OrdMap a)

symbolNamespace : WasmSymbol -> String
symbolNamespace (WasmFunc _) = "f"
symbolNamespace (WasmType _) = "t"
symbolNamespace (WasmGlobal _) = "g"
symbolNamespace (WasmData _) = "d"
symbolNamespace (WasmElem _) = "e"

symbolFrom : String -> String -> WasmSymbol
symbolFrom "f" n = WasmFunc n
symbolFrom "t" n = WasmType n
symbolFrom "g" n = WasmGlobal n
symbolFrom "d" n = WasmData n
symbolFrom _ n = WasmElem n

symbolLookup : WasmSymbol -> SymbolIndex a -> Option a
symbolLookup sym index = match omLookup (symbolNamespace sym) index
  None => None
  Some names => omLookup (symbolName sym) names

symbolHas : WasmSymbol -> SymbolIndex a -> Bool
symbolHas sym index = isSome (symbolLookup sym index)

symbolInsert : WasmSymbol -> a -> SymbolIndex a -> SymbolIndex a
symbolInsert sym value index =
  let names = optionOr omEmpty (omLookup (symbolNamespace sym) index)
  omInsert (symbolNamespace sym) (omInsert (symbolName sym) value names) index

symbolKeys : SymbolIndex a -> List WasmSymbol
symbolKeys index =
  flatMap
    (namespace => match omLookup namespace index
      None => []
      Some names => map (symbolFrom namespace) (omKeys names))
    (omKeys index)

data Expected = Expected WasmSymbol WasmShape SymbolOrigin
data Materialized = Materialized WasmSymbol WasmShape

expectedMap : List SymbolDeclaration ->
  SymbolIndex Expected ->
  SymbolIndex Expected
expectedMap [] acc = acc
expectedMap ((SymbolDeclaration sym shape at) :: rest) acc =
  expectedMap rest (symbolInsert sym (Expected sym shape at) acc)

-- Header groups stop at the first instruction. Nested reference value types
-- count as one parameter, while `$name` is a binder and contributes no slot.
paramSlots : List Token -> Int -> Int -> Result SymbolDefect (Int, List Token)
paramSlots [] _ _ =
  Err (UncheckedText "unterminated parameter group" moduleOrigin)
paramSlots ((Token text _ _) :: rest) depth count =
  if text == ")" && depth == 0 then
    Ok (count, rest)
  else if text == "(" then
    paramSlots rest (depth + 1) (if depth == 0 then count + 1 else count)
  else if text == ")" then
    paramSlots rest (depth - 1) count
  else
    paramSlots rest depth (if depth == 0 && not (named text) then
      count + 1
    else
      count)

skipGroup : List Token -> Int -> List Token
skipGroup [] _ = []
skipGroup ((Token text _ _) :: rest) depth =
  if text == ")" && depth == 0 then
    rest
  else
    skipGroup
      rest
      (depth + (if text == "(" then 1 else if text == ")" then -1 else 0))

functionShape : List Token ->
  Int ->
  Bool ->
  Option String ->
  Result SymbolDefect WasmShape
functionShape ((Token "(" _ _) :: (Token "param" _ _) :: rest) count _ typeName =
  do
    (n, after) <- paramSlots rest 0 0
    functionShape after (count + n) True typeName
functionShape ((Token "(" _ _) :: (Token "type" _ _) :: (Token name _ _) :: rest) count explicit _
  | named name =
    functionShape (skipGroup rest 0) count explicit (Some (bare name))
functionShape ((Token "(" _ _) :: (Token op _ _) :: rest) count explicit typeName
  | op == "result" || op == "local" || op == "export" || op == "import" =
    functionShape (skipGroup rest 0) count explicit typeName
functionShape _ count explicit None = Ok (FuncParams count)
functionShape _ count explicit (Some name) =
  Ok (FuncOfType name (if explicit then count else -1))

parent : List String -> String
parent [] = ""
parent (p :: _) = p

declaration : String -> String -> List String -> Option WasmSymbol
declaration "func" name context =
  if parent context == "module"
    || parent context == "import"
    || isEmpty context then
    Some (WasmFunc name)
  else
    None
declaration "type" name context =
  if parent context == "module"
    || parent context == "rec"
    || isEmpty context then
    Some (WasmType name)
  else
    None
declaration "global" name context =
  if parent context == "module"
    || parent context == "import"
    || isEmpty context then
    Some (WasmGlobal name)
  else
    None
declaration "data" name context =
  if parent context == "module" || isEmpty context then
    Some (WasmData name)
  else
    None
declaration _ _ _ = None

ordinaryShape : WasmSymbol -> WasmShape
ordinaryShape (WasmType _) = TypeDecl
ordinaryShape (WasmGlobal _) = GlobalDecl
ordinaryShape (WasmData _) = DataDecl
ordinaryShape (WasmElem _) = ElemDecl
ordinaryShape (WasmFunc _) = FuncParams 0

admit : WasmSymbol ->
  WasmShape ->
  SymbolIndex Materialized ->
  Result SymbolDefect (SymbolIndex Materialized)
admit (sym@(WasmElem _)) shape seen =
  Ok (symbolInsert sym (Materialized sym shape) seen)
admit sym shape seen =
  if symbolHas sym seen then
    Err (DuplicateDefinition sym moduleOrigin moduleOrigin)
  else
    Ok (symbolInsert sym (Materialized sym shape) seen)

inventory : List Token ->
  List String ->
  SymbolIndex Materialized ->
  OrdMap Int ->
  Result SymbolDefect (SymbolIndex Materialized, OrdMap Int)
inventory [] context seen types =
  if isEmpty context then
    Ok (seen, types)
  else
    Err (UncheckedText "unclosed expression" moduleOrigin)
inventory ((Token "(" _ _) :: (Token op _ _) :: (Token name _ _) :: rest) context seen types
  | named name = match declaration op (bare name) context
    Some (sym@(WasmFunc _)) => do
      shape <- functionShape rest 0 False None
      next <- admit sym shape seen
      inventory rest (op :: context) next types
    Some (sym@(WasmType typeName)) => do
      next <- admit sym TypeDecl seen
      match rest
        (Token "(" _ _) :: (Token "func" _ _) :: after => do
          shape <- functionShape after 0 False None
          let n = match shape
            FuncParams count => count
            FuncOfType _ count => count
            _ => 0
          inventory rest (op :: context) next (omInsert typeName n types)
        _ => inventory rest (op :: context) next types
    Some sym => do
      next <- admit sym (ordinaryShape sym) seen
      inventory rest (op :: context) next types
    None =>
      inventory
        (Token name False moduleOrigin :: rest)
        (op :: context)
        seen
        types
inventory ((Token "(" _ _) :: (Token op _ _) :: rest) context seen types =
  if op == "func"
    && (parent context == "module"
      || parent context == "import"
      || isEmpty context) then
    Err
      (UncheckedText
        "function declaration lacks a registry identity"
        moduleOrigin)
  else
    inventory rest (op :: context) seen types
inventory ((Token ")" _ _) :: rest) [] seen types =
  Err (UncheckedText "unmatched expression end" moduleOrigin)
inventory ((Token ")" _ _) :: rest) (_ :: outer) seen types =
  inventory rest outer seen types
inventory ((Token name _ _) :: rest) context seen types
  | named name && parent context == "elem" = do
    next <- admit (WasmElem (bare name)) ElemDecl seen
    inventory rest context next types
inventory (_ :: rest) context seen types = inventory rest context seen types

gapNames : CoveragePolicy -> SymbolRegistry -> SymbolIndex Unit
gapNames ClosedOutput _ = omEmpty
gapNames (RecordedGaps syms) reg = gapsGo syms reg omEmpty

gapsGo : List WasmSymbol ->
  SymbolRegistry ->
  SymbolIndex Unit ->
  SymbolIndex Unit
gapsGo [] _ acc = acc
gapsGo (sym :: rest) reg acc =
  gapsGo rest reg (if isExcused sym reg then symbolInsert sym () acc else acc)

actualCount : WasmShape -> OrdMap Int -> Int
actualCount (FuncImported n) _ = n
actualCount (FuncParams n) _ = n
actualCount (FuncOfType name n) types =
  if n >= 0 then n else optionOr -1 (omLookup name types)
actualCount _ _ = -1

sameShape : WasmShape -> WasmShape -> OrdMap Int -> Bool
sameShape (FuncImported n) actual types = n == actualCount actual types
sameShape (FuncParams n) actual types = n == actualCount actual types
sameShape (FuncOfType name n) (actual@(FuncOfType found _)) types =
  name == found && n == actualCount actual types
sameShape a b _ = a == b

declarationDefects : SymbolIndex Expected ->
  SymbolIndex Materialized ->
  OrdMap Int ->
  SymbolIndex Unit ->
  List SymbolDefect
declarationDefects expected seen types gaps =
  flatMap
      (sym => match symbolLookup sym expected
        None => []
        Some (Expected _ shape at) => match symbolLookup sym seen
          None => if symbolHas sym gaps then [] else [UndefinedReference sym at]
          Some (Materialized _ actual) =>
            if sameShape shape actual types then
              []
            else
              [
                ShapeMismatch
                  (symbolName sym)
                  (actualCount shape types)
                  (actualCount actual types)
                  at
                  at,
              ])
      (symbolKeys expected)
    ++ flatMap
      (sym =>
        if symbolHas sym expected then
          []
        else
          [UndefinedReference sym moduleOrigin])
      (symbolKeys seen)

useOf : String -> String -> List WasmSymbol
useOf "call" n = [WasmFunc n]
useOf "return_call" n = [WasmFunc n]
useOf "ref.func" n = [WasmFunc n, WasmElem n]
useOf "func" n = [WasmFunc n]
useOf "start" n = [WasmFunc n]
useOf "global.get" n = [WasmGlobal n]
useOf "global.set" n = [WasmGlobal n]
useOf "memory.init" n = [WasmData n]
useOf "data.drop" n = [WasmData n]
useOf op n =
  if op == "ref.null"
    || op == "ref.cast"
    || op == "ref.test"
    || op == "sub"
    || op == "final"
    || op == "type"
    || op == "ref"
    || op == "null"
    || op == "call_ref"
    || op == "return_call_ref"
    || startsWith "struct." op
    || startsWith "array." op then
    [WasmType n]
  else
    []

missingUse : SymbolIndex Materialized ->
  SymbolIndex Unit ->
  SymbolOrigin ->
  WasmSymbol ->
  List SymbolDefect
missingUse seen gaps at sym =
  if symbolHas sym seen || symbolHas sym gaps then
    []
  else match sym
    WasmElem name => [UndeclaredFuncRef name at]
    _ => [UndefinedReference sym at]

uses : List Token ->
  SymbolIndex Materialized ->
  SymbolIndex Unit ->
  List SymbolDefect
uses tokens seen gaps = reverseL (usesGo tokens seen gaps [])

usesGo : List Token ->
  SymbolIndex Materialized ->
  SymbolIndex Unit ->
  List SymbolDefect ->
  List SymbolDefect
usesGo [] _ _ acc = acc
usesGo ((Token op covered origin) :: rest) seen gaps acc = match rest
  [] =>
    if (op == "call" || op == "return_call") && not covered then
      UncheckedText "uncovered direct call" origin :: acc
    else
      acc
  (Token name _ _) :: after =>
    let uncovered =
      if (op == "call" || op == "return_call") && not covered then
        [UncheckedText "uncovered direct call" origin]
      else
        []
    let absent =
      if named name then
        flatMap (missingUse seen gaps origin) (useOf op (bare name))
      else
        []
    let extra = match after
      (Token second _ _) :: _ if named second
        && (op == "array.new_data" || op == "array.init_data") =>
        missingUse seen gaps origin (WasmData (bare second))
      (Token second _ _) :: _ if named second && op == "array.copy" =>
        missingUse seen gaps origin (WasmType (bare second))
      _ => []
    usesGo rest seen gaps (reverseL (uncovered ++ absent ++ extra) ++ acc)

-- Count code dependencies for manifest drift checks; comments and literals are
-- inert, and namespaces keep a global and a type with the same name distinct.
export
namedUses : String -> Result SymbolDefect (List (WasmSymbol, Int))
namedUses text = do
  tokens <- rawTokens text
  let counts = namedUseCounts tokens omEmpty
  Ok
    (map
      (sym => (sym, optionOr 0 (symbolLookup sym counts)))
      (symbolKeys counts))

namedUseCounts : List Token -> SymbolIndex Int -> SymbolIndex Int
namedUseCounts [] counts = counts
namedUseCounts ((Token op _ _) :: rest) counts = match rest
  (Token name _ _) :: after =>
    let first = if named name then useOf op (bare name) else []
    let second = match after
      (Token name2 _ _) :: _ if op == "array.copy" && named name2 =>
        [WasmType (bare name2)]
      _ => []
    namedUseCounts rest (fold countNamedUse counts (first ++ second))
  [] => counts

countNamedUse : SymbolIndex Int -> WasmSymbol -> SymbolIndex Int
countNamedUse counts (sym@(WasmType _)) =
  symbolInsert sym (optionOr 0 (symbolLookup sym counts) + 1) counts
countNamedUse counts (sym@(WasmGlobal _)) =
  symbolInsert sym (optionOr 0 (symbolLookup sym counts) + 1) counts
countNamedUse counts _ = counts

attributeOrigins : List Token ->
  SymbolIndex Expected ->
  SymbolOrigin ->
  List Token ->
  List Token
-- Origin attribution preserves each target’s nominal token type.
-- lint-disable-next-line rule-duplicate-body
attributeOrigins [] _ _ acc = reverseL acc
attributeOrigins ((Token "func" covered origin) :: (target@(Token name _ _)) :: rest) expected current acc
  | named name =
    let next = match symbolLookup (WasmFunc (bare name)) expected
      Some (Expected _ _ at) => at
      None => current
    attributeOrigins
      (target :: rest)
      expected
      next
      (Token "func" covered (if covered then origin else next) :: acc)
-- Origin attribution preserves each target’s nominal token type.
-- lint-disable-next-line rule-duplicate-body
attributeOrigins ((Token text covered origin) :: rest) expected current acc =
  attributeOrigins
    rest
    expected
    current
    (Token text covered (if covered then origin else current) :: acc)

-- Census fragments are not a module. Check their receipts and declarations,
-- but return no text and require no absent declaration or cross-fragment use.
export
checkCheckedFragment : SymbolRegistry ->
  CallCoverage ->
  String ->
  Result (List SymbolDefect) Unit
checkCheckedFragment reg (CallCoverage _ entries) text =
  match scan text (stringToUtf8Bytes text) entries True (Some reg) 0 0 [] []
    Err d => Err [d]
    Ok (tokens, _) => match inventory tokens [] omEmpty omEmpty
      Err d => Err [d]
      Ok (seen, types) =>
        let expected = expectedMap (declarations reg) omEmpty
        let defects =
          fragmentDeclarations expected seen types ++ uncovered tokens
        if isEmpty defects then Ok () else Err defects

fragmentDeclarations : SymbolIndex Expected ->
  SymbolIndex Materialized ->
  OrdMap Int ->
  List SymbolDefect
fragmentDeclarations expected seen types =
  flatMap
    (sym => match symbolLookup sym expected
      None => [UndefinedReference sym moduleOrigin]
      Some (Expected _ shape at) => match symbolLookup sym seen
        Some (Materialized _ actual) =>
          if sameShape shape actual types then
            []
          else
            [
              ShapeMismatch
                (symbolName sym)
                (actualCount shape types)
                (actualCount actual types)
                at
                at,
            ]
        None => [])
    (symbolKeys seen)

uncovered : List Token -> List SymbolDefect
uncovered tokens = reverseL (uncoveredGo tokens [])

uncoveredGo : List Token -> List SymbolDefect -> List SymbolDefect
uncoveredGo [] acc = acc
uncoveredGo ((Token op covered at) :: rest) acc =
  if (op == "call" || op == "return_call") && not covered then
    uncoveredGo rest (UncheckedText "uncovered direct call" at :: acc)
  else
    uncoveredGo rest acc

export
finishCheckedText : CoveragePolicy ->
  SymbolRegistry ->
  CallCoverage ->
  String ->
  Result (List SymbolDefect) String
finishCheckedText policy reg (CallCoverage _ entries) text =
  match scan text (stringToUtf8Bytes text) entries True (Some reg) 0 0 [] []
    Err d => Err [d]
    Ok (raw, stripped) => match inventory raw [] omEmpty omEmpty
      Err d => Err [d]
      Ok (seen, types) =>
        let expected = expectedMap (declarations reg) omEmpty
        let tokens = attributeOrigins raw expected moduleOrigin []
        let gaps = gapNames policy reg
        let elementUses =
          flatMap
            (sym => match sym
              WasmElem name => missingUse seen gaps moduleOrigin (WasmFunc name)
              _ => [])
            (symbolKeys seen)
        let defects =
          declarationDefects expected seen types gaps
            ++ uses tokens seen gaps
            ++ elementUses
        if isEmpty defects then Ok stripped else Err defects
# DESUGAR
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "WasmSymbol" true) (mem "WasmShape" true) (mem "SymbolRegistry" false) (mem "SymbolDefect" true) (mem "SymbolDeclaration" true) (mem "checkCall" false) (mem "declarations" false) (mem "isExcused" false) (mem "symbolName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "startsWith" false))))
(DData Public "CoveragePolicy" () ((variant "ClosedOutput" (ConPos)) (variant "RecordedGaps" (ConPos (TyApp (TyCon "List") (TyCon "WasmSymbol"))))) ())
(DData Private "Token" () ((variant "Token" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "SymbolOrigin")))) ())
(DData Private "Receipt" () ((variant "Receipt" (ConNamed (field "text" (TyCon "String")) (field "name" (TyCon "String")) (field "operands" (TyCon "Int")) (field "tailCall" (TyCon "Bool")) (field "origin" (TyCon "SymbolOrigin")) (field "tokens" (TyApp (TyCon "List") (TyCon "Token")))))) ())
(DData Abstract "CallCoverage" () ((variant "CallCoverage" (ConPos (TyCon "Int") (TyApp (TyCon "OrdMap") (TyCon "Receipt"))))) ())
(DTypeSig true "emptyCoverage" (TyCon "CallCoverage"))
(DFunDef false "emptyCoverage" () (EApp (EApp (EVar "CallCoverage") (ELit (LInt 0))) (EVar "omEmpty")))
(DTypeSig false "moduleOrigin" (TyCon "SymbolOrigin"))
(DFunDef false "moduleOrigin" () (EApp (EApp (EApp (EApp (EVar "SymbolOrigin") (ELit (LString "module"))) (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "checkedCall" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "CallCoverage") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "SymbolRegistry") (TyCon "CallCoverage") (TyCon "String"))))))))))
(DFunDef false "checkedCall" ((PVar "reg") (PVar "tailCall") (PVar "name") (PVar "operands") (PVar "origin") (PCon "CallCoverage" (PVar "next") (PVar "entries"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EApp (EVar "WasmFunc") (EVar "name"))) (EVar "operands")) (EVar "origin")) (EVar "reg"))) (ELam ((PVar "reg2")) (ELet false (PVar "instruction") (EIf (EVar "tailCall") (ELit (LString "return_call")) (ELit (LString "call"))) (ELet false (PVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "instruction"))) (ELit (LString " $"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EVar "andThen") (EMatch (EApp (EVar "rawTokens") (EVar "text")) (arm (PCon "Err" (PCon "UncheckedText" (PVar "reason") PWild)) () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (EVar "reason")) (EVar "origin")))) (arm (PVar "result") () (EVar "result")))) (ELam ((PVar "tokens")) (EIf (EBinOp "/=" (EApp (EVar "callFacts") (EVar "tokens")) (EListLit (ETuple (EVar "instruction") (EBinOp "++" (ELit (LString "$")) (EVar "name"))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "checked instruction must contain exactly one matching named call"))) (EVar "origin"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "intToString") (EVar "next"))) (DoLet false false (PVar "receipt") (ERecordCreate "Receipt" ((fa "text" (EVar "text")) (fa "name" (EVar "name")) (fa "operands" (EVar "operands")) (fa "tailCall" (EVar "tailCall")) (fa "origin" (EVar "origin")) (fa "tokens" (EVar "tokens"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "reg2") (EApp (EApp (EVar "CallCoverage") (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "receipt")) (EVar "entries"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\u{1e}W")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "text"))) (ELit (LString "\u{1f}")))))))))))))))
(DTypeSig false "byte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes")))) (EUnOp "-" (ELit (LInt 1))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))))
(DTypeSig false "space" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "space" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 32))) (EBinOp "==" (EVar "c") (ELit (LInt 9)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))))
(DTypeSig false "boundary" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "boundary" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 40)))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))))
(DTypeSig false "wordEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "boundary") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 30)))) (EBinOp "==" (EVar "c") (ELit (LInt 31)))) (EVar "i") (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "quotedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int")))))
(DFunDef false "quotedEnd" ((PVar "bytes") (PVar "i")) (EMatch (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (arm (PVar "c") ((GBool (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated string"))) (EVar "moduleOrigin")))) (arm (PLit (LInt 34)) () (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PLit (LInt 92)) () (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated string escape"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (arm PWild () (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "lineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))) (EVar "i") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "commentEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int"))))))
(DFunDef false "commentEnd" ((PVar "bytes") (PVar "i") (PVar "depth")) (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated block comment"))) (EVar "moduleOrigin"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 40))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 59))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 41)))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))))))
(DTypeSig false "keyEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "keyEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))))
(DTypeSig false "prependChecked" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))))
(DFunDef false "prependChecked" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChecked" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "origin") (PVar "acc")) (EApp (EApp (EApp (EVar "prependChecked") (EVar "rest")) (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "True")) (EVar "origin")) (EVar "acc"))))
(DTypeSig false "rawTokens" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "rawTokens" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "omEmpty")) (EVar "False")) (EVar "None")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "tokens") PWild) () (EApp (EVar "Ok") (EVar "tokens")))))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Receipt")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "SymbolRegistry")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyCon "String")))))))))))))
(DFunDef false "scan" ((PVar "text") (PVar "bytes") (PVar "entries") (PVar "markers") (PVar "registry") (PVar "i") (PVar "copied") (PVar "tokens") (PVar "chunks")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "tokens")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 30))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EVar "markers")) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 87)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed or nested receipt"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "endKey") (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "stringSliceBytes") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "endKey")) (EVar "text"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString ""))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "endKey")) (ELit (LInt 58)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed receipt key"))) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "entries")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unknown receipt"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PVar "receipt")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "endKey") (ELit (LInt 1)))) (DoLet false false (PVar "end") (EBinOp "+" (EVar "start") (EApp (EVar "stringByteLength") (EFieldAccess (EVar "receipt") "text")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "end")) (ELit (LInt 31)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed or unterminated receipt"))) (EFieldAccess (EVar "receipt") "origin"))) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "start")) (EVar "end")) (EVar "text")) (EFieldAccess (EVar "receipt") "text")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed receipt text"))) (EFieldAccess (EVar "receipt") "origin"))) (EMatch (EApp (EApp (EVar "recheck") (EVar "registry")) (EVar "receipt")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "prependChecked") (EFieldAccess (EVar "receipt") "tokens")) (EFieldAccess (EVar "receipt") "origin")) (EVar "tokens"))) (EBinOp "::" (EFieldAccess (EVar "receipt") "text") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))))))))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 31))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched receipt end"))) (EVar "moduleOrigin"))) (EIf (EApp (EVar "space") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EVar "i"))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 1)))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EVar "tokens")) (EVar "chunks")))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "\"\""))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "invalid comment delimiter"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "end") (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EVar "i")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text"))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))))))))))))))
(DTypeSig false "recheck" (TyFun (TyApp (TyCon "Option") (TyCon "SymbolRegistry")) (TyFun (TyCon "Receipt") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Unit")))))
(DFunDef false "recheck" ((PCon "None") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "recheck" ((PCon "Some" (PVar "reg")) (PVar "receipt")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EApp (EVar "WasmFunc") (EFieldAccess (EVar "receipt") "name"))) (EFieldAccess (EVar "receipt") "operands")) (EFieldAccess (EVar "receipt") "origin")) (EVar "reg"))) (ELam (PWild) (EApp (EVar "Ok") (ELit LUnit)))))
(DTypeSig false "named" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "named" ((PVar "s")) (EApp (EApp (EVar "startsWith") (ELit (LString "$"))) (EVar "s")))
(DTypeSig false "bare" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bare" ((PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "callFacts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "callFacts" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "callFactsGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "callFactsGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "callFactsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "callFactsGo" ((PCons (PCon "Token" (PVar "op") PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest"))) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "named") (EVar "name"))) (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EBinOp "::" (ETuple (EVar "op") (EVar "name")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "callFactsGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "acc")))
(DTypeAlias false "SymbolIndex" ("a") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyVar "a"))))
(DTypeSig false "symbolNamespace" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolNamespace" ((PCon "WasmFunc" PWild)) (ELit (LString "f")))
(DFunDef false "symbolNamespace" ((PCon "WasmType" PWild)) (ELit (LString "t")))
(DFunDef false "symbolNamespace" ((PCon "WasmGlobal" PWild)) (ELit (LString "g")))
(DFunDef false "symbolNamespace" ((PCon "WasmData" PWild)) (ELit (LString "d")))
(DFunDef false "symbolNamespace" ((PCon "WasmElem" PWild)) (ELit (LString "e")))
(DTypeSig false "symbolFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "WasmSymbol"))))
(DFunDef false "symbolFrom" ((PLit (LString "f")) (PVar "n")) (EApp (EVar "WasmFunc") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "t")) (PVar "n")) (EApp (EVar "WasmType") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "g")) (PVar "n")) (EApp (EVar "WasmGlobal") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "d")) (PVar "n")) (EApp (EVar "WasmData") (EVar "n")))
(DFunDef false "symbolFrom" (PWild (PVar "n")) (EApp (EVar "WasmElem") (EVar "n")))
(DTypeSig false "symbolLookup" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "symbolLookup" ((PVar "sym") (PVar "index")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EVar "index")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "names")))))
(DTypeSig false "symbolHas" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "symbolHas" ((PVar "sym") (PVar "index")) (EApp (EVar "isSome") (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "index"))))
(DTypeSig false "symbolInsert" (TyFun (TyCon "WasmSymbol") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "SymbolIndex") (TyVar "a"))))))
(DFunDef false "symbolInsert" ((PVar "sym") (PVar "value") (PVar "index")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EVar "index")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "value")) (EVar "names"))) (EVar "index")))))
(DTypeSig false "symbolKeys" (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "List") (TyCon "WasmSymbol"))))
(DFunDef false "symbolKeys" ((PVar "index")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "namespace")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "namespace")) (EVar "index")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "map") (EApp (EVar "symbolFrom") (EVar "namespace"))) (EApp (EVar "omKeys") (EVar "names"))))))) (EApp (EVar "omKeys") (EVar "index"))))
(DData Private "Expected" () ((variant "Expected" (ConPos (TyCon "WasmSymbol") (TyCon "WasmShape") (TyCon "SymbolOrigin")))) ())
(DData Private "Materialized" () ((variant "Materialized" (ConPos (TyCon "WasmSymbol") (TyCon "WasmShape")))) ())
(DTypeSig false "expectedMap" (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyApp (TyCon "SymbolIndex") (TyCon "Expected")))))
(DFunDef false "expectedMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "expectedMap" ((PCons (PCon "SymbolDeclaration" (PVar "sym") (PVar "shape") (PVar "at")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "expectedMap") (EVar "rest")) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EApp (EVar "Expected") (EVar "sym")) (EVar "shape")) (EVar "at"))) (EVar "acc"))))
(DTypeSig false "paramSlots" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "paramSlots" ((PList) PWild PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated parameter group"))) (EVar "moduleOrigin"))))
(DFunDef false "paramSlots" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth") (PVar "count")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Ok") (ETuple (EVar "count") (EVar "rest"))) (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EVar "count"))) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "count")) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EVar "depth")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "named") (EVar "text")))) (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EVar "count")))))))
(DTypeSig false "skipGroup" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "skipGroup" ((PList) PWild) (EListLit))
(DFunDef false "skipGroup" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "rest") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (EBinOp "+" (EVar "depth") (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (ELit (LInt 1)) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0))))))))
(DTypeSig false "functionShape" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "WasmShape")))))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "param")) PWild PWild) (PVar "rest"))) (PVar "count") PWild (PVar "typeName")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "n") (PVar "after")) () (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "after")) (EBinOp "+" (EVar "count") (EVar "n"))) (EVar "True")) (EVar "typeName")))))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "type")) PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")))) (PVar "count") (PVar "explicit") PWild) (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "functionShape") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (ELit (LInt 0)))) (EVar "count")) (EVar "explicit")) (EApp (EVar "Some") (EApp (EVar "bare") (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest"))) (PVar "count") (PVar "explicit") (PVar "typeName")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "result"))) (EBinOp "==" (EVar "op") (ELit (LString "local")))) (EBinOp "==" (EVar "op") (ELit (LString "export")))) (EBinOp "==" (EVar "op") (ELit (LString "import")))) (EApp (EApp (EApp (EApp (EVar "functionShape") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (ELit (LInt 0)))) (EVar "count")) (EVar "explicit")) (EVar "typeName")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionShape" (PWild (PVar "count") (PVar "explicit") (PCon "None")) (EApp (EVar "Ok") (EApp (EVar "FuncParams") (EVar "count"))))
(DFunDef false "functionShape" (PWild (PVar "count") (PVar "explicit") (PCon "Some" (PVar "name"))) (EApp (EVar "Ok") (EApp (EApp (EVar "FuncOfType") (EVar "name")) (EIf (EVar "explicit") (EVar "count") (EUnOp "-" (ELit (LInt 1)))))))
(DTypeSig false "parent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "parent" ((PList)) (ELit (LString "")))
(DFunDef false "parent" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "declaration" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "WasmSymbol"))))))
(DFunDef false "declaration" ((PLit (LString "func")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EVar "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmFunc") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "type")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "rec")))) (EApp (EVar "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmType") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "global")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EVar "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmGlobal") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "data")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EApp (EVar "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmData") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ordinaryShape" (TyFun (TyCon "WasmSymbol") (TyCon "WasmShape")))
(DFunDef false "ordinaryShape" ((PCon "WasmType" PWild)) (EVar "TypeDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmGlobal" PWild)) (EVar "GlobalDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmData" PWild)) (EVar "DataDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmElem" PWild)) (EVar "ElemDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmFunc" PWild)) (EApp (EVar "FuncParams") (ELit (LInt 0))))
(DTypeSig false "admit" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")))))))
(DFunDef false "admit" ((PAs "sym" (PCon "WasmElem" PWild)) (PVar "shape") (PVar "seen")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EVar "Materialized") (EVar "sym")) (EVar "shape"))) (EVar "seen"))))
(DFunDef false "admit" ((PVar "sym") (PVar "shape") (PVar "seen")) (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "sym")) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EVar "Materialized") (EVar "sym")) (EVar "shape"))) (EVar "seen")))))
(DTypeSig false "inventory" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))))))
(DFunDef false "inventory" ((PList) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EApp (EVar "isEmpty") (EVar "context")) (EApp (EVar "Ok") (ETuple (EVar "seen") (EVar "types"))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unclosed expression"))) (EVar "moduleOrigin")))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")))) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EApp (EVar "named") (EVar "name")) (EMatch (EApp (EApp (EApp (EVar "declaration") (EVar "op")) (EApp (EVar "bare") (EVar "name"))) (EVar "context")) (arm (PCon "Some" (PAs "sym" (PCon "WasmFunc" PWild))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "rest")) (ELit (LInt 0))) (EVar "False")) (EVar "None"))) (ELam ((PVar "shape")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))))) (arm (PCon "Some" (PAs "sym" (PCon "WasmType" (PVar "typeName")))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "TypeDecl")) (EVar "seen"))) (ELam ((PVar "next")) (EMatch (EVar "rest") (arm (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "func")) PWild PWild) (PVar "after"))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "after")) (ELit (LInt 0))) (EVar "False")) (EVar "None"))) (ELam ((PVar "shape")) (ELet false (PVar "n") (EMatch (EVar "shape") (arm (PCon "FuncParams" (PVar "count")) () (EVar "count")) (arm (PCon "FuncOfType" PWild (PVar "count")) () (EVar "count")) (arm PWild () (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EApp (EApp (EApp (EVar "omInsert") (EVar "typeName")) (EVar "n")) (EVar "types"))))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))))) (arm (PCon "Some" (PVar "sym")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EApp (EVar "ordinaryShape") (EVar "sym"))) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inventory") (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "name")) (EVar "False")) (EVar "moduleOrigin")) (EVar "rest"))) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "seen")) (EVar "types")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest"))) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "func"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EVar "isEmpty") (EVar "context")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "function declaration lacks a registry identity"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "seen")) (EVar "types"))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString ")")) PWild PWild) (PVar "rest")) (PList) (PVar "seen") (PVar "types")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched expression end"))) (EVar "moduleOrigin"))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString ")")) PWild PWild) (PVar "rest")) (PCons PWild (PVar "outer")) (PVar "seen") (PVar "types")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "outer")) (EVar "seen")) (EVar "types")))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EBinOp "&&" (EApp (EVar "named") (EVar "name")) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "elem")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "admit") (EApp (EVar "WasmElem") (EApp (EVar "bare") (EVar "name")))) (EVar "ElemDecl")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "context")) (EVar "next")) (EVar "types")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons PWild (PVar "rest")) (PVar "context") (PVar "seen") (PVar "types")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "context")) (EVar "seen")) (EVar "types")))
(DTypeSig false "gapNames" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "SymbolIndex") (TyCon "Unit")))))
(DFunDef false "gapNames" ((PCon "ClosedOutput") PWild) (EVar "omEmpty"))
(DFunDef false "gapNames" ((PCon "RecordedGaps" (PVar "syms")) (PVar "reg")) (EApp (EApp (EApp (EVar "gapsGo") (EVar "syms")) (EVar "reg")) (EVar "omEmpty")))
(DTypeSig false "gapsGo" (TyFun (TyApp (TyCon "List") (TyCon "WasmSymbol")) (TyFun (TyCon "SymbolRegistry") (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "SymbolIndex") (TyCon "Unit"))))))
(DFunDef false "gapsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "gapsGo" ((PCons (PVar "sym") (PVar "rest")) (PVar "reg") (PVar "acc")) (EApp (EApp (EApp (EVar "gapsGo") (EVar "rest")) (EVar "reg")) (EIf (EApp (EApp (EVar "isExcused") (EVar "sym")) (EVar "reg")) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (ELit LUnit)) (EVar "acc")) (EVar "acc"))))
(DTypeSig false "actualCount" (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "actualCount" ((PCon "FuncImported" (PVar "n")) PWild) (EVar "n"))
(DFunDef false "actualCount" ((PCon "FuncParams" (PVar "n")) PWild) (EVar "n"))
(DFunDef false "actualCount" ((PCon "FuncOfType" (PVar "name") (PVar "n")) (PVar "types")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EVar "n") (EApp (EApp (EVar "optionOr") (ELit (LInt -1))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "types")))))
(DFunDef false "actualCount" (PWild PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "sameShape" (TyFun (TyCon "WasmShape") (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Bool")))))
(DFunDef false "sameShape" ((PCon "FuncImported" (PVar "n")) (PVar "actual") (PVar "types")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))))
(DFunDef false "sameShape" ((PCon "FuncParams" (PVar "n")) (PVar "actual") (PVar "types")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))))
(DFunDef false "sameShape" ((PCon "FuncOfType" (PVar "name") (PVar "n")) (PAs "actual" (PCon "FuncOfType" (PVar "found") PWild)) (PVar "types")) (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "found")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types")))))
(DFunDef false "sameShape" ((PVar "a") (PVar "b") PWild) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "declarationDefects" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "declarationDefects" ((PVar "expected") (PVar "seen") (PVar "types") (PVar "gaps")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "sym")) (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "expected")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "Expected" PWild (PVar "shape") (PVar "at"))) () (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "gaps")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at"))))) (arm (PCon "Some" (PCon "Materialized" PWild (PVar "actual"))) () (EIf (EApp (EApp (EApp (EVar "sameShape") (EVar "shape")) (EVar "actual")) (EVar "types")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EApp (EApp (EVar "actualCount") (EVar "shape")) (EVar "types"))) (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))) (EVar "at")) (EVar "at")))))))))) (EApp (EVar "symbolKeys") (EVar "expected"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "sym")) (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "expected")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "moduleOrigin")))))) (EApp (EVar "symbolKeys") (EVar "seen")))))
(DTypeSig false "useOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmSymbol")))))
(DFunDef false "useOf" ((PLit (LString "call")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "return_call")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "ref.func")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n")) (EApp (EVar "WasmElem") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "func")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "start")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "global.get")) (PVar "n")) (EListLit (EApp (EVar "WasmGlobal") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "global.set")) (PVar "n")) (EListLit (EApp (EVar "WasmGlobal") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "memory.init")) (PVar "n")) (EListLit (EApp (EVar "WasmData") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "data.drop")) (PVar "n")) (EListLit (EApp (EVar "WasmData") (EVar "n"))))
(DFunDef false "useOf" ((PVar "op") (PVar "n")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "ref.null"))) (EBinOp "==" (EVar "op") (ELit (LString "ref.cast")))) (EBinOp "==" (EVar "op") (ELit (LString "ref.test")))) (EBinOp "==" (EVar "op") (ELit (LString "sub")))) (EBinOp "==" (EVar "op") (ELit (LString "final")))) (EBinOp "==" (EVar "op") (ELit (LString "type")))) (EBinOp "==" (EVar "op") (ELit (LString "ref")))) (EBinOp "==" (EVar "op") (ELit (LString "null")))) (EBinOp "==" (EVar "op") (ELit (LString "call_ref")))) (EBinOp "==" (EVar "op") (ELit (LString "return_call_ref")))) (EApp (EApp (EVar "startsWith") (ELit (LString "struct."))) (EVar "op"))) (EApp (EApp (EVar "startsWith") (ELit (LString "array."))) (EVar "op"))) (EListLit (EApp (EVar "WasmType") (EVar "n"))) (EListLit)))
(DTypeSig false "missingUse" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "WasmSymbol") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "missingUse" ((PVar "seen") (PVar "gaps") (PVar "at") (PVar "sym")) (EIf (EBinOp "||" (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "seen")) (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "gaps"))) (EListLit) (EMatch (EVar "sym") (arm (PCon "WasmElem" (PVar "name")) () (EListLit (EApp (EApp (EVar "UndeclaredFuncRef") (EVar "name")) (EVar "at")))) (arm PWild () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at")))))))
(DTypeSig false "uses" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "uses" ((PVar "tokens") (PVar "seen") (PVar "gaps")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "usesGo") (EVar "tokens")) (EVar "seen")) (EVar "gaps")) (EListLit))))
(DTypeSig false "usesGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "usesGo" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "usesGo" ((PCons (PCon "Token" (PVar "op") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "seen") (PVar "gaps") (PVar "acc")) (EMatch (EVar "rest") (arm (PList) () (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "origin")) (EVar "acc")) (EVar "acc"))) (arm (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "after")) () (EBlock (DoLet false false (PVar "uncovered") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EListLit (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "origin"))) (EListLit))) (DoLet false false (PVar "absent") (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin"))) (EApp (EApp (EVar "useOf") (EVar "op")) (EApp (EVar "bare") (EVar "name")))) (EListLit))) (DoLet false false (PVar "extra") (EMatch (EVar "after") (arm (PCons (PCon "Token" (PVar "second") PWild PWild) PWild) ((GBool (EBinOp "&&" (EApp (EVar "named") (EVar "second")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "array.new_data"))) (EBinOp "==" (EVar "op") (ELit (LString "array.init_data"))))))) (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin")) (EApp (EVar "WasmData") (EApp (EVar "bare") (EVar "second"))))) (arm (PCons (PCon "Token" (PVar "second") PWild PWild) PWild) ((GBool (EBinOp "&&" (EApp (EVar "named") (EVar "second")) (EBinOp "==" (EVar "op") (ELit (LString "array.copy")))))) (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin")) (EApp (EVar "WasmType") (EApp (EVar "bare") (EVar "second"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "usesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EBinOp "++" (EApp (EVar "reverseL") (EBinOp "++" (EBinOp "++" (EVar "uncovered") (EVar "absent")) (EVar "extra"))) (EVar "acc"))))))))
(DTypeSig true "namedUses" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyTuple (TyCon "WasmSymbol") (TyCon "Int"))))))
(DFunDef false "namedUses" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "rawTokens") (EVar "text"))) (ELam ((PVar "tokens")) (ELet false (PVar "counts") (EApp (EApp (EVar "namedUseCounts") (EVar "tokens")) (EVar "omEmpty")) (EApp (EVar "Ok") (EApp (EApp (EVar "map") (ELam ((PVar "sym")) (ETuple (EVar "sym") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts")))))) (EApp (EVar "symbolKeys") (EVar "counts"))))))))
(DTypeSig false "namedUseCounts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Int")) (TyApp (TyCon "SymbolIndex") (TyCon "Int")))))
(DFunDef false "namedUseCounts" ((PList) (PVar "counts")) (EVar "counts"))
(DFunDef false "namedUseCounts" ((PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest")) (PVar "counts")) (EMatch (EVar "rest") (arm (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "after")) () (EBlock (DoLet false false (PVar "first") (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EVar "useOf") (EVar "op")) (EApp (EVar "bare") (EVar "name"))) (EListLit))) (DoLet false false (PVar "second") (EMatch (EVar "after") (arm (PCons (PCon "Token" (PVar "name2") PWild PWild) PWild) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "array.copy"))) (EApp (EVar "named") (EVar "name2"))))) (EListLit (EApp (EVar "WasmType") (EApp (EVar "bare") (EVar "name2"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "namedUseCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "fold") (EVar "countNamedUse")) (EVar "counts")) (EBinOp "++" (EVar "first") (EVar "second"))))))) (arm (PList) () (EVar "counts"))))
(DTypeSig false "countNamedUse" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Int")) (TyFun (TyCon "WasmSymbol") (TyApp (TyCon "SymbolIndex") (TyCon "Int")))))
(DFunDef false "countNamedUse" ((PVar "counts") (PAs "sym" (PCon "WasmType" PWild))) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EBinOp "+" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts"))) (ELit (LInt 1)))) (EVar "counts")))
(DFunDef false "countNamedUse" ((PVar "counts") (PAs "sym" (PCon "WasmGlobal" PWild))) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EBinOp "+" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts"))) (ELit (LInt 1)))) (EVar "counts")))
(DFunDef false "countNamedUse" ((PVar "counts") PWild) (EVar "counts"))
(DTypeSig false "attributeOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "attributeOrigins" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PLit (LString "func")) (PVar "covered") (PVar "origin")) (PCons (PAs "target" (PCon "Token" (PVar "name") PWild PWild)) (PVar "rest"))) (PVar "expected") (PVar "current") (PVar "acc")) (EIf (EApp (EVar "named") (EVar "name")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "symbolLookup") (EApp (EVar "WasmFunc") (EApp (EVar "bare") (EVar "name")))) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "current")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EBinOp "::" (EVar "target") (EVar "rest"))) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "func"))) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "text") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "current")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "current"))) (EVar "acc"))))
(DTypeSig true "checkCheckedFragment" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "Unit"))))))
(DFunDef false "checkCheckedFragment" ((PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (EVar "reg"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "tokens") PWild)) () (EMatch (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "tokens")) (EListLit)) (EVar "omEmpty")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "seen") (PVar "types"))) () (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty"))) (DoLet false false (PVar "defects") (EBinOp "++" (EApp (EApp (EApp (EVar "fragmentDeclarations") (EVar "expected")) (EVar "seen")) (EVar "types")) (EApp (EVar "uncovered") (EVar "tokens")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "defects"))))))))))
(DTypeSig false "fragmentDeclarations" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "fragmentDeclarations" ((PVar "expected") (PVar "seen") (PVar "types")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "sym")) (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "expected")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "moduleOrigin")))) (arm (PCon "Some" (PCon "Expected" PWild (PVar "shape") (PVar "at"))) () (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "Some" (PCon "Materialized" PWild (PVar "actual"))) () (EIf (EApp (EApp (EApp (EVar "sameShape") (EVar "shape")) (EVar "actual")) (EVar "types")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EApp (EApp (EVar "actualCount") (EVar "shape")) (EVar "types"))) (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))) (EVar "at")) (EVar "at"))))) (arm (PCon "None") () (EListLit))))))) (EApp (EVar "symbolKeys") (EVar "seen"))))
(DTypeSig false "uncovered" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "uncovered" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "uncoveredGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "uncoveredGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "uncoveredGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "uncoveredGo" ((PCons (PCon "Token" (PVar "op") (PVar "covered") (PVar "at")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EApp (EApp (EVar "uncoveredGo") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "at")) (EVar "acc"))) (EApp (EApp (EVar "uncoveredGo") (EVar "rest")) (EVar "acc"))))
(DTypeSig true "finishCheckedText" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "String")))))))
(DFunDef false "finishCheckedText" ((PVar "policy") (PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (EVar "reg"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "raw") (PVar "stripped"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "raw")) (EListLit)) (EVar "omEmpty")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "seen") (PVar "types"))) () (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty"))) (DoLet false false (PVar "tokens") (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "raw")) (EVar "expected")) (EVar "moduleOrigin")) (EListLit))) (DoLet false false (PVar "gaps") (EApp (EApp (EVar "gapNames") (EVar "policy")) (EVar "reg"))) (DoLet false false (PVar "elementUses") (EApp (EApp (EVar "flatMap") (ELam ((PVar "sym")) (EMatch (EVar "sym") (arm (PCon "WasmElem" (PVar "name")) () (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "moduleOrigin")) (EApp (EVar "WasmFunc") (EVar "name")))) (arm PWild () (EListLit))))) (EApp (EVar "symbolKeys") (EVar "seen")))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "declarationDefects") (EVar "expected")) (EVar "seen")) (EVar "types")) (EVar "gaps")) (EApp (EApp (EApp (EVar "uses") (EVar "tokens")) (EVar "seen")) (EVar "gaps"))) (EVar "elementUses"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (EVar "stripped")) (EApp (EVar "Err") (EVar "defects"))))))))))
# MARK
(DUse false (UseGroup ("backend" "wasm_symbols") ((mem "WasmSymbol" true) (mem "WasmShape" true) (mem "SymbolRegistry" false) (mem "SymbolDefect" true) (mem "SymbolDeclaration" true) (mem "checkCall" false) (mem "declarations" false) (mem "isExcused" false) (mem "symbolName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "symbol_origin") ((mem "SymbolOrigin" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "startsWith" false))))
(DData Public "CoveragePolicy" () ((variant "ClosedOutput" (ConPos)) (variant "RecordedGaps" (ConPos (TyApp (TyCon "List") (TyCon "WasmSymbol"))))) ())
(DData Private "Token" () ((variant "Token" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "SymbolOrigin")))) ())
(DData Private "Receipt" () ((variant "Receipt" (ConNamed (field "text" (TyCon "String")) (field "name" (TyCon "String")) (field "operands" (TyCon "Int")) (field "tailCall" (TyCon "Bool")) (field "origin" (TyCon "SymbolOrigin")) (field "tokens" (TyApp (TyCon "List") (TyCon "Token")))))) ())
(DData Abstract "CallCoverage" () ((variant "CallCoverage" (ConPos (TyCon "Int") (TyApp (TyCon "OrdMap") (TyCon "Receipt"))))) ())
(DTypeSig true "emptyCoverage" (TyCon "CallCoverage"))
(DFunDef false "emptyCoverage" () (EApp (EApp (EVar "CallCoverage") (ELit (LInt 0))) (EVar "omEmpty")))
(DTypeSig false "moduleOrigin" (TyCon "SymbolOrigin"))
(DFunDef false "moduleOrigin" () (EApp (EApp (EApp (EApp (EVar "SymbolOrigin") (ELit (LString "module"))) (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "checkedCall" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "CallCoverage") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "SymbolRegistry") (TyCon "CallCoverage") (TyCon "String"))))))))))
(DFunDef false "checkedCall" ((PVar "reg") (PVar "tailCall") (PVar "name") (PVar "operands") (PVar "origin") (PCon "CallCoverage" (PVar "next") (PVar "entries"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EApp (EVar "WasmFunc") (EVar "name"))) (EVar "operands")) (EVar "origin")) (EVar "reg"))) (ELam ((PVar "reg2")) (ELet false (PVar "instruction") (EIf (EVar "tailCall") (ELit (LString "return_call")) (ELit (LString "call"))) (ELet false (PVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "instruction"))) (ELit (LString " $"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EVar "rawTokens") (EVar "text")) (arm (PCon "Err" (PCon "UncheckedText" (PVar "reason") PWild)) () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (EVar "reason")) (EVar "origin")))) (arm (PVar "result") () (EVar "result")))) (ELam ((PVar "tokens")) (EIf (EBinOp "/=" (EApp (EVar "callFacts") (EVar "tokens")) (EListLit (ETuple (EVar "instruction") (EBinOp "++" (ELit (LString "$")) (EVar "name"))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "checked instruction must contain exactly one matching named call"))) (EVar "origin"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "intToString") (EVar "next"))) (DoLet false false (PVar "receipt") (ERecordCreate "Receipt" ((fa "text" (EVar "text")) (fa "name" (EVar "name")) (fa "operands" (EVar "operands")) (fa "tailCall" (EVar "tailCall")) (fa "origin" (EVar "origin")) (fa "tokens" (EVar "tokens"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "reg2") (EApp (EApp (EVar "CallCoverage") (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "receipt")) (EVar "entries"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\u{1e}W")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "\u{1f}")))))))))))))))
(DTypeSig false "byte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "bytes") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes")))) (EUnOp "-" (ELit (LInt 1))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bytes"))))
(DTypeSig false "space" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "space" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 32))) (EBinOp "==" (EVar "c") (ELit (LInt 9)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))))
(DTypeSig false "boundary" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "boundary" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "space") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LInt 40)))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "==" (EVar "c") (ELit (LInt 59)))))
(DTypeSig false "wordEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "boundary") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LInt 34)))) (EBinOp "==" (EVar "c") (ELit (LInt 30)))) (EBinOp "==" (EVar "c") (ELit (LInt 31)))) (EVar "i") (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "quotedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int")))))
(DFunDef false "quotedEnd" ((PVar "bytes") (PVar "i")) (EMatch (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (arm (PVar "c") ((GBool (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated string"))) (EVar "moduleOrigin")))) (arm (PLit (LInt 34)) () (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PLit (LInt 92)) () (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated string escape"))) (EVar "moduleOrigin"))) (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (arm PWild () (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "lineEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EBinOp "==" (EVar "c") (ELit (LInt 10)))) (EBinOp "==" (EVar "c") (ELit (LInt 13)))) (EVar "i") (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "commentEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Int"))))))
(DFunDef false "commentEnd" ((PVar "bytes") (PVar "i") (PVar "depth")) (EIf (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated block comment"))) (EVar "moduleOrigin"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 40))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i")) (ELit (LInt 59))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 41)))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EApp (EVar "Ok") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))))))
(DTypeSig false "keyEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "keyEnd" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 48))) (EBinOp "<=" (EVar "c") (ELit (LInt 57)))) (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))))
(DTypeSig false "prependChecked" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token"))))))
(DFunDef false "prependChecked" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChecked" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "origin") (PVar "acc")) (EApp (EApp (EApp (EVar "prependChecked") (EVar "rest")) (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "True")) (EVar "origin")) (EVar "acc"))))
(DTypeSig false "rawTokens" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "rawTokens" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "omEmpty")) (EVar "False")) (EVar "None")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "tokens") PWild) () (EApp (EVar "Ok") (EVar "tokens")))))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Receipt")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "SymbolRegistry")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "List") (TyCon "Token")) (TyCon "String")))))))))))))
(DFunDef false "scan" ((PVar "text") (PVar "bytes") (PVar "entries") (PVar "markers") (PVar "registry") (PVar "i") (PVar "copied") (PVar "tokens") (PVar "chunks")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "tokens")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 30))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EVar "markers")) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 87)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed or nested receipt"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "endKey") (EApp (EApp (EVar "keyEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "stringSliceBytes") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "endKey")) (EVar "text"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString ""))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "endKey")) (ELit (LInt 58)))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "malformed receipt key"))) (EVar "moduleOrigin"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "entries")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unknown receipt"))) (EVar "moduleOrigin")))) (arm (PCon "Some" (PVar "receipt")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "endKey") (ELit (LInt 1)))) (DoLet false false (PVar "end") (EBinOp "+" (EVar "start") (EApp (EVar "stringByteLength") (EFieldAccess (EVar "receipt") "text")))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "end") (EApp (EVar "arrayLength") (EVar "bytes"))) (EBinOp "/=" (EApp (EApp (EVar "byte") (EVar "bytes")) (EVar "end")) (ELit (LInt 31)))) (EApp (EVar "not") (EApp (EVar "boundary") (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed or unterminated receipt"))) (EFieldAccess (EVar "receipt") "origin"))) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "start")) (EVar "end")) (EVar "text")) (EFieldAccess (EVar "receipt") "text")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "changed receipt text"))) (EFieldAccess (EVar "receipt") "origin"))) (EMatch (EApp (EApp (EVar "recheck") (EVar "registry")) (EVar "receipt")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EVar "d"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EBinOp "+" (EVar "end") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "prependChecked") (EFieldAccess (EVar "receipt") "tokens")) (EFieldAccess (EVar "receipt") "origin")) (EVar "tokens"))) (EBinOp "::" (EFieldAccess (EVar "receipt") "text") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "copied")) (EVar "i")) (EVar "text")) (EVar "chunks")))))))))))))))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 31))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched receipt end"))) (EVar "moduleOrigin"))) (EIf (EApp (EVar "space") (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EApp (EApp (EVar "lineEnd") (EVar "bytes")) (EVar "i"))) (EVar "copied")) (EVar "tokens")) (EVar "chunks")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EApp (EApp (EVar "byte") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 59)))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "commentEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 1)))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EVar "tokens")) (EVar "chunks")))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 34))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "quotedEnd") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "end")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "\"\""))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))) (EIf (EBinOp "==" (EVar "c") (ELit (LInt 59))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "invalid comment delimiter"))) (EVar "moduleOrigin"))) (EBlock (DoLet false false (PVar "end") (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LInt 40))) (EBinOp "==" (EVar "c") (ELit (LInt 41)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EVar "wordEnd") (EVar "bytes")) (EVar "i")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EVar "bytes")) (EVar "entries")) (EVar "markers")) (EVar "registry")) (EVar "end")) (EVar "copied")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "i")) (EVar "end")) (EVar "text"))) (EVar "False")) (EVar "moduleOrigin")) (EVar "tokens"))) (EVar "chunks")))))))))))))))
(DTypeSig false "recheck" (TyFun (TyApp (TyCon "Option") (TyCon "SymbolRegistry")) (TyFun (TyCon "Receipt") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "Unit")))))
(DFunDef false "recheck" ((PCon "None") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "recheck" ((PCon "Some" (PVar "reg")) (PVar "receipt")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "checkCall") (EApp (EVar "WasmFunc") (EFieldAccess (EVar "receipt") "name"))) (EFieldAccess (EVar "receipt") "operands")) (EFieldAccess (EVar "receipt") "origin")) (EVar "reg"))) (ELam (PWild) (EApp (EVar "Ok") (ELit LUnit)))))
(DTypeSig false "named" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "named" ((PVar "s")) (EApp (EApp (EVar "startsWith") (ELit (LString "$"))) (EVar "s")))
(DTypeSig false "bare" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bare" ((PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "callFacts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "callFacts" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "callFactsGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "callFactsGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "callFactsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "callFactsGo" ((PCons (PCon "Token" (PVar "op") PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest"))) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "named") (EVar "name"))) (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EBinOp "::" (ETuple (EVar "op") (EVar "name")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "callFactsGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "callFactsGo") (EVar "rest")) (EVar "acc")))
(DTypeAlias false "SymbolIndex" ("a") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyVar "a"))))
(DTypeSig false "symbolNamespace" (TyFun (TyCon "WasmSymbol") (TyCon "String")))
(DFunDef false "symbolNamespace" ((PCon "WasmFunc" PWild)) (ELit (LString "f")))
(DFunDef false "symbolNamespace" ((PCon "WasmType" PWild)) (ELit (LString "t")))
(DFunDef false "symbolNamespace" ((PCon "WasmGlobal" PWild)) (ELit (LString "g")))
(DFunDef false "symbolNamespace" ((PCon "WasmData" PWild)) (ELit (LString "d")))
(DFunDef false "symbolNamespace" ((PCon "WasmElem" PWild)) (ELit (LString "e")))
(DTypeSig false "symbolFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "WasmSymbol"))))
(DFunDef false "symbolFrom" ((PLit (LString "f")) (PVar "n")) (EApp (EVar "WasmFunc") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "t")) (PVar "n")) (EApp (EVar "WasmType") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "g")) (PVar "n")) (EApp (EVar "WasmGlobal") (EVar "n")))
(DFunDef false "symbolFrom" ((PLit (LString "d")) (PVar "n")) (EApp (EVar "WasmData") (EVar "n")))
(DFunDef false "symbolFrom" (PWild (PVar "n")) (EApp (EVar "WasmElem") (EVar "n")))
(DTypeSig false "symbolLookup" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "symbolLookup" ((PVar "sym") (PVar "index")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EMethodRef "index")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "names")))))
(DTypeSig false "symbolHas" (TyFun (TyCon "WasmSymbol") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "symbolHas" ((PVar "sym") (PVar "index")) (EApp (EVar "isSome") (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EMethodRef "index"))))
(DTypeSig false "symbolInsert" (TyFun (TyCon "WasmSymbol") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "SymbolIndex") (TyVar "a"))))))
(DFunDef false "symbolInsert" ((PVar "sym") (PVar "value") (PVar "index")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EMethodRef "index")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolNamespace") (EVar "sym"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "symbolName") (EVar "sym"))) (EVar "value")) (EVar "names"))) (EMethodRef "index")))))
(DTypeSig false "symbolKeys" (TyFun (TyApp (TyCon "SymbolIndex") (TyVar "a")) (TyApp (TyCon "List") (TyCon "WasmSymbol"))))
(DFunDef false "symbolKeys" ((PVar "index")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "namespace")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "namespace")) (EMethodRef "index")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EMethodRef "map") (EApp (EVar "symbolFrom") (EVar "namespace"))) (EApp (EVar "omKeys") (EVar "names"))))))) (EApp (EVar "omKeys") (EMethodRef "index"))))
(DData Private "Expected" () ((variant "Expected" (ConPos (TyCon "WasmSymbol") (TyCon "WasmShape") (TyCon "SymbolOrigin")))) ())
(DData Private "Materialized" () ((variant "Materialized" (ConPos (TyCon "WasmSymbol") (TyCon "WasmShape")))) ())
(DTypeSig false "expectedMap" (TyFun (TyApp (TyCon "List") (TyCon "SymbolDeclaration")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyApp (TyCon "SymbolIndex") (TyCon "Expected")))))
(DFunDef false "expectedMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "expectedMap" ((PCons (PCon "SymbolDeclaration" (PVar "sym") (PVar "shape") (PVar "at")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "expectedMap") (EVar "rest")) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EApp (EVar "Expected") (EVar "sym")) (EVar "shape")) (EVar "at"))) (EVar "acc"))))
(DTypeSig false "paramSlots" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token"))))))))
(DFunDef false "paramSlots" ((PList) PWild PWild) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unterminated parameter group"))) (EVar "moduleOrigin"))))
(DFunDef false "paramSlots" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth") (PVar "count")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Ok") (ETuple (EDictApp "count") (EVar "rest"))) (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EDictApp "count"))) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EDictApp "count")) (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (EVar "depth")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "named") (EVar "text")))) (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EDictApp "count")))))))
(DTypeSig false "skipGroup" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Token")))))
(DFunDef false "skipGroup" ((PList) PWild) (EListLit))
(DFunDef false "skipGroup" ((PCons (PCon "Token" (PVar "text") PWild PWild) (PVar "rest")) (PVar "depth")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "rest") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (EBinOp "+" (EVar "depth") (EIf (EBinOp "==" (EVar "text") (ELit (LString "("))) (ELit (LInt 1)) (EIf (EBinOp "==" (EVar "text") (ELit (LString ")"))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0))))))))
(DTypeSig false "functionShape" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyCon "WasmShape")))))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "param")) PWild PWild) (PVar "rest"))) (PVar "count") PWild (PVar "typeName")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "paramSlots") (EVar "rest")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "n") (PVar "after")) () (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "after")) (EBinOp "+" (EDictApp "count") (EVar "n"))) (EVar "True")) (EVar "typeName")))))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "type")) PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")))) (PVar "count") (PVar "explicit") PWild) (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "functionShape") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (ELit (LInt 0)))) (EDictApp "count")) (EVar "explicit")) (EApp (EVar "Some") (EApp (EVar "bare") (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionShape" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest"))) (PVar "count") (PVar "explicit") (PVar "typeName")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "result"))) (EBinOp "==" (EVar "op") (ELit (LString "local")))) (EBinOp "==" (EVar "op") (ELit (LString "export")))) (EBinOp "==" (EVar "op") (ELit (LString "import")))) (EApp (EApp (EApp (EApp (EVar "functionShape") (EApp (EApp (EVar "skipGroup") (EVar "rest")) (ELit (LInt 0)))) (EDictApp "count")) (EVar "explicit")) (EVar "typeName")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "functionShape" (PWild (PVar "count") (PVar "explicit") (PCon "None")) (EApp (EVar "Ok") (EApp (EVar "FuncParams") (EDictApp "count"))))
(DFunDef false "functionShape" (PWild (PVar "count") (PVar "explicit") (PCon "Some" (PVar "name"))) (EApp (EVar "Ok") (EApp (EApp (EVar "FuncOfType") (EVar "name")) (EIf (EVar "explicit") (EDictApp "count") (EUnOp "-" (ELit (LInt 1)))))))
(DTypeSig false "parent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "parent" ((PList)) (ELit (LString "")))
(DFunDef false "parent" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "declaration" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "WasmSymbol"))))))
(DFunDef false "declaration" ((PLit (LString "func")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EMethodRef "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmFunc") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "type")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "rec")))) (EApp (EMethodRef "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmType") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "global")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EMethodRef "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmGlobal") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" ((PLit (LString "data")) (PVar "name") (PVar "context")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EApp (EMethodRef "isEmpty") (EVar "context"))) (EApp (EVar "Some") (EApp (EVar "WasmData") (EVar "name"))) (EVar "None")))
(DFunDef false "declaration" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ordinaryShape" (TyFun (TyCon "WasmSymbol") (TyCon "WasmShape")))
(DFunDef false "ordinaryShape" ((PCon "WasmType" PWild)) (EVar "TypeDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmGlobal" PWild)) (EVar "GlobalDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmData" PWild)) (EVar "DataDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmElem" PWild)) (EVar "ElemDecl"))
(DFunDef false "ordinaryShape" ((PCon "WasmFunc" PWild)) (EApp (EVar "FuncParams") (ELit (LInt 0))))
(DTypeSig false "admit" (TyFun (TyCon "WasmSymbol") (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")))))))
(DFunDef false "admit" ((PAs "sym" (PCon "WasmElem" PWild)) (PVar "shape") (PVar "seen")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EVar "Materialized") (EVar "sym")) (EVar "shape"))) (EVar "seen"))))
(DFunDef false "admit" ((PVar "sym") (PVar "shape") (PVar "seen")) (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "seen")) (EApp (EVar "Err") (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "sym")) (EVar "moduleOrigin")) (EVar "moduleOrigin"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EApp (EApp (EVar "Materialized") (EVar "sym")) (EVar "shape"))) (EVar "seen")))))
(DTypeSig false "inventory" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyTuple (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))))))
(DFunDef false "inventory" ((PList) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EApp (EMethodRef "isEmpty") (EVar "context")) (EApp (EVar "Ok") (ETuple (EVar "seen") (EVar "types"))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unclosed expression"))) (EVar "moduleOrigin")))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")))) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EApp (EVar "named") (EVar "name")) (EMatch (EApp (EApp (EApp (EVar "declaration") (EVar "op")) (EApp (EVar "bare") (EVar "name"))) (EVar "context")) (arm (PCon "Some" (PAs "sym" (PCon "WasmFunc" PWild))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "rest")) (ELit (LInt 0))) (EVar "False")) (EVar "None"))) (ELam ((PVar "shape")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "shape")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))))) (arm (PCon "Some" (PAs "sym" (PCon "WasmType" (PVar "typeName")))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EVar "TypeDecl")) (EVar "seen"))) (ELam ((PVar "next")) (EMatch (EVar "rest") (arm (PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PLit (LString "func")) PWild PWild) (PVar "after"))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "functionShape") (EVar "after")) (ELit (LInt 0))) (EVar "False")) (EVar "None"))) (ELam ((PVar "shape")) (ELet false (PVar "n") (EMatch (EVar "shape") (arm (PCon "FuncParams" (PVar "count")) () (EDictApp "count")) (arm (PCon "FuncOfType" PWild (PVar "count")) () (EDictApp "count")) (arm PWild () (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EApp (EApp (EApp (EVar "omInsert") (EVar "typeName")) (EVar "n")) (EVar "types"))))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))))) (arm (PCon "Some" (PVar "sym")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "admit") (EVar "sym")) (EApp (EVar "ordinaryShape") (EVar "sym"))) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "next")) (EVar "types"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inventory") (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "name")) (EVar "False")) (EVar "moduleOrigin")) (EVar "rest"))) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "seen")) (EVar "types")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString "(")) PWild PWild) (PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest"))) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "func"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "module"))) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "import")))) (EApp (EMethodRef "isEmpty") (EVar "context")))) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "function declaration lacks a registry identity"))) (EVar "moduleOrigin"))) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EBinOp "::" (EVar "op") (EVar "context"))) (EVar "seen")) (EVar "types"))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString ")")) PWild PWild) (PVar "rest")) (PList) (PVar "seen") (PVar "types")) (EApp (EVar "Err") (EApp (EApp (EVar "UncheckedText") (ELit (LString "unmatched expression end"))) (EVar "moduleOrigin"))))
(DFunDef false "inventory" ((PCons (PCon "Token" (PLit (LString ")")) PWild PWild) (PVar "rest")) (PCons PWild (PVar "outer")) (PVar "seen") (PVar "types")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "outer")) (EVar "seen")) (EVar "types")))
(DFunDef false "inventory" ((PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "rest")) (PVar "context") (PVar "seen") (PVar "types")) (EIf (EBinOp "&&" (EApp (EVar "named") (EVar "name")) (EBinOp "==" (EApp (EVar "parent") (EVar "context")) (ELit (LString "elem")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "admit") (EApp (EVar "WasmElem") (EApp (EVar "bare") (EVar "name")))) (EVar "ElemDecl")) (EVar "seen"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "context")) (EVar "next")) (EVar "types")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "inventory" ((PCons PWild (PVar "rest")) (PVar "context") (PVar "seen") (PVar "types")) (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "rest")) (EVar "context")) (EVar "seen")) (EVar "types")))
(DTypeSig false "gapNames" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyApp (TyCon "SymbolIndex") (TyCon "Unit")))))
(DFunDef false "gapNames" ((PCon "ClosedOutput") PWild) (EVar "omEmpty"))
(DFunDef false "gapNames" ((PCon "RecordedGaps" (PVar "syms")) (PVar "reg")) (EApp (EApp (EApp (EVar "gapsGo") (EVar "syms")) (EVar "reg")) (EVar "omEmpty")))
(DTypeSig false "gapsGo" (TyFun (TyApp (TyCon "List") (TyCon "WasmSymbol")) (TyFun (TyCon "SymbolRegistry") (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "SymbolIndex") (TyCon "Unit"))))))
(DFunDef false "gapsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "gapsGo" ((PCons (PVar "sym") (PVar "rest")) (PVar "reg") (PVar "acc")) (EApp (EApp (EApp (EVar "gapsGo") (EVar "rest")) (EVar "reg")) (EIf (EApp (EApp (EVar "isExcused") (EVar "sym")) (EVar "reg")) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (ELit LUnit)) (EVar "acc")) (EVar "acc"))))
(DTypeSig false "actualCount" (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "actualCount" ((PCon "FuncImported" (PVar "n")) PWild) (EVar "n"))
(DFunDef false "actualCount" ((PCon "FuncParams" (PVar "n")) PWild) (EVar "n"))
(DFunDef false "actualCount" ((PCon "FuncOfType" (PVar "name") (PVar "n")) (PVar "types")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EVar "n") (EApp (EApp (EVar "optionOr") (ELit (LInt -1))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "types")))))
(DFunDef false "actualCount" (PWild PWild) (EUnOp "-" (ELit (LInt 1))))
(DTypeSig false "sameShape" (TyFun (TyCon "WasmShape") (TyFun (TyCon "WasmShape") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Bool")))))
(DFunDef false "sameShape" ((PCon "FuncImported" (PVar "n")) (PVar "actual") (PVar "types")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))))
(DFunDef false "sameShape" ((PCon "FuncParams" (PVar "n")) (PVar "actual") (PVar "types")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))))
(DFunDef false "sameShape" ((PCon "FuncOfType" (PVar "name") (PVar "n")) (PAs "actual" (PCon "FuncOfType" (PVar "found") PWild)) (PVar "types")) (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "found")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types")))))
(DFunDef false "sameShape" ((PVar "a") (PVar "b") PWild) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "declarationDefects" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "declarationDefects" ((PVar "expected") (PVar "seen") (PVar "types") (PVar "gaps")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sym")) (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "expected")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "Expected" PWild (PVar "shape") (PVar "at"))) () (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "gaps")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at"))))) (arm (PCon "Some" (PCon "Materialized" PWild (PVar "actual"))) () (EIf (EApp (EApp (EApp (EVar "sameShape") (EVar "shape")) (EVar "actual")) (EVar "types")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EApp (EApp (EVar "actualCount") (EVar "shape")) (EVar "types"))) (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))) (EVar "at")) (EVar "at")))))))))) (EApp (EVar "symbolKeys") (EVar "expected"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sym")) (EIf (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "expected")) (EListLit) (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "moduleOrigin")))))) (EApp (EVar "symbolKeys") (EVar "seen")))))
(DTypeSig false "useOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmSymbol")))))
(DFunDef false "useOf" ((PLit (LString "call")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "return_call")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "ref.func")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n")) (EApp (EVar "WasmElem") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "func")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "start")) (PVar "n")) (EListLit (EApp (EVar "WasmFunc") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "global.get")) (PVar "n")) (EListLit (EApp (EVar "WasmGlobal") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "global.set")) (PVar "n")) (EListLit (EApp (EVar "WasmGlobal") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "memory.init")) (PVar "n")) (EListLit (EApp (EVar "WasmData") (EVar "n"))))
(DFunDef false "useOf" ((PLit (LString "data.drop")) (PVar "n")) (EListLit (EApp (EVar "WasmData") (EVar "n"))))
(DFunDef false "useOf" ((PVar "op") (PVar "n")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "ref.null"))) (EBinOp "==" (EVar "op") (ELit (LString "ref.cast")))) (EBinOp "==" (EVar "op") (ELit (LString "ref.test")))) (EBinOp "==" (EVar "op") (ELit (LString "sub")))) (EBinOp "==" (EVar "op") (ELit (LString "final")))) (EBinOp "==" (EVar "op") (ELit (LString "type")))) (EBinOp "==" (EVar "op") (ELit (LString "ref")))) (EBinOp "==" (EVar "op") (ELit (LString "null")))) (EBinOp "==" (EVar "op") (ELit (LString "call_ref")))) (EBinOp "==" (EVar "op") (ELit (LString "return_call_ref")))) (EApp (EApp (EVar "startsWith") (ELit (LString "struct."))) (EVar "op"))) (EApp (EApp (EVar "startsWith") (ELit (LString "array."))) (EVar "op"))) (EListLit (EApp (EVar "WasmType") (EVar "n"))) (EListLit)))
(DTypeSig false "missingUse" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyCon "WasmSymbol") (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "missingUse" ((PVar "seen") (PVar "gaps") (PVar "at") (PVar "sym")) (EIf (EBinOp "||" (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "seen")) (EApp (EApp (EVar "symbolHas") (EVar "sym")) (EVar "gaps"))) (EListLit) (EMatch (EVar "sym") (arm (PCon "WasmElem" (PVar "name")) () (EListLit (EApp (EApp (EVar "UndeclaredFuncRef") (EVar "name")) (EVar "at")))) (arm PWild () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "at")))))))
(DTypeSig false "uses" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "uses" ((PVar "tokens") (PVar "seen") (PVar "gaps")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "usesGo") (EVar "tokens")) (EVar "seen")) (EVar "gaps")) (EListLit))))
(DTypeSig false "usesGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))))
(DFunDef false "usesGo" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "usesGo" ((PCons (PCon "Token" (PVar "op") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "seen") (PVar "gaps") (PVar "acc")) (EMatch (EVar "rest") (arm (PList) () (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "origin")) (EVar "acc")) (EVar "acc"))) (arm (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "after")) () (EBlock (DoLet false false (PVar "uncovered") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EListLit (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "origin"))) (EListLit))) (DoLet false false (PVar "absent") (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin"))) (EApp (EApp (EVar "useOf") (EVar "op")) (EApp (EVar "bare") (EVar "name")))) (EListLit))) (DoLet false false (PVar "extra") (EMatch (EVar "after") (arm (PCons (PCon "Token" (PVar "second") PWild PWild) PWild) ((GBool (EBinOp "&&" (EApp (EVar "named") (EVar "second")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "array.new_data"))) (EBinOp "==" (EVar "op") (ELit (LString "array.init_data"))))))) (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin")) (EApp (EVar "WasmData") (EApp (EVar "bare") (EVar "second"))))) (arm (PCons (PCon "Token" (PVar "second") PWild PWild) PWild) ((GBool (EBinOp "&&" (EApp (EVar "named") (EVar "second")) (EBinOp "==" (EVar "op") (ELit (LString "array.copy")))))) (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "origin")) (EApp (EVar "WasmType") (EApp (EVar "bare") (EVar "second"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "usesGo") (EVar "rest")) (EVar "seen")) (EVar "gaps")) (EBinOp "++" (EApp (EVar "reverseL") (EBinOp "++" (EBinOp "++" (EVar "uncovered") (EVar "absent")) (EVar "extra"))) (EVar "acc"))))))))
(DTypeSig true "namedUses" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyTuple (TyCon "WasmSymbol") (TyCon "Int"))))))
(DFunDef false "namedUses" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "rawTokens") (EVar "text"))) (ELam ((PVar "tokens")) (ELet false (PVar "counts") (EApp (EApp (EVar "namedUseCounts") (EVar "tokens")) (EVar "omEmpty")) (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (ELam ((PVar "sym")) (ETuple (EVar "sym") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts")))))) (EApp (EVar "symbolKeys") (EVar "counts"))))))))
(DTypeSig false "namedUseCounts" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Int")) (TyApp (TyCon "SymbolIndex") (TyCon "Int")))))
(DFunDef false "namedUseCounts" ((PList) (PVar "counts")) (EVar "counts"))
(DFunDef false "namedUseCounts" ((PCons (PCon "Token" (PVar "op") PWild PWild) (PVar "rest")) (PVar "counts")) (EMatch (EVar "rest") (arm (PCons (PCon "Token" (PVar "name") PWild PWild) (PVar "after")) () (EBlock (DoLet false false (PVar "first") (EIf (EApp (EVar "named") (EVar "name")) (EApp (EApp (EVar "useOf") (EVar "op")) (EApp (EVar "bare") (EVar "name"))) (EListLit))) (DoLet false false (PVar "second") (EMatch (EVar "after") (arm (PCons (PCon "Token" (PVar "name2") PWild PWild) PWild) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "array.copy"))) (EApp (EVar "named") (EVar "name2"))))) (EListLit (EApp (EVar "WasmType") (EApp (EVar "bare") (EVar "name2"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "namedUseCounts") (EVar "rest")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "countNamedUse")) (EVar "counts")) (EBinOp "++" (EVar "first") (EVar "second"))))))) (arm (PList) () (EVar "counts"))))
(DTypeSig false "countNamedUse" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Int")) (TyFun (TyCon "WasmSymbol") (TyApp (TyCon "SymbolIndex") (TyCon "Int")))))
(DFunDef false "countNamedUse" ((PVar "counts") (PAs "sym" (PCon "WasmType" PWild))) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EBinOp "+" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts"))) (ELit (LInt 1)))) (EVar "counts")))
(DFunDef false "countNamedUse" ((PVar "counts") (PAs "sym" (PCon "WasmGlobal" PWild))) (EApp (EApp (EApp (EVar "symbolInsert") (EVar "sym")) (EBinOp "+" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "counts"))) (ELit (LInt 1)))) (EVar "counts")))
(DFunDef false "countNamedUse" ((PVar "counts") PWild) (EVar "counts"))
(DTypeSig false "attributeOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyCon "SymbolOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "Token")))))))
(DFunDef false "attributeOrigins" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PLit (LString "func")) (PVar "covered") (PVar "origin")) (PCons (PAs "target" (PCon "Token" (PVar "name") PWild PWild)) (PVar "rest"))) (PVar "expected") (PVar "current") (PVar "acc")) (EIf (EApp (EVar "named") (EVar "name")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "symbolLookup") (EApp (EVar "WasmFunc") (EApp (EVar "bare") (EVar "name")))) (EVar "expected")) (arm (PCon "Some" (PCon "Expected" PWild PWild (PVar "at"))) () (EVar "at")) (arm (PCon "None") () (EVar "current")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EBinOp "::" (EVar "target") (EVar "rest"))) (EVar "expected")) (EVar "next")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (ELit (LString "func"))) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "next"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "attributeOrigins" ((PCons (PCon "Token" (PVar "text") (PVar "covered") (PVar "origin")) (PVar "rest")) (PVar "expected") (PVar "current") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "rest")) (EVar "expected")) (EVar "current")) (EBinOp "::" (EApp (EApp (EApp (EVar "Token") (EVar "text")) (EVar "covered")) (EIf (EVar "covered") (EVar "origin") (EVar "current"))) (EVar "acc"))))
(DTypeSig true "checkCheckedFragment" (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "Unit"))))))
(DFunDef false "checkCheckedFragment" ((PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (EVar "reg"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "tokens") PWild)) () (EMatch (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "tokens")) (EListLit)) (EVar "omEmpty")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "seen") (PVar "types"))) () (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty"))) (DoLet false false (PVar "defects") (EBinOp "++" (EApp (EApp (EApp (EVar "fragmentDeclarations") (EVar "expected")) (EVar "seen")) (EVar "types")) (EApp (EVar "uncovered") (EVar "tokens")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "defects"))))))))))
(DTypeSig false "fragmentDeclarations" (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Expected")) (TyFun (TyApp (TyCon "SymbolIndex") (TyCon "Materialized")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))))
(DFunDef false "fragmentDeclarations" ((PVar "expected") (PVar "seen") (PVar "types")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sym")) (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "expected")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "UndefinedReference") (EVar "sym")) (EVar "moduleOrigin")))) (arm (PCon "Some" (PCon "Expected" PWild (PVar "shape") (PVar "at"))) () (EMatch (EApp (EApp (EVar "symbolLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "Some" (PCon "Materialized" PWild (PVar "actual"))) () (EIf (EApp (EApp (EApp (EVar "sameShape") (EVar "shape")) (EVar "actual")) (EVar "types")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "ShapeMismatch") (EApp (EVar "symbolName") (EVar "sym"))) (EApp (EApp (EVar "actualCount") (EVar "shape")) (EVar "types"))) (EApp (EApp (EVar "actualCount") (EVar "actual")) (EVar "types"))) (EVar "at")) (EVar "at"))))) (arm (PCon "None") () (EListLit))))))) (EApp (EVar "symbolKeys") (EVar "seen"))))
(DTypeSig false "uncovered" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyApp (TyCon "List") (TyCon "SymbolDefect"))))
(DFunDef false "uncovered" ((PVar "tokens")) (EApp (EVar "reverseL") (EApp (EApp (EVar "uncoveredGo") (EVar "tokens")) (EListLit))))
(DTypeSig false "uncoveredGo" (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "SymbolDefect")) (TyApp (TyCon "List") (TyCon "SymbolDefect")))))
(DFunDef false "uncoveredGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "uncoveredGo" ((PCons (PCon "Token" (PVar "op") (PVar "covered") (PVar "at")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "call"))) (EBinOp "==" (EVar "op") (ELit (LString "return_call")))) (EApp (EVar "not") (EVar "covered"))) (EApp (EApp (EVar "uncoveredGo") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UncheckedText") (ELit (LString "uncovered direct call"))) (EVar "at")) (EVar "acc"))) (EApp (EApp (EVar "uncoveredGo") (EVar "rest")) (EVar "acc"))))
(DTypeSig true "finishCheckedText" (TyFun (TyCon "CoveragePolicy") (TyFun (TyCon "SymbolRegistry") (TyFun (TyCon "CallCoverage") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "SymbolDefect"))) (TyCon "String")))))))
(DFunDef false "finishCheckedText" ((PVar "policy") (PVar "reg") (PCon "CallCoverage" PWild (PVar "entries")) (PVar "text")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "text")) (EApp (EVar "stringToUtf8Bytes") (EVar "text"))) (EVar "entries")) (EVar "True")) (EApp (EVar "Some") (EVar "reg"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "raw") (PVar "stripped"))) () (EMatch (EApp (EApp (EApp (EApp (EVar "inventory") (EVar "raw")) (EListLit)) (EVar "omEmpty")) (EVar "omEmpty")) (arm (PCon "Err" (PVar "d")) () (EApp (EVar "Err") (EListLit (EVar "d")))) (arm (PCon "Ok" (PTuple (PVar "seen") (PVar "types"))) () (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EVar "expectedMap") (EApp (EVar "declarations") (EVar "reg"))) (EVar "omEmpty"))) (DoLet false false (PVar "tokens") (EApp (EApp (EApp (EApp (EVar "attributeOrigins") (EVar "raw")) (EVar "expected")) (EVar "moduleOrigin")) (EListLit))) (DoLet false false (PVar "gaps") (EApp (EApp (EVar "gapNames") (EVar "policy")) (EVar "reg"))) (DoLet false false (PVar "elementUses") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sym")) (EMatch (EVar "sym") (arm (PCon "WasmElem" (PVar "name")) () (EApp (EApp (EApp (EApp (EVar "missingUse") (EVar "seen")) (EVar "gaps")) (EVar "moduleOrigin")) (EApp (EVar "WasmFunc") (EVar "name")))) (arm PWild () (EListLit))))) (EApp (EVar "symbolKeys") (EVar "seen")))) (DoLet false false (PVar "defects") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "declarationDefects") (EVar "expected")) (EVar "seen")) (EVar "types")) (EVar "gaps")) (EApp (EApp (EApp (EVar "uses") (EVar "tokens")) (EVar "seen")) (EVar "gaps"))) (EVar "elementUses"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "defects")) (EApp (EVar "Ok") (EVar "stripped")) (EApp (EVar "Err") (EVar "defects"))))))))))
