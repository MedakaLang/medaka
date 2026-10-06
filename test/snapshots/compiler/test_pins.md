# META
source_lines=523
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/test_pins.mdk -- the typed known-red ledger shared by test
-- runners. Each project may carry medaka-test-pins.toml; a pin records one
-- expected failing selector and the issue that owns draining it. Parsing
-- rejects every shape it cannot explain, so a typo cannot turn a real failure
-- into a green run.

import toml.{Toml(..), TomlValue, parse, getString, getInt, getArray}
import support.ordmap.{
  OrdMap, omEmpty, omFromNames, omHasKey, omInsert, omLookup
}
import support.util.{contains, joinNl, lenKey}
import string.{
  contains as stringContains, drop, endsWith, indexOf, split, startsWith, toInt,
  trim, lines
}
import list.{reverse}

public export data PinKind = PropPin | TestPin deriving (Eq, Debug)

-- The two expected failure forms make native error pins unrepresentable for
-- assertion-only rows; Result cannot express that ledger invariant.
-- lint-disable-next-line rule-clone-type
public export data TestExpectedFailure =
  | ExpectAssertion String
  | ExpectError String
  deriving (Eq, Debug)

public export data TestPin = Pin {
  pinFile : String,
  pinKind : PinKind,
  pinName : String,
  pinEngine : String,
  pinIssue : Int,
  pinSeed : Option Int,
  pinCases : Option Int,
  pinDetail : Option String,
  pinExpected : Option TestExpectedFailure,
}
  deriving (Eq, Debug)

export type PinIndex = OrdMap TestPin

public export data PinObservation =
  | PinPassed
  | PinLawFailure
  | PinAssertionFailure String
  | PinRuntimeError String
  deriving (Eq, Debug)

public export data PinVerdict =
  | PinHeld Int
  | PinDrained Int
  | PinChanged Int String
  deriving (Eq, Debug)

-- ── Source shape and TOML schema ───────────────────────────────────────────

pinOrigin : String
pinOrigin = "medaka-test-pins.toml"

allowedRootKey : String -> Bool
allowedRootKey "version" = True
allowedRootKey _ = False

-- The TOML reader deliberately returns keys rather than headers. Inspecting
-- headers here keeps an empty `[[pin]]` and an empty unknown table loud too.
-- TOML itself still does the authoritative syntax validation afterward.
headerOk : String -> Bool
headerOk line =
  let t = trim line
  if startsWith "[" t then startsWith "[[pin]]" t else True

headersOk : List String -> Bool
headersOk [] = True
headersOk (line :: rest) = headerOk line && headersOk rest

pinHeaderCount : List String -> Int
pinHeaderCount [] = 0
pinHeaderCount (line :: rest) =
  let t = trim line
  (if startsWith "[[pin]]" t then 1 else 0) + pinHeaderCount rest

sourceHeadersBad : String -> Bool
sourceHeadersBad src = not (headersOk (lines src))

rootKeysOk : List (String, a) -> Bool
rootKeysOk [] = True
rootKeysOk ((key, _) :: rest) =
  (allowedRootKey key || startsWith "pin." key) && rootKeysOk rest

rootVersionCount : List (String, a) -> Int
rootVersionCount [] = 0
rootVersionCount ((key, _) :: rest) =
  (if key == "version" then 1 else 0) + rootVersionCount rest

fieldNames : Toml -> List String
fieldNames (Toml fields) = map fst fields

hasDuplicate : List String -> Bool
hasDuplicate [] = False
hasDuplicate (x :: xs) = contains x xs || hasDuplicate xs

hasOnly : List String -> List String -> Bool
hasOnly [] _ = True
hasOnly (field :: rest) allowed = contains field allowed && hasOnly rest allowed

requiredString : Int -> String -> Toml -> Result String String
requiredString i field entry = match getString field entry
  Some value => Ok value
  None =>
    Err
      "\{pinOrigin}: [[pin]] #\{intToString i}: missing string field '\{field}'"

requiredInt : Int -> String -> Toml -> Result String Int
requiredInt i field entry = match getInt field entry
  Some value => Ok value
  None =>
    Err
      "\{pinOrigin}: [[pin]] #\{intToString i}: missing integer field '\{field}'"

requiredLines : Int -> Toml -> Result String (List String)
requiredLines i entry = match getArray "detail_lines" entry
  Some value => Ok value
  None =>
    Err
      "\{pinOrigin}: [[pin]] #\{intToString i}: missing string-array field 'detail_lines'"

validPathPart : String -> Bool
validPathPart part = part /= "" && part /= "." && part /= ".."

validPathParts : List String -> Bool
validPathParts [] = True
validPathParts (part :: rest) = validPathPart part && validPathParts rest

validPinFile : String -> Bool
validPinFile file =
  file /= ""
    && not (startsWith "/" file)
    && not (stringContains "\\" file)
    && endsWith ".mdk" file
    && validPathParts (split "/" file)

validKind : String -> Bool
validKind kind = kind == "prop" || kind == "test"

validEngine : String -> Bool
validEngine engine = engine == "eval" || engine == "native"

baseFields : List String
baseFields = ["file", "kind", "name", "engine", "issue"]

propFields : List String
propFields = baseFields ++ ["seed", "cases", "failure"]

testFields : List String
testFields = baseFields ++ ["detail_lines", "failure"]

rowPrefix : Int -> String
rowPrefix i = "\{pinOrigin}: [[pin]] #\{intToString i}"

validateFields : Int -> String -> Toml -> Result String Unit
validateFields i kind entry =
  let fields = fieldNames entry
  if hasDuplicate fields then
    Err "\{rowPrefix i}: duplicate field"
  else if not
    (hasOnly fields (if kind == "prop" then propFields else testFields)) then
    Err "\{rowPrefix i}: unknown or disallowed field"
  else
    Ok ()

validateBase : Int -> String -> String -> String -> Int -> Result String Unit
validateBase i file name engine issue =
  if not (validPinFile file) then
    Err "\{rowPrefix i}: invalid project-relative .mdk file '\{file}'"
  else if name == "" then
    Err "\{rowPrefix i}: name must not be empty"
  else if not (validEngine engine) then
    Err "\{rowPrefix i}: engine must be 'eval' or 'native'"
  else if issue <= 0 then
    Err "\{rowPrefix i}: issue must be positive"
  else
    Ok ()

readPropPin : Int ->
  String ->
  String ->
  String ->
  Int ->
  Toml ->
  Result String TestPin
readPropPin i file name engine issue entry = do
  seed <- requiredInt i "seed" entry
  cases <- requiredInt i "cases" entry
  failure <- requiredString i "failure" entry
  if cases <= 0 then
    Err "\{rowPrefix i}: cases must be positive"
  else if failure /= "false" then
    Err "\{rowPrefix i}: failure must be the string \"false\""
  else
    Ok Pin {
      pinFile = file,
      pinKind = PropPin,
      pinName = name,
      pinEngine = engine,
      pinIssue = issue,
      pinSeed = Some seed,
      pinCases = Some cases,
      pinDetail = None,
      pinExpected = None,
    }

readTestPin : Int ->
  String ->
  String ->
  String ->
  Int ->
  Toml ->
  Result String TestPin
readTestPin i file name engine issue entry = do
  detailLines <- requiredLines i entry
  failure <- requiredString i "failure" entry
  expected <- testExpectedFailure i engine failure (joinNl detailLines)
  Ok Pin {
    pinFile = file,
    pinKind = TestPin,
    pinName = name,
    pinEngine = engine,
    pinIssue = issue,
    pinSeed = None,
    pinCases = None,
    pinDetail = Some (joinNl detailLines),
    pinExpected = Some expected,
  }

testExpectedFailure : Int ->
  String ->
  String ->
  String ->
  Result String TestExpectedFailure
testExpectedFailure i engine failure detail
  | failure == "assertion" = Ok (ExpectAssertion detail)
  | failure == "error" && engine == "native" = Ok (ExpectError detail)
  | failure == "error" =
    Err "\{rowPrefix i}: failure \"error\" is only valid for native test pins"
  | otherwise =
    Err "\{rowPrefix i}: test failure must be \"assertion\" or \"error\""

readPin : Toml -> Int -> Result String TestPin
readPin entry i = do
  kind <- requiredString i "kind" entry
  if not (validKind kind) then
    Err "\{rowPrefix i}: kind must be 'prop' or 'test'"
  else match validateFields i kind entry
    Err err => Err err
    Ok _ => do
      file <- requiredString i "file" entry
      name <- requiredString i "name" entry
      engine <- requiredString i "engine" entry
      issue <- requiredInt i "issue" entry
      match validateBase i file name engine issue
        Err err => Err err
        Ok _ =>
          if kind == "prop" then
            readPropPin i file name engine issue entry
          else
            readTestPin i file name engine issue entry

-- TOML stores array tables as flat qualified keys. Build this index once so
-- reading N pin rows does not scan the whole document N times.
pinRows : List (String, a) -> OrdMap (List (String, a))
pinRows fields = pinRowsGo fields omEmpty

pinRowsGo : List (String, a) ->
  OrdMap (List (String, a)) ->
  OrdMap (List (String, a))
pinRowsGo [] rows = rows
pinRowsGo ((key, value) :: rest) rows = match pinFieldKey key
  None => pinRowsGo rest rows
  Some (row, field) =>
    let prior = match omLookup row rows
      Some found => found
      None => []
    pinRowsGo rest (omInsert row ((field, value) :: prior) rows)

