# META
source_lines=234
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/eval_props.mdk — nonce-framed property rows for the isolated
-- interpreter-property worker.
--
-- A property body, generator, or shrinker may panic. Panics are not catchable
-- in Medaka, so test_cmd runs interpreter properties in one child per target.
-- This module owns the narrow stdout protocol between that child and its
-- parent. A fresh nonce separates ordinary target output from runner rows.

import json.{Json(..), jObject, parse, stringify, get, asInt, asString}
import support.util.{splitNl, joinNl, startsWith, anyList}
import tools.probe_transcript.{
  Chunk(..),
  chunksOf,
  mintNonce,
  noncedPrefix,
  sentinelLine,
}
import tools.prop_runner.{
  PropResult(..),
  PropStatus(..),
  PropFailureKind(..),
  PropRequest,
  propRequestName,
  propRequestSeed,
  propRequestCases,
}

bootstrapBase : String
bootstrapBase = "@@__mdk_eval_props_bootstrap__@@ "

export
startEvalPropWorker : Unit -> <IO> String
startEvalPropWorker _ =
  let nonce = mintNonce ()
  let _ = putStrLn "\{bootstrapBase}\{nonce}"
  let _ = flushStdout ()
  nonce

-- Emit the bootstrap before loading the target, and keep the nonce out of
-- argv and the environment. Framing avoids accidental output collisions;
-- property programs with OS effects remain trusted code.
export
takeEvalPropBootstrap : String -> Result String (String, String)
takeEvalPropBootstrap stdout = match splitNl stdout
  [] => Err "interpreter property worker omitted its bootstrap header"
  header :: rest =>
    if not (startsWith bootstrapBase header) then
      Err "interpreter property worker emitted a malformed bootstrap header"
    else
      let nonce =
        stringSlice (stringLength bootstrapBase) (stringLength header) header
      if nonce == "" then
        Err "interpreter property worker emitted an empty bootstrap nonce"
      else if anyList (startsWith bootstrapBase) rest then
        Err "interpreter property worker emitted a duplicate bootstrap header"
      else
        Ok (nonce, joinNl rest)

sentinelBase : String
sentinelBase = "@@__mdk_eval_props__@@"

export
sentinelPrefix : String -> String
sentinelPrefix nonce = noncedPrefix sentinelBase nonce

rowTag : Int -> String
rowTag i = "row-\{intToString i}"

endTag : String
endTag = "END"

export
emitEvalPropRows : String -> List PropResult -> <IO> Unit
emitEvalPropRows nonce rows = do
  let _ = emitRows nonce 0 rows
  let _ = putStrLn (sentinelLine (sentinelPrefix nonce) endTag)
  flushStdout ()

emitRows : String -> Int -> List PropResult -> <IO> Unit
emitRows _ _ [] = ()
emitRows nonce i (row :: rest) = do
  let _ = putStrLn (sentinelLine (sentinelPrefix nonce) (rowTag i))
  let _ = putStrLn (stringify (propResultJson row))
  let _ = flushStdout ()
  emitRows nonce (i + 1) rest

export
propResultJson : PropResult -> Json
propResultJson (PropResult engine name status failure detail seed cases) = jObject
  [
    ("engine", JString engine),
    ("name", JString name),
    ("status", JString (propStatusText status)),
    ("failureKind", propFailureKindJson failure),
    ("detail", JString detail),
    ("seed", JInt seed),
    ("cases", JInt cases),
  ]

export
propStatusText : PropStatus -> String
propStatusText PropPassedResult = "pass"
propStatusText PropFailedResult = "fail"
propStatusText PropErroredResult = "error"

export
propFailureKindJson : Option PropFailureKind -> Json
propFailureKindJson None = JNull
propFailureKindJson (Some kind) = JString (propFailureKindText kind)

export
propFailureKindText : PropFailureKind -> String
propFailureKindText PropLawFalse = "law-false"
propFailureKindText PropCapabilityError = "capability"
propFailureKindText PropBuildError = "build"
propFailureKindText PropRuntimeError = "runtime"
propFailureKindText PropProtocolError = "protocol"
propFailureKindText PropTypeError = "type"

-- Decode only an exact complete inventory. The parent knows every requested
-- name, seed and case budget before it starts the child, so accepting a
-- prefix or an unexpected row would turn a child abort into a false pass.
export
decodeEvalPropRows : String ->
  List PropRequest ->
  String ->
  Result String (List PropResult)
decodeEvalPropRows nonce requests stdout =
  let chunks = chunksOf (sentinelPrefix nonce) (splitNl stdout)
  if exactTags (expectedTags 0 requests) chunks then
    decodeRows requests chunks 0
  else
    Err
      "interpreter property worker emitted an incomplete or malformed transcript"

expectedTags : Int -> List PropRequest -> List String
expectedTags _ [] = [endTag]
expectedTags i (_ :: rest) = rowTag i :: expectedTags (i + 1) rest

exactTags : List String -> List Chunk -> Bool
exactTags [] [] = True
exactTags (expected :: rest) ((Chunk actual lines terminated) :: chunks) =
  expected == actual
    && (if expected == endTag then
      not terminated && lines == [""]
    else
      terminated)
    && exactTags rest chunks
exactTags _ _ = False

decodeRows : List PropRequest ->
  List Chunk ->
  Int ->
  Result String (List PropResult)
decodeRows [] [Chunk tag _ _] _
  | tag == endTag = Ok []
decodeRows [] _ _ = Err "interpreter property worker omitted its terminator"
decodeRows (request :: rest) ((Chunk tag lines _) :: chunks) i
  | tag /= rowTag i = Err "interpreter property worker row order changed"
  | otherwise = do
    row <- decodeRow request lines
    rows <- decodeRows rest chunks (i + 1)
    Ok (row :: rows)
decodeRows _ _ _ = Err "interpreter property worker omitted a requested row"

decodeRow : PropRequest -> List String -> Result String PropResult
decodeRow request [line] = do
  json <- parse line
  decodeResult request json
decodeRow _ _ = Err "interpreter property worker row was not one JSON value"

decodeResult : PropRequest -> Json -> Result String PropResult
decodeResult request json = do
  engine <- requiredString "engine" json
  name <- requiredString "name" json
  status <- requiredString "status" json
  failure <- requiredFailure json
  detail <- requiredString "detail" json
  seed <- requiredInt "seed" json
  cases <- requiredInt "cases" json
  if engine /= "eval" then
    Err "interpreter property worker changed a row engine"
  else if name /= propRequestName request then
    Err "interpreter property worker changed a row name"
  else if seed /= propRequestSeed request
    || cases /= propRequestCases request then
    Err "interpreter property worker changed a row replay request"
  else do
    parsedStatus <- parseStatus status
    checkedFailure <- validateFailure parsedStatus failure
    Ok (PropResult engine name parsedStatus checkedFailure detail seed cases)

requiredString : String -> Json -> Result String String
requiredString name json = match flatMap asString (get name json)
  Some value => Ok value
  None => Err "interpreter property worker row has no string \{debug name}"

requiredInt : String -> Json -> Result String Int
requiredInt name json = match flatMap asInt (get name json)
  Some value => Ok value
  None => Err "interpreter property worker row has no integer \{debug name}"

requiredFailure : Json -> Result String (Option PropFailureKind)
requiredFailure json = match get "failureKind" json
  Some JNull => Ok None
  Some (JString text) => map Some (parseFailure text)
  _ => Err "interpreter property worker row has an invalid failureKind"

parseStatus : String -> Result String PropStatus
parseStatus "pass" = Ok PropPassedResult
parseStatus "fail" = Ok PropFailedResult
parseStatus "error" = Ok PropErroredResult
parseStatus _ = Err "interpreter property worker row has an invalid status"

parseFailure : String -> Result String PropFailureKind
parseFailure "law-false" = Ok PropLawFalse
parseFailure "capability" = Ok PropCapabilityError
parseFailure "build" = Ok PropBuildError
parseFailure "runtime" = Ok PropRuntimeError
parseFailure "protocol" = Ok PropProtocolError
parseFailure "type" = Ok PropTypeError
parseFailure _ =
  Err "interpreter property worker row has an invalid failureKind"

validateFailure : PropStatus ->
  Option PropFailureKind ->
  Result String (Option PropFailureKind)
validateFailure PropPassedResult None = Ok None
validateFailure PropFailedResult (Some PropLawFalse) = Ok (Some PropLawFalse)
validateFailure PropErroredResult (Some PropLawFalse) =
  Err "interpreter property worker row has an invalid status/failureKind pair"