pinFieldKey : String -> Option (String, String)
pinFieldKey key =
  if not (startsWith "pin." key) then
    None
  else
    let tail = drop 4 key
    match indexOf "." tail
      None => None
      Some dot =>
        let row = stringSlice 0 dot tail
        let field = drop (dot + 1) tail
        match toInt row
          Some _ => if field == "" then None else Some (row, field)
          None => None

readPinsGo : OrdMap (List (String, TomlValue)) ->
  Int ->
  Int ->
  List TestPin ->
  Result String (List TestPin)
readPinsGo rows i n acc
  | i >= n = Ok (reverse acc)
  | otherwise =
    let row = intToString i
    match omLookup row rows
      None => Err "\{rowPrefix i}: no such row"
      Some fields => do
        pin <- readPin (Toml fields) i
        readPinsGo rows (i + 1) n (pin :: acc)

{- | Parse the repository's known-red ledger. A ledger with no `[[pin]]` rows
   is valid only when it says `version = 1`; it is the explicit empty state,
   not a missing or guessed configuration. -}
export
parsePins : String -> Result String (List TestPin)
parsePins src = parsePinsHeaders (sourceHeadersBad src) src

parsePinsHeaders : Bool -> String -> Result String (List TestPin)
parsePinsHeaders True _ = Err "\{pinOrigin}: only [[pin]] tables are allowed"
parsePinsHeaders False src = match parse src
  Err err => Err "\{pinOrigin}: not valid TOML: \{err}"
  Ok doc => parsePinsDoc src doc

parsePinsDoc : String -> Toml -> Result String (List TestPin)
parsePinsDoc src (Toml fields) =
  let doc = Toml fields
  if not (rootKeysOk fields) then
    Err "\{pinOrigin}: unknown top-level key or table"
  else if rootVersionCount fields /= 1 then
    Err "\{pinOrigin}: exactly one integer version field is required"
  else match getInt "version" doc
    Some 1 =>
      let n = pinHeaderCount (lines src)
      match readPinsGo (pinRows fields) 0 n []
        Err err => Err err
        Ok pins => map (_ => pins) (buildPinIndex pins)
    Some _ => Err "\{pinOrigin}: version must be 1"
    None => Err "\{pinOrigin}: exactly one integer version field is required"

-- ── Selecting and validating declared tests ────────────────────────────────

selectorKey : String -> PinKind -> String -> String -> String
selectorKey file kind name engine =
  lenKey file ++ lenKey (pinKindKey kind) ++ lenKey name ++ lenKey engine

pinKindKey : PinKind -> String
pinKindKey PropPin = "prop"
pinKindKey TestPin = "test"

pinSelectorKey : TestPin -> String
pinSelectorKey pin =
  selectorKey pin.pinFile pin.pinKind pin.pinName pin.pinEngine

export
buildPinIndex : List TestPin -> Result String PinIndex
buildPinIndex pins = buildPinIndexGo pins omEmpty

buildPinIndexGo : List TestPin -> PinIndex -> Result String PinIndex
buildPinIndexGo [] index = Ok index
buildPinIndexGo (pin :: rest) index =
  let key = pinSelectorKey pin
  match omLookup key index
    Some _ =>
      Err
        "\{pinOrigin}: duplicate selector for '\{pin.pinFile}' / \{pinKindKey pin.pinKind} '\{pin.pinName}' / \{pin.pinEngine}"
    None => buildPinIndexGo rest (omInsert key pin index)

export
pinFromIndex : PinIndex ->
  String ->
  PinKind ->
  String ->
  String ->
  Option TestPin
pinFromIndex index file kind name engine =
  omLookup (selectorKey file kind name engine) index

export
pinFor : List TestPin -> String -> PinKind -> String -> String -> Option TestPin
pinFor pins file kind name engine = match buildPinIndex pins
  Err _ => None
  Ok index => pinFromIndex index file kind name engine

pinNamePresent : TestPin -> OrdMap Unit -> OrdMap Unit -> Bool
pinNamePresent pin propNames testNames = match pin.pinKind
  PropPin => match omLookup pin.pinName propNames
    Some _ => True
    None => False
  TestPin => match omLookup pin.pinName testNames
    Some _ => True
    None => False

validatePinNamesGo : List TestPin ->
  String ->
  OrdMap Unit ->
  OrdMap Unit ->
  Result String Unit
validatePinNamesGo [] _ _ _ = Ok ()
validatePinNamesGo (pin :: rest) file propNames testNames =
  if pin.pinFile /= file || pinNamePresent pin propNames testNames then
    validatePinNamesGo rest file propNames testNames
  else
    Err
      "\{pinOrigin}: issue #\{intToString pin.pinIssue} pins missing \{pinKindName pin.pinKind} '\{pin.pinName}' in \{file}"

pinKindName : PinKind -> String
pinKindName PropPin = "property"
pinKindName TestPin = "test"

{- | Refuse a selected file whose ledger row no longer names a declaration.
   The caller decides which files filters select; this helper never treats a
   filtered-out row as drained or silently stale. -}
export
validatePinNames : List TestPin ->
  String ->
  List String ->
  List String ->
  Result String Unit
validatePinNames pins file propNames testNames = do
  propIndex <- declarationIndex pins file PropPin "property" propNames
  testIndex <- declarationIndex pins file TestPin "test" testNames
  validatePinNamesGo pins file propIndex testIndex

declarationIndex : List TestPin ->
  String ->
  PinKind ->
  String ->
  List String ->
  Result String (OrdMap Unit)
declarationIndex pins file kind label names =
  if hasSelectedPin pins file kind then
    uniqueDeclaredNames file label names omEmpty
  else
    Ok (omFromNames names omEmpty)

hasSelectedPin : List TestPin -> String -> PinKind -> Bool
hasSelectedPin [] _ _ = False
hasSelectedPin (pin :: rest) file kind =
  pin.pinFile == file && pin.pinKind == kind || hasSelectedPin rest file kind

-- A ledger selector identifies one result by kind/name/engine. Duplicate
-- declarations of one kind would make that identity ambiguous, so reject
-- before filtering or execution rather than silently pinning whichever runner
-- happens to visit first.
uniqueDeclaredNames : String ->
  String ->
  List String ->
  OrdMap Unit ->
  Result String (OrdMap Unit)
uniqueDeclaredNames _ _ [] seen = Ok seen
uniqueDeclaredNames file kind (name :: rest) seen =
  if omHasKey name seen then
    Err
      "\{pinOrigin}: ambiguous duplicate \{kind} declaration '\{name}' in \{file}"
  else
    uniqueDeclaredNames file kind rest (omInsert name () seen)

-- ── Observations and reporting ─────────────────────────────────────────────

export
classifyPin : TestPin -> PinObservation -> PinVerdict
classifyPin pin PinPassed = PinDrained pin.pinIssue
classifyPin pin PinLawFailure = classifyLawPin pin
classifyPin pin (PinAssertionFailure detail) = classifyAssertionPin pin detail
classifyPin pin (PinRuntimeError detail) = classifyRuntimePin pin detail

classifyLawPin : TestPin -> PinVerdict
classifyLawPin pin = match pin.pinKind
  PropPin => PinHeld pin.pinIssue
  TestPin =>
    PinChanged
      pin.pinIssue
      "expected an assertion failure, got a property-law failure"

classifyAssertionPin : TestPin -> String -> PinVerdict
classifyAssertionPin pin detail = match pin.pinKind
  PropPin =>
    PinChanged
      pin.pinIssue
      "expected a property-law failure, got an assertion failure"
  TestPin => match pin.pinExpected
    Some (ExpectAssertion expected) =>
      if detail == expected then
        PinHeld pin.pinIssue
      else
        PinChanged pin.pinIssue "assertion failure detail changed"
    Some (ExpectError _) =>
      PinChanged
        pin.pinIssue
        "expected a runtime error, got an assertion failure"
    None => PinChanged pin.pinIssue "test pin has no typed expected failure"

classifyRuntimePin : TestPin -> String -> PinVerdict
classifyRuntimePin pin detail = match pin.pinKind
  PropPin => PinChanged pin.pinIssue "runtime error: \{detail}"
  TestPin => match pin.pinExpected
    Some (ExpectError expected) =>
      if detail == expected then
        PinHeld pin.pinIssue
      else
        PinChanged pin.pinIssue "runtime error detail changed"
    Some (ExpectAssertion _) =>
      PinChanged pin.pinIssue "runtime error: \{detail}"
    None => PinChanged pin.pinIssue "test pin has no typed expected failure"

export
pinVerdictPassed : PinVerdict -> Bool
pinVerdictPassed (PinHeld _) = True
pinVerdictPassed _ = False

export
pinVerdictDetail : PinVerdict -> String
pinVerdictDetail (PinHeld issue) =
  "known-red issue #\{intToString issue} still holds"
pinVerdictDetail (PinDrained issue) =
  "known-red issue #\{intToString issue} unexpected pass; remove its pin"