validateFailure PropErroredResult (Some kind) = Ok (Some kind)
validateFailure _ _ =
  Err "interpreter property worker row has an invalid status/failureKind pair"
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "parse" false) (mem "stringify" false) (mem "get" false) (mem "asInt" false) (mem "asString" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitNl" false) (mem "joinNl" false) (mem "startsWith" false) (mem "anyList" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "mintNonce" false) (mem "noncedPrefix" false) (mem "sentinelLine" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "PropRequest" false) (mem "propRequestName" false) (mem "propRequestSeed" false) (mem "propRequestCases" false))))
(DTypeSig false "bootstrapBase" (TyCon "String"))
(DFunDef false "bootstrapBase" () (ELit (LString "@@__mdk_eval_props_bootstrap__@@ ")))
(DTypeSig true "startEvalPropWorker" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "startEvalPropWorker" (PWild) (EBlock (DoLet false false (PVar "nonce") (EApp (EVar "mintNonce") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "bootstrapBase"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "nonce"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EVar "nonce"))))
(DTypeSig true "takeEvalPropBootstrap" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "takeEvalPropBootstrap" ((PVar "stdout")) (EMatch (EApp (EVar "splitNl") (EVar "stdout")) (arm (PList) () (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted its bootstrap header")))) (arm (PCons (PVar "header") (PVar "rest")) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "bootstrapBase")) (EVar "header"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted a malformed bootstrap header"))) (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "bootstrapBase"))) (EApp (EVar "stringLength") (EVar "header"))) (EVar "header"))) (DoExpr (EIf (EBinOp "==" (EVar "nonce") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted an empty bootstrap nonce"))) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "startsWith") (EVar "bootstrapBase"))) (EVar "rest")) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted a duplicate bootstrap header"))) (EApp (EVar "Ok") (ETuple (EVar "nonce") (EApp (EVar "joinNl") (EVar "rest"))))))))))))
(DTypeSig false "sentinelBase" (TyCon "String"))
(DFunDef false "sentinelBase" () (ELit (LString "@@__mdk_eval_props__@@")))
(DTypeSig true "sentinelPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelPrefix" ((PVar "nonce")) (EApp (EApp (EVar "noncedPrefix") (EVar "sentinelBase")) (EVar "nonce")))
(DTypeSig false "rowTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "rowTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "row-")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "endTag" (TyCon "String"))
(DFunDef false "endTag" () (ELit (LString "END")))
(DTypeSig true "emitEvalPropRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitEvalPropRows" ((PVar "nonce") (PVar "rows")) (ELet false PWild (EApp (EApp (EApp (EVar "emitRows") (EVar "nonce")) (ELit (LInt 0))) (EVar "rows")) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EVar "endTag"))) (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "emitRows" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitRows" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitRows" ((PVar "nonce") (PVar "i") (PCons (PVar "row") (PVar "rest"))) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "rowTag") (EVar "i")))) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EVar "stringify") (EApp (EVar "propResultJson") (EVar "row")))) (ELet false PWild (EApp (EVar "flushStdout") (ELit LUnit)) (EApp (EApp (EApp (EVar "emitRows") (EVar "nonce")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig true "propResultJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propResultJson" ((PCon "PropResult" (PVar "engine") (PVar "name") (PVar "status") (PVar "failure") (PVar "detail") (PVar "seed") (PVar "cases"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EVar "engine"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "propStatusText") (EVar "status")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EVar "failure"))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EVar "seed"))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EVar "cases"))))))
(DTypeSig true "propStatusText" (TyFun (TyCon "PropStatus") (TyCon "String")))
(DFunDef false "propStatusText" ((PCon "PropPassedResult")) (ELit (LString "pass")))
(DFunDef false "propStatusText" ((PCon "PropFailedResult")) (ELit (LString "fail")))
(DFunDef false "propStatusText" ((PCon "PropErroredResult")) (ELit (LString "error")))
(DTypeSig true "propFailureKindJson" (TyFun (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyCon "Json")))
(DFunDef false "propFailureKindJson" ((PCon "None")) (EVar "JNull"))
(DFunDef false "propFailureKindJson" ((PCon "Some" (PVar "kind"))) (EApp (EVar "JString") (EApp (EVar "propFailureKindText") (EVar "kind"))))
(DTypeSig true "propFailureKindText" (TyFun (TyCon "PropFailureKind") (TyCon "String")))
(DFunDef false "propFailureKindText" ((PCon "PropLawFalse")) (ELit (LString "law-false")))
(DFunDef false "propFailureKindText" ((PCon "PropCapabilityError")) (ELit (LString "capability")))
(DFunDef false "propFailureKindText" ((PCon "PropBuildError")) (ELit (LString "build")))
(DFunDef false "propFailureKindText" ((PCon "PropRuntimeError")) (ELit (LString "runtime")))
(DFunDef false "propFailureKindText" ((PCon "PropProtocolError")) (ELit (LString "protocol")))
(DFunDef false "propFailureKindText" ((PCon "PropTypeError")) (ELit (LString "type")))
(DTypeSig true "decodeEvalPropRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "decodeEvalPropRows" ((PVar "nonce") (PVar "requests") (PVar "stdout")) (EBlock (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "splitNl") (EVar "stdout")))) (DoExpr (EIf (EApp (EApp (EVar "exactTags") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "requests"))) (EVar "chunks")) (EApp (EApp (EApp (EVar "decodeRows") (EVar "requests")) (EVar "chunks")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted an incomplete or malformed transcript")))))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "::" (EApp (EVar "rowTag") (EVar "i")) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "exactTags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyCon "Bool"))))
(DFunDef false "exactTags" ((PList) (PList)) (EVar "True"))
(DFunDef false "exactTags" ((PCons (PVar "expected") (PVar "rest")) (PCons (PCon "Chunk" (PVar "actual") (PVar "lines") (PVar "terminated")) (PVar "chunks"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "expected") (EVar "actual")) (EIf (EBinOp "==" (EVar "expected") (EVar "endTag")) (EBinOp "&&" (EApp (EVar "not") (EVar "terminated")) (EBinOp "==" (EVar "lines") (EListLit (ELit (LString ""))))) (EVar "terminated"))) (EApp (EApp (EVar "exactTags") (EVar "rest")) (EVar "chunks"))))
(DFunDef false "exactTags" (PWild PWild) (EVar "False"))
(DTypeSig false "decodeRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "decodeRows" ((PList) (PList (PCon "Chunk" (PVar "tag") PWild PWild)) PWild) (EIf (EBinOp "==" (EVar "tag") (EVar "endTag")) (EApp (EVar "Ok") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "decodeRows" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted its terminator"))))
(DFunDef false "decodeRows" ((PCons (PVar "request") (PVar "rest")) (PCons (PCon "Chunk" (PVar "tag") (PVar "lines") PWild) (PVar "chunks")) (PVar "i")) (EIf (EBinOp "/=" (EVar "tag") (EApp (EVar "rowTag") (EVar "i"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker row order changed"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decodeRow") (EVar "request")) (EVar "lines"))) (ELam ((PVar "row")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decodeRows") (EVar "rest")) (EVar "chunks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "rows")) (EApp (EVar "Ok") (EBinOp "::" (EVar "row") (EVar "rows"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "decodeRows" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted a requested row"))))
(DTypeSig false "decodeRow" (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropResult")))))
(DFunDef false "decodeRow" ((PVar "request") (PList (PVar "line"))) (EApp (EApp (EVar "andThen") (EApp (EVar "parse") (EVar "line"))) (ELam ((PVar "json")) (EApp (EApp (EVar "decodeResult") (EVar "request")) (EVar "json")))))
(DFunDef false "decodeRow" (PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row was not one JSON value"))))
(DTypeSig false "decodeResult" (TyFun (TyCon "PropRequest") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropResult")))))
(DFunDef false "decodeResult" ((PVar "request") (PVar "json")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "engine"))) (EVar "json"))) (ELam ((PVar "engine")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "name"))) (EVar "json"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "status"))) (EVar "json"))) (ELam ((PVar "status")) (EApp (EApp (EVar "andThen") (EApp (EVar "requiredFailure") (EVar "json"))) (ELam ((PVar "failure")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "detail"))) (EVar "json"))) (ELam ((PVar "detail")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredInt") (ELit (LString "seed"))) (EVar "json"))) (ELam ((PVar "seed")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "requiredInt") (ELit (LString "cases"))) (EVar "json"))) (ELam ((PVar "cases")) (EIf (EBinOp "/=" (EVar "engine") (ELit (LString "eval"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row engine"))) (EIf (EBinOp "/=" (EVar "name") (EApp (EVar "propRequestName") (EVar "request"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row name"))) (EIf (EBinOp "||" (EBinOp "/=" (EVar "seed") (EApp (EVar "propRequestSeed") (EVar "request"))) (EBinOp "/=" (EVar "cases") (EApp (EVar "propRequestCases") (EVar "request")))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row replay request"))) (EApp (EApp (EVar "andThen") (EApp (EVar "parseStatus") (EVar "status"))) (ELam ((PVar "parsedStatus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "validateFailure") (EVar "parsedStatus")) (EVar "failure"))) (ELam ((PVar "checkedFailure")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "parsedStatus")) (EVar "checkedFailure")) (EVar "detail")) (EVar "seed")) (EVar "cases")))))))))))))))))))))))))
(DTypeSig false "requiredString" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "requiredString" ((PVar "name") (PVar "json")) (EMatch (EApp (EApp (EVar "flatMap") (EVar "asString")) (EApp (EApp (EVar "get") (EVar "name")) (EVar "json"))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker row has no string ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "name")))) (ELit (LString "")))))))
(DTypeSig false "requiredInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "requiredInt" ((PVar "name") (PVar "json")) (EMatch (EApp (EApp (EVar "flatMap") (EVar "asInt")) (EApp (EApp (EVar "get") (EVar "name")) (EVar "json"))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker row has no integer ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "name")))) (ELit (LString "")))))))
(DTypeSig false "requiredFailure" (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "PropFailureKind")))))
(DFunDef false "requiredFailure" ((PVar "json")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "failureKind"))) (EVar "json")) (arm (PCon "Some" (PCon "JNull")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PCon "JString" (PVar "text"))) () (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "parseFailure") (EVar "text")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid failureKind"))))))
(DTypeSig false "parseStatus" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropStatus"))))
(DFunDef false "parseStatus" ((PLit (LString "pass"))) (EApp (EVar "Ok") (EVar "PropPassedResult")))
(DFunDef false "parseStatus" ((PLit (LString "fail"))) (EApp (EVar "Ok") (EVar "PropFailedResult")))
(DFunDef false "parseStatus" ((PLit (LString "error"))) (EApp (EVar "Ok") (EVar "PropErroredResult")))
(DFunDef false "parseStatus" (PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status"))))
(DTypeSig false "parseFailure" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropFailureKind"))))
(DFunDef false "parseFailure" ((PLit (LString "law-false"))) (EApp (EVar "Ok") (EVar "PropLawFalse")))
(DFunDef false "parseFailure" ((PLit (LString "capability"))) (EApp (EVar "Ok") (EVar "PropCapabilityError")))
(DFunDef false "parseFailure" ((PLit (LString "build"))) (EApp (EVar "Ok") (EVar "PropBuildError")))
(DFunDef false "parseFailure" ((PLit (LString "runtime"))) (EApp (EVar "Ok") (EVar "PropRuntimeError")))
(DFunDef false "parseFailure" ((PLit (LString "protocol"))) (EApp (EVar "Ok") (EVar "PropProtocolError")))
(DFunDef false "parseFailure" ((PLit (LString "type"))) (EApp (EVar "Ok") (EVar "PropTypeError")))
(DFunDef false "parseFailure" (PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid failureKind"))))
(DTypeSig false "validateFailure" (TyFun (TyCon "PropStatus") (TyFun (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "PropFailureKind"))))))
(DFunDef false "validateFailure" ((PCon "PropPassedResult") (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "validateFailure" ((PCon "PropFailedResult") (PCon "Some" (PCon "PropLawFalse"))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "PropLawFalse"))))
(DFunDef false "validateFailure" ((PCon "PropErroredResult") (PCon "Some" (PCon "PropLawFalse"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status/failureKind pair"))))
(DFunDef false "validateFailure" ((PCon "PropErroredResult") (PCon "Some" (PVar "kind"))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "kind"))))
(DFunDef false "validateFailure" (PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status/failureKind pair"))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "parse" false) (mem "stringify" false) (mem "get" false) (mem "asInt" false) (mem "asString" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitNl" false) (mem "joinNl" false) (mem "startsWith" false) (mem "anyList" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "mintNonce" false) (mem "noncedPrefix" false) (mem "sentinelLine" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "PropRequest" false) (mem "propRequestName" false) (mem "propRequestSeed" false) (mem "propRequestCases" false))))
(DTypeSig false "bootstrapBase" (TyCon "String"))
(DFunDef false "bootstrapBase" () (ELit (LString "@@__mdk_eval_props_bootstrap__@@ ")))
(DTypeSig true "startEvalPropWorker" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "startEvalPropWorker" (PWild) (EBlock (DoLet false false (PVar "nonce") (EApp (EVar "mintNonce") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "bootstrapBase"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "nonce"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EVar "nonce"))))
(DTypeSig true "takeEvalPropBootstrap" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "takeEvalPropBootstrap" ((PVar "stdout")) (EMatch (EApp (EVar "splitNl") (EVar "stdout")) (arm (PList) () (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted its bootstrap header")))) (arm (PCons (PVar "header") (PVar "rest")) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "bootstrapBase")) (EVar "header"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted a malformed bootstrap header"))) (EBlock (DoLet false false (PVar "nonce") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "bootstrapBase"))) (EApp (EVar "stringLength") (EVar "header"))) (EVar "header"))) (DoExpr (EIf (EBinOp "==" (EVar "nonce") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted an empty bootstrap nonce"))) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "startsWith") (EVar "bootstrapBase"))) (EVar "rest")) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted a duplicate bootstrap header"))) (EApp (EVar "Ok") (ETuple (EVar "nonce") (EApp (EVar "joinNl") (EVar "rest"))))))))))))
(DTypeSig false "sentinelBase" (TyCon "String"))
(DFunDef false "sentinelBase" () (ELit (LString "@@__mdk_eval_props__@@")))
(DTypeSig true "sentinelPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelPrefix" ((PVar "nonce")) (EApp (EApp (EVar "noncedPrefix") (EVar "sentinelBase")) (EVar "nonce")))
(DTypeSig false "rowTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "rowTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "row-")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "endTag" (TyCon "String"))
(DFunDef false "endTag" () (ELit (LString "END")))
(DTypeSig true "emitEvalPropRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitEvalPropRows" ((PVar "nonce") (PVar "rows")) (ELet false PWild (EApp (EApp (EApp (EVar "emitRows") (EVar "nonce")) (ELit (LInt 0))) (EVar "rows")) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EVar "endTag"))) (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "emitRows" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitRows" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitRows" ((PVar "nonce") (PVar "i") (PCons (PVar "row") (PVar "rest"))) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EApp (EVar "sentinelLine") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "rowTag") (EVar "i")))) (ELet false PWild (EApp (EVar "putStrLn") (EApp (EVar "stringify") (EApp (EVar "propResultJson") (EVar "row")))) (ELet false PWild (EApp (EVar "flushStdout") (ELit LUnit)) (EApp (EApp (EApp (EVar "emitRows") (EVar "nonce")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig true "propResultJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "propResultJson" ((PCon "PropResult" (PVar "engine") (PVar "name") (PVar "status") (PVar "failure") (PVar "detail") (PVar "seed") (PVar "cases"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EVar "engine"))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "propStatusText") (EVar "status")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EVar "failure"))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EVar "seed"))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EVar "cases"))))))
(DTypeSig true "propStatusText" (TyFun (TyCon "PropStatus") (TyCon "String")))
(DFunDef false "propStatusText" ((PCon "PropPassedResult")) (ELit (LString "pass")))
(DFunDef false "propStatusText" ((PCon "PropFailedResult")) (ELit (LString "fail")))
(DFunDef false "propStatusText" ((PCon "PropErroredResult")) (ELit (LString "error")))
(DTypeSig true "propFailureKindJson" (TyFun (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyCon "Json")))
(DFunDef false "propFailureKindJson" ((PCon "None")) (EVar "JNull"))
(DFunDef false "propFailureKindJson" ((PCon "Some" (PVar "kind"))) (EApp (EVar "JString") (EApp (EVar "propFailureKindText") (EVar "kind"))))
(DTypeSig true "propFailureKindText" (TyFun (TyCon "PropFailureKind") (TyCon "String")))
(DFunDef false "propFailureKindText" ((PCon "PropLawFalse")) (ELit (LString "law-false")))
(DFunDef false "propFailureKindText" ((PCon "PropCapabilityError")) (ELit (LString "capability")))
(DFunDef false "propFailureKindText" ((PCon "PropBuildError")) (ELit (LString "build")))
(DFunDef false "propFailureKindText" ((PCon "PropRuntimeError")) (ELit (LString "runtime")))
(DFunDef false "propFailureKindText" ((PCon "PropProtocolError")) (ELit (LString "protocol")))
(DFunDef false "propFailureKindText" ((PCon "PropTypeError")) (ELit (LString "type")))
(DTypeSig true "decodeEvalPropRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "decodeEvalPropRows" ((PVar "nonce") (PVar "requests") (PVar "stdout")) (EBlock (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EApp (EVar "sentinelPrefix") (EVar "nonce"))) (EApp (EVar "splitNl") (EVar "stdout")))) (DoExpr (EIf (EApp (EApp (EVar "exactTags") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "requests"))) (EVar "chunks")) (EApp (EApp (EApp (EVar "decodeRows") (EVar "requests")) (EVar "chunks")) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "interpreter property worker emitted an incomplete or malformed transcript")))))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "::" (EApp (EVar "rowTag") (EVar "i")) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "exactTags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyCon "Bool"))))
(DFunDef false "exactTags" ((PList) (PList)) (EVar "True"))
(DFunDef false "exactTags" ((PCons (PVar "expected") (PVar "rest")) (PCons (PCon "Chunk" (PVar "actual") (PVar "lines") (PVar "terminated")) (PVar "chunks"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "expected") (EVar "actual")) (EIf (EBinOp "==" (EVar "expected") (EVar "endTag")) (EBinOp "&&" (EApp (EVar "not") (EVar "terminated")) (EBinOp "==" (EVar "lines") (EListLit (ELit (LString ""))))) (EVar "terminated"))) (EApp (EApp (EVar "exactTags") (EVar "rest")) (EVar "chunks"))))
(DFunDef false "exactTags" (PWild PWild) (EVar "False"))
(DTypeSig false "decodeRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "decodeRows" ((PList) (PList (PCon "Chunk" (PVar "tag") PWild PWild)) PWild) (EIf (EBinOp "==" (EVar "tag") (EVar "endTag")) (EApp (EVar "Ok") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "decodeRows" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted its terminator"))))
(DFunDef false "decodeRows" ((PCons (PVar "request") (PVar "rest")) (PCons (PCon "Chunk" (PVar "tag") (PVar "lines") PWild) (PVar "chunks")) (PVar "i")) (EIf (EBinOp "/=" (EVar "tag") (EApp (EVar "rowTag") (EVar "i"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker row order changed"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decodeRow") (EVar "request")) (EVar "lines"))) (ELam ((PVar "row")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decodeRows") (EVar "rest")) (EVar "chunks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELam ((PVar "rows")) (EApp (EVar "Ok") (EBinOp "::" (EVar "row") (EVar "rows"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "decodeRows" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker omitted a requested row"))))
(DTypeSig false "decodeRow" (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropResult")))))
(DFunDef false "decodeRow" ((PVar "request") (PList (PVar "line"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "parse") (EVar "line"))) (ELam ((PVar "json")) (EApp (EApp (EVar "decodeResult") (EVar "request")) (EVar "json")))))
(DFunDef false "decodeRow" (PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row was not one JSON value"))))
(DTypeSig false "decodeResult" (TyFun (TyCon "PropRequest") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropResult")))))
(DFunDef false "decodeResult" ((PVar "request") (PVar "json")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "engine"))) (EVar "json"))) (ELam ((PVar "engine")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "name"))) (EVar "json"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "status"))) (EVar "json"))) (ELam ((PVar "status")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "requiredFailure") (EVar "json"))) (ELam ((PVar "failure")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredString") (ELit (LString "detail"))) (EVar "json"))) (ELam ((PVar "detail")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredInt") (ELit (LString "seed"))) (EVar "json"))) (ELam ((PVar "seed")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "requiredInt") (ELit (LString "cases"))) (EVar "json"))) (ELam ((PVar "cases")) (EIf (EBinOp "/=" (EVar "engine") (ELit (LString "eval"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row engine"))) (EIf (EBinOp "/=" (EVar "name") (EApp (EVar "propRequestName") (EVar "request"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row name"))) (EIf (EBinOp "||" (EBinOp "/=" (EVar "seed") (EApp (EVar "propRequestSeed") (EVar "request"))) (EBinOp "/=" (EVar "cases") (EApp (EVar "propRequestCases") (EVar "request")))) (EApp (EVar "Err") (ELit (LString "interpreter property worker changed a row replay request"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "parseStatus") (EVar "status"))) (ELam ((PVar "parsedStatus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "validateFailure") (EVar "parsedStatus")) (EVar "failure"))) (ELam ((PVar "checkedFailure")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "parsedStatus")) (EVar "checkedFailure")) (EVar "detail")) (EVar "seed")) (EVar "cases")))))))))))))))))))))))))
(DTypeSig false "requiredString" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "requiredString" ((PVar "name") (PVar "json")) (EMatch (EApp (EApp (EDictApp "flatMap") (EVar "asString")) (EApp (EApp (EVar "get") (EVar "name")) (EVar "json"))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker row has no string ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "name")))) (ELit (LString "")))))))
(DTypeSig false "requiredInt" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "requiredInt" ((PVar "name") (PVar "json")) (EMatch (EApp (EApp (EDictApp "flatMap") (EVar "asInt")) (EApp (EApp (EVar "get") (EVar "name")) (EVar "json"))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker row has no integer ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "name")))) (ELit (LString "")))))))
(DTypeSig false "requiredFailure" (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "PropFailureKind")))))
(DFunDef false "requiredFailure" ((PVar "json")) (EMatch (EApp (EApp (EVar "get") (ELit (LString "failureKind"))) (EVar "json")) (arm (PCon "Some" (PCon "JNull")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PCon "JString" (PVar "text"))) () (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "parseFailure") (EVar "text")))) (arm PWild () (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid failureKind"))))))
(DTypeSig false "parseStatus" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropStatus"))))
(DFunDef false "parseStatus" ((PLit (LString "pass"))) (EApp (EVar "Ok") (EVar "PropPassedResult")))
(DFunDef false "parseStatus" ((PLit (LString "fail"))) (EApp (EVar "Ok") (EVar "PropFailedResult")))
(DFunDef false "parseStatus" ((PLit (LString "error"))) (EApp (EVar "Ok") (EVar "PropErroredResult")))
(DFunDef false "parseStatus" (PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status"))))
(DTypeSig false "parseFailure" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PropFailureKind"))))
(DFunDef false "parseFailure" ((PLit (LString "law-false"))) (EApp (EVar "Ok") (EVar "PropLawFalse")))
(DFunDef false "parseFailure" ((PLit (LString "capability"))) (EApp (EVar "Ok") (EVar "PropCapabilityError")))
(DFunDef false "parseFailure" ((PLit (LString "build"))) (EApp (EVar "Ok") (EVar "PropBuildError")))
(DFunDef false "parseFailure" ((PLit (LString "runtime"))) (EApp (EVar "Ok") (EVar "PropRuntimeError")))
(DFunDef false "parseFailure" ((PLit (LString "protocol"))) (EApp (EVar "Ok") (EVar "PropProtocolError")))
(DFunDef false "parseFailure" ((PLit (LString "type"))) (EApp (EVar "Ok") (EVar "PropTypeError")))
(DFunDef false "parseFailure" (PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid failureKind"))))
(DTypeSig false "validateFailure" (TyFun (TyCon "PropStatus") (TyFun (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "PropFailureKind"))))))
(DFunDef false "validateFailure" ((PCon "PropPassedResult") (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "validateFailure" ((PCon "PropFailedResult") (PCon "Some" (PCon "PropLawFalse"))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "PropLawFalse"))))
(DFunDef false "validateFailure" ((PCon "PropErroredResult") (PCon "Some" (PCon "PropLawFalse"))) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status/failureKind pair"))))
(DFunDef false "validateFailure" ((PCon "PropErroredResult") (PCon "Some" (PVar "kind"))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "kind"))))
(DFunDef false "validateFailure" (PWild PWild) (EApp (EVar "Err") (ELit (LString "interpreter property worker row has an invalid status/failureKind pair"))))