pinVerdictDetail (PinChanged issue detail) =
  "known-red issue #\{intToString issue} changed: \{detail}"
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" false) (mem "parse" false) (mem "getString" false) (mem "getInt" false) (mem "getArray" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "lenKey" false))))
(DUse false (UseGroup ("string") ((mem "contains" false "stringContains") (mem "drop" false) (mem "endsWith" false) (mem "indexOf" false) (mem "split" false) (mem "startsWith" false) (mem "toInt" false) (mem "trim" false) (mem "lines" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "PinKind" () ((variant "PropPin" (ConPos)) (variant "TestPin" (ConPos))) ())
(DImpl true "Eq" ((TyCon "PinKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PropPin") (PCon "PropPin")) () (EVar "True")) (arm (PTuple (PCon "TestPin") (PCon "TestPin")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PropPin") () (ELit (LString "PropPin"))) (arm (PCon "TestPin") () (ELit (LString "TestPin")))))))
(DData Public "TestExpectedFailure" () ((variant "ExpectAssertion" (ConPos (TyCon "String"))) (variant "ExpectError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "TestExpectedFailure")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ExpectAssertion" (PVar "__a0")) (PCon "ExpectAssertion" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ExpectError" (PVar "__a0")) (PCon "ExpectError" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "TestExpectedFailure")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ExpectAssertion" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ExpectAssertion ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "ExpectError" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ExpectError ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "TestPin" () ((variant "Pin" (ConNamed (field "pinFile" (TyCon "String")) (field "pinKind" (TyCon "PinKind")) (field "pinName" (TyCon "String")) (field "pinEngine" (TyCon "String")) (field "pinIssue" (TyCon "Int")) (field "pinSeed" (TyApp (TyCon "Option") (TyCon "Int"))) (field "pinCases" (TyApp (TyCon "Option") (TyCon "Int"))) (field "pinDetail" (TyApp (TyCon "Option") (TyCon "String"))) (field "pinExpected" (TyApp (TyCon "Option") (TyCon "TestExpectedFailure")))))) ())
(DImpl true "Eq" ((TyCon "TestPin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Pin" ((rf "pinFile" (PVar "__a0")) (rf "pinKind" (PVar "__a1")) (rf "pinName" (PVar "__a2")) (rf "pinEngine" (PVar "__a3")) (rf "pinIssue" (PVar "__a4")) (rf "pinSeed" (PVar "__a5")) (rf "pinCases" (PVar "__a6")) (rf "pinDetail" (PVar "__a7")) (rf "pinExpected" (PVar "__a8"))) false) (PRec "Pin" ((rf "pinFile" (PVar "__b0")) (rf "pinKind" (PVar "__b1")) (rf "pinName" (PVar "__b2")) (rf "pinEngine" (PVar "__b3")) (rf "pinIssue" (PVar "__b4")) (rf "pinSeed" (PVar "__b5")) (rf "pinCases" (PVar "__b6")) (rf "pinDetail" (PVar "__b7")) (rf "pinExpected" (PVar "__b8"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EVar "eq") (EVar "__a6")) (EVar "__b6"))) (EApp (EApp (EVar "eq") (EVar "__a7")) (EVar "__b7"))) (EApp (EApp (EVar "eq") (EVar "__a8")) (EVar "__b8"))))))))
(DImpl true "Debug" ((TyCon "TestPin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Pin" ((rf "pinFile" (PVar "__a0")) (rf "pinKind" (PVar "__a1")) (rf "pinName" (PVar "__a2")) (rf "pinEngine" (PVar "__a3")) (rf "pinIssue" (PVar "__a4")) (rf "pinSeed" (PVar "__a5")) (rf "pinCases" (PVar "__a6")) (rf "pinDetail" (PVar "__a7")) (rf "pinExpected" (PVar "__a8"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pin {")) (ELit (LString " pinFile = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", pinKind = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", pinName = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", pinEngine = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", pinIssue = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString ", pinSeed = "))) (EApp (EVar "debug") (EVar "__a5"))) (ELit (LString ", pinCases = "))) (EApp (EVar "debug") (EVar "__a6"))) (ELit (LString ", pinDetail = "))) (EApp (EVar "debug") (EVar "__a7"))) (ELit (LString ", pinExpected = "))) (EApp (EVar "debug") (EVar "__a8"))) (ELit (LString " }"))))))))
(DTypeAlias true "PinIndex" () (TyApp (TyCon "OrdMap") (TyCon "TestPin")))
(DData Public "PinObservation" () ((variant "PinPassed" (ConPos)) (variant "PinLawFailure" (ConPos)) (variant "PinAssertionFailure" (ConPos (TyCon "String"))) (variant "PinRuntimeError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "PinObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PinPassed") (PCon "PinPassed")) () (EVar "True")) (arm (PTuple (PCon "PinLawFailure") (PCon "PinLawFailure")) () (EVar "True")) (arm (PTuple (PCon "PinAssertionFailure" (PVar "__a0")) (PCon "PinAssertionFailure" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinRuntimeError" (PVar "__a0")) (PCon "PinRuntimeError" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PinPassed") () (ELit (LString "PinPassed"))) (arm (PCon "PinLawFailure") () (ELit (LString "PinLawFailure"))) (arm (PCon "PinAssertionFailure" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinAssertionFailure ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "PinRuntimeError" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinRuntimeError ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "PinVerdict" () ((variant "PinHeld" (ConPos (TyCon "Int"))) (variant "PinDrained" (ConPos (TyCon "Int"))) (variant "PinChanged" (ConPos (TyCon "Int") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "PinVerdict")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PinHeld" (PVar "__a0")) (PCon "PinHeld" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinDrained" (PVar "__a0")) (PCon "PinDrained" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinChanged" (PVar "__a0") (PVar "__a1")) (PCon "PinChanged" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinVerdict")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PinHeld" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinHeld ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "PinDrained" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinDrained ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "PinChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PinChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DTypeSig false "pinOrigin" (TyCon "String"))
(DFunDef false "pinOrigin" () (ELit (LString "medaka-test-pins.toml")))
(DTypeSig false "allowedRootKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allowedRootKey" ((PLit (LString "version"))) (EVar "True"))
(DFunDef false "allowedRootKey" (PWild) (EVar "False"))
(DTypeSig false "headerOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "headerOk" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "["))) (EVar "t")) (EApp (EApp (EVar "startsWith") (ELit (LString "[[pin]]"))) (EVar "t")) (EVar "True")))))
(DTypeSig false "headersOk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "headersOk" ((PList)) (EVar "True"))
(DFunDef false "headersOk" ((PCons (PVar "line") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "headerOk") (EVar "line")) (EApp (EVar "headersOk") (EVar "rest"))))
(DTypeSig false "pinHeaderCount" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "pinHeaderCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "pinHeaderCount" ((PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoExpr (EBinOp "+" (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "[[pin]]"))) (EVar "t")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "pinHeaderCount") (EVar "rest"))))))
(DTypeSig false "sourceHeadersBad" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sourceHeadersBad" ((PVar "src")) (EApp (EVar "not") (EApp (EVar "headersOk") (EApp (EVar "lines") (EVar "src")))))
(DTypeSig false "rootKeysOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyCon "Bool")))
(DFunDef false "rootKeysOk" ((PList)) (EVar "True"))
(DFunDef false "rootKeysOk" ((PCons (PTuple (PVar "key") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "allowedRootKey") (EVar "key")) (EApp (EApp (EVar "startsWith") (ELit (LString "pin."))) (EVar "key"))) (EApp (EVar "rootKeysOk") (EVar "rest"))))
(DTypeSig false "rootVersionCount" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyCon "Int")))
(DFunDef false "rootVersionCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "rootVersionCount" ((PCons (PTuple (PVar "key") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "key") (ELit (LString "version"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "rootVersionCount") (EVar "rest"))))
(DTypeSig false "fieldNames" (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PCon "Toml" (PVar "fields"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "fields")))
(DTypeSig false "hasDuplicate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasDuplicate" ((PList)) (EVar "False"))
(DFunDef false "hasDuplicate" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "x")) (EVar "xs")) (EApp (EVar "hasDuplicate") (EVar "xs"))))
(DTypeSig false "hasOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasOnly" ((PList) PWild) (EVar "True"))
(DFunDef false "hasOnly" ((PCons (PVar "field") (PVar "rest")) (PVar "allowed")) (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "field")) (EVar "allowed")) (EApp (EApp (EVar "hasOnly") (EVar "rest")) (EVar "allowed"))))
(DTypeSig false "requiredString" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "requiredString" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "requiredInt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "requiredInt" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getInt") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing integer field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "requiredLines" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "requiredLines" ((PVar "i") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (ELit (LString "detail_lines"))) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing string-array field 'detail_lines'")))))))
(DTypeSig false "validPathPart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validPathPart" ((PVar "part")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "part") (ELit (LString ""))) (EBinOp "/=" (EVar "part") (ELit (LString ".")))) (EBinOp "/=" (EVar "part") (ELit (LString "..")))))
(DTypeSig false "validPathParts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "validPathParts" ((PList)) (EVar "True"))
(DFunDef false "validPathParts" ((PCons (PVar "part") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "validPathPart") (EVar "part")) (EApp (EVar "validPathParts") (EVar "rest"))))
(DTypeSig false "validPinFile" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validPinFile" ((PVar "file")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "file") (ELit (LString ""))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "file")))) (EApp (EVar "not") (EApp (EApp (EVar "stringContains") (ELit (LString "\\"))) (EVar "file")))) (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "file"))) (EApp (EVar "validPathParts") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "file")))))
(DTypeSig false "validKind" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validKind" ((PVar "kind")) (EBinOp "||" (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EBinOp "==" (EVar "kind") (ELit (LString "test")))))
(DTypeSig false "validEngine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validEngine" ((PVar "engine")) (EBinOp "||" (EBinOp "==" (EVar "engine") (ELit (LString "eval"))) (EBinOp "==" (EVar "engine") (ELit (LString "native")))))
(DTypeSig false "baseFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "baseFields" () (EListLit (ELit (LString "file")) (ELit (LString "kind")) (ELit (LString "name")) (ELit (LString "engine")) (ELit (LString "issue"))))
(DTypeSig false "propFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "propFields" () (EBinOp "++" (EVar "baseFields") (EListLit (ELit (LString "seed")) (ELit (LString "cases")) (ELit (LString "failure")))))
(DTypeSig false "testFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testFields" () (EBinOp "++" (EVar "baseFields") (EListLit (ELit (LString "detail_lines")) (ELit (LString "failure")))))
(DTypeSig false "rowPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "rowPrefix" ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "validateFields" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "validateFields" ((PVar "i") (PVar "kind") (PVar "entry")) (EBlock (DoLet false false (PVar "fields") (EApp (EVar "fieldNames") (EVar "entry"))) (DoExpr (EIf (EApp (EVar "hasDuplicate") (EVar "fields")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": duplicate field")))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "hasOnly") (EVar "fields")) (EIf (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EVar "propFields") (EVar "testFields")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": unknown or disallowed field")))) (EApp (EVar "Ok") (ELit LUnit)))))))
(DTypeSig false "validateBase" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "validateBase" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue")) (EIf (EApp (EVar "not") (EApp (EVar "validPinFile") (EVar "file"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": invalid project-relative .mdk file '"))) (EApp (EVar "display") (EVar "file"))) (ELit (LString "'")))) (EIf (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": name must not be empty")))) (EIf (EApp (EVar "not") (EApp (EVar "validEngine") (EVar "engine"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": engine must be 'eval' or 'native'")))) (EIf (EBinOp "<=" (EVar "issue") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": issue must be positive")))) (EApp (EVar "Ok") (ELit LUnit)))))))
(DTypeSig false "readPropPin" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))))))
(DFunDef false "readPropPin" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue") (PVar "entry")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "seed"))) (EVar "entry"))) (ELam ((PVar "seed")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "cases"))) (EVar "entry"))) (ELam ((PVar "cases")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "failure"))) (EVar "entry"))) (ELam ((PVar "failure")) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": cases must be positive")))) (EIf (EBinOp "/=" (EVar "failure") (ELit (LString "false"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": failure must be the string \"false\"")))) (EApp (EVar "Ok") (ERecordCreate "Pin" ((fa "pinFile" (EVar "file")) (fa "pinKind" (EVar "PropPin")) (fa "pinName" (EVar "name")) (fa "pinEngine" (EVar "engine")) (fa "pinIssue" (EVar "issue")) (fa "pinSeed" (EApp (EVar "Some") (EVar "seed"))) (fa "pinCases" (EApp (EVar "Some") (EVar "cases"))) (fa "pinDetail" (EVar "None")) (fa "pinExpected" (EVar "None"))))))))))))))
(DTypeSig false "readTestPin" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))))))
(DFunDef false "readTestPin" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue") (PVar "entry")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredLines") (EVar "i")) (EVar "entry"))) (ELam ((PVar "detailLines")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "failure"))) (EVar "entry"))) (ELam ((PVar "failure")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "testExpectedFailure") (EVar "i")) (EVar "engine")) (EVar "failure")) (EApp (EVar "joinNl") (EVar "detailLines")))) (ELam ((PVar "expected")) (EApp (EVar "Ok") (ERecordCreate "Pin" ((fa "pinFile" (EVar "file")) (fa "pinKind" (EVar "TestPin")) (fa "pinName" (EVar "name")) (fa "pinEngine" (EVar "engine")) (fa "pinIssue" (EVar "issue")) (fa "pinSeed" (EVar "None")) (fa "pinCases" (EVar "None")) (fa "pinDetail" (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "detailLines")))) (fa "pinExpected" (EApp (EVar "Some") (EVar "expected")))))))))))))
(DTypeSig false "testExpectedFailure" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestExpectedFailure")))))))
(DFunDef false "testExpectedFailure" ((PVar "i") (PVar "engine") (PVar "failure") (PVar "detail")) (EIf (EBinOp "==" (EVar "failure") (ELit (LString "assertion"))) (EApp (EVar "Ok") (EApp (EVar "ExpectAssertion") (EVar "detail"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "failure") (ELit (LString "error"))) (EBinOp "==" (EVar "engine") (ELit (LString "native")))) (EApp (EVar "Ok") (EApp (EVar "ExpectError") (EVar "detail"))) (EIf (EBinOp "==" (EVar "failure") (ELit (LString "error"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": failure \"error\" is only valid for native test pins")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": test failure must be \"assertion\" or \"error\"")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "readPin" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))
(DFunDef false "readPin" ((PVar "entry") (PVar "i")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "kind"))) (EVar "entry"))) (ELam ((PVar "kind")) (EIf (EApp (EVar "not") (EApp (EVar "validKind") (EVar "kind"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": kind must be 'prop' or 'test'")))) (EMatch (EApp (EApp (EApp (EVar "validateFields") (EVar "i")) (EVar "kind")) (EVar "entry")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "file"))) (EVar "entry"))) (ELam ((PVar "file")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "name"))) (EVar "entry"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "engine"))) (EVar "entry"))) (ELam ((PVar "engine")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "issue"))) (EVar "entry"))) (ELam ((PVar "issue")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "validateBase") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" PWild) () (EIf (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "readPropPin") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "readTestPin") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (EVar "entry")))))))))))))))))))
(DTypeSig false "pinRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "pinRows" ((PVar "fields")) (EApp (EApp (EVar "pinRowsGo") (EVar "fields")) (EVar "omEmpty")))
(DTypeSig false "pinRowsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "pinRowsGo" ((PList) (PVar "rows")) (EVar "rows"))
(DFunDef false "pinRowsGo" ((PCons (PTuple (PVar "key") (PVar "value")) (PVar "rest")) (PVar "rows")) (EMatch (EApp (EVar "pinFieldKey") (EVar "key")) (arm (PCon "None") () (EApp (EApp (EVar "pinRowsGo") (EVar "rest")) (EVar "rows"))) (arm (PCon "Some" (PTuple (PVar "row") (PVar "field"))) () (EBlock (DoLet false false (PVar "prior") (EMatch (EApp (EApp (EVar "omLookup") (EVar "row")) (EVar "rows")) (arm (PCon "Some" (PVar "found")) () (EVar "found")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "pinRowsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "row")) (EBinOp "::" (ETuple (EVar "field") (EVar "value")) (EVar "prior"))) (EVar "rows"))))))))
(DTypeSig false "pinFieldKey" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "pinFieldKey" ((PVar "key")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "pin."))) (EVar "key"))) (EVar "None") (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "key"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "."))) (EVar "tail")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "dot")) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "dot")) (EVar "tail"))) (DoLet false false (PVar "field") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "dot") (ELit (LInt 1)))) (EVar "tail"))) (DoExpr (EMatch (EApp (EVar "toInt") (EVar "row")) (arm (PCon "Some" PWild) () (EIf (EBinOp "==" (EVar "field") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "row") (EVar "field"))))) (arm (PCon "None") () (EVar "None")))))))))))
(DTypeSig false "readPinsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))))
(DFunDef false "readPinsGo" ((PVar "rows") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "row") (EApp (EVar "intToString") (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "row")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": no such row"))))) (arm (PCon "Some" (PVar "fields")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "readPin") (EApp (EVar "Toml") (EVar "fields"))) (EVar "i"))) (ELam ((PVar "pin")) (EApp (EApp (EApp (EApp (EVar "readPinsGo") (EVar "rows")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "pin") (EVar "acc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parsePins" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin")))))
(DFunDef false "parsePins" ((PVar "src")) (EApp (EApp (EVar "parsePinsHeaders") (EApp (EVar "sourceHeadersBad") (EVar "src"))) (EVar "src")))
(DTypeSig false "parsePinsHeaders" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))
(DFunDef false "parsePinsHeaders" ((PCon "True") PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": only [[pin]] tables are allowed")))))
(DFunDef false "parsePinsHeaders" ((PCon "False") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": not valid TOML: "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "parsePinsDoc") (EVar "src")) (EVar "doc")))))
(DTypeSig false "parsePinsDoc" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))
(DFunDef false "parsePinsDoc" ((PVar "src") (PCon "Toml" (PVar "fields"))) (EBlock (DoLet false false (PVar "doc") (EApp (EVar "Toml") (EVar "fields"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "rootKeysOk") (EVar "fields"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": unknown top-level key or table")))) (EIf (EBinOp "/=" (EApp (EVar "rootVersionCount") (EVar "fields")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": exactly one integer version field is required")))) (EMatch (EApp (EApp (EVar "getInt") (ELit (LString "version"))) (EVar "doc")) (arm (PCon "Some" (PLit (LInt 1))) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "pinHeaderCount") (EApp (EVar "lines") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "readPinsGo") (EApp (EVar "pinRows") (EVar "fields"))) (ELit (LInt 0))) (EVar "n")) (EListLit)) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PVar "pins")) () (EApp (EApp (EVar "map") (ELam (PWild) (EVar "pins"))) (EApp (EVar "buildPinIndex") (EVar "pins")))))))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": version must be 1"))))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": exactly one integer version field is required")))))))))))
(DTypeSig false "selectorKey" (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "selectorKey" ((PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EVar "file")) (EApp (EVar "lenKey") (EApp (EVar "pinKindKey") (EVar "kind")))) (EApp (EVar "lenKey") (EVar "name"))) (EApp (EVar "lenKey") (EVar "engine"))))
(DTypeSig false "pinKindKey" (TyFun (TyCon "PinKind") (TyCon "String")))
(DFunDef false "pinKindKey" ((PCon "PropPin")) (ELit (LString "prop")))
(DFunDef false "pinKindKey" ((PCon "TestPin")) (ELit (LString "test")))
(DTypeSig false "pinSelectorKey" (TyFun (TyCon "TestPin") (TyCon "String")))
(DFunDef false "pinSelectorKey" ((PVar "pin")) (EApp (EApp (EApp (EApp (EVar "selectorKey") (EFieldAccess (EVar "pin") "pinFile")) (EFieldAccess (EVar "pin") "pinKind")) (EFieldAccess (EVar "pin") "pinName")) (EFieldAccess (EVar "pin") "pinEngine")))
(DTypeSig true "buildPinIndex" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinIndex"))))
(DFunDef false "buildPinIndex" ((PVar "pins")) (EApp (EApp (EVar "buildPinIndexGo") (EVar "pins")) (EVar "omEmpty")))
(DTypeSig false "buildPinIndexGo" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "PinIndex") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinIndex")))))
(DFunDef false "buildPinIndexGo" ((PList) (PVar "index")) (EApp (EVar "Ok") (EVar "index")))
(DFunDef false "buildPinIndexGo" ((PCons (PVar "pin") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "pinSelectorKey") (EVar "pin"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "index")) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": duplicate selector for '"))) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' / "))) (EApp (EVar "display") (EApp (EVar "pinKindKey") (EFieldAccess (EVar "pin") "pinKind")))) (ELit (LString " '"))) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinName"))) (ELit (LString "' / "))) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinEngine"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "buildPinIndexGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "pin")) (EVar "index"))))))))
(DTypeSig true "pinFromIndex" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TestPin"))))))))
(DFunDef false "pinFromIndex" ((PVar "index") (PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EApp (EApp (EVar "selectorKey") (EVar "file")) (EVar "kind")) (EVar "name")) (EVar "engine"))) (EVar "index")))
(DTypeSig true "pinFor" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TestPin"))))))))
(DFunDef false "pinFor" ((PVar "pins") (PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EMatch (EApp (EVar "buildPinIndex") (EVar "pins")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "index")) () (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EVar "index")) (EVar "file")) (EVar "kind")) (EVar "name")) (EVar "engine")))))
(DTypeSig false "pinNamePresent" (TyFun (TyCon "TestPin") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))
(DFunDef false "pinNamePresent" ((PVar "pin") (PVar "propNames") (PVar "testNames")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "pin") "pinName")) (EVar "propNames")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False")))) (arm (PCon "TestPin") () (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "pin") "pinName")) (EVar "testNames")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "validatePinNamesGo" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "validatePinNamesGo" ((PList) PWild PWild PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validatePinNamesGo" ((PCons (PVar "pin") (PVar "rest")) (PVar "file") (PVar "propNames") (PVar "testNames")) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")) (EApp (EApp (EApp (EVar "pinNamePresent") (EVar "pin")) (EVar "propNames")) (EVar "testNames"))) (EApp (EApp (EApp (EApp (EVar "validatePinNamesGo") (EVar "rest")) (EVar "file")) (EVar "propNames")) (EVar "testNames")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": issue #"))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "pin") "pinIssue")))) (ELit (LString " pins missing "))) (EApp (EVar "display") (EApp (EVar "pinKindName") (EFieldAccess (EVar "pin") "pinKind")))) (ELit (LString " '"))) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinName"))) (ELit (LString "' in "))) (EApp (EVar "display") (EVar "file"))) (ELit (LString ""))))))
(DTypeSig false "pinKindName" (TyFun (TyCon "PinKind") (TyCon "String")))
(DFunDef false "pinKindName" ((PCon "PropPin")) (ELit (LString "property")))
(DFunDef false "pinKindName" ((PCon "TestPin")) (ELit (LString "test")))
(DTypeSig true "validatePinNames" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "validatePinNames" ((PVar "pins") (PVar "file") (PVar "propNames") (PVar "testNames")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "declarationIndex") (EVar "pins")) (EVar "file")) (EVar "PropPin")) (ELit (LString "property"))) (EVar "propNames"))) (ELam ((PVar "propIndex")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "declarationIndex") (EVar "pins")) (EVar "file")) (EVar "TestPin")) (ELit (LString "test"))) (EVar "testNames"))) (ELam ((PVar "testIndex")) (EApp (EApp (EApp (EApp (EVar "validatePinNamesGo") (EVar "pins")) (EVar "file")) (EVar "propIndex")) (EVar "testIndex")))))))
(DTypeSig false "declarationIndex" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))))
(DFunDef false "declarationIndex" ((PVar "pins") (PVar "file") (PVar "kind") (PVar "label") (PVar "names")) (EIf (EApp (EApp (EApp (EVar "hasSelectedPin") (EVar "pins")) (EVar "file")) (EVar "kind")) (EApp (EApp (EApp (EApp (EVar "uniqueDeclaredNames") (EVar "file")) (EVar "label")) (EVar "names")) (EVar "omEmpty")) (EApp (EVar "Ok") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty")))))
(DTypeSig false "hasSelectedPin" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyCon "Bool")))))
(DFunDef false "hasSelectedPin" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "hasSelectedPin" ((PCons (PVar "pin") (PVar "rest")) (PVar "file") (PVar "kind")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")) (EBinOp "==" (EFieldAccess (EVar "pin") "pinKind") (EVar "kind"))) (EApp (EApp (EApp (EVar "hasSelectedPin") (EVar "rest")) (EVar "file")) (EVar "kind"))))
(DTypeSig false "uniqueDeclaredNames" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "uniqueDeclaredNames" (PWild PWild (PList) (PVar "seen")) (EApp (EVar "Ok") (EVar "seen")))
(DFunDef false "uniqueDeclaredNames" ((PVar "file") (PVar "kind") (PCons (PVar "name") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "pinOrigin"))) (ELit (LString ": ambiguous duplicate "))) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " declaration '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' in "))) (EApp (EVar "display") (EVar "file"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "uniqueDeclaredNames") (EVar "file")) (EVar "kind")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig true "classifyPin" (TyFun (TyCon "TestPin") (TyFun (TyCon "PinObservation") (TyCon "PinVerdict"))))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinPassed")) (EApp (EVar "PinDrained") (EFieldAccess (EVar "pin") "pinIssue")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinLawFailure")) (EApp (EVar "classifyLawPin") (EVar "pin")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinAssertionFailure" (PVar "detail"))) (EApp (EApp (EVar "classifyAssertionPin") (EVar "pin")) (EVar "detail")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinRuntimeError" (PVar "detail"))) (EApp (EApp (EVar "classifyRuntimePin") (EVar "pin")) (EVar "detail")))
(DTypeSig false "classifyLawPin" (TyFun (TyCon "TestPin") (TyCon "PinVerdict")))
(DFunDef false "classifyLawPin" ((PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue"))) (arm (PCon "TestPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected an assertion failure, got a property-law failure"))))))
(DTypeSig false "classifyAssertionPin" (TyFun (TyCon "TestPin") (TyFun (TyCon "String") (TyCon "PinVerdict"))))
(DFunDef false "classifyAssertionPin" ((PVar "pin") (PVar "detail")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected a property-law failure, got an assertion failure")))) (arm (PCon "TestPin") () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectAssertion" (PVar "expected"))) () (EIf (EBinOp "==" (EVar "detail") (EVar "expected")) (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue")) (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "assertion failure detail changed"))))) (arm (PCon "Some" (PCon "ExpectError" PWild)) () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected a runtime error, got an assertion failure")))) (arm (PCon "None") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "test pin has no typed expected failure"))))))))
(DTypeSig false "classifyRuntimePin" (TyFun (TyCon "TestPin") (TyFun (TyCon "String") (TyCon "PinVerdict"))))
(DFunDef false "classifyRuntimePin" ((PVar "pin") (PVar "detail")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error: ")) (EApp (EVar "display") (EVar "detail"))) (ELit (LString ""))))) (arm (PCon "TestPin") () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectError" (PVar "expected"))) () (EIf (EBinOp "==" (EVar "detail") (EVar "expected")) (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue")) (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "runtime error detail changed"))))) (arm (PCon "Some" (PCon "ExpectAssertion" PWild)) () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error: ")) (EApp (EVar "display") (EVar "detail"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "test pin has no typed expected failure"))))))))
(DTypeSig true "pinVerdictPassed" (TyFun (TyCon "PinVerdict") (TyCon "Bool")))
(DFunDef false "pinVerdictPassed" ((PCon "PinHeld" PWild)) (EVar "True"))
(DFunDef false "pinVerdictPassed" (PWild) (EVar "False"))
(DTypeSig true "pinVerdictDetail" (TyFun (TyCon "PinVerdict") (TyCon "String")))
(DFunDef false "pinVerdictDetail" ((PCon "PinHeld" (PVar "issue"))) (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " still holds"))))
(DFunDef false "pinVerdictDetail" ((PCon "PinDrained" (PVar "issue"))) (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " unexpected pass; remove its pin"))))
(DFunDef false "pinVerdictDetail" ((PCon "PinChanged" (PVar "issue") (PVar "detail"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " changed: "))) (EApp (EVar "display") (EVar "detail"))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" false) (mem "parse" false) (mem "getString" false) (mem "getInt" false) (mem "getArray" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "lenKey" false))))
(DUse false (UseGroup ("string") ((mem "contains" false "stringContains") (mem "drop" false) (mem "endsWith" false) (mem "indexOf" false) (mem "split" false) (mem "startsWith" false) (mem "toInt" false) (mem "trim" false) (mem "lines" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "PinKind" () ((variant "PropPin" (ConPos)) (variant "TestPin" (ConPos))) ())
(DImpl true "Eq" ((TyCon "PinKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PropPin") (PCon "PropPin")) () (EVar "True")) (arm (PTuple (PCon "TestPin") (PCon "TestPin")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PropPin") () (ELit (LString "PropPin"))) (arm (PCon "TestPin") () (ELit (LString "TestPin")))))))
(DData Public "TestExpectedFailure" () ((variant "ExpectAssertion" (ConPos (TyCon "String"))) (variant "ExpectError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "TestExpectedFailure")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ExpectAssertion" (PVar "__a0")) (PCon "ExpectAssertion" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ExpectError" (PVar "__a0")) (PCon "ExpectError" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "TestExpectedFailure")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ExpectAssertion" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ExpectAssertion ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "ExpectError" (PVar "__a0")) () (EBinOp "++" (ELit (LString "ExpectError ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "TestPin" () ((variant "Pin" (ConNamed (field "pinFile" (TyCon "String")) (field "pinKind" (TyCon "PinKind")) (field "pinName" (TyCon "String")) (field "pinEngine" (TyCon "String")) (field "pinIssue" (TyCon "Int")) (field "pinSeed" (TyApp (TyCon "Option") (TyCon "Int"))) (field "pinCases" (TyApp (TyCon "Option") (TyCon "Int"))) (field "pinDetail" (TyApp (TyCon "Option") (TyCon "String"))) (field "pinExpected" (TyApp (TyCon "Option") (TyCon "TestExpectedFailure")))))) ())
(DImpl true "Eq" ((TyCon "TestPin")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Pin" ((rf "pinFile" (PVar "__a0")) (rf "pinKind" (PVar "__a1")) (rf "pinName" (PVar "__a2")) (rf "pinEngine" (PVar "__a3")) (rf "pinIssue" (PVar "__a4")) (rf "pinSeed" (PVar "__a5")) (rf "pinCases" (PVar "__a6")) (rf "pinDetail" (PVar "__a7")) (rf "pinExpected" (PVar "__a8"))) false) (PRec "Pin" ((rf "pinFile" (PVar "__b0")) (rf "pinKind" (PVar "__b1")) (rf "pinName" (PVar "__b2")) (rf "pinEngine" (PVar "__b3")) (rf "pinIssue" (PVar "__b4")) (rf "pinSeed" (PVar "__b5")) (rf "pinCases" (PVar "__b6")) (rf "pinDetail" (PVar "__b7")) (rf "pinExpected" (PVar "__b8"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))) (EApp (EApp (EMethodRef "eq") (EVar "__a6")) (EVar "__b6"))) (EApp (EApp (EMethodRef "eq") (EVar "__a7")) (EVar "__b7"))) (EApp (EApp (EMethodRef "eq") (EVar "__a8")) (EVar "__b8"))))))))
(DImpl true "Debug" ((TyCon "TestPin")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Pin" ((rf "pinFile" (PVar "__a0")) (rf "pinKind" (PVar "__a1")) (rf "pinName" (PVar "__a2")) (rf "pinEngine" (PVar "__a3")) (rf "pinIssue" (PVar "__a4")) (rf "pinSeed" (PVar "__a5")) (rf "pinCases" (PVar "__a6")) (rf "pinDetail" (PVar "__a7")) (rf "pinExpected" (PVar "__a8"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Pin {")) (ELit (LString " pinFile = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", pinKind = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", pinName = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", pinEngine = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", pinIssue = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString ", pinSeed = "))) (EApp (EMethodRef "debug") (EVar "__a5"))) (ELit (LString ", pinCases = "))) (EApp (EMethodRef "debug") (EVar "__a6"))) (ELit (LString ", pinDetail = "))) (EApp (EMethodRef "debug") (EVar "__a7"))) (ELit (LString ", pinExpected = "))) (EApp (EMethodRef "debug") (EVar "__a8"))) (ELit (LString " }"))))))))
(DTypeAlias true "PinIndex" () (TyApp (TyCon "OrdMap") (TyCon "TestPin")))
(DData Public "PinObservation" () ((variant "PinPassed" (ConPos)) (variant "PinLawFailure" (ConPos)) (variant "PinAssertionFailure" (ConPos (TyCon "String"))) (variant "PinRuntimeError" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "PinObservation")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PinPassed") (PCon "PinPassed")) () (EVar "True")) (arm (PTuple (PCon "PinLawFailure") (PCon "PinLawFailure")) () (EVar "True")) (arm (PTuple (PCon "PinAssertionFailure" (PVar "__a0")) (PCon "PinAssertionFailure" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinRuntimeError" (PVar "__a0")) (PCon "PinRuntimeError" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinObservation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PinPassed") () (ELit (LString "PinPassed"))) (arm (PCon "PinLawFailure") () (ELit (LString "PinLawFailure"))) (arm (PCon "PinAssertionFailure" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinAssertionFailure ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "PinRuntimeError" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinRuntimeError ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "PinVerdict" () ((variant "PinHeld" (ConPos (TyCon "Int"))) (variant "PinDrained" (ConPos (TyCon "Int"))) (variant "PinChanged" (ConPos (TyCon "Int") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "PinVerdict")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "PinHeld" (PVar "__a0")) (PCon "PinHeld" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinDrained" (PVar "__a0")) (PCon "PinDrained" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PinChanged" (PVar "__a0") (PVar "__a1")) (PCon "PinChanged" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "PinVerdict")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "PinHeld" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinHeld ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "PinDrained" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PinDrained ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "PinChanged" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PinChanged ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DTypeSig false "pinOrigin" (TyCon "String"))
(DFunDef false "pinOrigin" () (ELit (LString "medaka-test-pins.toml")))
(DTypeSig false "allowedRootKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allowedRootKey" ((PLit (LString "version"))) (EVar "True"))
(DFunDef false "allowedRootKey" (PWild) (EVar "False"))
(DTypeSig false "headerOk" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "headerOk" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "["))) (EVar "t")) (EApp (EApp (EVar "startsWith") (ELit (LString "[[pin]]"))) (EVar "t")) (EVar "True")))))
(DTypeSig false "headersOk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "headersOk" ((PList)) (EVar "True"))
(DFunDef false "headersOk" ((PCons (PVar "line") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "headerOk") (EVar "line")) (EApp (EVar "headersOk") (EVar "rest"))))
(DTypeSig false "pinHeaderCount" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "pinHeaderCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "pinHeaderCount" ((PCons (PVar "line") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoExpr (EBinOp "+" (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "[[pin]]"))) (EVar "t")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "pinHeaderCount") (EVar "rest"))))))
(DTypeSig false "sourceHeadersBad" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sourceHeadersBad" ((PVar "src")) (EApp (EVar "not") (EApp (EVar "headersOk") (EApp (EVar "lines") (EVar "src")))))
(DTypeSig false "rootKeysOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyCon "Bool")))
(DFunDef false "rootKeysOk" ((PList)) (EVar "True"))
(DFunDef false "rootKeysOk" ((PCons (PTuple (PVar "key") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "allowedRootKey") (EVar "key")) (EApp (EApp (EVar "startsWith") (ELit (LString "pin."))) (EVar "key"))) (EApp (EVar "rootKeysOk") (EVar "rest"))))
(DTypeSig false "rootVersionCount" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyCon "Int")))
(DFunDef false "rootVersionCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "rootVersionCount" ((PCons (PTuple (PVar "key") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "key") (ELit (LString "version"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "rootVersionCount") (EVar "rest"))))
(DTypeSig false "fieldNames" (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PCon "Toml" (PVar "fields"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "fields")))
(DTypeSig false "hasDuplicate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "hasDuplicate" ((PList)) (EVar "False"))
(DFunDef false "hasDuplicate" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "x")) (EVar "xs")) (EApp (EVar "hasDuplicate") (EVar "xs"))))
(DTypeSig false "hasOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasOnly" ((PList) PWild) (EVar "True"))
(DFunDef false "hasOnly" ((PCons (PVar "field") (PVar "rest")) (PVar "allowed")) (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "field")) (EVar "allowed")) (EApp (EApp (EVar "hasOnly") (EVar "rest")) (EVar "allowed"))))
(DTypeSig false "requiredString" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "requiredString" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "requiredInt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "requiredInt" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getInt") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing integer field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "requiredLines" (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "requiredLines" ((PVar "i") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (ELit (LString "detail_lines"))) (EVar "entry")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing string-array field 'detail_lines'")))))))
(DTypeSig false "validPathPart" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validPathPart" ((PVar "part")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "part") (ELit (LString ""))) (EBinOp "/=" (EVar "part") (ELit (LString ".")))) (EBinOp "/=" (EVar "part") (ELit (LString "..")))))
(DTypeSig false "validPathParts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "validPathParts" ((PList)) (EVar "True"))
(DFunDef false "validPathParts" ((PCons (PVar "part") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "validPathPart") (EVar "part")) (EApp (EVar "validPathParts") (EVar "rest"))))
(DTypeSig false "validPinFile" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validPinFile" ((PVar "file")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "file") (ELit (LString ""))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "file")))) (EApp (EVar "not") (EApp (EApp (EVar "stringContains") (ELit (LString "\\"))) (EVar "file")))) (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "file"))) (EApp (EVar "validPathParts") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "file")))))
(DTypeSig false "validKind" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validKind" ((PVar "kind")) (EBinOp "||" (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EBinOp "==" (EVar "kind") (ELit (LString "test")))))
(DTypeSig false "validEngine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validEngine" ((PVar "engine")) (EBinOp "||" (EBinOp "==" (EVar "engine") (ELit (LString "eval"))) (EBinOp "==" (EVar "engine") (ELit (LString "native")))))
(DTypeSig false "baseFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "baseFields" () (EListLit (ELit (LString "file")) (ELit (LString "kind")) (ELit (LString "name")) (ELit (LString "engine")) (ELit (LString "issue"))))
(DTypeSig false "propFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "propFields" () (EBinOp "++" (EVar "baseFields") (EListLit (ELit (LString "seed")) (ELit (LString "cases")) (ELit (LString "failure")))))
(DTypeSig false "testFields" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "testFields" () (EBinOp "++" (EVar "baseFields") (EListLit (ELit (LString "detail_lines")) (ELit (LString "failure")))))
(DTypeSig false "rowPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "rowPrefix" ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": [[pin]] #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "validateFields" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "validateFields" ((PVar "i") (PVar "kind") (PVar "entry")) (EBlock (DoLet false false (PVar "fields") (EApp (EVar "fieldNames") (EVar "entry"))) (DoExpr (EIf (EApp (EVar "hasDuplicate") (EVar "fields")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": duplicate field")))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "hasOnly") (EVar "fields")) (EIf (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EVar "propFields") (EVar "testFields")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": unknown or disallowed field")))) (EApp (EVar "Ok") (ELit LUnit)))))))
(DTypeSig false "validateBase" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "validateBase" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue")) (EIf (EApp (EVar "not") (EApp (EVar "validPinFile") (EVar "file"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": invalid project-relative .mdk file '"))) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString "'")))) (EIf (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": name must not be empty")))) (EIf (EApp (EVar "not") (EApp (EVar "validEngine") (EVar "engine"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": engine must be 'eval' or 'native'")))) (EIf (EBinOp "<=" (EVar "issue") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": issue must be positive")))) (EApp (EVar "Ok") (ELit LUnit)))))))
(DTypeSig false "readPropPin" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))))))
(DFunDef false "readPropPin" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue") (PVar "entry")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "seed"))) (EVar "entry"))) (ELam ((PVar "seed")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "cases"))) (EVar "entry"))) (ELam ((PVar "cases")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "failure"))) (EVar "entry"))) (ELam ((PVar "failure")) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": cases must be positive")))) (EIf (EBinOp "/=" (EVar "failure") (ELit (LString "false"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": failure must be the string \"false\"")))) (EApp (EVar "Ok") (ERecordCreate "Pin" ((fa "pinFile" (EVar "file")) (fa "pinKind" (EVar "PropPin")) (fa "pinName" (EVar "name")) (fa "pinEngine" (EVar "engine")) (fa "pinIssue" (EVar "issue")) (fa "pinSeed" (EApp (EVar "Some") (EVar "seed"))) (fa "pinCases" (EApp (EVar "Some") (EVar "cases"))) (fa "pinDetail" (EVar "None")) (fa "pinExpected" (EVar "None"))))))))))))))
(DTypeSig false "readTestPin" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))))))
(DFunDef false "readTestPin" ((PVar "i") (PVar "file") (PVar "name") (PVar "engine") (PVar "issue") (PVar "entry")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredLines") (EVar "i")) (EVar "entry"))) (ELam ((PVar "detailLines")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "failure"))) (EVar "entry"))) (ELam ((PVar "failure")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "testExpectedFailure") (EVar "i")) (EVar "engine")) (EVar "failure")) (EApp (EVar "joinNl") (EVar "detailLines")))) (ELam ((PVar "expected")) (EApp (EVar "Ok") (ERecordCreate "Pin" ((fa "pinFile" (EVar "file")) (fa "pinKind" (EVar "TestPin")) (fa "pinName" (EVar "name")) (fa "pinEngine" (EVar "engine")) (fa "pinIssue" (EVar "issue")) (fa "pinSeed" (EVar "None")) (fa "pinCases" (EVar "None")) (fa "pinDetail" (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "detailLines")))) (fa "pinExpected" (EApp (EVar "Some") (EVar "expected")))))))))))))
(DTypeSig false "testExpectedFailure" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestExpectedFailure")))))))
(DFunDef false "testExpectedFailure" ((PVar "i") (PVar "engine") (PVar "failure") (PVar "detail")) (EIf (EBinOp "==" (EVar "failure") (ELit (LString "assertion"))) (EApp (EVar "Ok") (EApp (EVar "ExpectAssertion") (EVar "detail"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "failure") (ELit (LString "error"))) (EBinOp "==" (EVar "engine") (ELit (LString "native")))) (EApp (EVar "Ok") (EApp (EVar "ExpectError") (EVar "detail"))) (EIf (EBinOp "==" (EVar "failure") (ELit (LString "error"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": failure \"error\" is only valid for native test pins")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": test failure must be \"assertion\" or \"error\"")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "readPin" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "TestPin")))))
(DFunDef false "readPin" ((PVar "entry") (PVar "i")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "kind"))) (EVar "entry"))) (ELam ((PVar "kind")) (EIf (EApp (EVar "not") (EApp (EVar "validKind") (EVar "kind"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": kind must be 'prop' or 'test'")))) (EMatch (EApp (EApp (EApp (EVar "validateFields") (EVar "i")) (EVar "kind")) (EVar "entry")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "file"))) (EVar "entry"))) (ELam ((PVar "file")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "name"))) (EVar "entry"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredString") (EVar "i")) (ELit (LString "engine"))) (EVar "entry"))) (ELam ((PVar "engine")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "requiredInt") (EVar "i")) (ELit (LString "issue"))) (EVar "entry"))) (ELam ((PVar "issue")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "validateBase") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" PWild) () (EIf (EBinOp "==" (EVar "kind") (ELit (LString "prop"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "readPropPin") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "readTestPin") (EVar "i")) (EVar "file")) (EVar "name")) (EVar "engine")) (EVar "issue")) (EVar "entry")))))))))))))))))))
(DTypeSig false "pinRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "pinRows" ((PVar "fields")) (EApp (EApp (EVar "pinRowsGo") (EVar "fields")) (EVar "omEmpty")))
(DTypeSig false "pinRowsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "pinRowsGo" ((PList) (PVar "rows")) (EVar "rows"))
(DFunDef false "pinRowsGo" ((PCons (PTuple (PVar "key") (PVar "value")) (PVar "rest")) (PVar "rows")) (EMatch (EApp (EVar "pinFieldKey") (EVar "key")) (arm (PCon "None") () (EApp (EApp (EVar "pinRowsGo") (EVar "rest")) (EVar "rows"))) (arm (PCon "Some" (PTuple (PVar "row") (PVar "field"))) () (EBlock (DoLet false false (PVar "prior") (EMatch (EApp (EApp (EVar "omLookup") (EVar "row")) (EVar "rows")) (arm (PCon "Some" (PVar "found")) () (EVar "found")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "pinRowsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "row")) (EBinOp "::" (ETuple (EVar "field") (EVar "value")) (EVar "prior"))) (EVar "rows"))))))))
(DTypeSig false "pinFieldKey" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "pinFieldKey" ((PVar "key")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "pin."))) (EVar "key"))) (EVar "None") (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "key"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "."))) (EVar "tail")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "dot")) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "dot")) (EVar "tail"))) (DoLet false false (PVar "field") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "dot") (ELit (LInt 1)))) (EVar "tail"))) (DoExpr (EMatch (EApp (EVar "toInt") (EVar "row")) (arm (PCon "Some" PWild) () (EIf (EBinOp "==" (EVar "field") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "row") (EVar "field"))))) (arm (PCon "None") () (EVar "None")))))))))))
(DTypeSig false "readPinsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))))
(DFunDef false "readPinsGo" ((PVar "rows") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "row") (EApp (EVar "intToString") (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "row")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rowPrefix") (EVar "i")))) (ELit (LString ": no such row"))))) (arm (PCon "Some" (PVar "fields")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "readPin") (EApp (EVar "Toml") (EVar "fields"))) (EVar "i"))) (ELam ((PVar "pin")) (EApp (EApp (EApp (EApp (EVar "readPinsGo") (EVar "rows")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "pin") (EVar "acc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parsePins" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin")))))
(DFunDef false "parsePins" ((PVar "src")) (EApp (EApp (EVar "parsePinsHeaders") (EApp (EVar "sourceHeadersBad") (EVar "src"))) (EVar "src")))
(DTypeSig false "parsePinsHeaders" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))
(DFunDef false "parsePinsHeaders" ((PCon "True") PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": only [[pin]] tables are allowed")))))
(DFunDef false "parsePinsHeaders" ((PCon "False") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": not valid TOML: "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "parsePinsDoc") (EVar "src")) (EVar "doc")))))
(DTypeSig false "parsePinsDoc" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "TestPin"))))))
(DFunDef false "parsePinsDoc" ((PVar "src") (PCon "Toml" (PVar "fields"))) (EBlock (DoLet false false (PVar "doc") (EApp (EVar "Toml") (EVar "fields"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "rootKeysOk") (EVar "fields"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": unknown top-level key or table")))) (EIf (EBinOp "/=" (EApp (EVar "rootVersionCount") (EVar "fields")) (ELit (LInt 1))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": exactly one integer version field is required")))) (EMatch (EApp (EApp (EVar "getInt") (ELit (LString "version"))) (EVar "doc")) (arm (PCon "Some" (PLit (LInt 1))) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "pinHeaderCount") (EApp (EVar "lines") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "readPinsGo") (EApp (EVar "pinRows") (EVar "fields"))) (ELit (LInt 0))) (EVar "n")) (EListLit)) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PVar "pins")) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "pins"))) (EApp (EVar "buildPinIndex") (EVar "pins")))))))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": version must be 1"))))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": exactly one integer version field is required")))))))))))
(DTypeSig false "selectorKey" (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "selectorKey" ((PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EVar "file")) (EApp (EVar "lenKey") (EApp (EVar "pinKindKey") (EVar "kind")))) (EApp (EVar "lenKey") (EVar "name"))) (EApp (EVar "lenKey") (EVar "engine"))))
(DTypeSig false "pinKindKey" (TyFun (TyCon "PinKind") (TyCon "String")))
(DFunDef false "pinKindKey" ((PCon "PropPin")) (ELit (LString "prop")))
(DFunDef false "pinKindKey" ((PCon "TestPin")) (ELit (LString "test")))
(DTypeSig false "pinSelectorKey" (TyFun (TyCon "TestPin") (TyCon "String")))
(DFunDef false "pinSelectorKey" ((PVar "pin")) (EApp (EApp (EApp (EApp (EVar "selectorKey") (EFieldAccess (EVar "pin") "pinFile")) (EFieldAccess (EVar "pin") "pinKind")) (EFieldAccess (EVar "pin") "pinName")) (EFieldAccess (EVar "pin") "pinEngine")))
(DTypeSig true "buildPinIndex" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinIndex"))))
(DFunDef false "buildPinIndex" ((PVar "pins")) (EApp (EApp (EVar "buildPinIndexGo") (EVar "pins")) (EVar "omEmpty")))
(DTypeSig false "buildPinIndexGo" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "PinIndex") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinIndex")))))
(DFunDef false "buildPinIndexGo" ((PList) (PVar "index")) (EApp (EVar "Ok") (EMethodRef "index")))
(DFunDef false "buildPinIndexGo" ((PCons (PVar "pin") (PVar "rest")) (PVar "index")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "pinSelectorKey") (EVar "pin"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EMethodRef "index")) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": duplicate selector for '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' / "))) (EApp (EMethodRef "display") (EApp (EVar "pinKindKey") (EFieldAccess (EVar "pin") "pinKind")))) (ELit (LString " '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinName"))) (ELit (LString "' / "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinEngine"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "buildPinIndexGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "pin")) (EMethodRef "index"))))))))
(DTypeSig true "pinFromIndex" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TestPin"))))))))
(DFunDef false "pinFromIndex" ((PVar "index") (PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EApp (EApp (EVar "selectorKey") (EVar "file")) (EVar "kind")) (EVar "name")) (EVar "engine"))) (EMethodRef "index")))
(DTypeSig true "pinFor" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "TestPin"))))))))
(DFunDef false "pinFor" ((PVar "pins") (PVar "file") (PVar "kind") (PVar "name") (PVar "engine")) (EMatch (EApp (EVar "buildPinIndex") (EVar "pins")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "index")) () (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EMethodRef "index")) (EVar "file")) (EVar "kind")) (EVar "name")) (EVar "engine")))))
(DTypeSig false "pinNamePresent" (TyFun (TyCon "TestPin") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))
(DFunDef false "pinNamePresent" ((PVar "pin") (PVar "propNames") (PVar "testNames")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "pin") "pinName")) (EVar "propNames")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False")))) (arm (PCon "TestPin") () (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "pin") "pinName")) (EVar "testNames")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "validatePinNamesGo" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "validatePinNamesGo" ((PList) PWild PWild PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validatePinNamesGo" ((PCons (PVar "pin") (PVar "rest")) (PVar "file") (PVar "propNames") (PVar "testNames")) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")) (EApp (EApp (EApp (EVar "pinNamePresent") (EVar "pin")) (EVar "propNames")) (EVar "testNames"))) (EApp (EApp (EApp (EApp (EVar "validatePinNamesGo") (EVar "rest")) (EVar "file")) (EVar "propNames")) (EVar "testNames")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": issue #"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "pin") "pinIssue")))) (ELit (LString " pins missing "))) (EApp (EMethodRef "display") (EApp (EVar "pinKindName") (EFieldAccess (EVar "pin") "pinKind")))) (ELit (LString " '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinName"))) (ELit (LString "' in "))) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ""))))))
(DTypeSig false "pinKindName" (TyFun (TyCon "PinKind") (TyCon "String")))
(DFunDef false "pinKindName" ((PCon "PropPin")) (ELit (LString "property")))
(DFunDef false "pinKindName" ((PCon "TestPin")) (ELit (LString "test")))
(DTypeSig true "validatePinNames" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "validatePinNames" ((PVar "pins") (PVar "file") (PVar "propNames") (PVar "testNames")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "declarationIndex") (EVar "pins")) (EVar "file")) (EVar "PropPin")) (ELit (LString "property"))) (EVar "propNames"))) (ELam ((PVar "propIndex")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "declarationIndex") (EVar "pins")) (EVar "file")) (EVar "TestPin")) (ELit (LString "test"))) (EVar "testNames"))) (ELam ((PVar "testIndex")) (EApp (EApp (EApp (EApp (EVar "validatePinNamesGo") (EVar "pins")) (EVar "file")) (EVar "propIndex")) (EVar "testIndex")))))))
(DTypeSig false "declarationIndex" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))))
(DFunDef false "declarationIndex" ((PVar "pins") (PVar "file") (PVar "kind") (PVar "label") (PVar "names")) (EIf (EApp (EApp (EApp (EVar "hasSelectedPin") (EVar "pins")) (EVar "file")) (EVar "kind")) (EApp (EApp (EApp (EApp (EVar "uniqueDeclaredNames") (EVar "file")) (EVar "label")) (EVar "names")) (EVar "omEmpty")) (EApp (EVar "Ok") (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty")))))
(DTypeSig false "hasSelectedPin" (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyFun (TyCon "String") (TyFun (TyCon "PinKind") (TyCon "Bool")))))
(DFunDef false "hasSelectedPin" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "hasSelectedPin" ((PCons (PVar "pin") (PVar "rest")) (PVar "file") (PVar "kind")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")) (EBinOp "==" (EFieldAccess (EVar "pin") "pinKind") (EVar "kind"))) (EApp (EApp (EApp (EVar "hasSelectedPin") (EVar "rest")) (EVar "file")) (EVar "kind"))))
(DTypeSig false "uniqueDeclaredNames" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "uniqueDeclaredNames" (PWild PWild (PList) (PVar "seen")) (EApp (EVar "Ok") (EVar "seen")))
(DFunDef false "uniqueDeclaredNames" ((PVar "file") (PVar "kind") (PCons (PVar "name") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "pinOrigin"))) (ELit (LString ": ambiguous duplicate "))) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " declaration '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' in "))) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "uniqueDeclaredNames") (EVar "file")) (EVar "kind")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen")))))
(DTypeSig true "classifyPin" (TyFun (TyCon "TestPin") (TyFun (TyCon "PinObservation") (TyCon "PinVerdict"))))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinPassed")) (EApp (EVar "PinDrained") (EFieldAccess (EVar "pin") "pinIssue")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinLawFailure")) (EApp (EVar "classifyLawPin") (EVar "pin")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinAssertionFailure" (PVar "detail"))) (EApp (EApp (EVar "classifyAssertionPin") (EVar "pin")) (EVar "detail")))
(DFunDef false "classifyPin" ((PVar "pin") (PCon "PinRuntimeError" (PVar "detail"))) (EApp (EApp (EVar "classifyRuntimePin") (EVar "pin")) (EVar "detail")))
(DTypeSig false "classifyLawPin" (TyFun (TyCon "TestPin") (TyCon "PinVerdict")))
(DFunDef false "classifyLawPin" ((PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue"))) (arm (PCon "TestPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected an assertion failure, got a property-law failure"))))))
(DTypeSig false "classifyAssertionPin" (TyFun (TyCon "TestPin") (TyFun (TyCon "String") (TyCon "PinVerdict"))))
(DFunDef false "classifyAssertionPin" ((PVar "pin") (PVar "detail")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected a property-law failure, got an assertion failure")))) (arm (PCon "TestPin") () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectAssertion" (PVar "expected"))) () (EIf (EBinOp "==" (EVar "detail") (EVar "expected")) (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue")) (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "assertion failure detail changed"))))) (arm (PCon "Some" (PCon "ExpectError" PWild)) () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "expected a runtime error, got an assertion failure")))) (arm (PCon "None") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "test pin has no typed expected failure"))))))))
(DTypeSig false "classifyRuntimePin" (TyFun (TyCon "TestPin") (TyFun (TyCon "String") (TyCon "PinVerdict"))))
(DFunDef false "classifyRuntimePin" ((PVar "pin") (PVar "detail")) (EMatch (EFieldAccess (EVar "pin") "pinKind") (arm (PCon "PropPin") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error: ")) (EApp (EMethodRef "display") (EVar "detail"))) (ELit (LString ""))))) (arm (PCon "TestPin") () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectError" (PVar "expected"))) () (EIf (EBinOp "==" (EVar "detail") (EVar "expected")) (EApp (EVar "PinHeld") (EFieldAccess (EVar "pin") "pinIssue")) (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "runtime error detail changed"))))) (arm (PCon "Some" (PCon "ExpectAssertion" PWild)) () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error: ")) (EApp (EMethodRef "display") (EVar "detail"))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EVar "PinChanged") (EFieldAccess (EVar "pin") "pinIssue")) (ELit (LString "test pin has no typed expected failure"))))))))
(DTypeSig true "pinVerdictPassed" (TyFun (TyCon "PinVerdict") (TyCon "Bool")))
(DFunDef false "pinVerdictPassed" ((PCon "PinHeld" PWild)) (EVar "True"))
(DFunDef false "pinVerdictPassed" (PWild) (EVar "False"))
(DTypeSig true "pinVerdictDetail" (TyFun (TyCon "PinVerdict") (TyCon "String")))
(DFunDef false "pinVerdictDetail" ((PCon "PinHeld" (PVar "issue"))) (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " still holds"))))
(DFunDef false "pinVerdictDetail" ((PCon "PinDrained" (PVar "issue"))) (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " unexpected pass; remove its pin"))))
(DFunDef false "pinVerdictDetail" ((PCon "PinChanged" (PVar "issue") (PVar "detail"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red issue #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "issue")))) (ELit (LString " changed: "))) (EApp (EMethodRef "display") (EVar "detail"))) (ELit (LString ""))))
