# META
source_lines=2604
stages=DESUGAR,MARK
# SOURCE
{- | Pure, bounded HTTP/1.1 request framing and response building.

   The parser accepts exactly one complete origin-form HTTP/1.1 request. It
   preserves field order and duplicates until framing has been validated,
   keeps bodies as raw bytes, and exposes connection lifetime as plain data.
   No socket, filesystem, or other effect is involved, so a caller supplies
   the bytes and decides what to do with the frame. `net` is the socket
   layer.

   Every ceiling the framer enforces is an exported `max*` value paired with
   a `check*` predicate, so a caller can test either side of a boundary
   without building a maximum-sized request. -}

import bytebuilder.{
  Builder,
  appendBytes,
  buildArray,
  buildBytes,
  emitU8,
  newBuilder,
}
import bytes.*
import json.{Json, parse}
import list.{reverse}
import string.{fromUtf8, toUtf8}
import test.{expectEqual, expectTrue}

-- # Resource limits

{- | The ceiling on one raw request, request line and framing bytes included.

   > maxHttpRequestBytes
   6291456 -}
export
maxHttpRequestBytes : Int
maxHttpRequestBytes = 6291456

-- | The ceiling on the combined header and trailer sections of one request or
-- response.
export
maxHttpHeaderBytes : Int
maxHttpHeaderBytes = 65536

-- | The ceiling on one decoded body, after chunked transfer coding is removed.
export
maxHttpBodyBytes : Int
maxHttpBodyBytes = 5242880

-- | The ceiling on one request line.
export
maxHttpRequestLineBytes : Int
maxHttpRequestLineBytes = 8192

-- | The ceiling on one response status line.
export
maxHttpResponseStatusLineBytes : Int
maxHttpResponseStatusLineBytes = 8192

-- | The ceiling on one response chunk's declared size.
export
maxHttpResponseChunkBytes : Int
maxHttpResponseChunkBytes = 1048576

-- | The ceiling on the number of header fields in one request or response.
export
maxHttpHeaderFields : Int
maxHttpHeaderFields = 100

-- | The ceiling on the number of trailer fields in one request.
export
maxHttpTrailerFields : Int
maxHttpTrailerFields = 32

-- | The ceiling on the number of chunks in one chunked body.
export
maxHttpChunks : Int
maxHttpChunks = 65536

-- | The ceiling on a body decoded as JSON by `decodeRequestBody`.
export
maxJsonBodyBytes : Int
maxJsonBodyBytes = 153600

-- | The ceiling on a body decoded as text by `decodeRequestBody`.
export
maxTextBodyBytes : Int
maxTextBodyBytes = 102400

-- | The ceiling on a body kept as raw bytes by `decodeRequestBody`.
export
maxRawBodyBytes : Int
maxRawBodyBytes = 5242880

{- | `Ok` when `size` is within `maxHttpRequestBytes`, `Err` with the
   diagnostic the framer reports otherwise.

   > isOk (checkHttpRequestBytes maxHttpRequestBytes)
   True -}
export
checkHttpRequestBytes : Int -> Result String Unit
checkHttpRequestBytes size =
  if size > maxHttpRequestBytes then
    Err "http: request exceeds 6291456-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxHttpHeaderBytes`, `Err` with the
-- diagnostic the framer reports otherwise.
export
checkHttpHeaderBytes : Int -> Result String Unit
checkHttpHeaderBytes size =
  if size > maxHttpHeaderBytes then
    Err
      "http: combined header and trailer section exceeds 65536-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxHttpBodyBytes`, `Err` with the diagnostic
-- the framer reports otherwise.
export
checkHttpBodyBytes : Int -> Result String Unit
checkHttpBodyBytes size =
  if size > maxHttpBodyBytes then
    Err "http: decoded body exceeds 5242880-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxHttpRequestLineBytes`, `Err` with the
-- diagnostic the framer reports otherwise.
export
checkHttpRequestLineBytes : Int -> Result String Unit
checkHttpRequestLineBytes size =
  if size > maxHttpRequestLineBytes then
    Err "http: request line exceeds 8192-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxHttpResponseStatusLineBytes`.
export
checkHttpResponseStatusLineBytes : Int -> Result String Unit
checkHttpResponseStatusLineBytes size =
  if size > maxHttpResponseStatusLineBytes then
    Err "http: status line exceeds 8192-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxHttpResponseChunkBytes`.
export
checkHttpResponseChunkBytes : Int -> Result String Unit
checkHttpResponseChunkBytes size =
  if size > maxHttpResponseChunkBytes then
    Err "http: chunk size exceeds 1048576-byte resource limit"
  else
    Ok ()

-- | `Ok` when `count` is within `maxHttpHeaderFields`, `Err` with the
-- diagnostic the framer reports otherwise.
export
checkHttpHeaderFields : Int -> Result String Unit
checkHttpHeaderFields count =
  if count > maxHttpHeaderFields then
    Err "http: header field count exceeds 100 resource limit"
  else
    Ok ()

-- | `Ok` when `count` is within `maxHttpTrailerFields`, `Err` with the
-- diagnostic the framer reports otherwise.
export
checkHttpTrailerFields : Int -> Result String Unit
checkHttpTrailerFields count =
  if count > maxHttpTrailerFields then
    Err "http: trailer field count exceeds 32 resource limit"
  else
    Ok ()

-- | `Ok` when `count` is within `maxHttpChunks`, `Err` with the diagnostic
-- the framer reports otherwise.
export
checkHttpChunks : Int -> Result String Unit
checkHttpChunks count =
  if count > maxHttpChunks then
    Err "http: chunk count exceeds 65536 resource limit"
  else
    Ok ()

{- | `Ok` when `size` is within `maxJsonBodyBytes`, `Err` with the diagnostic
   `decodeRequestBody` reports otherwise.

   > isErr (checkJsonBodyBytes (maxJsonBodyBytes + 1))
   True -}
export
checkJsonBodyBytes : Int -> Result String Unit
checkJsonBodyBytes size =
  if size > maxJsonBodyBytes then
    Err "http: JSON body exceeds 153600-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxTextBodyBytes`, `Err` with the diagnostic
-- `decodeRequestBody` reports otherwise.
export
checkTextBodyBytes : Int -> Result String Unit
checkTextBodyBytes size =
  if size > maxTextBodyBytes then
    Err "http: text body exceeds 102400-byte resource limit"
  else
    Ok ()

-- | `Ok` when `size` is within `maxRawBodyBytes`, `Err` with the diagnostic
-- `decodeRequestBody` reports otherwise.
export
checkRawBodyBytes : Int -> Result String Unit
checkRawBodyBytes size =
  if size > maxRawBodyBytes then
    Err "http: raw body exceeds 5242880-byte resource limit"
  else
    Ok ()

-- # Requests

-- | An ordered HTTP field. Names are canonical lowercase ASCII; values are
-- raw bytes with surrounding optional whitespace removed.
export data Header = Header String (Array Int)

-- | A fully framed HTTP/1.1 request. Constructors stay private so callers
-- cannot manufacture a request that bypassed framing checks.
export data Request =
  | Request String String (List Header) (List Header) Bytes Bool

data RequestLine = RequestLine String String Int
data HeaderBlock = HeaderBlock (List Header) Int Int
data BodyMode = NoBody | FixedBody Int | ChunkedBody | UntilCloseBody
data ParsedBody = ParsedBody Bytes (List Header) Int

-- | The body of a request that framed no body at all.
emptyBody : Bytes
emptyBody = fromArrayAssumeByteDomain [||]

-- | Structural classification for request-framing failures. The diagnostic is
-- retained for direct parser callers, while the server can select 400 versus
-- 413 without inspecting diagnostic text.
public export data HttpParseFailure =
  | HttpMalformed String
  | HttpResourceExcess String

-- | Outcome of framing a byte buffer that may still be growing. `Incomplete`
-- carries the diagnostic the one-shot parser reports for the same input, so a
-- buffer that a stream could still complete stays distinguishable from one
-- that no further byte can rescue without changing any existing message.
data FrameError = Incomplete String | Fatal HttpParseFailure

settle : Result FrameError a -> Result HttpParseFailure a
settle (Ok value) = Ok value
settle (Err (Incomplete message)) = Err (HttpMalformed message)
settle (Err (Fatal failure)) = Err failure

malformed : String -> Result FrameError a
malformed message = Err (Fatal (HttpMalformed message))

incomplete : String -> Result FrameError a
incomplete message = Err (Incomplete message)

resourceExcess : Result String Unit -> Result FrameError Unit
resourceExcess (Ok ()) = Ok ()
resourceExcess (Err message) = Err (Fatal (HttpResourceExcess message))

-- | The diagnostic a framing failure carries, whichever class it is.
export
httpParseFailureMessage : HttpParseFailure -> String
httpParseFailureMessage (HttpMalformed message) = message
httpParseFailureMessage (HttpResourceExcess message) = message

-- | The field's canonical lowercase ASCII name.
export
headerName : Header -> String
headerName (Header name _) = name

-- | The field's raw value bytes, with surrounding optional whitespace
-- already removed. The result is a copy, so mutating it cannot reach the
-- header.
export
headerValue : Header -> Array Int
headerValue (Header _ value) = arrayCopy value

copyHeaders : List Header -> List Header
copyHeaders [] = []
copyHeaders ((Header name value) :: rest) =
  Header name (arrayCopy value) :: copyHeaders rest

-- | The request method token, exactly as it was received.
export
requestMethod : Request -> String
requestMethod (Request method _ _ _ _ _) = method

-- | The origin-form request target, still percent-encoded. `parseTargetQuery`
-- splits and decodes it.
export
requestTarget : Request -> String
requestTarget (Request _ target _ _ _ _) = target

-- | The header fields in received order, duplicates retained.
export
requestHeaders : Request -> List Header
requestHeaders (Request _ _ headers _ _ _) = copyHeaders headers

-- | The trailer fields in received order, empty for a request that was not
-- chunked.
export
requestTrailers : Request -> List Header
requestTrailers (Request _ _ _ trailers _ _) = copyHeaders trailers

-- | The decoded body bytes, with any chunked transfer coding removed. The
-- stored body is already a private copy that framing cut out of the input
-- (`bytes.slice` copies), and nothing else holds it, so this hands it out
-- rather than copying again; a caller wanting an `Array Int` writes
-- `toArray` and pays for the unpacking where it asked for it.
export
requestBody : Request -> Bytes
requestBody (Request _ _ _ _ body _) = body

-- | Length of the framed body without copying its attacker-controlled bytes.
export
requestBodyLength : Request -> Int
requestBodyLength (Request _ _ _ _ body _) = bytesLength body

-- | Whether the connection stays open after this request, as its Connection
-- field settled it.
export
requestKeepAlive : Request -> Bool
requestKeepAlive (Request _ _ _ _ _ keepAlive) = keepAlive

-- | Whether every element of `value[i, end)` is a legal 0..255 value. An
-- `Array Int` a caller supplies carries no such guarantee, so a response
-- field value and a media type are checked before they are believed. `end` is
-- a parameter rather than `arrayLength value` because a caller may mean only a
-- prefix.
validBytes : Array Int -> Int -> Int -> Bool
validBytes value i end =
  if i >= end then
    True
  else
    value[i] >= 0 && value[i] <= 255 && validBytes value (i + 1) end

lowerByte : Int -> Int
lowerByte byte = if byte >= 65 && byte <= 90 then byte + 32 else byte

lowerAscii : Array Int -> Int -> Int -> String
lowerAscii input start end =
  fromUtf8 (arrayMakeWith (end - start) (i => lowerByte input[start + i]))

-- The `*Bytes` twin of each grammar predicate below — `lowerAsciiBytes`,
-- `allTokenBytes`, `validFieldValueBytes`, `findByteBytes`,
-- `trimLeftOwsBytes`, `trimRightOwsBytes`, `skipOwsBytes`,
-- `scanTokenEndBytes` — is its body over a `Bytes` rather than an
-- `Array` of `Int`. The duplication is deliberate and temporary: `Index` is
-- resolved per element, so one shared body would have to be constrained
-- over the container and dispatch on every byte of every header scanned.
-- The `Array`-based originals stay for callers not yet migrated; B5 removes
-- them, and the duplication with them (`docs/design/BYTES-DESIGN.md`).
lowerAsciiBytes : Bytes -> Int -> Int -> String
lowerAsciiBytes input start end =
  fromUtf8 (arrayMakeWith (end - start) (i => lowerByte input[start + i]))

-- | Whether `byte` is one of HTTP's ASCII token bytes.
export
isTokenByte : Int -> Bool
isTokenByte byte =
  byte >= 48 && byte <= 57
    || byte >= 65 && byte <= 90
    || byte >= 97 && byte <= 122
    || byte == 33
    || byte == 35
    || byte == 36
    || byte == 37
    || byte == 38
    || byte == 39
    || byte == 42
    || byte == 43
    || byte == 45
    || byte == 46
    || byte == 94
    || byte == 95
    || byte == 96
    || byte == 124
    || byte == 126

allToken : Array Int -> Int -> Int -> Bool
allToken input pos end =
  if pos >= end then
    True
  else
    isTokenByte input[pos] && allToken input (pos + 1) end

allTokenBytes : Bytes -> Int -> Int -> Bool
allTokenBytes input pos end =
  if pos >= end then
    True
  else
    isTokenByte input[pos] && allTokenBytes input (pos + 1) end

isHexByte : Int -> Bool
isHexByte byte =
  byte >= 48 && byte <= 57
    || byte >= 65 && byte <= 70
    || byte >= 97 && byte <= 102

isUnreservedByte : Int -> Bool
isUnreservedByte byte =
  byte >= 48 && byte <= 57
    || byte >= 65 && byte <= 90
    || byte >= 97 && byte <= 122
    || byte == 45
    || byte == 46
    || byte == 95
    || byte == 126

isSubDelimiterByte : Int -> Bool
isSubDelimiterByte byte =
  byte == 33
    || byte == 36
    || byte == 38
    || byte == 39
    || byte == 40
    || byte == 41
    || byte == 42
    || byte == 43
    || byte == 44
    || byte == 59
    || byte == 61

validTarget : Bytes -> Int -> Int -> Bool -> Bool
validTarget input pos end query =
  if pos >= end then
    True
  else
    let byte = input[pos]
    if byte == 37 then
      pos + 2 < end
        && isHexByte input[pos + 1]
        && isHexByte input[pos + 2]
        && validTarget input (pos + 3) end query
    else
      let pchar =
        isUnreservedByte byte
          || isSubDelimiterByte byte
          || byte == 58
          || byte == 64
      if pchar || byte == 47 || query && byte == 63 then
        validTarget input (pos + 1) end query
      else if not query && byte == 63 then
        validTarget input (pos + 1) end True
      else
        False

exactAsciiAt : Bytes -> Int -> String -> Bool
exactAsciiAt input start expected =
  let wanted = toUtf8Bytes expected
  let size = bytesLength wanted
  start + size <= bytesLength input
    && slice input start (start + size) == wanted

validFieldValue : Array Int -> Int -> Int -> Bool
validFieldValue input pos end =
  if pos >= end then
    True
  else
    let byte = input[pos]
    (byte == 9 || byte >= 32 && byte /= 127)
      && validFieldValue input (pos + 1) end

validFieldValueBytes : Bytes -> Int -> Int -> Bool
validFieldValueBytes input pos end =
  if pos >= end then
    True
  else
    let byte = input[pos]
    (byte == 9 || byte >= 32 && byte /= 127)
      && validFieldValueBytes input (pos + 1) end

{- | Find `wanted` in the half-open range `value[pos, end)`. No element at or
   beyond `end` is inspected. -}
export
findByte : Array Int -> Int -> Int -> Int -> Option Int
findByte value pos end wanted =
  if pos >= end then
    None
  else if value[pos] == wanted then
    Some pos
  else
    findByte value (pos + 1) end wanted

findByteBytes : Bytes -> Int -> Int -> Int -> Option Int
findByteBytes input pos end wanted =
  if pos >= end then
    None
  else if input[pos] == wanted then
    Some pos
  else
    findByteBytes input (pos + 1) end wanted

-- | `avail` is how many bytes of `input` the caller has actually received; the
-- search runs out of input there, not at `bytesLength input`.
findCrlfChecked : String ->
  Bytes ->
  Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError Int
findCrlfChecked label input avail start pos limit =
  if pos - start > limit then
    Err (Fatal (HttpResourceExcess "http: \{label} exceeds its resource limit"))
  else if pos >= avail then
    incomplete "http: truncated \{label}; expected CRLF"
  else if input[pos] == 10 then
    malformed "http: bare LF in \{label}"
  else if input[pos] == 13 then
    -- A trailing CR is the one-shot parser's bare CR and a stream's half-read
    -- CRLF, so it keeps that diagnostic while staying completable.
    if pos + 1 >= avail then
      incomplete "http: bare CR in \{label}"
    else if input[pos + 1] /= 10 then
      malformed "http: bare CR in \{label}"
    else
      Ok pos
  else
    findCrlfChecked label input avail start (pos + 1) limit

{- | Find the CR byte of the first CRLF in the half-open range
   `input[pos, end)`. A CR at `end - 1` is not a complete CRLF. -}
export
findCrlf : Bytes -> Int -> Int -> Option Int
findCrlf input pos end =
  if pos + 1 >= end then
    None
  else if input[pos] == 13 && input[pos + 1] == 10 then
    Some pos
  else
    findCrlf input (pos + 1) end

-- | `cursor` is where the CRLF search resumes; it is `start` for a fresh scan
-- and a later, already-searched offset when a suspended scan continues.
parseRequestLine : Bytes -> Int -> Int -> Int -> Result FrameError RequestLine
parseRequestLine input avail start cursor = do
  end <- findCrlfChecked
    "request line"
    input
    avail
    start
    cursor
    maxHttpRequestLineBytes
  () <- resourceExcess (checkHttpRequestLineBytes (end - start))
  firstSpace <- match findByteBytes input start end 32
    None =>
      malformed
        "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1"
    Some pos => Ok pos
  secondSpace <- match findByteBytes input (firstSpace + 1) end 32
    None =>
      malformed
        "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1"
    Some pos => Ok pos
  if firstSpace == start || not (allTokenBytes input start firstSpace) then
    malformed "http: invalid method token"
  else if secondSpace == firstSpace + 1 then
    malformed "http: empty request target"
  else if input[firstSpace + 1] /= 47
    || not (validTarget input (firstSpace + 1) secondSpace False) then
    malformed
      "http: request target must be an origin-form ASCII target without a fragment"
  else if secondSpace + 9 /= end
    || not (exactAsciiAt input (secondSpace + 1) "HTTP/1.1") then
    malformed "http: only HTTP/1.1 requests are supported"
  else
    Ok
      (RequestLine
        (fromUtf8Bytes (slice input start firstSpace))
        (fromUtf8Bytes (slice input (firstSpace + 1) secondSpace))
        (end + 2))

-- | Skip optional whitespace in the half-open range `value[pos, end)`.
export
trimLeftOws : Array Int -> Int -> Int -> Int
trimLeftOws value pos end =
  if pos < end && (value[pos] == 32 || value[pos] == 9) then
    trimLeftOws value (pos + 1) end
  else
    pos

trimLeftOwsBytes : Bytes -> Int -> Int -> Int
trimLeftOwsBytes input pos end =
  if pos < end && (input[pos] == 32 || input[pos] == 9) then
    trimLeftOwsBytes input (pos + 1) end
  else
    pos

-- | Trim optional whitespace from the right edge of `value[start, end)`.
export
trimRightOws : Array Int -> Int -> Int -> Int
trimRightOws value start end =
  if end > start && (value[end - 1] == 32 || value[end - 1] == 9) then
    trimRightOws value start (end - 1)
  else
    end

trimRightOwsBytes : Bytes -> Int -> Int -> Int
trimRightOwsBytes input start end =
  if end > start && (input[end - 1] == 32 || input[end - 1] == 9) then
    trimRightOwsBytes input start (end - 1)
  else
    end

parseHeaderLine : Bytes -> Int -> Int -> Result FrameError Header
parseHeaderLine input start end =
  if input[start] == 32 || input[start] == 9 then
    malformed "http: obsolete folded header lines are forbidden"
  else match findByteBytes input start end 58
    None => malformed "http: malformed header field; missing colon"
    Some colon =>
      if colon == start || not (allTokenBytes input start colon) then
        malformed "http: invalid header field name"
      else if not (validFieldValueBytes input (colon + 1) end) then
        malformed "http: control byte in header field value"
      else
        let valueStart = trimLeftOwsBytes input (colon + 1) end
        let valueEnd = trimRightOwsBytes input valueStart end
        Ok
          (Header
            (lowerAsciiBytes input start colon)
            (toArray (slice input valueStart valueEnd)))

forbiddenTrailer : Header -> Bool
forbiddenTrailer (Header name _) =
  name == "content-length"
    || name == "transfer-encoding"
    || name == "trailer"
    || name == "host"
    || name == "connection"

checkFieldCount : Bool -> Int -> Result FrameError Unit
checkFieldCount trailer count =
  if trailer then
    resourceExcess (checkHttpTrailerFields count)
  else
    resourceExcess (checkHttpHeaderFields count)

-- | One field line of a header or trailer section. `FieldDone` reports the
-- index past the section's blank line and the section's accumulated byte count.
data FieldStep = FieldDone Int Int | FieldMore Header Int

-- | Frame exactly one field line. This is the single place a field line's
-- extent and legality are decided, so the one-shot fold below and the
-- resumable scan further down cannot disagree about where a section ends.
-- `cursor` resumes an interrupted CRLF search; it is `pos` for a fresh line.
fieldStep : Bytes ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Result FrameError FieldStep
fieldStep input avail pos cursor sectionStart priorBytes count trailer = do
  end <- findCrlfChecked
    (if trailer then "trailer field" else "header field")
    input
    avail
    pos
    cursor
    maxHttpHeaderBytes
  let next = end + 2
  let totalBytes = priorBytes + next - sectionStart
  () <- resourceExcess (checkHttpHeaderBytes totalBytes)
  if end == pos then
    Ok (FieldDone next totalBytes)
  else do
    () <- checkFieldCount trailer (count + 1)
    field <- parseHeaderLine input pos end
    if trailer && forbiddenTrailer field then
      malformed "http: forbidden framing or routing field in trailer"
    else
      Ok (FieldMore field next)

parseFieldsChecked : Bytes ->
  Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  List Header ->
  Result FrameError HeaderBlock
parseFieldsChecked input pos sectionStart priorBytes count trailer acc = do
  step <- fieldStep
    input
    (bytesLength input)
    pos
    pos
    sectionStart
    priorBytes
    count
    trailer
  match step
    FieldDone next totalBytes => Ok (HeaderBlock (reverse acc) next totalBytes)
    FieldMore field next =>
      parseFieldsChecked
        input
        next
        sectionStart
        priorBytes
        (count + 1)
        trailer
        (field :: acc)

{- | Parse a complete header or trailer section beginning at `pos`. Fields
   retain their received order and duplicates, names are lowercased, and
   surrounding optional whitespace is removed from values. When `trailer` is
   `True`, framing and routing fields forbidden in trailers are rejected.
   The returned offset is just past the section's empty-line CRLF. -}
export
parseFields : Bytes -> Int -> Bool -> Result HttpParseFailure (List Header, Int)
parseFields input pos trailer =
  map
    ((HeaderBlock fields next _) => (fields, next))
    (settle (parseFieldsChecked input pos pos 0 0 trailer []))

countNamed : String -> List Header -> Int
countNamed _ [] = 0
countNamed wanted ((Header name _) :: rest) =
  (if name == wanted then 1 else 0) + countNamed wanted rest

findNamed : String -> List Header -> Option (Array Int)
findNamed _ [] = None
findNamed wanted ((Header name value) :: rest) =
  if name == wanted then Some value else findNamed wanted rest

asciiEqualCiGo : Array Int -> Array Int -> Int -> Bool
asciiEqualCiGo value expected i =
  if i >= arrayLength value then
    i == arrayLength expected
  else
    i < arrayLength expected
      && value[i] <= 127
      && lowerByte value[i] == lowerByte expected[i]
      && asciiEqualCiGo value expected (i + 1)

asciiEqualCi : Array Int -> String -> Bool
asciiEqualCi value expected = asciiEqualCiGo value (toUtf8 expected) 0

parseDecimalGo : Array Int -> Int -> Int -> Result FrameError Int
parseDecimalGo value i acc =
  if i >= arrayLength value then
    Ok acc
  else
    let byte = value[i]
    if byte < 48 || byte > 57 then
      malformed "http: invalid Content-Length"
    else
      let digit = byte - 48
      if acc > (4611686018427387903 - digit) / 10 then
        malformed "http: Content-Length overflows Int"
      else
        parseDecimalGo value (i + 1) (acc * 10 + digit)

parseContentLength : Array Int -> Result FrameError Int
parseContentLength value =
  if arrayLength value == 0 then
    malformed "http: empty Content-Length"
  else do
    size <- parseDecimalGo value 0 0
    () <- resourceExcess (checkHttpBodyBytes size)
    Ok size

selectBodyMode : List Header -> Result FrameError BodyMode
selectBodyMode headers =
  let clCount = countNamed "content-length" headers
  let teCount = countNamed "transfer-encoding" headers
  if clCount > 1 then
    malformed "http: duplicate Content-Length is ambiguous"
  else if clCount > 0 && teCount > 0 then
    malformed "http: Transfer-Encoding with Content-Length is ambiguous"
  else if teCount > 0 then
    if teCount /= 1 then
      malformed "http: repeated Transfer-Encoding is unsupported"
    else match findNamed "transfer-encoding" headers
      Some value =>
        if asciiEqualCi value "chunked" then
          Ok ChunkedBody
        else
          malformed
            "http: unsupported transfer coding; expected exactly chunked"
      None => malformed "http: internal transfer framing error"
  else if clCount == 1 then match findNamed "content-length" headers
    Some value => map FixedBody (parseContentLength value)
    None => malformed "http: internal content framing error"
  else
    Ok NoBody

scanTokenEnd : Array Int -> Int -> Int -> Int
scanTokenEnd value pos end =
  if pos < end && isTokenByte value[pos] then
    scanTokenEnd value (pos + 1) end
  else
    pos

scanTokenEndBytes : Bytes -> Int -> Int -> Int
scanTokenEndBytes input pos end =
  if pos < end && isTokenByte input[pos] then
    scanTokenEndBytes input (pos + 1) end
  else
    pos

parseConnectionValue : Array Int -> Int -> Bool -> Result FrameError Bool
parseConnectionValue value pos sawClose =
  let end = arrayLength value
  let start = trimLeftOws value pos end
  if start >= end then
    malformed "http: empty token in Connection field"
  else
    let tokenEnd = scanTokenEnd value start end
    if tokenEnd == start then
      malformed "http: invalid Connection token"
    else
      let closeNow = sawClose || lowerAscii value start tokenEnd == "close"
      let after = trimLeftOws value tokenEnd end
      if after == end then
        Ok closeNow
      else if value[after] /= 44 then
        malformed "http: invalid Connection token list"
      else
        parseConnectionValue value (after + 1) closeNow

keepAliveFromHeaders : List Header -> Result FrameError Bool
keepAliveFromHeaders [] = Ok True
keepAliveFromHeaders ((Header name value) :: rest) = do
  restKeepAlive <- keepAliveFromHeaders rest
  if name /= "connection" then
    Ok restKeepAlive
  else do
    closes <- parseConnectionValue value 0 False
    Ok (restKeepAlive && not closes)

validRegName : Array Int -> Int -> Int -> Bool
validRegName value pos end =
  if pos >= end then
    True
  else
    let byte = value[pos]
    if byte == 37 then
      pos + 2 < end
        && isHexByte value[pos + 1]
        && isHexByte value[pos + 2]
        && validRegName value (pos + 3) end
    else
      (isUnreservedByte byte || isSubDelimiterByte byte)
        && validRegName value (pos + 1) end

allDigits : Array Int -> Int -> Int -> Bool
allDigits value pos end =
  if pos >= end then
    True
  else
    value[pos] >= 48 && value[pos] <= 57 && allDigits value (pos + 1) end

decimalValue : Array Int -> Int -> Int -> Int -> Int
decimalValue value pos end acc =
  if pos >= end then
    acc
  else
    decimalValue value (pos + 1) end (acc * 10 + value[pos] - 48)

validIpv4 : Array Int -> Int -> Int -> Int -> Bool
validIpv4 value start end parts =
  if parts >= 4 || start >= end then
    False
  else
    let dot = match findByte value start end 46
      None => end
      Some pos => pos
    let size = dot - start
    let validPart =
      size >= 1
        && size <= 3
        && allDigits value start dot
        && decimalValue value start dot 0 <= 255
        && (size == 1 || value[start] /= 48)
    if not validPart then
      False
    else if dot == end then
      parts == 3
    else
      validIpv4 value (dot + 1) end (parts + 1)

allHex : Array Int -> Int -> Int -> Bool
allHex value pos end =
  if pos >= end then
    True
  else
    isHexByte value[pos] && allHex value (pos + 1) end

validIpv6Go : Array Int -> Int -> Int -> Int -> Bool -> Bool
validIpv6Go value pos end groups compressed =
  if pos >= end then
    if compressed then groups < 8 else groups == 8
  else
    let colon = match findByte value pos end 58
      None => end
      Some at => at
    if colon == pos then
      False
    else
      let dot = findByte value pos colon 46
      let componentGroups = match dot
        None => if colon - pos <= 4 && allHex value pos colon then 1 else 9
        Some _ => if colon == end && validIpv4 value pos colon 0 then 2 else 9
      let nextGroups = groups + componentGroups
      if nextGroups > 8 then
        False
      else if colon == end then
        if compressed then nextGroups < 8 else nextGroups == 8
      else if colon + 1 < end && value[colon + 1] == 58 then
        not compressed && validIpv6Go value (colon + 2) end nextGroups True
      else
        validIpv6Go value (colon + 1) end nextGroups compressed

validIpv6 : Array Int -> Int -> Int -> Bool
validIpv6 value start end =
  if start >= end then
    False
  else if value[start] == 58 then
    start + 1 < end
      && value[start + 1] == 58
      && validIpv6Go value (start + 2) end 0 True
  else
    validIpv6Go value start end 0 False

scanHex : Array Int -> Int -> Int -> Int
scanHex value pos end =
  if pos < end && isHexByte value[pos] then scanHex value (pos + 1) end else pos

validIpvFutureTail : Array Int -> Int -> Int -> Bool
validIpvFutureTail value pos end =
  if pos >= end then
    True
  else
    let byte = value[pos]
    (isUnreservedByte byte || isSubDelimiterByte byte || byte == 58)
      && validIpvFutureTail value (pos + 1) end

validIpvFuture : Array Int -> Int -> Int -> Bool
validIpvFuture value start end =
  if start >= end || value[start] /= 118 && value[start] /= 86 then
    False
  else
    let versionEnd = scanHex value (start + 1) end
    versionEnd > start + 1
      && versionEnd < end
      && value[versionEnd] == 46
      && versionEnd + 1 < end
      && validIpvFutureTail value (versionEnd + 1) end

validIpLiteral : Array Int -> Int -> Int -> Bool
validIpLiteral value start end =
  validIpv6 value start end || validIpvFuture value start end

validHostAuthority : Array Int -> Bool
validHostAuthority value =
  let end = arrayLength value
  if end == 0 then
    False
  else if value[0] == 91 then match findByte value 1 end 93
    None => False
    Some close =>
      validIpLiteral value 1 close
        && (close + 1 == end
          || close + 1 < end
            && value[close + 1] == 58
            && allDigits value (close + 2) end)
  else match findByte value 0 end 58
    None => validRegName value 0 end
    Some colon =>
      colon > 0 && validRegName value 0 colon && allDigits value (colon + 1) end

validateHost : List Header -> Result FrameError Unit
validateHost headers =
  if countNamed "host" headers /= 1 then
    malformed "http: HTTP/1.1 requires exactly one Host field"
  else match findNamed "host" headers
    Some value =>
      if not (validHostAuthority value) then
        malformed "http: Host field must contain a valid authority"
      else
        Ok ()
    None => malformed "http: missing Host field"

-- | The `size` bytes at `pos`, or the truncation the buffer ran out at. The
-- diagnostic names the buffer's own end, which is the earliest byte a later
-- read can supply.
readSliceAt : Bytes -> Int -> Int -> Result FrameError (Bytes, Int)
readSliceAt input pos size =
  let avail = bytesLength input
  if pos + size > avail then
    incomplete "http: truncated body at byte \{intToString avail}"
  else
    Ok (slice input pos (pos + size), pos + size)

emitArray : Array Int -> Int -> Builder -> Unit
emitArray bytes i out =
  if i >= arrayLength bytes then
    ()
  else
    emitU8 bytes[i] out
    emitArray bytes (i + 1) out

-- | Decode one ASCII hexadecimal digit.
export
hexDigit : Int -> Option Int
hexDigit byte =
  if byte >= 48 && byte <= 57 then
    Some (byte - 48)
  else if byte >= 65 && byte <= 70 then
    Some (byte - 55)
  else if byte >= 97 && byte <= 102 then
    Some (byte - 87)
  else
    None

parseHexSizeGo : Bytes -> Int -> Int -> Int -> Result FrameError Int
parseHexSizeGo input pos end acc =
  if pos >= end then
    Ok acc
  else match hexDigit input[pos]
    None => malformed "http: invalid chunk size"
    Some digit =>
      if acc > (maxHttpBodyBytes - digit) / 16 then
        Err
          (Fatal
            (HttpResourceExcess "http: chunk size exceeds decoded body limit"))
      else
        parseHexSizeGo input (pos + 1) end (acc * 16 + digit)

-- | Skip optional whitespace in the half-open range `value[pos, end)`.
export
skipOws : Array Int -> Int -> Int -> Int
skipOws value pos end =
  if pos < end && (value[pos] == 32 || value[pos] == 9) then
    skipOws value (pos + 1) end
  else
    pos

skipOwsBytes : Bytes -> Int -> Int -> Int
skipOwsBytes input pos end =
  if pos < end && (input[pos] == 32 || input[pos] == 9) then
    skipOwsBytes input (pos + 1) end
  else
    pos

scanQuoted : Bytes -> Int -> Int -> Result FrameError Int
scanQuoted input pos end =
  if pos >= end then
    malformed "http: unterminated quoted chunk extension"
  else if input[pos] == 34 then
    Ok (pos + 1)
  else if input[pos] == 92 then
    if pos + 1 >= end then
      malformed "http: truncated quoted-pair in chunk extension"
    else
      let escaped = input[pos + 1]
      if escaped == 9 || escaped == 32 || escaped >= 33 && escaped /= 127 then
        scanQuoted input (pos + 2) end
      else
        malformed "http: control byte in quoted chunk extension"
  else
    let byte = input[pos]
    if byte == 9
      || byte == 32
      || byte >= 33 && byte /= 34 && byte /= 92 && byte /= 127 then
      scanQuoted input (pos + 1) end
    else
      malformed "http: control byte in quoted chunk extension"

parseChunkExtensionValue : Bytes -> Int -> Int -> Result FrameError Int
parseChunkExtensionValue input pos end =
  if pos >= end then
    malformed "http: missing chunk extension value"
  else if input[pos] == 34 then
    scanQuoted input (pos + 1) end
  else
    let valueEnd = scanTokenEndBytes input pos end
    if valueEnd == pos then
      malformed "http: invalid chunk extension value"
    else
      Ok valueEnd

parseChunkExtensionsGo : Bytes -> Int -> Int -> Result FrameError Unit
parseChunkExtensionsGo input pos end =
  let start = skipOwsBytes input pos end
  if start == end then
    Ok ()
  else if input[start] /= 59 then
    malformed "http: invalid chunk extension separator"
  else
    let nameStart = skipOwsBytes input (start + 1) end
    let nameEnd = scanTokenEndBytes input nameStart end
    if nameEnd == nameStart then
      malformed "http: empty chunk extension name"
    else
      let afterName = skipOwsBytes input nameEnd end
      if afterName < end && input[afterName] == 61 then do
        valueEnd <- parseChunkExtensionValue
          input
          (skipOwsBytes input (afterName + 1) end)
          end
        parseChunkExtensionsGo input valueEnd end
      else
        parseChunkExtensionsGo input afterName end

parseChunkSize : Bytes -> Int -> Int -> Result FrameError Int
parseChunkSize input start end =
  let semi = match findByteBytes input start end 59
    None => end
    Some pos => pos
  if semi == start then
    malformed "http: empty chunk size"
  else do
    size <- parseHexSizeGo input start semi 0
    () <- parseChunkExtensionsGo input semi end
    Ok size

parseChunkedChecked : Bytes ->
  Int ->
  Int ->
  Builder ->
  Int ->
  Int ->
  Result FrameError ParsedBody
parseChunkedChecked input pos headerBytes out total count = do
  head <- chunkHeadStep input (bytesLength input) pos pos total count
  match head
    ChunkEnd dataPos => do
      (HeaderBlock trailers finalPos _) <- parseFieldsChecked
        input
        dataPos
        dataPos
        headerBytes
        0
        True
        []
      Ok (ParsedBody (buildBytes out) trailers finalPos)
    ChunkBody dataPos size => do
      (chunk, _) <- readSliceAt input dataPos size
      next <- chunkDataEnd input (bytesLength input) dataPos size
      let () = appendBytes chunk out
      parseChunkedChecked input next headerBytes out (total + size) (count + 1)

{- | Decode one complete chunked body beginning at `pos`. The result contains
   the decoded bytes, retained trailer fields, and the offset just past the
   terminating trailer section. Per-chunk, decoded-body, chunk-count, trailer,
   and framing ceilings are enforced before the result is returned. -}
export
parseChunked : Bytes -> Int -> Result HttpParseFailure (Bytes, List Header, Int)
parseChunked input pos =
  map
    ((ParsedBody body trailers next) => (body, trailers, next))
    (settle (parseChunkedChecked input pos 0 (newBuilder ()) 0 0))

-- | The head of one chunk: either the terminating zero-size chunk, whose data
-- position starts the trailer section, or a data chunk of that size.
data ChunkHead = ChunkEnd Int | ChunkBody Int Int

-- | Frame one chunk's size line and apply the chunk-count and decoded-size
-- ceilings. Shared by the decoding fold above and the resumable scan, so a
-- chunk's extent has one definition. `cursor` resumes an interrupted search.
chunkHeadStep : Bytes ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError ChunkHead
chunkHeadStep input avail pos cursor total count = do
  lineEnd <- findCrlfChecked
    "chunk-size line"
    input
    avail
    pos
    cursor
    maxHttpHeaderBytes
  size <- parseChunkSize input pos lineEnd
  let dataPos = lineEnd + 2
  if size == 0 then
    Ok (ChunkEnd dataPos)
  else do
    () <- resourceExcess (checkHttpChunks (count + 1))
    if size > maxHttpBodyBytes - total then
      Err
        (Fatal
          (HttpResourceExcess
            "http: decoded chunked body exceeds resource limit"))
    else
      Ok (ChunkBody dataPos size)

-- | Where the chunk whose data starts at `dataPos` ends, CRLF included. The
-- truncation diagnostic matches `readSliceAt`'s so that framing the chunk and
-- decoding it report the same shortfall.
chunkDataEnd : Bytes -> Int -> Int -> Int -> Result FrameError Int
chunkDataEnd input avail dataPos size =
  let afterChunk = dataPos + size
  if afterChunk > avail then
    incomplete "http: truncated body at byte \{intToString avail}"
  else if afterChunk + 2 > avail then
    incomplete "http: truncated CRLF after chunk data"
  else if input[afterChunk] /= 13 || input[afterChunk + 1] /= 10 then
    malformed "http: missing CRLF after chunk data"
  else
    Ok (afterChunk + 2)

-- | Frame the body and report the index one past its last byte. Bytes beyond
-- that index belong to whatever follows the request, so rejecting them is the
-- one-shot parser's job rather than the body framer's.
parseBody : BodyMode -> Bytes -> Int -> Int -> Result FrameError ParsedBody
parseBody NoBody _ pos _ = Ok (ParsedBody emptyBody [] pos)
parseBody (FixedBody size) input pos _ = do
  (body, finalPos) <- readSliceAt input pos size
  Ok (ParsedBody body [] finalPos)
parseBody ChunkedBody input pos headerBytes =
  parseChunkedChecked input pos headerBytes (newBuilder ()) 0 0
parseBody UntilCloseBody input pos _ =
  Ok (ParsedBody (slice input pos (bytesLength input)) [] (bytesLength input))

-- | The diagnostic each body mode reports for bytes past its own frame.
trailingMessage : BodyMode -> String
trailingMessage NoBody = "http: unframed or trailing request bytes"
trailingMessage (FixedBody _) = "http: bytes after framed fixed-length request"
trailingMessage ChunkedBody = "http: bytes after framed chunked request"

data FramedRequest = FramedRequest Request BodyMode Int

-- | Everything the header section settled: the request line, its fields, the
-- body framing they select, where the body starts and how many bytes the
-- section spent. None of it can change once the blank line has arrived.
data FrameHead = FrameHead RequestLine (List Header) BodyMode Bool Int Int

-- | A fully framed request span: its head plus the index one past its last
-- byte. The body bytes are not part of it, so framing a span costs nothing
-- proportional to the body.
data FrameSpan = FrameSpan FrameHead Int

headHeaderBytes : FrameHead -> Int
headHeaderBytes (FrameHead _ _ _ _ _ headerBytes) = headerBytes

requestLineHeaderPos : RequestLine -> Int
requestLineHeaderPos (RequestLine _ _ headerPos) = headerPos

-- | Where the body of a request whose head is framed can still be growing.
data BodyPhase =
  | BodyUntil Int
  | BodyChunkSize Int Int Int Int
  | BodyChunkData Int Int Int Int
  | BodyTrailers Int Int Int Int

-- | Where a scan of a still-growing buffer suspended. Each phase is a point at
-- which only later bytes can change the verdict, so resuming there and
-- scanning the whole buffer afresh reach the same answer.
data ScanPhase =
  | PhaseLine Int
  | PhaseFields RequestLine (List Header) Int Int Int
  | PhaseBody FrameHead BodyPhase

-- | The three ways a scan ends. `ScanSuspend` carries the diagnostic the
-- one-shot parser reports for the same buffer, so nothing about a message
-- depends on whether the scan was resumed.
data ScanOutcome =
  | ScanSuspend String ScanPhase
  | ScanFatal HttpParseFailure
  | ScanFramed FrameSpan

-- | Where an interrupted CRLF search resumes. A search only ever runs out of
-- input at the buffer's end, and it stops one byte early on a trailing CR, so
-- the last byte read is the earliest offset a later read must reconsider.
crlfResume : Int -> Int -> Int
crlfResume avail lineStart = max lineStart (avail - 1)

buildHead : RequestLine ->
  List Header ->
  Int ->
  Int ->
  Result FrameError FrameHead
buildHead line headers bodyPos headerBytes = do
  () <- validateHost headers
  mode <- selectBodyMode headers
  keepAlive <- keepAliveFromHeaders headers
  Ok (FrameHead line headers mode keepAlive bodyPos headerBytes)

headBodyPhase : FrameHead -> BodyPhase
headBodyPhase (FrameHead _ _ NoBody _ bodyPos _) = BodyUntil bodyPos
headBodyPhase (FrameHead _ _ (FixedBody size) _ bodyPos _) =
  BodyUntil (bodyPos + size)
headBodyPhase (FrameHead _ _ ChunkedBody _ bodyPos _) =
  BodyChunkSize bodyPos 0 0 bodyPos

scanBody : Bytes -> Int -> FrameHead -> BodyPhase -> ScanOutcome
scanBody _ avail head (BodyUntil finalPos) =
  if finalPos <= avail then
    ScanFramed (FrameSpan head finalPos)
  else
    ScanSuspend
      "http: truncated body at byte \{intToString avail}"
      (PhaseBody head (BodyUntil finalPos))
scanBody input avail head (BodyChunkSize chunkPos total count cursor) =
  match chunkHeadStep input avail chunkPos (max chunkPos cursor) total count
    Err (Incomplete message) =>
      ScanSuspend
        message
        (PhaseBody
          head
          (BodyChunkSize chunkPos total count (crlfResume avail chunkPos)))
    Err (Fatal failure) => ScanFatal failure
    Ok (ChunkEnd dataPos) =>
      scanBody input avail head (BodyTrailers dataPos dataPos 0 dataPos)
    Ok (ChunkBody dataPos size) =>
      scanBody input avail head (BodyChunkData dataPos size total count)
scanBody input avail head (BodyChunkData dataPos size total count) =
  match chunkDataEnd input avail dataPos size
    Err (Incomplete message) =>
      ScanSuspend
        message
        (PhaseBody head (BodyChunkData dataPos size total count))
    Err (Fatal failure) => ScanFatal failure
    Ok next =>
      scanBody
        input
        avail
        head
        (BodyChunkSize next (total + size) (count + 1) next)
scanBody input avail head (BodyTrailers sectionStart pos count cursor) =
  let step =
    fieldStep
      input
      avail
      pos
      (max pos cursor)
      sectionStart
      (headHeaderBytes head)
      count
      True
  match step
    Err (Incomplete message) =>
      ScanSuspend
        message
        (PhaseBody
          head
          (BodyTrailers sectionStart pos count (crlfResume avail pos)))
    Err (Fatal failure) => ScanFatal failure
    Ok (FieldMore _ next) =>
      scanBody
        input
        avail
        head
        (BodyTrailers sectionStart next (count + 1) next)
    Ok (FieldDone finalPos _) => ScanFramed (FrameSpan head finalPos)

-- | Advance a scan of the request starting at `start` from `phase`. Every
-- framing decision in this module is taken here or in a step this calls, so
-- the resumable scanner and the one-shot parser are the same framer.
scanFrom : Bytes -> Int -> Int -> ScanPhase -> ScanOutcome
scanFrom input avail start (PhaseLine cursor) =
  match parseRequestLine input avail start (max start cursor)
    Err (Incomplete message) =>
      ScanSuspend message (PhaseLine (crlfResume avail start))
    Err (Fatal failure) => ScanFatal failure
    Ok line =>
      let headerPos = requestLineHeaderPos line
      scanFrom input avail start (PhaseFields line [] headerPos 0 headerPos)
scanFrom input avail start (PhaseFields line acc pos count cursor) =
  let step =
    fieldStep
      input
      avail
      pos
      (max pos cursor)
      (requestLineHeaderPos line)
      0
      count
      False
  match step
    Err (Incomplete message) =>
      ScanSuspend
        message
        (PhaseFields line acc pos count (crlfResume avail pos))
    Err (Fatal failure) => ScanFatal failure
    Ok (FieldMore field next) =>
      scanFrom
        input
        avail
        start
        (PhaseFields line (field :: acc) next (count + 1) next)
    Ok (FieldDone bodyPos headerBytes) =>
      match settle (buildHead line (reverse acc) bodyPos headerBytes)
        Err failure => ScanFatal failure
        Ok head => scanBody input avail head (headBodyPhase head)
scanFrom input avail _ (PhaseBody head phase) = scanBody input avail head phase

frameSpanAt : Bytes -> Int -> Result FrameError FrameSpan
frameSpanAt input start =
  let outcome = scanFrom input (bytesLength input) start (PhaseLine start)
  match outcome
    ScanSuspend message _ => Err (Incomplete message)
    ScanFatal failure => Err (Fatal failure)
    ScanFramed span => Ok span

-- | Collect the body of an already-framed span. The span fixed where the
-- request ends, so this only has to produce the bytes and trailers inside it.
frameFromSpan : Bytes -> FrameHead -> Int -> Result FrameError FramedRequest
frameFromSpan input (FrameHead (RequestLine method target _) headers mode keepAlive bodyPos headerBytes) finalPos =
  do
    (ParsedBody body trailers _) <- parseBody mode input bodyPos headerBytes
    Ok
      (FramedRequest
        (Request method target headers trailers body keepAlive)
        mode
        finalPos)

frameRequestAt : Bytes -> Int -> Result FrameError FramedRequest
frameRequestAt input start = do
  (FrameSpan head finalPos) <- frameSpanAt input start
  frameFromSpan input head finalPos

parseWholeBuffer : Bytes -> Result FrameError Request
parseWholeBuffer input = do
  () <- resourceExcess (checkHttpRequestBytes (bytesLength input))
  (FramedRequest request mode finalPos) <- frameRequestAt input 0
  if finalPos /= bytesLength input then
    malformed (trailingMessage mode)
  else
    Ok request

-- | Parse one complete request while preserving structural failure class.
export
parseRequestClassified : Bytes -> Result HttpParseFailure Request
parseRequestClassified input = settle (parseWholeBuffer input)

-- # Incremental framing

-- | Where a scan over a byte buffer stopped. `HttpNeedMore` is the one verdict
-- more bytes can change; `HttpFramedAt` reports the index one past the last
-- byte of the framed request, which is where the next one begins.
public export data HttpFrame =
  | HttpNeedMore
  | HttpFramedAt Int
  | HttpFrameFailed HttpParseFailure

requestBytesVerdict : Int -> HttpFrame -> HttpFrame
requestBytesVerdict size framed = match checkHttpRequestBytes size
  Ok () => framed
  Err message => HttpFrameFailed (HttpResourceExcess message)

{- | How far a scan of a growing buffer has already got. The type is opaque:
   a caller obtains one from `httpScanStart`, hands it back to
   `scanRequestBoundaryFrom` with the same request `start` and a buffer that has
   only grown at its end, and gets a fresh one to carry to the next read.

   A state is only meaningful for the buffer prefix it was produced from. Any
   other buffer, or a different `start`, needs `httpScanStart` again, which is
   what a caller does at a request boundary, since the next request is a new
   scan. Nothing is lost by starting over: a fresh state reaches exactly the
   verdict a resumed one does. -}
export data HttpScan = HttpScan ScanPhase

-- | A scan that has read nothing.
export
httpScanStart : HttpScan
httpScanStart = HttpScan (PhaseLine 0)

{- | Whether a scan that has not yet framed a request is still inside the
   request line or the header fields, meaning the request's header section has
   not been terminated. Only this module can answer it, the scan's phase being
   private, so a caller that budgets the header phase apart from the body has
   no other way to tell the two apart. A scan that already framed a request
   reports False: its header section ended. -}
export
httpScanInHeaders : HttpScan -> Bool
httpScanInHeaders (HttpScan (PhaseLine _)) = True
httpScanInHeaders (HttpScan (PhaseFields _ _ _ _ _)) = True
httpScanInHeaders (HttpScan (PhaseBody _ _)) = False

{- | How many further bytes this scan needs before the request it is framing is
   complete, given the `avail` the scan was produced from, or `None` when that
   is not settled yet.

   Settled for exactly one shape: a body whose end position the header section
   already fixed, which is a `Content-Length` body and a bodyless request. A
   scan still inside the header section has not selected a body mode, and a
   chunked body declares its length one chunk at a time, so neither can say
   what is still owed and both report `None`.

   Only this module can answer it, the scan's phase being private. A caller
   that must reserve a resource for a whole request before accepting any of it
   — `pds/shell/server.mdk`'s in-flight buffer budget — has no other route to
   the number: the declared length is a header this module has already graded
   into a body mode, and reading it again outside would be a second framer
   able to disagree with this one. -}
export
httpScanBodyRemaining : HttpScan -> Int -> Option Int
httpScanBodyRemaining (HttpScan (PhaseBody _ (BodyUntil finalPos))) avail =
  Some (max 0 (finalPos - avail))
httpScanBodyRemaining _ _ = None

scanVerdict : Int -> Int -> HttpScan -> ScanOutcome -> (HttpFrame, HttpScan)
scanVerdict _ start scanned (ScanFramed (FrameSpan _ finalPos)) =
  (requestBytesVerdict (finalPos - start) (HttpFramedAt finalPos), scanned)
scanVerdict _ _ scanned (ScanFatal failure) = (HttpFrameFailed failure, scanned)
scanVerdict avail start _ (ScanSuspend _ phase) = (
  requestBytesVerdict (avail - start) HttpNeedMore,
  HttpScan phase,
)

{- | Find the end of the first complete request at or after `start` in the first
   `avail` bytes of `input`, resuming the scan `state` left off at. Bytes of
   `input` at or past `avail` are not input: they are whatever a caller's
   backing array holds beyond what it has received, so no framing decision may
   read them. A buffer whose pending bytes already exceed the per-request
   ceiling is rejected rather than left pending, so a caller can bound what it
   buffers.

   The cost of a resumed scan is proportional to the bytes that arrived since
   the state was produced, not to the bytes already buffered, because every
   suspension point is one only later bytes can move past. -}
export
scanRequestBoundaryWithin : Bytes ->
  Int ->
  Int ->
  HttpScan ->
  (HttpFrame, HttpScan)
scanRequestBoundaryWithin input avail start (HttpScan phase) =
  -- A refused buffer leaves the scan where it was: the bytes it rejected were
  -- never accepted, so a later read must not skip over them.
  let unchanged = HttpScan phase
  if avail < 0 || avail > bytesLength input then
    (
      HttpFrameFailed (HttpMalformed "http: scan length outside buffer"),
      unchanged,
    )
  else if start < 0 || start > avail then
    (
      HttpFrameFailed (HttpMalformed "http: scan offset outside buffer"),
      unchanged,
    )
  else
    scanVerdict avail start (HttpScan phase) (scanFrom input avail start phase)

-- | Scan a buffer whose every byte is received input. This is
-- `scanRequestBoundaryWithin` at the buffer's full length, so a caller that
-- keeps no spare capacity needs to know nothing about the distinction.
export
scanRequestBoundaryFrom : Bytes -> Int -> HttpScan -> (HttpFrame, HttpScan)
scanRequestBoundaryFrom input start scan =
  scanRequestBoundaryWithin input (bytesLength input) start scan

-- | Find the end of the first complete request at or after `start` without a
-- prior scan. This is `scanRequestBoundaryFrom` from `httpScanStart`, so a
-- whole-buffer scan and a resumed one cannot be two different framers.
export
scanRequestBoundary : Bytes -> Int -> HttpFrame
scanRequestBoundary input start =
  fst (scanRequestBoundaryFrom input start httpScanStart)

-- | Parse the frame `[start, end)` exactly as `parseRequestClassified` parses
-- that region on its own, so a scanned boundary and a parse cannot disagree.
export
parseRequestAt : Bytes -> Int -> Int -> Result HttpParseFailure Request
parseRequestAt input start end =
  if start < 0 || end < start || end > bytesLength input then
    Err (HttpMalformed "http: request frame bounds outside buffer")
  else
    parseRequestClassified (slice input start end)

-- | Parse one complete request, reporting a failure as its diagnostic alone.
-- `parseRequestClassified` keeps the structural class a caller needs to
-- choose 400 against 413.
export
parseRequest : Bytes -> Result String Request
parseRequest input = match parseRequestClassified input
  Ok request => Ok request
  Err failure => Err (httpParseFailureMessage failure)

-- # Response parsing

{- | A parsed HTTP/1.0 or HTTP/1.1 response. Fields and trailers retain their
   received order and duplicates; the body has any chunked transfer coding
   removed. The constructor is private so every value has passed the framing
   and resource checks below. -}
export data ParsedResponse =
  | ParsedResponse Int String (List Header) (List Header) (Array Int)

-- | The parsed response's status code.
export
parsedResponseStatus : ParsedResponse -> Int
parsedResponseStatus (ParsedResponse status _ _ _ _) = status

-- | The parsed response's reason phrase, exactly as received.
export
parsedResponseReason : ParsedResponse -> String
parsedResponseReason (ParsedResponse _ reason _ _ _) = reason

-- | The parsed response fields in received order, duplicates retained.
export
parsedResponseHeaders : ParsedResponse -> List Header
parsedResponseHeaders (ParsedResponse _ _ headers _ _) = copyHeaders headers

-- | Parsed trailer fields in received order, or an empty list for a body
-- without chunked transfer coding.
export
parsedResponseTrailers : ParsedResponse -> List Header
parsedResponseTrailers (ParsedResponse _ _ _ trailers _) = copyHeaders trailers

-- | The decoded response body, with chunk framing removed.
export
parsedResponseBody : ParsedResponse -> Array Int
parsedResponseBody (ParsedResponse _ _ _ _ body) = arrayCopy body

-- | The decoded response body's length without copying it.
export
parsedResponseBodyLength : ParsedResponse -> Int
parsedResponseBodyLength (ParsedResponse _ _ _ _ body) = arrayLength body

data ResponseStatusLine = ResponseStatusLine Int String Int
data ResponseFieldStep =
  | ResponseFieldDone Int Int
  | ResponseFieldMore Header Int

responseMalformed : String -> Result FrameError a
responseMalformed message = Err (Fatal (HttpMalformed message))

responseResourceExcess : Result String Unit -> Result FrameError Unit
responseResourceExcess (Ok ()) = Ok ()
responseResourceExcess (Err message) = Err (Fatal (HttpResourceExcess message))

responseFindCrlf : String ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError Int
responseFindCrlf label input avail start limit =
  responseFindCrlfGo label input avail start start limit

responseFindCrlfGo : String ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError Int
responseFindCrlfGo label input avail start pos limit =
  if pos - start > limit then
    Err (Fatal (HttpResourceExcess "http: \{label} exceeds its resource limit"))
  else if pos >= avail then
    responseMalformed "http: truncated \{label}; expected CRLF"
  else if input[pos] == 10 then
    responseMalformed "http: bare LF in \{label}"
  else if input[pos] == 13 then
    if pos + 1 >= avail || input[pos + 1] /= 10 then
      responseMalformed "http: bare CR in \{label}"
    else
      Ok pos
  else
    responseFindCrlfGo label input avail start (pos + 1) limit

responseParseDecimalGo : Array Int -> Int -> Int -> Result FrameError Int
responseParseDecimalGo value i acc =
  if i >= arrayLength value then
    Ok acc
  else
    let byte = value[i]
    if byte < 48 || byte > 57 then
      responseMalformed "http: invalid decimal field"
    else
      let digit = byte - 48
      if acc > (intMaxBound - digit) / 10 then
        responseMalformed "http: decimal field overflows Int"
      else
        responseParseDecimalGo value (i + 1) (acc * 10 + digit)

responseParseStatusLine : Array Int ->
  Int ->
  Result FrameError ResponseStatusLine
responseParseStatusLine input avail = do
  end <- responseFindCrlf
    "status line"
    input
    avail
    0
    maxHttpResponseStatusLineBytes
  () <- responseResourceExcess (checkHttpResponseStatusLineBytes end)
  firstSpace <- match findByte input 0 end 32
    None =>
      responseMalformed
        "http: malformed status line; expected HTTP-version SP status SP reason"
    Some pos => Ok pos
  secondSpace <- match findByte input (firstSpace + 1) end 32
    None =>
      responseMalformed
        "http: malformed status line; expected HTTP-version SP status SP reason"
    Some pos => Ok pos
  let versionBytes = slice input 0 firstSpace
  if firstSpace /= 8
    || not
      (versionBytes == toUtf8 "HTTP/1.1"
        || versionBytes == toUtf8 "HTTP/1.0") then
    responseMalformed "http: only HTTP/1.0 and HTTP/1.1 responses are supported"
  else if secondSpace - firstSpace - 1 /= 3 then
    responseMalformed "http: status code must be exactly three digits"
  else do
    status <- responseParseDecimalGo
      (slice input (firstSpace + 1) (firstSpace + 4))
      0
      0
    if status < 100 || status > 999 then
      responseMalformed "http: status code out of range"
    else
      Ok
        (ResponseStatusLine
          status
          (fromUtf8 (slice input (secondSpace + 1) end))
          (end + 2))

responseParseHeaderLine : Array Int -> Int -> Int -> Result FrameError Header
responseParseHeaderLine input start end =
  if input[start] == 32 || input[start] == 9 then
    responseMalformed "http: obsolete folded header lines are forbidden"
  else match findByte input start end 58
    None => responseMalformed "http: malformed header field; missing colon"
    Some colon =>
      if colon == start || not (allToken input start colon) then
        responseMalformed "http: invalid header field name"
      else if not (validFieldValue input (colon + 1) end) then
        responseMalformed "http: control byte in header field value"
      else
        let valueStart = trimLeftOws input (colon + 1) end
        let valueEnd = trimRightOws input valueStart end
        Ok
          (Header
            (lowerAscii input start colon)
            (slice input valueStart valueEnd))

responseFieldStep : Array Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError ResponseFieldStep
responseFieldStep input avail pos sectionStart priorBytes count = do
  end <- responseFindCrlf "header field" input avail pos maxHttpHeaderBytes
  let next = end + 2
  let totalBytes = priorBytes + next - sectionStart
  if totalBytes > maxHttpHeaderBytes then
    Err
      (Fatal
        (HttpResourceExcess
          "http: combined header and trailer section exceeds 65536-byte resource limit"))
  else if end == pos then
    Ok (ResponseFieldDone next totalBytes)
  else if count + 1 > maxHttpHeaderFields then
    Err
      (Fatal
        (HttpResourceExcess
          "http: header field count exceeds 100 resource limit"))
  else do
    field <- responseParseHeaderLine input pos end
    Ok (ResponseFieldMore field next)

responseParseFields : Array Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  List Header ->
  Result FrameError (List Header, Int, Int)
responseParseFields input avail pos sectionStart priorBytes count acc = do
  step <- responseFieldStep input avail pos sectionStart priorBytes count
  match step
    ResponseFieldDone next totalBytes => Ok (reverse acc, next, totalBytes)
    ResponseFieldMore field next =>
      responseParseFields
        input
        avail
        next
        sectionStart
        priorBytes
        (count + 1)
        (field :: acc)

responseCountNamed : String -> List Header -> Int
responseCountNamed _ [] = 0
responseCountNamed wanted ((Header name _) :: rest) =
  (if name == wanted then 1 else 0) + responseCountNamed wanted rest

responseFindNamed : String -> List Header -> Option (Array Int)
responseFindNamed _ [] = None
responseFindNamed wanted ((Header name value) :: rest) =
  if name == wanted then Some value else responseFindNamed wanted rest

responseImpliesNoBody : Int -> Bool
responseImpliesNoBody status =
  status >= 100 && status < 200 || status == 204 || status == 304

responseSelectBodyMode : Int -> List Header -> Result FrameError BodyMode
responseSelectBodyMode status headers =
  let clCount = responseCountNamed "content-length" headers
  let teCount = responseCountNamed "transfer-encoding" headers
  if clCount > 1 then
    responseMalformed "http: duplicate Content-Length is ambiguous"
  else if clCount > 0 && teCount > 0 then
    responseMalformed "http: Transfer-Encoding with Content-Length is ambiguous"
  else if teCount > 0 then
    if teCount /= 1 then
      responseMalformed "http: repeated Transfer-Encoding is unsupported"
    else match responseFindNamed "transfer-encoding" headers
      None => responseMalformed "http: missing Transfer-Encoding value"
      Some value =>
        if asciiEqualCi value "chunked" then
          Ok ChunkedBody
        else
          responseMalformed "http: unsupported Transfer-Encoding coding"
  else match responseFindNamed "content-length" headers
    None =>
      if responseImpliesNoBody status then Ok NoBody else Ok UntilCloseBody
    Some value =>
      if arrayLength value == 0 then
        responseMalformed "http: empty Content-Length"
      else do
        size <- responseParseDecimalGo value 0 0
        if size > maxHttpBodyBytes then
          Err
            (Fatal
              (HttpResourceExcess
                "http: decoded body exceeds 5242880-byte resource limit"))
        else
          Ok (FixedBody size)

responseParseHexSizeGo : Array Int -> Int -> Int -> Int -> Result FrameError Int
responseParseHexSizeGo input pos end acc =
  if pos >= end then
    Ok acc
  else match hexDigit input[pos]
    None => responseMalformed "http: invalid chunk size"
    Some digit =>
      if acc > (maxHttpResponseChunkBytes - digit) / 16 then
        Err
          (Fatal (HttpResourceExcess "http: chunk size exceeds resource limit"))
      else
        responseParseHexSizeGo input (pos + 1) end (acc * 16 + digit)

responseScanQuoted : Array Int -> Int -> Int -> Result FrameError Int
responseScanQuoted input pos end =
  if pos >= end then
    responseMalformed "http: unterminated quoted chunk extension"
  else if input[pos] == 34 then
    Ok (pos + 1)
  else if input[pos] == 92 then
    if pos + 1 >= end then
      responseMalformed "http: truncated quoted-pair in chunk extension"
    else
      let escaped = input[pos + 1]
      if escaped == 9 || escaped == 32 || escaped >= 33 && escaped /= 127 then
        responseScanQuoted input (pos + 2) end
      else
        responseMalformed "http: control byte in quoted chunk extension"
  else
    let byte = input[pos]
    if byte == 9
      || byte == 32
      || byte >= 33 && byte /= 34 && byte /= 92 && byte /= 127 then
      responseScanQuoted input (pos + 1) end
    else
      responseMalformed "http: control byte in quoted chunk extension"

responseParseChunkExtensionValue : Array Int ->
  Int ->
  Int ->
  Result FrameError Int
responseParseChunkExtensionValue input pos end =
  if pos >= end then
    responseMalformed "http: missing chunk extension value"
  else if input[pos] == 34 then
    responseScanQuoted input (pos + 1) end
  else
    let valueEnd = scanTokenEnd input pos end
    if valueEnd == pos then
      responseMalformed "http: invalid chunk extension value"
    else
      Ok valueEnd

responseParseChunkExtensionsGo : Array Int ->
  Int ->
  Int ->
  Result FrameError Unit
responseParseChunkExtensionsGo input pos end =
  let start = skipOws input pos end
  if start == end then
    Ok ()
  else if input[start] /= 59 then
    responseMalformed "http: invalid chunk extension separator"
  else
    let nameStart = skipOws input (start + 1) end
    let nameEnd = scanTokenEnd input nameStart end
    if nameEnd == nameStart then
      responseMalformed "http: empty chunk extension name"
    else
      let afterName = skipOws input nameEnd end
      if afterName < end && input[afterName] == 61 then do
        valueEnd <- responseParseChunkExtensionValue
          input
          (skipOws input (afterName + 1) end)
          end
        responseParseChunkExtensionsGo input valueEnd end
      else
        responseParseChunkExtensionsGo input afterName end

responseParseChunkSize : Array Int -> Int -> Int -> Result FrameError Int
responseParseChunkSize input start end =
  let semi = match findByte input start end 59
    None => end
    Some pos => pos
  if semi == start then
    responseMalformed "http: empty chunk size"
  else do
    size <- responseParseHexSizeGo input start semi 0
    () <- responseParseChunkExtensionsGo input semi end
    Ok size

data ResponseChunkHead = ResponseChunkEnd Int | ResponseChunkBody Int Int

responseChunkHeadStep : Array Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError ResponseChunkHead
responseChunkHeadStep input avail pos count = do
  lineEnd <- responseFindCrlf
    "chunk-size line"
    input
    avail
    pos
    maxHttpHeaderBytes
  size <- responseParseChunkSize input pos lineEnd
  () <- responseResourceExcess (checkHttpResponseChunkBytes size)
  let dataPos = lineEnd + 2
  if size == 0 then
    Ok (ResponseChunkEnd dataPos)
  else if count + 1 > maxHttpChunks then
    Err
      (Fatal
        (HttpResourceExcess "http: chunk count exceeds 65536 resource limit"))
  else
    Ok (ResponseChunkBody dataPos size)

responseReadSliceAt : Array Int ->
  Int ->
  Int ->
  Int ->
  Result FrameError (Array Int, Int)
responseReadSliceAt input avail pos size =
  if pos + size > avail then
    responseMalformed "http: truncated chunk body"
  else
    Ok (slice input pos (pos + size), pos + size)

responseChunkDataEnd : Array Int -> Int -> Int -> Int -> Result FrameError Int
responseChunkDataEnd input avail dataPos size =
  let afterChunk = dataPos + size
  if afterChunk > avail then
    responseMalformed "http: truncated chunk body"
  else if afterChunk + 2 > avail then
    responseMalformed "http: truncated CRLF after chunk data"
  else if input[afterChunk] /= 13 || input[afterChunk + 1] /= 10 then
    responseMalformed "http: missing CRLF after chunk data"
  else
    Ok (afterChunk + 2)

responseParseChunked : Array Int ->
  Int ->
  Int ->
  Builder ->
  Int ->
  Int ->
  Result FrameError (Array Int, List Header, Int)
responseParseChunked input avail pos out total count = do
  head <- responseChunkHeadStep input avail pos count
  match head
    ResponseChunkEnd dataPos => do
      (trailers, finalPos, _) <- responseParseFields
        input
        avail
        dataPos
        dataPos
        0
        0
        []
      Ok (buildArray out, trailers, finalPos)
    ResponseChunkBody dataPos size => do
      if total + size > maxHttpBodyBytes then
        Err
          (Fatal
            (HttpResourceExcess
              "http: decoded body exceeds 5242880-byte resource limit"))
      else do
        (chunk, _) <- responseReadSliceAt input avail dataPos size
        next <- responseChunkDataEnd input avail dataPos size
        let () = emitArray chunk 0 out
        responseParseChunked input avail next out (total + size) (count + 1)

responseParseBody : BodyMode ->
  Array Int ->
  Int ->
  Int ->
  Result FrameError (Array Int, List Header, Int)
responseParseBody NoBody _ _ pos = Ok ([||], [], pos)
responseParseBody (FixedBody size) input avail pos = do
  (body, finalPos) <- responseReadSliceAt input avail pos size
  Ok (body, [], finalPos)
responseParseBody ChunkedBody input avail pos =
  responseParseChunked input avail pos (newBuilder ()) 0 0
responseParseBody UntilCloseBody input avail pos =
  Ok (slice input pos avail, [], avail)

{- | Parse one complete HTTP response with structural failure classification.
   Status lines, fields, chunks, decoded bodies, and trailers are bounded.
   Transfer-coding tokens are compared as ASCII case-insensitively. A response
   without a declared length is close-delimited unless its status forbids a
   body. -}
export
parseResponseClassified : Array Int -> Result HttpParseFailure ParsedResponse
parseResponseClassified input = settle (parseResponseChecked input)

parseResponseChecked : Array Int -> Result FrameError ParsedResponse
parseResponseChecked input = do
  let avail = arrayLength input
  (ResponseStatusLine status reason lineEnd) <- responseParseStatusLine
    input
    avail
  (headers, headerEnd, _) <- responseParseFields
    input
    avail
    lineEnd
    lineEnd
    0
    0
    []
  mode <- responseSelectBodyMode status headers
  (body, trailers, finalPos) <- responseParseBody mode input avail headerEnd
  if finalPos /= avail then
    responseMalformed "http: bytes after framed response"
  else
    Ok (ParsedResponse status reason headers trailers body)

{- | `parseResponseClassified` with its structural class collapsed to the
   diagnostic string.

   > isErr (parseResponse [||])
   True -}
export
parseResponse : Array Int -> Result String ParsedResponse
parseResponse input = match parseResponseClassified input
  Ok response => Ok response
  Err failure => Err (httpParseFailureMessage failure)

test "response malformed diagnostics use the public http vocabulary" =
  match parseResponseClassified [||]
    Err (HttpMalformed message) =>
      expectEqual "http: truncated status line; expected CRLF" message
    _ => expectTrue False

test "response resource diagnostics use the public http vocabulary" =
  let input =
    toUtf8 "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n100001\r\n"
  match parseResponseClassified input
    Err (HttpResourceExcess message) =>
      expectEqual "http: chunk size exceeds resource limit" message
    _ => expectTrue False

responseScanChunkedEnd : Array Int -> Int -> Int -> Int -> Result FrameError Int
responseScanChunkedEnd input avail pos count = do
  head <- responseChunkHeadStep input avail pos count
  match head
    ResponseChunkEnd dataPos => do
      (_, finalPos, _) <- responseParseFields input avail dataPos dataPos 0 0 []
      Ok finalPos
    ResponseChunkBody dataPos size => do
      next <- responseChunkDataEnd input avail dataPos size
      responseScanChunkedEnd input avail next (count + 1)

responseScanBodyEnd : BodyMode ->
  Array Int ->
  Int ->
  Int ->
  Result FrameError Int
responseScanBodyEnd NoBody _ _ pos = Ok pos
responseScanBodyEnd (FixedBody size) _ avail pos =
  if pos + size > avail then
    responseMalformed "http: declared body is still arriving"
  else
    Ok (pos + size)
responseScanBodyEnd ChunkedBody input avail pos =
  responseScanChunkedEnd input avail pos 0
responseScanBodyEnd UntilCloseBody _ _ _ =
  responseMalformed "http: close-delimited response ends only at the close"

responseScanEnd : Array Int -> Int -> Result FrameError Int
responseScanEnd input avail = do
  (ResponseStatusLine status _ lineEnd) <- responseParseStatusLine input avail
  (headers, headerEnd, _) <- responseParseFields
    input
    avail
    lineEnd
    lineEnd
    0
    0
    []
  mode <- responseSelectBodyMode status headers
  responseScanBodyEnd mode input avail headerEnd

{- | The offset just past the first response framed by `input[0, avail)`, or
   `None` when that prefix is incomplete, malformed, or close-delimited.
   Bytes at or beyond `avail` are never inspected. A returned boundary may be
   less than `avail` when another message follows it. -}
export
responseBoundaryWithin : Array Int -> Int -> Option Int
responseBoundaryWithin input avail =
  if avail < 0 || avail > arrayLength input then
    None
  else match responseScanEnd input avail
    Ok end => Some end
    Err _ => None

-- | `responseBoundaryWithin` over all bytes in `input`.
export
responseBoundary : Array Int -> Option Int
responseBoundary input = responseBoundaryWithin input (arrayLength input)

-- # Response building

-- | A buffered HTTP response. The constructor is private: responses can only
-- be obtained through `makeResponse`, after their status line and fields have
-- been checked for response splitting and reserved framing fields.
export data Response = Response Int String (List Header) (Array Int)

validResponseValue : Array Int -> Int -> Bool
validResponseValue value i =
  if i >= arrayLength value then
    True
  else
    let byte = value[i]
    byte >= 32 && byte <= 126 && validResponseValue value (i + 1)

-- | Construct a safe response field. Names are canonicalized to lowercase;
-- values must be printable ASCII and therefore cannot contain CR, LF, or any
-- other control byte.
export
makeHeader : String -> Array Int -> Result String Header
makeHeader name value =
  let nameBytes = toUtf8 name
  if arrayLength nameBytes == 0
    || not (allToken nameBytes 0 (arrayLength nameBytes)) then
    Err "http: invalid response header field name"
  else if not (validBytes value 0 (arrayLength value))
    || not (validResponseValue value 0) then
    Err "http: control or non-ASCII byte in response header field value"
  else
    Ok
      (Header
        (lowerAscii nameBytes 0 (arrayLength nameBytes))
        (arrayCopy value))

validReason : String -> Bool
validReason reason = validResponseValue (toUtf8 reason) 0

hasReservedResponseField : List Header -> Bool
hasReservedResponseField [] = False
hasReservedResponseField ((Header name _) :: rest) =
  name == "content-length"
    || name == "transfer-encoding"
    || hasReservedResponseField rest

-- | Construct a deterministic buffered response. The serializer owns all
-- framing, so callers cannot supply Content-Length or Transfer-Encoding.
export
makeResponse : Int ->
  String ->
  List Header ->
  Array Int ->
  Result String Response
makeResponse status reason headers body =
  if status < 100 || status > 599 then
    Err "http: response status must be between 100 and 599"
  else if not (validReason reason) then
    Err "http: invalid control or non-ASCII byte in response reason phrase"
  else if hasReservedResponseField headers then
    Err "http: response framing fields are reserved"
  else if not (validBytes body 0 (arrayLength body)) then
    Err "http: response body element outside byte range 0..255"
  else
    Ok (Response status reason (copyHeaders headers) (arrayCopy body))

-- | The response status code.
export
responseStatus : Response -> Int
responseStatus (Response status _ _ _) = status

-- | The caller's response fields in the order they were supplied. The
-- computed Content-Length is added by `serializeResponse` and is not among
-- them.
export
responseHeaders : Response -> List Header
responseHeaders (Response _ _ headers _) = copyHeaders headers

-- | The response body bytes.
export
responseBody : Response -> Array Int
responseBody (Response _ _ _ body) = arrayCopy body

-- | The response reason phrase, exactly as constructed.
export
responseReason : Response -> String
responseReason (Response _ reason _ _) = reason

emitAscii : String -> Builder -> Unit
emitAscii text out = emitArray (toUtf8 text) 0 out

emitResponseHeaders : List Header -> Builder -> Unit
emitResponseHeaders [] _ = ()
emitResponseHeaders ((Header name value) :: rest) out =
  emitAscii name out
  emitAscii ": " out
  emitArray value 0 out
  emitAscii "\r\n" out
  emitResponseHeaders rest out

-- | Serialize a complete HTTP/1.1 response. Caller fields remain in their
-- original order and exactly one computed Content-Length follows them.
export
serializeResponse : Response -> Array Int
serializeResponse (Response status reason headers body) =
  let out = newBuilder ()
  emitAscii "HTTP/1.1 " out
  emitAscii (intToString status) out
  emitAscii " " out
  emitAscii reason out
  emitAscii "\r\n" out
  emitResponseHeaders headers out
  emitAscii "content-length: " out
  emitAscii (intToString (arrayLength body)) out
  emitAscii "\r\n\r\n" out
  emitArray body 0 out
  buildArray out

-- # Targets, media types, and bodies

-- | A parsed, canonical media type, holding only the lowercased type and
-- subtype. `parseMediaType` validates any parameters but does not retain
-- them.
export data MediaType = MediaType String String

-- | A request body decoded according to its media type. JSON and text are
-- strictly UTF-8; every other media type keeps its raw bytes.
public export data DecodedBody =
  | JsonBody MediaType Json
  | TextBody MediaType String
  | RawBody MediaType (Array Int)

-- | One decoded query parameter: its name and its value, empty when the
-- query gave it none.
public export data QueryParam = QueryParam String String

percentNibble : Int -> Option Int
percentNibble byte = hexDigit byte

decodeQueryBytes : Array Int -> Int -> Int -> Builder -> Result String Unit
decodeQueryBytes input pos end out =
  if pos >= end then
    Ok ()
  else if input[pos] /= 37 then
    let () = emitU8 input[pos] out
    decodeQueryBytes input (pos + 1) end out
  else if pos + 2 >= end then
    Err "http: malformed percent escape in query"
  else match (percentNibble input[pos + 1], percentNibble input[pos + 2])
    (Some high, Some low) =>
      let () = emitU8 (high * 16 + low) out
      decodeQueryBytes input (pos + 3) end out
    _ => Err "http: malformed percent escape in query"

continuation : Int -> Bool
continuation byte = byte >= 128 && byte <= 191

utf8Step : Array Int -> Int -> Option (Int, Int)
utf8Step bytes i =
  let size = arrayLength bytes
  let b0 = bytes[i]
  if b0 <= 127 then
    Some (b0, i + 1)
  else if b0 >= 194
    && b0 <= 223
    && i + 1 < size
    && continuation bytes[i + 1] then
    Some ((b0 - 192) * 64 + bytes[i + 1] - 128, i + 2)
  else if b0 == 224
    && i + 2 < size
    && bytes[i + 1] >= 160
    && bytes[i + 1] <= 191
    && continuation bytes[i + 2] then
    Some (
      (b0 - 224) * 4096 + (bytes[i + 1] - 128) * 64 + bytes[i + 2] - 128,
      i + 3,
    )
  else if b0 >= 225
    && b0 <= 236
    && i + 2 < size
    && continuation bytes[i + 1]
    && continuation bytes[i + 2] then
    Some (
      (b0 - 224) * 4096 + (bytes[i + 1] - 128) * 64 + bytes[i + 2] - 128,
      i + 3,
    )
  else if b0 >= 238
    && b0 <= 239
    && i + 2 < size
    && continuation bytes[i + 1]
    && continuation bytes[i + 2] then
    Some (
      (b0 - 224) * 4096 + (bytes[i + 1] - 128) * 64 + bytes[i + 2] - 128,
      i + 3,
    )
  else if b0 == 237
    && i + 2 < size
    && bytes[i + 1] >= 128
    && bytes[i + 1] <= 159
    && continuation bytes[i + 2] then
    Some (
      (b0 - 224) * 4096 + (bytes[i + 1] - 128) * 64 + bytes[i + 2] - 128,
      i + 3,
    )
  else if b0 == 240
    && i + 3 < size
    && bytes[i + 1] >= 144
    && bytes[i + 1] <= 191
    && continuation bytes[i + 2]
    && continuation bytes[i + 3] then
    Some (
      (b0 - 240) * 262144
        + (bytes[i + 1] - 128) * 4096
        + (bytes[i + 2] - 128) * 64
        + bytes[i + 3]
        - 128,
      i + 4,
    )
  else if b0 >= 241
    && b0 <= 243
    && i + 3 < size
    && continuation bytes[i + 1]
    && continuation bytes[i + 2]
    && continuation bytes[i + 3] then
    Some (
      (b0 - 240) * 262144
        + (bytes[i + 1] - 128) * 4096
        + (bytes[i + 2] - 128) * 64
        + bytes[i + 3]
        - 128,
      i + 4,
    )
  else if b0 == 244
    && i + 3 < size
    && bytes[i + 1] >= 128
    && bytes[i + 1] <= 143
    && continuation bytes[i + 2]
    && continuation bytes[i + 3] then
    Some (
      (b0 - 240) * 262144
        + (bytes[i + 1] - 128) * 4096
        + (bytes[i + 2] - 128) * 64
        + bytes[i + 3]
        - 128,
      i + 4,
    )
  else
    None

validUtf8From : Array Int -> Int -> Bool
validUtf8From bytes i =
  if i >= arrayLength bytes then
    True
  else match utf8Step bytes i
    None => False
    Some (_, next) => validUtf8From bytes next

validQueryTextFrom : Array Int -> Int -> Bool
validQueryTextFrom bytes i =
  if i >= arrayLength bytes then
    True
  else match utf8Step bytes i
    None => False
    Some (code, next) =>
      code > 31
        && not (code >= 127 && code <= 159)
        && validQueryTextFrom bytes next

decodeQueryPart : Array Int -> Int -> Int -> Result String String
decodeQueryPart input start end = do
  let out = newBuilder ()
  () <- decodeQueryBytes input start end out
  let decoded = buildArray out
  if not (validQueryTextFrom decoded 0) then
    Err "http: query component is invalid UTF-8 or contains a control character"
  else
    Ok (fromUtf8 decoded)

parseQueryFields : Array Int ->
  Int ->
  List QueryParam ->
  Result String (List QueryParam)
parseQueryFields input start acc =
  let end = arrayLength input
  if start >= end then
    Ok (reverse acc)
  else
    let amp = match findByte input start end 38
      None => end
      Some pos => pos
    let equals = match findByte input start amp 61
      None => amp
      Some pos => pos
    if equals == start then
      Err "http: empty query parameter name"
    else do
      name <- decodeQueryPart input start equals
      if name == "" then
        Err "http: empty query parameter name"
      else do
        value <- if equals == amp then
          Ok ""
        else
          decodeQueryPart input (equals + 1) amp
        let next = if amp == end then end else amp + 1
        if next == end && amp < end then
          Err "http: empty query parameter name"
        else
          parseQueryFields input next (QueryParam name value :: acc)

-- | Split and decode the validated origin target. Ordered duplicates and
-- empty values are retained; `+` is ordinary URI data and remains literal.
export
parseTargetQuery : Request -> Result String (String, List QueryParam)
parseTargetQuery (Request _ target _ _ _ _) =
  let bytes = toUtf8 target
  match findByte bytes 0 (arrayLength bytes) 35
    Some _ => Err "http: fragment is forbidden in request target"
    None => match findByte bytes 0 (arrayLength bytes) 63
      None => Ok (target, [])
      Some queryAt => do
        let path = fromUtf8 (slice bytes 0 queryAt)
        if queryAt + 1 == arrayLength bytes then
          Ok (path, [])
        else do
          params <- parseQueryFields bytes (queryAt + 1) []
          Ok (path, params)

-- | The lowercased type, such as `"text"` for `text/plain`.
export
mediaTypeType : MediaType -> String
mediaTypeType (MediaType kind _) = kind

-- | The lowercased subtype, such as `"plain"` for `text/plain`.
export
mediaTypeSubtype : MediaType -> String
mediaTypeSubtype (MediaType _ subtype) = subtype

validMediaBytes : Array Int -> Int -> Bool
validMediaBytes bytes i =
  if i >= arrayLength bytes then
    True
  else
    let byte = bytes[i]
    (byte == 9 || byte >= 32 && byte <= 126) && validMediaBytes bytes (i + 1)

scanMediaQuoted : Array Int -> Int -> Int -> Result String Int
scanMediaQuoted value pos end =
  if pos >= end then
    Err "http: unterminated quoted media-type parameter"
  else if value[pos] == 34 then
    Ok (pos + 1)
  else if value[pos] == 92 then
    if pos + 1 >= end || value[pos + 1] < 32 || value[pos + 1] > 126 then
      Err "http: invalid quoted media-type parameter"
    else
      scanMediaQuoted value (pos + 2) end
  else if value[pos] < 32 || value[pos] == 127 then
    Err "http: control byte in media-type parameter"
  else
    scanMediaQuoted value (pos + 1) end

parseMediaParameters : Array Int -> Int -> Int -> Int -> Result String Unit
parseMediaParameters value pos end count =
  let start = skipOws value pos end
  if start == end then
    Ok ()
  else if count >= 32 then
    Err "http: media type has too many parameters"
  else if value[start] /= 59 then
    Err "http: invalid media-type parameter separator"
  else
    let nameStart = skipOws value (start + 1) end
    let nameEnd = scanTokenEnd value nameStart end
    if nameEnd == nameStart then
      Err "http: empty media-type parameter name"
    else
      let afterName = skipOws value nameEnd end
      if afterName >= end || value[afterName] /= 61 then
        Err "http: media-type parameter requires a value"
      else
        let valueStart = skipOws value (afterName + 1) end
        if valueStart >= end then
          Err "http: media-type parameter requires a value"
        else do
          valueEnd <- if value[valueStart] == 34 then
            scanMediaQuoted value (valueStart + 1) end
          else
            let tokenEnd = scanTokenEnd value valueStart end
            if tokenEnd == valueStart then
              Err "http: invalid media-type parameter value"
            else
              Ok tokenEnd
          parseMediaParameters value valueEnd end (count + 1)

-- | Parse a bounded ASCII media type. Type and subtype matching is
-- case-insensitive and returned in canonical lowercase form.
export
parseMediaType : Array Int -> Result String MediaType
parseMediaType value =
  let end = arrayLength value
  if end == 0 || end > 4096 then
    Err "http: media type exceeds its 4096-byte resource limit"
  else if not (validBytes value 0 end) || not (validMediaBytes value 0) then
    Err "http: media type must be bounded ASCII"
  else
    let typeEnd = scanTokenEnd value 0 end
    if typeEnd == 0 || typeEnd >= end || value[typeEnd] /= 47 then
      Err "http: invalid media type"
    else
      let subtypeStart = typeEnd + 1
      let subtypeEnd = scanTokenEnd value subtypeStart end
      if subtypeEnd == subtypeStart then
        Err "http: invalid media subtype"
      else do
        () <- parseMediaParameters value subtypeEnd end 0
        Ok
          (MediaType
            (lowerAscii value 0 typeEnd)
            (lowerAscii value subtypeStart subtypeEnd))

contentType : List Header -> Result String MediaType
contentType headers =
  let count = countNamed "content-type" headers
  if count == 0 then
    Err "http: request body requires Content-Type"
  else if count > 1 then
    Err "http: duplicate Content-Type"
  else match findNamed "content-type" headers
    None => Err "http: request body requires Content-Type"
    Some value => parseMediaType value

-- | Decode a framed request body according to its supplied media type. JSON
-- and text are strictly UTF-8 and have narrower endpoint limits; all other
-- valid media types retain their raw bytes.
export
decodeRequestBody : Request -> Result String DecodedBody
decodeRequestBody (Request _ _ headers _ packed _) = do
  mediaType <- contentType headers
  -- Every arm's size cap reads only the length, which the packed body
  -- already knows in O(1). Unpacking first would allocate a machine word
  -- per byte of a body the very next line refuses — the endpoint caps are
  -- far below the framer's, so the refused case is the large one.
  let size = bytesLength packed
  match mediaType
    MediaType "application" "json" => do
      () <- checkJsonBodyBytes size
      let body = toArray packed
      if not (validUtf8From body 0) then
        Err "http: JSON body is not valid UTF-8"
      else match parse (fromUtf8 body)
        Err message => Err "http: invalid JSON body: \{message}"
        Ok value => Ok (JsonBody mediaType value)
    MediaType "text" _ => do
      () <- checkTextBodyBytes size
      let body = toArray packed
      if not (validUtf8From body 0) then
        Err "http: text body is not valid UTF-8"
      else
        Ok (TextBody mediaType (fromUtf8 body))
    _ => do
      () <- checkRawBodyBytes size
      Ok (RawBody mediaType (toArray packed))
# DESUGAR
(DUse false (UseGroup ("bytebuilder") ((mem "Builder" false) (mem "appendBytes" false) (mem "buildArray" false) (mem "buildBytes" false) (mem "emitU8" false) (mem "newBuilder" false))))
(DUse false (UseWild ("bytes")))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "fromUtf8" false) (mem "toUtf8" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeSig true "maxHttpRequestBytes" (TyCon "Int"))
(DFunDef false "maxHttpRequestBytes" () (ELit (LInt 6291456)))
(DTypeSig true "maxHttpHeaderBytes" (TyCon "Int"))
(DFunDef false "maxHttpHeaderBytes" () (ELit (LInt 65536)))
(DTypeSig true "maxHttpBodyBytes" (TyCon "Int"))
(DFunDef false "maxHttpBodyBytes" () (ELit (LInt 5242880)))
(DTypeSig true "maxHttpRequestLineBytes" (TyCon "Int"))
(DFunDef false "maxHttpRequestLineBytes" () (ELit (LInt 8192)))
(DTypeSig true "maxHttpResponseStatusLineBytes" (TyCon "Int"))
(DFunDef false "maxHttpResponseStatusLineBytes" () (ELit (LInt 8192)))
(DTypeSig true "maxHttpResponseChunkBytes" (TyCon "Int"))
(DFunDef false "maxHttpResponseChunkBytes" () (ELit (LInt 1048576)))
(DTypeSig true "maxHttpHeaderFields" (TyCon "Int"))
(DFunDef false "maxHttpHeaderFields" () (ELit (LInt 100)))
(DTypeSig true "maxHttpTrailerFields" (TyCon "Int"))
(DFunDef false "maxHttpTrailerFields" () (ELit (LInt 32)))
(DTypeSig true "maxHttpChunks" (TyCon "Int"))
(DFunDef false "maxHttpChunks" () (ELit (LInt 65536)))
(DTypeSig true "maxJsonBodyBytes" (TyCon "Int"))
(DFunDef false "maxJsonBodyBytes" () (ELit (LInt 153600)))
(DTypeSig true "maxTextBodyBytes" (TyCon "Int"))
(DFunDef false "maxTextBodyBytes" () (ELit (LInt 102400)))
(DTypeSig true "maxRawBodyBytes" (TyCon "Int"))
(DFunDef false "maxRawBodyBytes" () (ELit (LInt 5242880)))
(DTypeSig true "checkHttpRequestBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpRequestBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpRequestBytes")) (EApp (EVar "Err") (ELit (LString "http: request exceeds 6291456-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpHeaderBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpHeaderBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpHeaderBytes")) (EApp (EVar "Err") (ELit (LString "http: combined header and trailer section exceeds 65536-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpRequestLineBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpRequestLineBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpRequestLineBytes")) (EApp (EVar "Err") (ELit (LString "http: request line exceeds 8192-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpResponseStatusLineBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpResponseStatusLineBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpResponseStatusLineBytes")) (EApp (EVar "Err") (ELit (LString "http: status line exceeds 8192-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpResponseChunkBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpResponseChunkBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpResponseChunkBytes")) (EApp (EVar "Err") (ELit (LString "http: chunk size exceeds 1048576-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpHeaderFields" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpHeaderFields" ((PVar "count")) (EIf (EBinOp ">" (EVar "count") (EVar "maxHttpHeaderFields")) (EApp (EVar "Err") (ELit (LString "http: header field count exceeds 100 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpTrailerFields" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpTrailerFields" ((PVar "count")) (EIf (EBinOp ">" (EVar "count") (EVar "maxHttpTrailerFields")) (EApp (EVar "Err") (ELit (LString "http: trailer field count exceeds 32 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpChunks" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpChunks" ((PVar "count")) (EIf (EBinOp ">" (EVar "count") (EVar "maxHttpChunks")) (EApp (EVar "Err") (ELit (LString "http: chunk count exceeds 65536 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkJsonBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkJsonBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxJsonBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: JSON body exceeds 153600-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkTextBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkTextBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxTextBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: text body exceeds 102400-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkRawBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkRawBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxRawBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: raw body exceeds 5242880-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DData Abstract "Header" () ((variant "Header" (ConPos (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Abstract "Request" () ((variant "Request" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Bytes") (TyCon "Bool")))) ())
(DData Private "RequestLine" () ((variant "RequestLine" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int")))) ())
(DData Private "HeaderBlock" () ((variant "HeaderBlock" (ConPos (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int")))) ())
(DData Private "BodyMode" () ((variant "NoBody" (ConPos)) (variant "FixedBody" (ConPos (TyCon "Int"))) (variant "ChunkedBody" (ConPos)) (variant "UntilCloseBody" (ConPos))) ())
(DData Private "ParsedBody" () ((variant "ParsedBody" (ConPos (TyCon "Bytes") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int")))) ())
(DTypeSig false "emptyBody" (TyCon "Bytes"))
(DFunDef false "emptyBody" () (EApp (EVar "fromArrayAssumeByteDomain") (EArrayLit)))
(DData Public "HttpParseFailure" () ((variant "HttpMalformed" (ConPos (TyCon "String"))) (variant "HttpResourceExcess" (ConPos (TyCon "String")))) ())
(DData Private "FrameError" () ((variant "Incomplete" (ConPos (TyCon "String"))) (variant "Fatal" (ConPos (TyCon "HttpParseFailure")))) ())
(DTypeSig false "settle" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyVar "a"))))
(DFunDef false "settle" ((PCon "Ok" (PVar "value"))) (EApp (EVar "Ok") (EVar "value")))
(DFunDef false "settle" ((PCon "Err" (PCon "Incomplete" (PVar "message")))) (EApp (EVar "Err") (EApp (EVar "HttpMalformed") (EVar "message"))))
(DFunDef false "settle" ((PCon "Err" (PCon "Fatal" (PVar "failure")))) (EApp (EVar "Err") (EVar "failure")))
(DTypeSig false "malformed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "malformed" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpMalformed") (EVar "message")))))
(DTypeSig false "incomplete" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "incomplete" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Incomplete") (EVar "message"))))
(DTypeSig false "resourceExcess" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "resourceExcess" ((PCon "Ok" (PLit LUnit))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "resourceExcess" ((PCon "Err" (PVar "message"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EVar "message")))))
(DTypeSig true "httpParseFailureMessage" (TyFun (TyCon "HttpParseFailure") (TyCon "String")))
(DFunDef false "httpParseFailureMessage" ((PCon "HttpMalformed" (PVar "message"))) (EVar "message"))
(DFunDef false "httpParseFailureMessage" ((PCon "HttpResourceExcess" (PVar "message"))) (EVar "message"))
(DTypeSig true "headerName" (TyFun (TyCon "Header") (TyCon "String")))
(DFunDef false "headerName" ((PCon "Header" (PVar "name") PWild)) (EVar "name"))
(DTypeSig true "headerValue" (TyFun (TyCon "Header") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "headerValue" ((PCon "Header" PWild (PVar "value"))) (EApp (EVar "arrayCopy") (EVar "value")))
(DTypeSig false "copyHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "copyHeaders" ((PList)) (EListLit))
(DFunDef false "copyHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "Header") (EVar "name")) (EApp (EVar "arrayCopy") (EVar "value"))) (EApp (EVar "copyHeaders") (EVar "rest"))))
(DTypeSig true "requestMethod" (TyFun (TyCon "Request") (TyCon "String")))
(DFunDef false "requestMethod" ((PCon "Request" (PVar "method") PWild PWild PWild PWild PWild)) (EVar "method"))
(DTypeSig true "requestTarget" (TyFun (TyCon "Request") (TyCon "String")))
(DFunDef false "requestTarget" ((PCon "Request" PWild (PVar "target") PWild PWild PWild PWild)) (EVar "target"))
(DTypeSig true "requestHeaders" (TyFun (TyCon "Request") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "requestHeaders" ((PCon "Request" PWild PWild (PVar "headers") PWild PWild PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "requestTrailers" (TyFun (TyCon "Request") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "requestTrailers" ((PCon "Request" PWild PWild PWild (PVar "trailers") PWild PWild)) (EApp (EVar "copyHeaders") (EVar "trailers")))
(DTypeSig true "requestBody" (TyFun (TyCon "Request") (TyCon "Bytes")))
(DFunDef false "requestBody" ((PCon "Request" PWild PWild PWild PWild (PVar "body") PWild)) (EVar "body"))
(DTypeSig true "requestBodyLength" (TyFun (TyCon "Request") (TyCon "Int")))
(DFunDef false "requestBodyLength" ((PCon "Request" PWild PWild PWild PWild (PVar "body") PWild)) (EApp (EVar "bytesLength") (EVar "body")))
(DTypeSig true "requestKeepAlive" (TyFun (TyCon "Request") (TyCon "Bool")))
(DFunDef false "requestKeepAlive" ((PCon "Request" PWild PWild PWild PWild PWild (PVar "keepAlive"))) (EVar "keepAlive"))
(DTypeSig false "validBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validBytes" ((PVar "value") (PVar "i") (PVar "end")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "i")) (ELit (LInt 0))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "i")) (ELit (LInt 255)))) (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "lowerByte" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "lowerByte" ((PVar "byte")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90)))) (EBinOp "+" (EVar "byte") (ELit (LInt 32))) (EVar "byte")))
(DTypeSig false "lowerAscii" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lowerAscii" ((PVar "input") (PVar "start") (PVar "end")) (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "i")) (EApp (EVar "lowerByte") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "start") (EVar "i"))))))))
(DTypeSig false "lowerAsciiBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lowerAsciiBytes" ((PVar "input") (PVar "start") (PVar "end")) (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "i")) (EApp (EVar "lowerByte") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "start") (EVar "i"))))))))
(DTypeSig true "isTokenByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isTokenByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 122))))) (EBinOp "==" (EVar "byte") (ELit (LInt 33)))) (EBinOp "==" (EVar "byte") (ELit (LInt 35)))) (EBinOp "==" (EVar "byte") (ELit (LInt 36)))) (EBinOp "==" (EVar "byte") (ELit (LInt 37)))) (EBinOp "==" (EVar "byte") (ELit (LInt 38)))) (EBinOp "==" (EVar "byte") (ELit (LInt 39)))) (EBinOp "==" (EVar "byte") (ELit (LInt 42)))) (EBinOp "==" (EVar "byte") (ELit (LInt 43)))) (EBinOp "==" (EVar "byte") (ELit (LInt 45)))) (EBinOp "==" (EVar "byte") (ELit (LInt 46)))) (EBinOp "==" (EVar "byte") (ELit (LInt 94)))) (EBinOp "==" (EVar "byte") (ELit (LInt 95)))) (EBinOp "==" (EVar "byte") (ELit (LInt 96)))) (EBinOp "==" (EVar "byte") (ELit (LInt 124)))) (EBinOp "==" (EVar "byte") (ELit (LInt 126)))))
(DTypeSig false "allToken" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allToken" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isTokenByte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allToken") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "allTokenBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allTokenBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isTokenByte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "isHexByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isHexByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 70))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 102))))))
(DTypeSig false "isUnreservedByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isUnreservedByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 122))))) (EBinOp "==" (EVar "byte") (ELit (LInt 45)))) (EBinOp "==" (EVar "byte") (ELit (LInt 46)))) (EBinOp "==" (EVar "byte") (ELit (LInt 95)))) (EBinOp "==" (EVar "byte") (ELit (LInt 126)))))
(DTypeSig false "isSubDelimiterByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSubDelimiterByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 33))) (EBinOp "==" (EVar "byte") (ELit (LInt 36)))) (EBinOp "==" (EVar "byte") (ELit (LInt 38)))) (EBinOp "==" (EVar "byte") (ELit (LInt 39)))) (EBinOp "==" (EVar "byte") (ELit (LInt 40)))) (EBinOp "==" (EVar "byte") (ELit (LInt 41)))) (EBinOp "==" (EVar "byte") (ELit (LInt 42)))) (EBinOp "==" (EVar "byte") (ELit (LInt 43)))) (EBinOp "==" (EVar "byte") (ELit (LInt 44)))) (EBinOp "==" (EVar "byte") (ELit (LInt 59)))) (EBinOp "==" (EVar "byte") (ELit (LInt 61)))))
(DTypeSig false "validTarget" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "validTarget" ((PVar "input") (PVar "pos") (PVar "end") (PVar "query")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "byte") (ELit (LInt 37))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end")) (EVar "query"))) (EBlock (DoLet false false (PVar "pchar") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EBinOp "==" (EVar "byte") (ELit (LInt 58)))) (EBinOp "==" (EVar "byte") (ELit (LInt 64))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EVar "pchar") (EBinOp "==" (EVar "byte") (ELit (LInt 47)))) (EBinOp "&&" (EVar "query") (EBinOp "==" (EVar "byte") (ELit (LInt 63))))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "query")) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "query")) (EBinOp "==" (EVar "byte") (ELit (LInt 63)))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "True")) (EVar "False"))))))))))
(DTypeSig false "exactAsciiAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "exactAsciiAt" ((PVar "input") (PVar "start") (PVar "expected")) (EBlock (DoLet false false (PVar "wanted") (EApp (EVar "toUtf8Bytes") (EVar "expected"))) (DoLet false false (PVar "size") (EApp (EVar "bytesLength") (EVar "wanted"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EBinOp "+" (EVar "start") (EVar "size")) (EApp (EVar "bytesLength") (EVar "input"))) (EBinOp "==" (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "start")) (EBinOp "+" (EVar "start") (EVar "size"))) (EVar "wanted"))))))
(DTypeSig false "validFieldValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validFieldValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "validFieldValue") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validFieldValueBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validFieldValueBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "validFieldValueBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig true "findByte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findByte" ((PVar "value") (PVar "pos") (PVar "end") (PVar "wanted")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (EVar "wanted")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "wanted")))))
(DTypeSig false "findByteBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findByteBytes" ((PVar "input") (PVar "pos") (PVar "end") (PVar "wanted")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (EVar "wanted")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "wanted")))))
(DTypeSig false "findCrlfChecked" (TyFun (TyCon "String") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))))
(DFunDef false "findCrlfChecked" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "pos") (PVar "limit")) (EIf (EBinOp ">" (EBinOp "-" (EVar "pos") (EVar "start")) (EVar "limit")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EBinOp "++" (EBinOp "++" (ELit (LString "http: ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " exceeds its resource limit")))))) (EIf (EBinOp ">=" (EVar "pos") (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "; expected CRLF")))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 10))) (EApp (EVar "malformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare LF in ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10))) (EApp (EVar "malformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "limit")))))))
(DTypeSig true "findCrlf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findCrlf" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EVar "findCrlf") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "parseRequestLine" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "RequestLine")))))))
(DFunDef false "parseRequestLine" ((PVar "input") (PVar "avail") (PVar "start") (PVar "cursor")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (ELit (LString "request line"))) (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "cursor")) (EVar "maxHttpRequestLineBytes"))) (ELam ((PVar "end")) (EApp (EApp (EVar "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpRequestLineBytes") (EBinOp "-" (EVar "end") (EVar "start"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "firstSpace")) (EApp (EApp (EVar "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "secondSpace")) (EIf (EBinOp "||" (EBinOp "==" (EVar "firstSpace") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EVar "start")) (EVar "firstSpace")))) (EApp (EVar "malformed") (ELit (LString "http: invalid method token"))) (EIf (EBinOp "==" (EVar "secondSpace") (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EApp (EVar "malformed") (ELit (LString "http: empty request target"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (ELit (LInt 47))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "secondSpace")) (EVar "False")))) (EApp (EVar "malformed") (ELit (LString "http: request target must be an origin-form ASCII target without a fragment"))) (EIf (EBinOp "||" (EBinOp "/=" (EBinOp "+" (EVar "secondSpace") (ELit (LInt 9))) (EVar "end")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "exactAsciiAt") (EVar "input")) (EBinOp "+" (EVar "secondSpace") (ELit (LInt 1)))) (ELit (LString "HTTP/1.1"))))) (EApp (EVar "malformed") (ELit (LString "http: only HTTP/1.1 requests are supported"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "RequestLine") (EApp (EVar "fromUtf8Bytes") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "start")) (EVar "firstSpace")))) (EApp (EVar "fromUtf8Bytes") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "secondSpace")))) (EBinOp "+" (EVar "end") (ELit (LInt 2)))))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig true "trimLeftOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimLeftOws" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "trimLeftOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimLeftOwsBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimLeftOwsBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig true "trimRightOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimRightOws" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "end") (EVar "start")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimRightOws") (EVar "value")) (EVar "start")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "end")))
(DTypeSig false "trimRightOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimRightOwsBytes" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "end") (EVar "start")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimRightOwsBytes") (EVar "input")) (EVar "start")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "end")))
(DTypeSig false "parseHeaderLine" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Header"))))))
(DFunDef false "parseHeaderLine" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 9)))) (EApp (EVar "malformed") (ELit (LString "http: obsolete folded header lines are forbidden"))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed header field; missing colon")))) (arm (PCon "Some" (PVar "colon")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "colon") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EVar "start")) (EVar "colon")))) (EApp (EVar "malformed") (ELit (LString "http: invalid header field name"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validFieldValueBytes") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "malformed") (ELit (LString "http: control byte in header field value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "trimLeftOwsBytes") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "trimRightOwsBytes") (EVar "input")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAsciiBytes") (EVar "input")) (EVar "start")) (EVar "colon"))) (EApp (EVar "toArray") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "valueStart")) (EVar "valueEnd")))))))))))))
(DTypeSig false "forbiddenTrailer" (TyFun (TyCon "Header") (TyCon "Bool")))
(DFunDef false "forbiddenTrailer" ((PCon "Header" (PVar "name") PWild)) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "content-length"))) (EBinOp "==" (EVar "name") (ELit (LString "transfer-encoding")))) (EBinOp "==" (EVar "name") (ELit (LString "trailer")))) (EBinOp "==" (EVar "name") (ELit (LString "host")))) (EBinOp "==" (EVar "name") (ELit (LString "connection")))))
(DTypeSig false "checkFieldCount" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit")))))
(DFunDef false "checkFieldCount" ((PVar "trailer") (PVar "count")) (EIf (EVar "trailer") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpTrailerFields") (EVar "count"))) (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpHeaderFields") (EVar "count")))))
(DData Private "FieldStep" () ((variant "FieldDone" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "FieldMore" (ConPos (TyCon "Header") (TyCon "Int")))) ())
(DTypeSig false "fieldStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FieldStep")))))))))))
(DFunDef false "fieldStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "cursor") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "trailer")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (EIf (EVar "trailer") (ELit (LString "trailer field")) (ELit (LString "header field")))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "cursor")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "end")) (ELet false (PVar "next") (EBinOp "+" (EVar "end") (ELit (LInt 2))) (ELet false (PVar "totalBytes") (EBinOp "-" (EBinOp "+" (EVar "priorBytes") (EVar "next")) (EVar "sectionStart")) (EApp (EApp (EVar "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpHeaderBytes") (EVar "totalBytes")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EIf (EBinOp "==" (EVar "end") (EVar "pos")) (EApp (EVar "Ok") (EApp (EApp (EVar "FieldDone") (EVar "next")) (EVar "totalBytes"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "checkFieldCount") (EVar "trailer")) (EBinOp "+" (EVar "count") (ELit (LInt 1))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseHeaderLine") (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "field")) (EIf (EBinOp "&&" (EVar "trailer") (EApp (EVar "forbiddenTrailer") (EVar "field"))) (EApp (EVar "malformed") (ELit (LString "http: forbidden framing or routing field in trailer"))) (EApp (EVar "Ok") (EApp (EApp (EVar "FieldMore") (EVar "field")) (EVar "next"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "parseFieldsChecked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "HeaderBlock"))))))))))
(DFunDef false "parseFieldsChecked" ((PVar "input") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "trailer") (PVar "acc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "pos")) (EVar "pos")) (EVar "sectionStart")) (EVar "priorBytes")) (EVar "count")) (EVar "trailer"))) (ELam ((PVar "step")) (EMatch (EVar "step") (arm (PCon "FieldDone" (PVar "next") (PVar "totalBytes")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "HeaderBlock") (EApp (EVar "reverse") (EVar "acc"))) (EVar "next")) (EVar "totalBytes")))) (arm (PCon "FieldMore" (PVar "field") (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "next")) (EVar "sectionStart")) (EVar "priorBytes")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EVar "trailer")) (EBinOp "::" (EVar "field") (EVar "acc"))))))))
(DTypeSig true "parseFields" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyTuple (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int")))))))
(DFunDef false "parseFields" ((PVar "input") (PVar "pos") (PVar "trailer")) (EApp (EApp (EVar "map") (ELam ((PCon "HeaderBlock" (PVar "fields") (PVar "next") PWild)) (ETuple (EVar "fields") (EVar "next")))) (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "pos")) (EVar "pos")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "trailer")) (EListLit)))))
(DTypeSig false "countNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))
(DFunDef false "countNamed" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "countNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "findNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "findNamed" (PWild (PList)) (EVar "None"))
(DFunDef false "findNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "findNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "asciiEqualCiGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "asciiEqualCiGo" ((PVar "value") (PVar "expected") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EBinOp "==" (EVar "i") (EApp (EVar "arrayLength") (EVar "expected"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "expected"))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "i")) (ELit (LInt 127)))) (EBinOp "==" (EApp (EVar "lowerByte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "i"))) (EApp (EVar "lowerByte") (EApp (EApp (EVar "index") (EVar "expected")) (EVar "i"))))) (EApp (EApp (EApp (EVar "asciiEqualCiGo") (EVar "value")) (EVar "expected")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "asciiEqualCi" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "asciiEqualCi" ((PVar "value") (PVar "expected")) (EApp (EApp (EApp (EVar "asciiEqualCiGo") (EVar "value")) (EApp (EVar "toUtf8") (EVar "expected"))) (ELit (LInt 0))))
(DTypeSig false "parseDecimalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseDecimalGo" ((PVar "value") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EApp (EVar "Ok") (EVar "acc")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "byte") (ELit (LInt 48))) (EBinOp ">" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "malformed") (ELit (LString "http: invalid Content-Length"))) (EBlock (DoLet false false (PVar "digit") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (DoExpr (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (ELit (LInt 4611686018427387903)) (EVar "digit")) (ELit (LInt 10)))) (EApp (EVar "malformed") (ELit (LString "http: Content-Length overflows Int"))) (EApp (EApp (EApp (EVar "parseDecimalGo") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "digit")))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "value")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "malformed") (ELit (LString "http: empty Content-Length"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseDecimalGo") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EVar "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpBodyBytes") (EVar "size")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "selectBodyMode" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "BodyMode"))))
(DFunDef false "selectBodyMode" ((PVar "headers")) (EBlock (DoLet false false (PVar "clCount") (EApp (EApp (EVar "countNamed") (ELit (LString "content-length"))) (EVar "headers"))) (DoLet false false (PVar "teCount") (EApp (EApp (EVar "countNamed") (ELit (LString "transfer-encoding"))) (EVar "headers"))) (DoExpr (EIf (EBinOp ">" (EVar "clCount") (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: duplicate Content-Length is ambiguous"))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "clCount") (ELit (LInt 0))) (EBinOp ">" (EVar "teCount") (ELit (LInt 0)))) (EApp (EVar "malformed") (ELit (LString "http: Transfer-Encoding with Content-Length is ambiguous"))) (EIf (EBinOp ">" (EVar "teCount") (ELit (LInt 0))) (EIf (EBinOp "/=" (EVar "teCount") (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: repeated Transfer-Encoding is unsupported"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "transfer-encoding"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EApp (EVar "asciiEqualCi") (EVar "value")) (ELit (LString "chunked"))) (EApp (EVar "Ok") (EVar "ChunkedBody")) (EApp (EVar "malformed") (ELit (LString "http: unsupported transfer coding; expected exactly chunked"))))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: internal transfer framing error")))))) (EIf (EBinOp "==" (EVar "clCount") (ELit (LInt 1))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "content-length"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EApp (EApp (EVar "map") (EVar "FixedBody")) (EApp (EVar "parseContentLength") (EVar "value")))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: internal content framing error"))))) (EApp (EVar "Ok") (EVar "NoBody")))))))))
(DTypeSig false "scanTokenEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanTokenEnd" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isTokenByte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "scanTokenEndBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanTokenEndBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isTokenByte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "parseConnectionValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Bool"))))))
(DFunDef false "parseConnectionValue" ((PVar "value") (PVar "pos") (PVar "sawClose")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: empty token in Connection field"))) (EBlock (DoLet false false (PVar "tokenEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "start")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "tokenEnd") (EVar "start")) (EApp (EVar "malformed") (ELit (LString "http: invalid Connection token"))) (EBlock (DoLet false false (PVar "closeNow") (EBinOp "||" (EVar "sawClose") (EBinOp "==" (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (EVar "start")) (EVar "tokenEnd")) (ELit (LString "close"))))) (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EVar "tokenEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "after") (EVar "end")) (EApp (EVar "Ok") (EVar "closeNow")) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "after")) (ELit (LInt 44))) (EApp (EVar "malformed") (ELit (LString "http: invalid Connection token list"))) (EApp (EApp (EApp (EVar "parseConnectionValue") (EVar "value")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "closeNow")))))))))))))
(DTypeSig false "keepAliveFromHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Bool"))))
(DFunDef false "keepAliveFromHeaders" ((PList)) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "keepAliveFromHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "andThen") (EApp (EVar "keepAliveFromHeaders") (EVar "rest"))) (ELam ((PVar "restKeepAlive")) (EIf (EBinOp "/=" (EVar "name") (ELit (LString "connection"))) (EApp (EVar "Ok") (EVar "restKeepAlive")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseConnectionValue") (EVar "value")) (ELit (LInt 0))) (EVar "False"))) (ELam ((PVar "closes")) (EApp (EVar "Ok") (EBinOp "&&" (EVar "restKeepAlive") (EApp (EVar "not") (EVar "closes"))))))))))
(DTypeSig false "validRegName" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validRegName" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "byte") (ELit (LInt 37))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end"))))))))
(DTypeSig false "allDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allDigits" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 57)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "decimalValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "decimalValue" ((PVar "value") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "decimalValue") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos"))) (ELit (LInt 48))))))
(DTypeSig false "validIpv4" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "validIpv4" ((PVar "value") (PVar "start") (PVar "end") (PVar "parts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "parts") (ELit (LInt 4))) (EBinOp ">=" (EVar "start") (EVar "end"))) (EVar "False") (EBlock (DoLet false false (PVar "dot") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "start")) (EVar "end")) (ELit (LInt 46))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoLet false false (PVar "size") (EBinOp "-" (EVar "dot") (EVar "start"))) (DoLet false false (PVar "validPart") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "size") (ELit (LInt 1))) (EBinOp "<=" (EVar "size") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EVar "start")) (EVar "dot"))) (EBinOp "<=" (EApp (EApp (EApp (EApp (EVar "decimalValue") (EVar "value")) (EVar "start")) (EVar "dot")) (ELit (LInt 0))) (ELit (LInt 255)))) (EBinOp "||" (EBinOp "==" (EVar "size") (ELit (LInt 1))) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "start")) (ELit (LInt 48)))))) (DoExpr (EIf (EApp (EVar "not") (EVar "validPart")) (EVar "False") (EIf (EBinOp "==" (EVar "dot") (EVar "end")) (EBinOp "==" (EVar "parts") (ELit (LInt 3))) (EApp (EApp (EApp (EApp (EVar "validIpv4") (EVar "value")) (EBinOp "+" (EVar "dot") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EVar "parts") (ELit (LInt 1))))))))))
(DTypeSig false "allHex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allHex" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allHex") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "validIpv6Go" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "validIpv6Go" ((PVar "value") (PVar "pos") (PVar "end") (PVar "groups") (PVar "compressed")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EIf (EVar "compressed") (EBinOp "<" (EVar "groups") (ELit (LInt 8))) (EBinOp "==" (EVar "groups") (ELit (LInt 8)))) (EBlock (DoLet false false (PVar "colon") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "pos")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "at")) () (EVar "at")))) (DoExpr (EIf (EBinOp "==" (EVar "colon") (EVar "pos")) (EVar "False") (EBlock (DoLet false false (PVar "dot") (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "pos")) (EVar "colon")) (ELit (LInt 46)))) (DoLet false false (PVar "componentGroups") (EMatch (EVar "dot") (arm (PCon "None") () (EIf (EBinOp "&&" (EBinOp "<=" (EBinOp "-" (EVar "colon") (EVar "pos")) (ELit (LInt 4))) (EApp (EApp (EApp (EVar "allHex") (EVar "value")) (EVar "pos")) (EVar "colon"))) (ELit (LInt 1)) (ELit (LInt 9)))) (arm (PCon "Some" PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "colon") (EVar "end")) (EApp (EApp (EApp (EApp (EVar "validIpv4") (EVar "value")) (EVar "pos")) (EVar "colon")) (ELit (LInt 0)))) (ELit (LInt 2)) (ELit (LInt 9)))))) (DoLet false false (PVar "nextGroups") (EBinOp "+" (EVar "groups") (EVar "componentGroups"))) (DoExpr (EIf (EBinOp ">" (EVar "nextGroups") (ELit (LInt 8))) (EVar "False") (EIf (EBinOp "==" (EVar "colon") (EVar "end")) (EIf (EVar "compressed") (EBinOp "<" (EVar "nextGroups") (ELit (LInt 8))) (EBinOp "==" (EVar "nextGroups") (ELit (LInt 8)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "colon") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (ELit (LInt 58)))) (EBinOp "&&" (EApp (EVar "not") (EVar "compressed")) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 2)))) (EVar "end")) (EVar "nextGroups")) (EVar "True"))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end")) (EVar "nextGroups")) (EVar "compressed"))))))))))))
(DTypeSig false "validIpv6" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpv6" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "start")) (ELit (LInt 58))) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "start") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (ELit (LInt 58)))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 2)))) (EVar "end")) (ELit (LInt 0))) (EVar "True"))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EVar "start")) (EVar "end")) (ELit (LInt 0))) (EVar "False")))))
(DTypeSig false "scanHex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanHex" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanHex") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "validIpvFutureTail" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpvFutureTail" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EBinOp "==" (EVar "byte") (ELit (LInt 58)))) (EApp (EApp (EApp (EVar "validIpvFutureTail") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validIpvFuture" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpvFuture" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "start") (EVar "end")) (EBinOp "&&" (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "start")) (ELit (LInt 118))) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "start")) (ELit (LInt 86))))) (EVar "False") (EBlock (DoLet false false (PVar "versionEnd") (EApp (EApp (EApp (EVar "scanHex") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "versionEnd") (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "<" (EVar "versionEnd") (EVar "end"))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "versionEnd")) (ELit (LInt 46)))) (EBinOp "<" (EBinOp "+" (EVar "versionEnd") (ELit (LInt 1))) (EVar "end"))) (EApp (EApp (EApp (EVar "validIpvFutureTail") (EVar "value")) (EBinOp "+" (EVar "versionEnd") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validIpLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpLiteral" ((PVar "value") (PVar "start") (PVar "end")) (EBinOp "||" (EApp (EApp (EApp (EVar "validIpv6") (EVar "value")) (EVar "start")) (EVar "end")) (EApp (EApp (EApp (EVar "validIpvFuture") (EVar "value")) (EVar "start")) (EVar "end"))))
(DTypeSig false "validHostAuthority" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "validHostAuthority" ((PVar "value")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoExpr (EIf (EBinOp "==" (EVar "end") (ELit (LInt 0))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 91))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (ELit (LInt 1))) (EVar "end")) (ELit (LInt 93))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "close")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "validIpLiteral") (EVar "value")) (ELit (LInt 1))) (EVar "close")) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "close") (ELit (LInt 1))) (EVar "end")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "close") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "close") (ELit (LInt 1)))) (ELit (LInt 58)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "close") (ELit (LInt 2)))) (EVar "end"))))))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (ELit (LInt 0))) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (arm (PCon "Some" (PVar "colon")) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "colon") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (ELit (LInt 0))) (EVar "colon"))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))))))))))
(DTypeSig false "validateHost" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "validateHost" ((PVar "headers")) (EIf (EBinOp "/=" (EApp (EApp (EVar "countNamed") (ELit (LString "host"))) (EVar "headers")) (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: HTTP/1.1 requires exactly one Host field"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "host"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EVar "not") (EApp (EVar "validHostAuthority") (EVar "value"))) (EApp (EVar "malformed") (ELit (LString "http: Host field must contain a valid authority"))) (EApp (EVar "Ok") (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: missing Host field")))))))
(DTypeSig false "readSliceAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyCon "Bytes") (TyCon "Int")))))))
(DFunDef false "readSliceAt" ((PVar "input") (PVar "pos") (PVar "size")) (EBlock (DoLet false false (PVar "avail") (EApp (EVar "bytesLength") (EVar "input"))) (DoExpr (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "size"))) (EBinOp "+" (EVar "pos") (EVar "size"))))))))
(DTypeSig false "emitArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyCon "Unit")))))
(DFunDef false "emitArray" ((PVar "bytes") (PVar "i") (PVar "out")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "out"))))))
(DTypeSig true "hexDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexDigit" ((PVar "byte")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 55)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 87)))) (EVar "None")))))
(DTypeSig false "parseHexSizeGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "parseHexSizeGo" ((PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EVar "hexDigit") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: invalid chunk size")))) (arm (PCon "Some" (PVar "digit")) () (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "maxHttpBodyBytes") (EVar "digit")) (ELit (LInt 16)))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk size exceeds decoded body limit"))))) (EApp (EApp (EApp (EApp (EVar "parseHexSizeGo") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "digit"))))))))
(DTypeSig true "skipOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipOws" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "skipOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipOwsBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "scanQuoted" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "scanQuoted" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: unterminated quoted chunk extension"))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: truncated quoted-pair in chunk extension"))) (EBlock (DoLet false false (PVar "escaped") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "escaped") (ELit (LInt 9))) (EBinOp "==" (EVar "escaped") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp ">=" (EVar "escaped") (ELit (LInt 33))) (EBinOp "/=" (EVar "escaped") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: control byte in quoted chunk extension"))))))) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "==" (EVar "byte") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 33))) (EBinOp "/=" (EVar "byte") (ELit (LInt 34)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 92)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: control byte in quoted chunk extension"))))))))))
(DTypeSig false "parseChunkExtensionValue" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseChunkExtensionValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: missing chunk extension value"))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "valueEnd") (EVar "pos")) (EApp (EVar "malformed") (ELit (LString "http: invalid chunk extension value"))) (EApp (EVar "Ok") (EVar "valueEnd"))))))))
(DTypeSig false "parseChunkExtensionsGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))))
(DFunDef false "parseChunkExtensionsGo" ((PVar "input") (PVar "pos") (PVar "end")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "malformed") (ELit (LString "http: invalid chunk extension separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "malformed") (ELit (LString "http: empty chunk extension name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "afterName") (EVar "end")) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseChunkExtensionValue") (EVar "input")) (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (EVar "end"))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "valueEnd")) (EVar "end")))) (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "afterName")) (EVar "end")))))))))))))
(DTypeSig false "parseChunkSize" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseChunkSize" ((PVar "input") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "semi") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 59))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "semi") (EVar "start")) (EApp (EVar "malformed") (ELit (LString "http: empty chunk size"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "parseHexSizeGo") (EVar "input")) (EVar "start")) (EVar "semi")) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "semi")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig false "parseChunkedChecked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedBody")))))))))
(DFunDef false "parseChunkedChecked" ((PVar "input") (PVar "pos") (PVar "headerBytes") (PVar "out") (PVar "total") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chunkHeadStep") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "pos")) (EVar "pos")) (EVar "total")) (EVar "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ChunkEnd" (PVar "dataPos")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "dataPos")) (EVar "dataPos")) (EVar "headerBytes")) (ELit (LInt 0))) (EVar "True")) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "HeaderBlock" (PVar "trailers") (PVar "finalPos") PWild) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EApp (EVar "buildBytes") (EVar "out"))) (EVar "trailers")) (EVar "finalPos")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm (PCon "ChunkBody" (PVar "dataPos") (PVar "size")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "readSliceAt") (EVar "input")) (EVar "dataPos")) (EVar "size"))) (ELam ((PTuple (PVar "chunk") PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "chunkDataEnd") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (ELet false (PLit LUnit) (EApp (EApp (EVar "appendBytes") (EVar "chunk")) (EVar "out")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "next")) (EVar "headerBytes")) (EVar "out")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EVar "count") (ELit (LInt 1))))))))))))))
(DTypeSig true "parseChunked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyTuple (TyCon "Bytes") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))
(DFunDef false "parseChunked" ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "map") (ELam ((PCon "ParsedBody" (PVar "body") (PVar "trailers") (PVar "next"))) (ETuple (EVar "body") (EVar "trailers") (EVar "next")))) (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "pos")) (ELit (LInt 0))) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DData Private "ChunkHead" () ((variant "ChunkEnd" (ConPos (TyCon "Int"))) (variant "ChunkBody" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "chunkHeadStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ChunkHead")))))))))
(DFunDef false "chunkHeadStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "cursor") (PVar "total") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (ELit (LString "chunk-size line"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "cursor")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "lineEnd")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseChunkSize") (EVar "input")) (EVar "pos")) (EVar "lineEnd"))) (ELam ((PVar "size")) (ELet false (PVar "dataPos") (EBinOp "+" (EVar "lineEnd") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "size") (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "ChunkEnd") (EVar "dataPos"))) (EApp (EApp (EVar "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpChunks") (EBinOp "+" (EVar "count") (ELit (LInt 1)))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EIf (EBinOp ">" (EVar "size") (EBinOp "-" (EVar "maxHttpBodyBytes") (EVar "total"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded chunked body exceeds resource limit"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "ChunkBody") (EVar "dataPos")) (EVar "size"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))
(DTypeSig false "chunkDataEnd" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "chunkDataEnd" ((PVar "input") (PVar "avail") (PVar "dataPos") (PVar "size")) (EBlock (DoLet false false (PVar "afterChunk") (EBinOp "+" (EVar "dataPos") (EVar "size"))) (DoExpr (EIf (EBinOp ">" (EVar "afterChunk") (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EIf (EBinOp ">" (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))) (EVar "avail")) (EApp (EVar "incomplete") (ELit (LString "http: truncated CRLF after chunk data"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EVar "afterChunk")) (ELit (LInt 13))) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "afterChunk") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "malformed") (ELit (LString "http: missing CRLF after chunk data"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))))))))))
(DTypeSig false "parseBody" (TyFun (TyCon "BodyMode") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedBody")))))))
(DFunDef false "parseBody" ((PCon "NoBody") PWild (PVar "pos") PWild) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EVar "emptyBody")) (EListLit)) (EVar "pos"))))
(DFunDef false "parseBody" ((PCon "FixedBody" (PVar "size")) (PVar "input") (PVar "pos") PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "readSliceAt") (EVar "input")) (EVar "pos")) (EVar "size"))) (ELam ((PTuple (PVar "body") (PVar "finalPos"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EVar "body")) (EListLit)) (EVar "finalPos"))))))
(DFunDef false "parseBody" ((PCon "ChunkedBody") (PVar "input") (PVar "pos") (PVar "headerBytes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "pos")) (EVar "headerBytes")) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))
(DFunDef false "parseBody" ((PCon "UntilCloseBody") (PVar "input") (PVar "pos") PWild) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EApp (EVar "bytesLength") (EVar "input")))) (EListLit)) (EApp (EVar "bytesLength") (EVar "input")))))
(DTypeSig false "trailingMessage" (TyFun (TyCon "BodyMode") (TyCon "String")))
(DFunDef false "trailingMessage" ((PCon "NoBody")) (ELit (LString "http: unframed or trailing request bytes")))
(DFunDef false "trailingMessage" ((PCon "FixedBody" PWild)) (ELit (LString "http: bytes after framed fixed-length request")))
(DFunDef false "trailingMessage" ((PCon "ChunkedBody")) (ELit (LString "http: bytes after framed chunked request")))
(DData Private "FramedRequest" () ((variant "FramedRequest" (ConPos (TyCon "Request") (TyCon "BodyMode") (TyCon "Int")))) ())
(DData Private "FrameHead" () ((variant "FrameHead" (ConPos (TyCon "RequestLine") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "BodyMode") (TyCon "Bool") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "FrameSpan" () ((variant "FrameSpan" (ConPos (TyCon "FrameHead") (TyCon "Int")))) ())
(DTypeSig false "headHeaderBytes" (TyFun (TyCon "FrameHead") (TyCon "Int")))
(DFunDef false "headHeaderBytes" ((PCon "FrameHead" PWild PWild PWild PWild PWild (PVar "headerBytes"))) (EVar "headerBytes"))
(DTypeSig false "requestLineHeaderPos" (TyFun (TyCon "RequestLine") (TyCon "Int")))
(DFunDef false "requestLineHeaderPos" ((PCon "RequestLine" PWild PWild (PVar "headerPos"))) (EVar "headerPos"))
(DData Private "BodyPhase" () ((variant "BodyUntil" (ConPos (TyCon "Int"))) (variant "BodyChunkSize" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "BodyChunkData" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "BodyTrailers" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "ScanPhase" () ((variant "PhaseLine" (ConPos (TyCon "Int"))) (variant "PhaseFields" (ConPos (TyCon "RequestLine") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "PhaseBody" (ConPos (TyCon "FrameHead") (TyCon "BodyPhase")))) ())
(DData Private "ScanOutcome" () ((variant "ScanSuspend" (ConPos (TyCon "String") (TyCon "ScanPhase"))) (variant "ScanFatal" (ConPos (TyCon "HttpParseFailure"))) (variant "ScanFramed" (ConPos (TyCon "FrameSpan")))) ())
(DTypeSig false "crlfResume" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "crlfResume" ((PVar "avail") (PVar "lineStart")) (EApp (EApp (EVar "max") (EVar "lineStart")) (EBinOp "-" (EVar "avail") (ELit (LInt 1)))))
(DTypeSig false "buildHead" (TyFun (TyCon "RequestLine") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FrameHead")))))))
(DFunDef false "buildHead" ((PVar "line") (PVar "headers") (PVar "bodyPos") (PVar "headerBytes")) (EApp (EApp (EVar "andThen") (EApp (EVar "validateHost") (EVar "headers"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EVar "selectBodyMode") (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EVar "andThen") (EApp (EVar "keepAliveFromHeaders") (EVar "headers"))) (ELam ((PVar "keepAlive")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FrameHead") (EVar "line")) (EVar "headers")) (EVar "mode")) (EVar "keepAlive")) (EVar "bodyPos")) (EVar "headerBytes")))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "headBodyPhase" (TyFun (TyCon "FrameHead") (TyCon "BodyPhase")))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "NoBody") PWild (PVar "bodyPos") PWild)) (EApp (EVar "BodyUntil") (EVar "bodyPos")))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "FixedBody" (PVar "size")) PWild (PVar "bodyPos") PWild)) (EApp (EVar "BodyUntil") (EBinOp "+" (EVar "bodyPos") (EVar "size"))))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "ChunkedBody") PWild (PVar "bodyPos") PWild)) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "bodyPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "bodyPos")))
(DTypeSig false "scanBody" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "FrameHead") (TyFun (TyCon "BodyPhase") (TyCon "ScanOutcome"))))))
(DFunDef false "scanBody" (PWild (PVar "avail") (PVar "head") (PCon "BodyUntil" (PVar "finalPos"))) (EIf (EBinOp "<=" (EVar "finalPos") (EVar "avail")) (EApp (EVar "ScanFramed") (EApp (EApp (EVar "FrameSpan") (EVar "head")) (EVar "finalPos"))) (EApp (EApp (EVar "ScanSuspend") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EVar "BodyUntil") (EVar "finalPos"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyChunkSize" (PVar "chunkPos") (PVar "total") (PVar "count") (PVar "cursor"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "chunkPos")) (EApp (EApp (EVar "max") (EVar "chunkPos")) (EVar "cursor"))) (EVar "total")) (EVar "count")) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "chunkPos")) (EVar "total")) (EVar "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "chunkPos")))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "ChunkEnd" (PVar "dataPos"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (EVar "dataPos")))) (arm (PCon "Ok" (PCon "ChunkBody" (PVar "dataPos") (PVar "size"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkData") (EVar "dataPos")) (EVar "size")) (EVar "total")) (EVar "count"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyChunkData" (PVar "dataPos") (PVar "size") (PVar "total") (PVar "count"))) (EMatch (EApp (EApp (EApp (EApp (EVar "chunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size")) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkData") (EVar "dataPos")) (EVar "size")) (EVar "total")) (EVar "count"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "next")) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "next")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EVar "next"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyTrailers" (PVar "sectionStart") (PVar "pos") (PVar "count") (PVar "cursor"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EApp (EVar "max") (EVar "pos")) (EVar "cursor"))) (EVar "sectionStart")) (EApp (EVar "headHeaderBytes") (EVar "head"))) (EVar "count")) (EVar "True"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "sectionStart")) (EVar "pos")) (EVar "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "pos")))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "FieldMore" PWild (PVar "next"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "sectionStart")) (EVar "next")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EVar "next")))) (arm (PCon "Ok" (PCon "FieldDone" (PVar "finalPos") PWild)) () (EApp (EVar "ScanFramed") (EApp (EApp (EVar "FrameSpan") (EVar "head")) (EVar "finalPos"))))))))
(DTypeSig false "scanFrom" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ScanPhase") (TyCon "ScanOutcome"))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") (PVar "start") (PCon "PhaseLine" (PVar "cursor"))) (EMatch (EApp (EApp (EApp (EApp (EVar "parseRequestLine") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EVar "max") (EVar "start")) (EVar "cursor"))) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EVar "PhaseLine") (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "start"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "line")) () (EBlock (DoLet false false (PVar "headerPos") (EApp (EVar "requestLineHeaderPos") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EListLit)) (EVar "headerPos")) (ELit (LInt 0))) (EVar "headerPos"))))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") (PVar "start") (PCon "PhaseFields" (PVar "line") (PVar "acc") (PVar "pos") (PVar "count") (PVar "cursor"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EApp (EVar "max") (EVar "pos")) (EVar "cursor"))) (EApp (EVar "requestLineHeaderPos") (EVar "line"))) (ELit (LInt 0))) (EVar "count")) (EVar "False"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EVar "acc")) (EVar "pos")) (EVar "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "pos"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "FieldMore" (PVar "field") (PVar "next"))) () (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EBinOp "::" (EVar "field") (EVar "acc"))) (EVar "next")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EVar "next")))) (arm (PCon "Ok" (PCon "FieldDone" (PVar "bodyPos") (PVar "headerBytes"))) () (EMatch (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EVar "buildHead") (EVar "line")) (EApp (EVar "reverse") (EVar "acc"))) (EVar "bodyPos")) (EVar "headerBytes"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "head")) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EVar "headBodyPhase") (EVar "head"))))))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") PWild (PCon "PhaseBody" (PVar "head") (PVar "phase"))) (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EVar "phase")))
(DTypeSig false "frameSpanAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FrameSpan")))))
(DFunDef false "frameSpanAt" ((PVar "input") (PVar "start")) (EBlock (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "start")) (EApp (EVar "PhaseLine") (EVar "start")))) (DoExpr (EMatch (EVar "outcome") (arm (PCon "ScanSuspend" (PVar "message") PWild) () (EApp (EVar "Err") (EApp (EVar "Incomplete") (EVar "message")))) (arm (PCon "ScanFatal" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "Fatal") (EVar "failure")))) (arm (PCon "ScanFramed" (PVar "span")) () (EApp (EVar "Ok") (EVar "span")))))))
(DTypeSig false "frameFromSpan" (TyFun (TyCon "Bytes") (TyFun (TyCon "FrameHead") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FramedRequest"))))))
(DFunDef false "frameFromSpan" ((PVar "input") (PCon "FrameHead" (PCon "RequestLine" (PVar "method") (PVar "target") PWild) (PVar "headers") (PVar "mode") (PVar "keepAlive") (PVar "bodyPos") (PVar "headerBytes")) (PVar "finalPos")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "parseBody") (EVar "mode")) (EVar "input")) (EVar "bodyPos")) (EVar "headerBytes"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ParsedBody" (PVar "body") (PVar "trailers") PWild) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "FramedRequest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Request") (EVar "method")) (EVar "target")) (EVar "headers")) (EVar "trailers")) (EVar "body")) (EVar "keepAlive"))) (EVar "mode")) (EVar "finalPos")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "frameRequestAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FramedRequest")))))
(DFunDef false "frameRequestAt" ((PVar "input") (PVar "start")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "frameSpanAt") (EVar "input")) (EVar "start"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "FrameSpan" (PVar "head") (PVar "finalPos")) () (EApp (EApp (EApp (EVar "frameFromSpan") (EVar "input")) (EVar "head")) (EVar "finalPos"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseWholeBuffer" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Request"))))
(DFunDef false "parseWholeBuffer" ((PVar "input")) (EApp (EApp (EVar "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpRequestBytes") (EApp (EVar "bytesLength") (EVar "input"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "frameRequestAt") (EVar "input")) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "FramedRequest" (PVar "request") (PVar "mode") (PVar "finalPos")) () (EIf (EBinOp "/=" (EVar "finalPos") (EApp (EVar "bytesLength") (EVar "input"))) (EApp (EVar "malformed") (EApp (EVar "trailingMessage") (EVar "mode"))) (EApp (EVar "Ok") (EVar "request")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "parseRequestClassified" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "Request"))))
(DFunDef false "parseRequestClassified" ((PVar "input")) (EApp (EVar "settle") (EApp (EVar "parseWholeBuffer") (EVar "input"))))
(DData Public "HttpFrame" () ((variant "HttpNeedMore" (ConPos)) (variant "HttpFramedAt" (ConPos (TyCon "Int"))) (variant "HttpFrameFailed" (ConPos (TyCon "HttpParseFailure")))) ())
(DTypeSig false "requestBytesVerdict" (TyFun (TyCon "Int") (TyFun (TyCon "HttpFrame") (TyCon "HttpFrame"))))
(DFunDef false "requestBytesVerdict" ((PVar "size") (PVar "framed")) (EMatch (EApp (EVar "checkHttpRequestBytes") (EVar "size")) (arm (PCon "Ok" (PLit LUnit)) () (EVar "framed")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpResourceExcess") (EVar "message"))))))
(DData Abstract "HttpScan" () ((variant "HttpScan" (ConPos (TyCon "ScanPhase")))) ())
(DTypeSig true "httpScanStart" (TyCon "HttpScan"))
(DFunDef false "httpScanStart" () (EApp (EVar "HttpScan") (EApp (EVar "PhaseLine") (ELit (LInt 0)))))
(DTypeSig true "httpScanInHeaders" (TyFun (TyCon "HttpScan") (TyCon "Bool")))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseLine" PWild))) (EVar "True"))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseFields" PWild PWild PWild PWild PWild))) (EVar "True"))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseBody" PWild PWild))) (EVar "False"))
(DTypeSig true "httpScanBodyRemaining" (TyFun (TyCon "HttpScan") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "httpScanBodyRemaining" ((PCon "HttpScan" (PCon "PhaseBody" PWild (PCon "BodyUntil" (PVar "finalPos")))) (PVar "avail")) (EApp (EVar "Some") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "finalPos") (EVar "avail")))))
(DFunDef false "httpScanBodyRemaining" (PWild PWild) (EVar "None"))
(DTypeSig false "scanVerdict" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyFun (TyCon "ScanOutcome") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan")))))))
(DFunDef false "scanVerdict" (PWild (PVar "start") (PVar "scanned") (PCon "ScanFramed" (PCon "FrameSpan" PWild (PVar "finalPos")))) (ETuple (EApp (EApp (EVar "requestBytesVerdict") (EBinOp "-" (EVar "finalPos") (EVar "start"))) (EApp (EVar "HttpFramedAt") (EVar "finalPos"))) (EVar "scanned")))
(DFunDef false "scanVerdict" (PWild PWild (PVar "scanned") (PCon "ScanFatal" (PVar "failure"))) (ETuple (EApp (EVar "HttpFrameFailed") (EVar "failure")) (EVar "scanned")))
(DFunDef false "scanVerdict" ((PVar "avail") (PVar "start") PWild (PCon "ScanSuspend" PWild (PVar "phase"))) (ETuple (EApp (EApp (EVar "requestBytesVerdict") (EBinOp "-" (EVar "avail") (EVar "start"))) (EVar "HttpNeedMore")) (EApp (EVar "HttpScan") (EVar "phase"))))
(DTypeSig true "scanRequestBoundaryWithin" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan")))))))
(DFunDef false "scanRequestBoundaryWithin" ((PVar "input") (PVar "avail") (PVar "start") (PCon "HttpScan" (PVar "phase"))) (EBlock (DoLet false false (PVar "unchanged") (EApp (EVar "HttpScan") (EVar "phase"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "avail") (ELit (LInt 0))) (EBinOp ">" (EVar "avail") (EApp (EVar "bytesLength") (EVar "input")))) (ETuple (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpMalformed") (ELit (LString "http: scan length outside buffer")))) (EVar "unchanged")) (EIf (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp ">" (EVar "start") (EVar "avail"))) (ETuple (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpMalformed") (ELit (LString "http: scan offset outside buffer")))) (EVar "unchanged")) (EApp (EApp (EApp (EApp (EVar "scanVerdict") (EVar "avail")) (EVar "start")) (EApp (EVar "HttpScan") (EVar "phase"))) (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "phase"))))))))
(DTypeSig true "scanRequestBoundaryFrom" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan"))))))
(DFunDef false "scanRequestBoundaryFrom" ((PVar "input") (PVar "start") (PVar "scan")) (EApp (EApp (EApp (EApp (EVar "scanRequestBoundaryWithin") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "start")) (EVar "scan")))
(DTypeSig true "scanRequestBoundary" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyCon "HttpFrame"))))
(DFunDef false "scanRequestBoundary" ((PVar "input") (PVar "start")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "scanRequestBoundaryFrom") (EVar "input")) (EVar "start")) (EVar "httpScanStart"))))
(DTypeSig true "parseRequestAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "Request"))))))
(DFunDef false "parseRequestAt" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp "<" (EVar "end") (EVar "start"))) (EBinOp ">" (EVar "end") (EApp (EVar "bytesLength") (EVar "input")))) (EApp (EVar "Err") (EApp (EVar "HttpMalformed") (ELit (LString "http: request frame bounds outside buffer")))) (EApp (EVar "parseRequestClassified") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "start")) (EVar "end")))))
(DTypeSig true "parseRequest" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Request"))))
(DFunDef false "parseRequest" ((PVar "input")) (EMatch (EApp (EVar "parseRequestClassified") (EVar "input")) (arm (PCon "Ok" (PVar "request")) () (EApp (EVar "Ok") (EVar "request"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "httpParseFailureMessage") (EVar "failure"))))))
(DData Abstract "ParsedResponse" () ((variant "ParsedResponse" (ConPos (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig true "parsedResponseStatus" (TyFun (TyCon "ParsedResponse") (TyCon "Int")))
(DFunDef false "parsedResponseStatus" ((PCon "ParsedResponse" (PVar "status") PWild PWild PWild PWild)) (EVar "status"))
(DTypeSig true "parsedResponseReason" (TyFun (TyCon "ParsedResponse") (TyCon "String")))
(DFunDef false "parsedResponseReason" ((PCon "ParsedResponse" PWild (PVar "reason") PWild PWild PWild)) (EVar "reason"))
(DTypeSig true "parsedResponseHeaders" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "parsedResponseHeaders" ((PCon "ParsedResponse" PWild PWild (PVar "headers") PWild PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "parsedResponseTrailers" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "parsedResponseTrailers" ((PCon "ParsedResponse" PWild PWild PWild (PVar "trailers") PWild)) (EApp (EVar "copyHeaders") (EVar "trailers")))
(DTypeSig true "parsedResponseBody" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "parsedResponseBody" ((PCon "ParsedResponse" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayCopy") (EVar "body")))
(DTypeSig true "parsedResponseBodyLength" (TyFun (TyCon "ParsedResponse") (TyCon "Int")))
(DFunDef false "parsedResponseBodyLength" ((PCon "ParsedResponse" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayLength") (EVar "body")))
(DData Private "ResponseStatusLine" () ((variant "ResponseStatusLine" (ConPos (TyCon "Int") (TyCon "String") (TyCon "Int")))) ())
(DData Private "ResponseFieldStep" () ((variant "ResponseFieldDone" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "ResponseFieldMore" (ConPos (TyCon "Header") (TyCon "Int")))) ())
(DTypeSig false "responseMalformed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "responseMalformed" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpMalformed") (EVar "message")))))
(DTypeSig false "responseResourceExcess" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "responseResourceExcess" ((PCon "Ok" (PLit LUnit))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "responseResourceExcess" ((PCon "Err" (PVar "message"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EVar "message")))))
(DTypeSig false "responseFindCrlf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))))
(DFunDef false "responseFindCrlf" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "limit")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlfGo") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "start")) (EVar "limit")))
(DTypeSig false "responseFindCrlfGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))))
(DFunDef false "responseFindCrlfGo" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "pos") (PVar "limit")) (EIf (EBinOp ">" (EBinOp "-" (EVar "pos") (EVar "start")) (EVar "limit")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EBinOp "++" (EBinOp "++" (ELit (LString "http: ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " exceeds its resource limit")))))) (EIf (EBinOp ">=" (EVar "pos") (EVar "avail")) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "; expected CRLF")))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 10))) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare LF in ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "avail")) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlfGo") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "limit")))))))
(DTypeSig false "responseParseDecimalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseDecimalGo" ((PVar "value") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EApp (EVar "Ok") (EVar "acc")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "byte") (ELit (LInt 48))) (EBinOp ">" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid decimal field"))) (EBlock (DoLet false false (PVar "digit") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (DoExpr (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "intMaxBound") (EVar "digit")) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (ELit (LString "http: decimal field overflows Int"))) (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "digit")))))))))))
(DTypeSig false "responseParseStatusLine" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseStatusLine")))))
(DFunDef false "responseParseStatusLine" ((PVar "input") (PVar "avail")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "status line"))) (EVar "input")) (EVar "avail")) (ELit (LInt 0))) (EVar "maxHttpResponseStatusLineBytes"))) (ELam ((PVar "end")) (EApp (EApp (EVar "andThen") (EApp (EVar "responseResourceExcess") (EApp (EVar "checkHttpResponseStatusLineBytes") (EVar "end")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EVar "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (ELit (LInt 0))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed status line; expected HTTP-version SP status SP reason")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "firstSpace")) (EApp (EApp (EVar "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed status line; expected HTTP-version SP status SP reason")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "secondSpace")) (ELet false (PVar "versionBytes") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (ELit (LInt 0))) (EVar "firstSpace")) (EIf (EBinOp "||" (EBinOp "/=" (EVar "firstSpace") (ELit (LInt 8))) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "versionBytes") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.1")))) (EBinOp "==" (EVar "versionBytes") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.0"))))))) (EApp (EVar "responseMalformed") (ELit (LString "http: only HTTP/1.0 and HTTP/1.1 responses are supported"))) (EIf (EBinOp "/=" (EBinOp "-" (EBinOp "-" (EVar "secondSpace") (EVar "firstSpace")) (ELit (LInt 1))) (ELit (LInt 3))) (EApp (EVar "responseMalformed") (ELit (LString "http: status code must be exactly three digits"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 4))))) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "status")) (EIf (EBinOp "||" (EBinOp "<" (EVar "status") (ELit (LInt 100))) (EBinOp ">" (EVar "status") (ELit (LInt 999)))) (EApp (EVar "responseMalformed") (ELit (LString "http: status code out of range"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ResponseStatusLine") (EVar "status")) (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EBinOp "+" (EVar "secondSpace") (ELit (LInt 1)))) (EVar "end")))) (EBinOp "+" (EVar "end") (ELit (LInt 2)))))))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "responseParseHeaderLine" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Header"))))))
(DFunDef false "responseParseHeaderLine" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 9)))) (EApp (EVar "responseMalformed") (ELit (LString "http: obsolete folded header lines are forbidden"))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed header field; missing colon")))) (arm (PCon "Some" (PVar "colon")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "colon") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allToken") (EVar "input")) (EVar "start")) (EVar "colon")))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid header field name"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validFieldValue") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in header field value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "trimRightOws") (EVar "input")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "input")) (EVar "start")) (EVar "colon"))) (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "valueStart")) (EVar "valueEnd"))))))))))))
(DTypeSig false "responseFieldStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseFieldStep")))))))))
(DFunDef false "responseFieldStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "header field"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "end")) (ELet false (PVar "next") (EBinOp "+" (EVar "end") (ELit (LInt 2))) (ELet false (PVar "totalBytes") (EBinOp "-" (EBinOp "+" (EVar "priorBytes") (EVar "next")) (EVar "sectionStart")) (EIf (EBinOp ">" (EVar "totalBytes") (EVar "maxHttpHeaderBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: combined header and trailer section exceeds 65536-byte resource limit"))))) (EIf (EBinOp "==" (EVar "end") (EVar "pos")) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseFieldDone") (EVar "next")) (EVar "totalBytes"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EVar "maxHttpHeaderFields")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: header field count exceeds 100 resource limit"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseHeaderLine") (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "field")) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseFieldMore") (EVar "field")) (EVar "next")))))))))))))
(DTypeSig false "responseParseFields" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "responseParseFields" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "acc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "sectionStart")) (EVar "priorBytes")) (EVar "count"))) (ELam ((PVar "step")) (EMatch (EVar "step") (arm (PCon "ResponseFieldDone" (PVar "next") (PVar "totalBytes")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EVar "next") (EVar "totalBytes")))) (arm (PCon "ResponseFieldMore" (PVar "field") (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "next")) (EVar "sectionStart")) (EVar "priorBytes")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))) (EBinOp "::" (EVar "field") (EVar "acc"))))))))
(DTypeSig false "responseCountNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))
(DFunDef false "responseCountNamed" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "responseCountNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "responseCountNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "responseFindNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "responseFindNamed" (PWild (PList)) (EVar "None"))
(DFunDef false "responseFindNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "responseFindNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "responseImpliesNoBody" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "responseImpliesNoBody" ((PVar "status")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "status") (ELit (LInt 100))) (EBinOp "<" (EVar "status") (ELit (LInt 200)))) (EBinOp "==" (EVar "status") (ELit (LInt 204)))) (EBinOp "==" (EVar "status") (ELit (LInt 304)))))
(DTypeSig false "responseSelectBodyMode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "BodyMode")))))
(DFunDef false "responseSelectBodyMode" ((PVar "status") (PVar "headers")) (EBlock (DoLet false false (PVar "clCount") (EApp (EApp (EVar "responseCountNamed") (ELit (LString "content-length"))) (EVar "headers"))) (DoLet false false (PVar "teCount") (EApp (EApp (EVar "responseCountNamed") (ELit (LString "transfer-encoding"))) (EVar "headers"))) (DoExpr (EIf (EBinOp ">" (EVar "clCount") (ELit (LInt 1))) (EApp (EVar "responseMalformed") (ELit (LString "http: duplicate Content-Length is ambiguous"))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "clCount") (ELit (LInt 0))) (EBinOp ">" (EVar "teCount") (ELit (LInt 0)))) (EApp (EVar "responseMalformed") (ELit (LString "http: Transfer-Encoding with Content-Length is ambiguous"))) (EIf (EBinOp ">" (EVar "teCount") (ELit (LInt 0))) (EIf (EBinOp "/=" (EVar "teCount") (ELit (LInt 1))) (EApp (EVar "responseMalformed") (ELit (LString "http: repeated Transfer-Encoding is unsupported"))) (EMatch (EApp (EApp (EVar "responseFindNamed") (ELit (LString "transfer-encoding"))) (EVar "headers")) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: missing Transfer-Encoding value")))) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EApp (EVar "asciiEqualCi") (EVar "value")) (ELit (LString "chunked"))) (EApp (EVar "Ok") (EVar "ChunkedBody")) (EApp (EVar "responseMalformed") (ELit (LString "http: unsupported Transfer-Encoding coding"))))))) (EMatch (EApp (EApp (EVar "responseFindNamed") (ELit (LString "content-length"))) (EVar "headers")) (arm (PCon "None") () (EIf (EApp (EVar "responseImpliesNoBody") (EVar "status")) (EApp (EVar "Ok") (EVar "NoBody")) (EApp (EVar "Ok") (EVar "UntilCloseBody")))) (arm (PCon "Some" (PVar "value")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "responseMalformed") (ELit (LString "http: empty Content-Length"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))))) (EApp (EVar "Ok") (EApp (EVar "FixedBody") (EVar "size")))))))))))))))
(DTypeSig false "responseParseHexSizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseParseHexSizeGo" ((PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EVar "hexDigit") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk size")))) (arm (PCon "Some" (PVar "digit")) () (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "maxHttpResponseChunkBytes") (EVar "digit")) (ELit (LInt 16)))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk size exceeds resource limit"))))) (EApp (EApp (EApp (EApp (EVar "responseParseHexSizeGo") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "digit"))))))))
(DTypeSig false "responseScanQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseScanQuoted" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: unterminated quoted chunk extension"))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated quoted-pair in chunk extension"))) (EBlock (DoLet false false (PVar "escaped") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "escaped") (ELit (LInt 9))) (EBinOp "==" (EVar "escaped") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp ">=" (EVar "escaped") (ELit (LInt 33))) (EBinOp "/=" (EVar "escaped") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in quoted chunk extension"))))))) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "==" (EVar "byte") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 33))) (EBinOp "/=" (EVar "byte") (ELit (LInt 34)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 92)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in quoted chunk extension"))))))))))
(DTypeSig false "responseParseChunkExtensionValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseChunkExtensionValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: missing chunk extension value"))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "valueEnd") (EVar "pos")) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk extension value"))) (EApp (EVar "Ok") (EVar "valueEnd"))))))))
(DTypeSig false "responseParseChunkExtensionsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))))
(DFunDef false "responseParseChunkExtensionsGo" ((PVar "input") (PVar "pos") (PVar "end")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk extension separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "input")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "responseMalformed") (ELit (LString "http: empty chunk extension name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "afterName") (EVar "end")) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "input")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseChunkExtensionValue") (EVar "input")) (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (EVar "end"))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "valueEnd")) (EVar "end")))) (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "afterName")) (EVar "end")))))))))))))
(DTypeSig false "responseParseChunkSize" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseChunkSize" ((PVar "input") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "semi") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 59))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "semi") (EVar "start")) (EApp (EVar "responseMalformed") (ELit (LString "http: empty chunk size"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseParseHexSizeGo") (EVar "input")) (EVar "start")) (EVar "semi")) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "semi")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DData Private "ResponseChunkHead" () ((variant "ResponseChunkEnd" (ConPos (TyCon "Int"))) (variant "ResponseChunkBody" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "responseChunkHeadStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseChunkHead")))))))
(DFunDef false "responseChunkHeadStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "chunk-size line"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "lineEnd")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "responseParseChunkSize") (EVar "input")) (EVar "pos")) (EVar "lineEnd"))) (ELam ((PVar "size")) (EApp (EApp (EVar "andThen") (EApp (EVar "responseResourceExcess") (EApp (EVar "checkHttpResponseChunkBytes") (EVar "size")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "dataPos") (EBinOp "+" (EVar "lineEnd") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "size") (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "ResponseChunkEnd") (EVar "dataPos"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EVar "maxHttpChunks")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk count exceeds 65536 resource limit"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseChunkBody") (EVar "dataPos")) (EVar "size"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "responseReadSliceAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))))))
(DFunDef false "responseReadSliceAt" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "size")) (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated chunk body"))) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "size"))) (EBinOp "+" (EVar "pos") (EVar "size"))))))
(DTypeSig false "responseChunkDataEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseChunkDataEnd" ((PVar "input") (PVar "avail") (PVar "dataPos") (PVar "size")) (EBlock (DoLet false false (PVar "afterChunk") (EBinOp "+" (EVar "dataPos") (EVar "size"))) (DoExpr (EIf (EBinOp ">" (EVar "afterChunk") (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated chunk body"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated CRLF after chunk data"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EVar "afterChunk")) (ELit (LInt 13))) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "afterChunk") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (ELit (LString "http: missing CRLF after chunk data"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))))))))))
(DTypeSig false "responseParseChunked" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))))))
(DFunDef false "responseParseChunked" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "out") (PVar "total") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ResponseChunkEnd" (PVar "dataPos")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "trailers") (PVar "finalPos") PWild)) (EApp (EVar "Ok") (ETuple (EApp (EVar "buildArray") (EVar "out")) (EVar "trailers") (EVar "finalPos")))))) (arm (PCon "ResponseChunkBody" (PVar "dataPos") (PVar "size")) () (EIf (EBinOp ">" (EBinOp "+" (EVar "total") (EVar "size")) (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseReadSliceAt") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PTuple (PVar "chunk") PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (ELet false (PLit LUnit) (EApp (EApp (EApp (EVar "emitArray") (EVar "chunk")) (ELit (LInt 0))) (EVar "out")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseChunked") (EVar "input")) (EVar "avail")) (EVar "next")) (EVar "out")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EVar "count") (ELit (LInt 1)))))))))))))))
(DTypeSig false "responseParseBody" (TyFun (TyCon "BodyMode") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))))
(DFunDef false "responseParseBody" ((PCon "NoBody") PWild PWild (PVar "pos")) (EApp (EVar "Ok") (ETuple (EArrayLit) (EListLit) (EVar "pos"))))
(DFunDef false "responseParseBody" ((PCon "FixedBody" (PVar "size")) (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseReadSliceAt") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "size"))) (ELam ((PTuple (PVar "body") (PVar "finalPos"))) (EApp (EVar "Ok") (ETuple (EVar "body") (EListLit) (EVar "finalPos"))))))
(DFunDef false "responseParseBody" ((PCon "ChunkedBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseChunked") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))
(DFunDef false "responseParseBody" ((PCon "UntilCloseBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EVar "avail")) (EListLit) (EVar "avail"))))
(DTypeSig true "parseResponseClassified" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponseClassified" ((PVar "input")) (EApp (EVar "settle") (EApp (EVar "parseResponseChecked") (EVar "input"))))
(DTypeSig false "parseResponseChecked" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponseChecked" ((PVar "input")) (ELet false (PVar "avail") (EApp (EVar "arrayLength") (EVar "input")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "responseParseStatusLine") (EVar "input")) (EVar "avail"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ResponseStatusLine" (PVar "status") (PVar "reason") (PVar "lineEnd")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "lineEnd")) (EVar "lineEnd")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "headers") (PVar "headerEnd") PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "responseSelectBodyMode") (EVar "status")) (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseParseBody") (EVar "mode")) (EVar "input")) (EVar "avail")) (EVar "headerEnd"))) (ELam ((PTuple (PVar "body") (PVar "trailers") (PVar "finalPos"))) (EIf (EBinOp "/=" (EVar "finalPos") (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: bytes after framed response"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "ParsedResponse") (EVar "status")) (EVar "reason")) (EVar "headers")) (EVar "trailers")) (EVar "body"))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "parseResponse" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponse" ((PVar "input")) (EMatch (EApp (EVar "parseResponseClassified") (EVar "input")) (arm (PCon "Ok" (PVar "response")) () (EApp (EVar "Ok") (EVar "response"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "httpParseFailureMessage") (EVar "failure"))))))
(DTest false "response malformed diagnostics use the public http vocabulary" (EMatch (EApp (EVar "parseResponseClassified") (EArrayLit)) (arm (PCon "Err" (PCon "HttpMalformed" (PVar "message"))) () (EApp (EApp (EVar "expectEqual") (ELit (LString "http: truncated status line; expected CRLF"))) (EVar "message"))) (arm PWild () (EApp (EVar "expectTrue") (EVar "False")))))
(DTest false "response resource diagnostics use the public http vocabulary" (EBlock (DoLet false false (PVar "input") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n100001\r\n")))) (DoExpr (EMatch (EApp (EVar "parseResponseClassified") (EVar "input")) (arm (PCon "Err" (PCon "HttpResourceExcess" (PVar "message"))) () (EApp (EApp (EVar "expectEqual") (ELit (LString "http: chunk size exceeds resource limit"))) (EVar "message"))) (arm PWild () (EApp (EVar "expectTrue") (EVar "False")))))))
(DTypeSig false "responseScanChunkedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseScanChunkedEnd" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ResponseChunkEnd" (PVar "dataPos")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple PWild (PVar "finalPos") PWild)) (EApp (EVar "Ok") (EVar "finalPos"))))) (arm (PCon "ResponseChunkBody" (PVar "dataPos") (PVar "size")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "responseScanChunkedEnd") (EVar "input")) (EVar "avail")) (EVar "next")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))))))))))
(DTypeSig false "responseScanBodyEnd" (TyFun (TyCon "BodyMode") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseScanBodyEnd" ((PCon "NoBody") PWild PWild (PVar "pos")) (EApp (EVar "Ok") (EVar "pos")))
(DFunDef false "responseScanBodyEnd" ((PCon "FixedBody" (PVar "size")) PWild (PVar "avail") (PVar "pos")) (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: declared body is still arriving"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (EVar "size")))))
(DFunDef false "responseScanBodyEnd" ((PCon "ChunkedBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "responseScanChunkedEnd") (EVar "input")) (EVar "avail")) (EVar "pos")) (ELit (LInt 0))))
(DFunDef false "responseScanBodyEnd" ((PCon "UntilCloseBody") PWild PWild PWild) (EApp (EVar "responseMalformed") (ELit (LString "http: close-delimited response ends only at the close"))))
(DTypeSig false "responseScanEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))
(DFunDef false "responseScanEnd" ((PVar "input") (PVar "avail")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "responseParseStatusLine") (EVar "input")) (EVar "avail"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ResponseStatusLine" (PVar "status") PWild (PVar "lineEnd")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "lineEnd")) (EVar "lineEnd")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "headers") (PVar "headerEnd") PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "responseSelectBodyMode") (EVar "status")) (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EApp (EApp (EVar "responseScanBodyEnd") (EVar "mode")) (EVar "input")) (EVar "avail")) (EVar "headerEnd"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "responseBoundaryWithin" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "responseBoundaryWithin" ((PVar "input") (PVar "avail")) (EIf (EBinOp "||" (EBinOp "<" (EVar "avail") (ELit (LInt 0))) (EBinOp ">" (EVar "avail") (EApp (EVar "arrayLength") (EVar "input")))) (EVar "None") (EMatch (EApp (EApp (EVar "responseScanEnd") (EVar "input")) (EVar "avail")) (arm (PCon "Ok" (PVar "end")) () (EApp (EVar "Some") (EVar "end"))) (arm (PCon "Err" PWild) () (EVar "None")))))
(DTypeSig true "responseBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "responseBoundary" ((PVar "input")) (EApp (EApp (EVar "responseBoundaryWithin") (EVar "input")) (EApp (EVar "arrayLength") (EVar "input"))))
(DData Abstract "Response" () ((variant "Response" (ConPos (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig false "validResponseValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validResponseValue" ((PVar "value") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "value")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "<=" (EVar "byte") (ELit (LInt 126)))) (EApp (EApp (EVar "validResponseValue") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "makeHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Header")))))
(DFunDef false "makeHeader" ((PVar "name") (PVar "value")) (EBlock (DoLet false false (PVar "nameBytes") (EApp (EVar "toUtf8") (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allToken") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "nameBytes"))))) (EApp (EVar "Err") (ELit (LString "http: invalid response header field name"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "value")))) (EApp (EVar "not") (EApp (EApp (EVar "validResponseValue") (EVar "value")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "http: control or non-ASCII byte in response header field value"))) (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "nameBytes")))) (EApp (EVar "arrayCopy") (EVar "value")))))))))
(DTypeSig false "validReason" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validReason" ((PVar "reason")) (EApp (EApp (EVar "validResponseValue") (EApp (EVar "toUtf8") (EVar "reason"))) (ELit (LInt 0))))
(DTypeSig false "hasReservedResponseField" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Bool")))
(DFunDef false "hasReservedResponseField" ((PList)) (EVar "False"))
(DFunDef false "hasReservedResponseField" ((PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "content-length"))) (EBinOp "==" (EVar "name") (ELit (LString "transfer-encoding")))) (EApp (EVar "hasReservedResponseField") (EVar "rest"))))
(DTypeSig true "makeResponse" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Response")))))))
(DFunDef false "makeResponse" ((PVar "status") (PVar "reason") (PVar "headers") (PVar "body")) (EIf (EBinOp "||" (EBinOp "<" (EVar "status") (ELit (LInt 100))) (EBinOp ">" (EVar "status") (ELit (LInt 599)))) (EApp (EVar "Err") (ELit (LString "http: response status must be between 100 and 599"))) (EIf (EApp (EVar "not") (EApp (EVar "validReason") (EVar "reason"))) (EApp (EVar "Err") (ELit (LString "http: invalid control or non-ASCII byte in response reason phrase"))) (EIf (EApp (EVar "hasReservedResponseField") (EVar "headers")) (EApp (EVar "Err") (ELit (LString "http: response framing fields are reserved"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "body")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "body")))) (EApp (EVar "Err") (ELit (LString "http: response body element outside byte range 0..255"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "Response") (EVar "status")) (EVar "reason")) (EApp (EVar "copyHeaders") (EVar "headers"))) (EApp (EVar "arrayCopy") (EVar "body")))))))))
(DTypeSig true "responseStatus" (TyFun (TyCon "Response") (TyCon "Int")))
(DFunDef false "responseStatus" ((PCon "Response" (PVar "status") PWild PWild PWild)) (EVar "status"))
(DTypeSig true "responseHeaders" (TyFun (TyCon "Response") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "responseHeaders" ((PCon "Response" PWild PWild (PVar "headers") PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "responseBody" (TyFun (TyCon "Response") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "responseBody" ((PCon "Response" PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayCopy") (EVar "body")))
(DTypeSig true "responseReason" (TyFun (TyCon "Response") (TyCon "String")))
(DFunDef false "responseReason" ((PCon "Response" PWild (PVar "reason") PWild PWild)) (EVar "reason"))
(DTypeSig false "emitAscii" (TyFun (TyCon "String") (TyFun (TyCon "Builder") (TyCon "Unit"))))
(DFunDef false "emitAscii" ((PVar "text") (PVar "out")) (EApp (EApp (EApp (EVar "emitArray") (EApp (EVar "toUtf8") (EVar "text"))) (ELit (LInt 0))) (EVar "out")))
(DTypeSig false "emitResponseHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyCon "Builder") (TyCon "Unit"))))
(DFunDef false "emitResponseHeaders" ((PList) PWild) (ELit LUnit))
(DFunDef false "emitResponseHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest")) (PVar "out")) (EBlock (DoExpr (EApp (EApp (EVar "emitAscii") (EVar "name")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString ": "))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "value")) (ELit (LInt 0))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitResponseHeaders") (EVar "rest")) (EVar "out")))))
(DTypeSig true "serializeResponse" (TyFun (TyCon "Response") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "serializeResponse" ((PCon "Response" (PVar "status") (PVar "reason") (PVar "headers") (PVar "body"))) (EBlock (DoLet false false (PVar "out") (EApp (EVar "newBuilder") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "HTTP/1.1 "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EApp (EVar "intToString") (EVar "status"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString " "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EVar "reason")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitResponseHeaders") (EVar "headers")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "content-length: "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "body")))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "body")) (ELit (LInt 0))) (EVar "out"))) (DoExpr (EApp (EVar "buildArray") (EVar "out")))))
(DData Abstract "MediaType" () ((variant "MediaType" (ConPos (TyCon "String") (TyCon "String")))) ())
(DData Public "DecodedBody" () ((variant "JsonBody" (ConPos (TyCon "MediaType") (TyCon "Json"))) (variant "TextBody" (ConPos (TyCon "MediaType") (TyCon "String"))) (variant "RawBody" (ConPos (TyCon "MediaType") (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Public "QueryParam" () ((variant "QueryParam" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "percentNibble" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "percentNibble" ((PVar "byte")) (EApp (EVar "hexDigit") (EVar "byte")))
(DTypeSig false "decodeQueryBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "decodeQueryBytes" ((PVar "input") (PVar "pos") (PVar "end") (PVar "out")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (ELit (LInt 37))) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "out")))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: malformed percent escape in query"))) (EMatch (ETuple (EApp (EVar "percentNibble") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EVar "percentNibble") (EApp (EApp (EVar "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (arm (PTuple (PCon "Some" (PVar "high")) (PCon "Some" (PVar "low"))) () (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EVar "emitU8") (EBinOp "+" (EBinOp "*" (EVar "high") (ELit (LInt 16))) (EVar "low"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end")) (EVar "out"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "http: malformed percent escape in query")))))))))
(DTypeSig false "continuation" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "continuation" ((PVar "byte")) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 128))) (EBinOp "<=" (EVar "byte") (ELit (LInt 191)))))
(DTypeSig false "utf8Step" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8Step" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "arrayLength") (EVar "bytes"))) (DoLet false false (PVar "b0") (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (EApp (EVar "Some") (ETuple (EVar "b0") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 192))) (ELit (LInt 64))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 160)))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 191)))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 225))) (EBinOp "<=" (EVar "b0") (ELit (LInt 236)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 238))) (EBinOp "<=" (EVar "b0") (ELit (LInt 239)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128)))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 159)))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 144)))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 191)))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 241))) (EBinOp "<=" (EVar "b0") (ELit (LInt 243)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128)))) (EBinOp "<=" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 143)))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EVar "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EVar "None")))))))))))))
(DTypeSig false "validUtf8From" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validUtf8From" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EMatch (EApp (EApp (EVar "utf8Step") (EVar "bytes")) (EVar "i")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "next"))) () (EApp (EApp (EVar "validUtf8From") (EVar "bytes")) (EVar "next"))))))
(DTypeSig false "validQueryTextFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validQueryTextFrom" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EMatch (EApp (EApp (EVar "utf8Step") (EVar "bytes")) (EVar "i")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "code") (PVar "next"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "code") (ELit (LInt 31))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "code") (ELit (LInt 127))) (EBinOp "<=" (EVar "code") (ELit (LInt 159)))))) (EApp (EApp (EVar "validQueryTextFrom") (EVar "bytes")) (EVar "next")))))))
(DTypeSig false "decodeQueryPart" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "decodeQueryPart" ((PVar "input") (PVar "start") (PVar "end")) (ELet false (PVar "out") (EApp (EVar "newBuilder") (ELit LUnit)) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EVar "start")) (EVar "end")) (EVar "out"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "decoded") (EApp (EVar "buildArray") (EVar "out")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validQueryTextFrom") (EVar "decoded")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: query component is invalid UTF-8 or contains a control character"))) (EApp (EVar "Ok") (EApp (EVar "fromUtf8") (EVar "decoded")))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "parseQueryFields" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "QueryParam")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "QueryParam")))))))
(DFunDef false "parseQueryFields" ((PVar "input") (PVar "start") (PVar "acc")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "input"))) (DoExpr (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))) (EBlock (DoLet false false (PVar "amp") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 38))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoLet false false (PVar "equals") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "amp")) (ELit (LInt 61))) (arm (PCon "None") () (EVar "amp")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "equals") (EVar "start")) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decodeQueryPart") (EVar "input")) (EVar "start")) (EVar "equals"))) (ELam ((PVar "name")) (EIf (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EVar "andThen") (EIf (EBinOp "==" (EVar "equals") (EVar "amp")) (EApp (EVar "Ok") (ELit (LString ""))) (EApp (EApp (EApp (EVar "decodeQueryPart") (EVar "input")) (EBinOp "+" (EVar "equals") (ELit (LInt 1)))) (EVar "amp")))) (ELam ((PVar "value")) (ELet false (PVar "next") (EIf (EBinOp "==" (EVar "amp") (EVar "end")) (EVar "end") (EBinOp "+" (EVar "amp") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "next") (EVar "end")) (EBinOp "<" (EVar "amp") (EVar "end"))) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EApp (EVar "parseQueryFields") (EVar "input")) (EVar "next")) (EBinOp "::" (EApp (EApp (EVar "QueryParam") (EVar "name")) (EVar "value")) (EVar "acc")))))))))))))))))
(DTypeSig true "parseTargetQuery" (TyFun (TyCon "Request") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "QueryParam"))))))
(DFunDef false "parseTargetQuery" ((PCon "Request" PWild (PVar "target") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "toUtf8") (EVar "target"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LInt 35))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "http: fragment is forbidden in request target")))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LInt 63))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "target") (EListLit)))) (arm (PCon "Some" (PVar "queryAt")) () (ELet false (PVar "path") (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EVar "slice") (EVar "bytes")) (ELit (LInt 0))) (EVar "queryAt"))) (EIf (EBinOp "==" (EBinOp "+" (EVar "queryAt") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EApp (EVar "Ok") (ETuple (EVar "path") (EListLit))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseQueryFields") (EVar "bytes")) (EBinOp "+" (EVar "queryAt") (ELit (LInt 1)))) (EListLit))) (ELam ((PVar "params")) (EApp (EVar "Ok") (ETuple (EVar "path") (EVar "params"))))))))))))))
(DTypeSig true "mediaTypeType" (TyFun (TyCon "MediaType") (TyCon "String")))
(DFunDef false "mediaTypeType" ((PCon "MediaType" (PVar "kind") PWild)) (EVar "kind"))
(DTypeSig true "mediaTypeSubtype" (TyFun (TyCon "MediaType") (TyCon "String")))
(DFunDef false "mediaTypeSubtype" ((PCon "MediaType" PWild (PVar "subtype"))) (EVar "subtype"))
(DTypeSig false "validMediaBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validMediaBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "<=" (EVar "byte") (ELit (LInt 126))))) (EApp (EApp (EVar "validMediaBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "scanMediaQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "scanMediaQuoted" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: unterminated quoted media-type parameter"))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EBinOp "<" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 32)))) (EBinOp ">" (EApp (EApp (EVar "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 126)))) (EApp (EVar "Err") (ELit (LString "http: invalid quoted media-type parameter"))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "pos")) (ELit (LInt 127)))) (EApp (EVar "Err") (ELit (LString "http: control byte in media-type parameter"))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "parseMediaParameters" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "parseMediaParameters" ((PVar "value") (PVar "pos") (PVar "end") (PVar "count")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp ">=" (EVar "count") (ELit (LInt 32))) (EApp (EVar "Err") (ELit (LString "http: media type has too many parameters"))) (EIf (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "Err") (ELit (LString "http: invalid media-type parameter separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "Err") (ELit (LString "http: empty media-type parameter name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "afterName") (EVar "end")) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EVar "Err") (ELit (LString "http: media-type parameter requires a value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (DoExpr (EIf (EBinOp ">=" (EVar "valueStart") (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: media-type parameter requires a value"))) (EApp (EApp (EVar "andThen") (EIf (EBinOp "==" (EApp (EApp (EVar "index") (EVar "value")) (EVar "valueStart")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "valueStart") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "tokenEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "tokenEnd") (EVar "valueStart")) (EApp (EVar "Err") (ELit (LString "http: invalid media-type parameter value"))) (EApp (EVar "Ok") (EVar "tokenEnd"))))))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EApp (EVar "parseMediaParameters") (EVar "value")) (EVar "valueEnd")) (EVar "end")) (EBinOp "+" (EVar "count") (ELit (LInt 1)))))))))))))))))))))
(DTypeSig true "parseMediaType" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "MediaType"))))
(DFunDef false "parseMediaType" ((PVar "value")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "end") (ELit (LInt 0))) (EBinOp ">" (EVar "end") (ELit (LInt 4096)))) (EApp (EVar "Err") (ELit (LString "http: media type exceeds its 4096-byte resource limit"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (EApp (EVar "not") (EApp (EApp (EVar "validMediaBytes") (EVar "value")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "http: media type must be bounded ASCII"))) (EBlock (DoLet false false (PVar "typeEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "typeEnd") (ELit (LInt 0))) (EBinOp ">=" (EVar "typeEnd") (EVar "end"))) (EBinOp "/=" (EApp (EApp (EVar "index") (EVar "value")) (EVar "typeEnd")) (ELit (LInt 47)))) (EApp (EVar "Err") (ELit (LString "http: invalid media type"))) (EBlock (DoLet false false (PVar "subtypeStart") (EBinOp "+" (EVar "typeEnd") (ELit (LInt 1)))) (DoLet false false (PVar "subtypeEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "subtypeStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "subtypeEnd") (EVar "subtypeStart")) (EApp (EVar "Err") (ELit (LString "http: invalid media subtype"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "parseMediaParameters") (EVar "value")) (EVar "subtypeEnd")) (EVar "end")) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EApp (EApp (EVar "MediaType") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (ELit (LInt 0))) (EVar "typeEnd"))) (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (EVar "subtypeStart")) (EVar "subtypeEnd"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))
(DTypeSig false "contentType" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "MediaType"))))
(DFunDef false "contentType" ((PVar "headers")) (EBlock (DoLet false false (PVar "count") (EApp (EApp (EVar "countNamed") (ELit (LString "content-type"))) (EVar "headers"))) (DoExpr (EIf (EBinOp "==" (EVar "count") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "http: request body requires Content-Type"))) (EIf (EBinOp ">" (EVar "count") (ELit (LInt 1))) (EApp (EVar "Err") (ELit (LString "http: duplicate Content-Type"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "content-type"))) (EVar "headers")) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "http: request body requires Content-Type")))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "parseMediaType") (EVar "value")))))))))
(DTypeSig true "decodeRequestBody" (TyFun (TyCon "Request") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "DecodedBody"))))
(DFunDef false "decodeRequestBody" ((PCon "Request" PWild PWild (PVar "headers") PWild (PVar "packed") PWild)) (EApp (EApp (EVar "andThen") (EApp (EVar "contentType") (EVar "headers"))) (ELam ((PVar "mediaType")) (ELet false (PVar "size") (EApp (EVar "bytesLength") (EVar "packed")) (EMatch (EVar "mediaType") (arm (PCon "MediaType" (PLit (LString "application")) (PLit (LString "json"))) () (EApp (EApp (EVar "andThen") (EApp (EVar "checkJsonBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "body") (EApp (EVar "toArray") (EVar "packed")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validUtf8From") (EVar "body")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: JSON body is not valid UTF-8"))) (EMatch (EApp (EVar "parse") (EApp (EVar "fromUtf8") (EVar "body"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "http: invalid JSON body: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "value")) () (EApp (EVar "Ok") (EApp (EApp (EVar "JsonBody") (EVar "mediaType")) (EVar "value")))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm (PCon "MediaType" (PLit (LString "text")) PWild) () (EApp (EApp (EVar "andThen") (EApp (EVar "checkTextBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "body") (EApp (EVar "toArray") (EVar "packed")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validUtf8From") (EVar "body")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: text body is not valid UTF-8"))) (EApp (EVar "Ok") (EApp (EApp (EVar "TextBody") (EVar "mediaType")) (EApp (EVar "fromUtf8") (EVar "body"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm PWild () (EApp (EApp (EVar "andThen") (EApp (EVar "checkRawBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EApp (EApp (EVar "RawBody") (EVar "mediaType")) (EApp (EVar "toArray") (EVar "packed"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
# MARK
(DUse false (UseGroup ("bytebuilder") ((mem "Builder" false) (mem "appendBytes" false) (mem "buildArray" false) (mem "buildBytes" false) (mem "emitU8" false) (mem "newBuilder" false))))
(DUse false (UseWild ("bytes")))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "parse" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "fromUtf8" false) (mem "toUtf8" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false))))
(DTypeSig true "maxHttpRequestBytes" (TyCon "Int"))
(DFunDef false "maxHttpRequestBytes" () (ELit (LInt 6291456)))
(DTypeSig true "maxHttpHeaderBytes" (TyCon "Int"))
(DFunDef false "maxHttpHeaderBytes" () (ELit (LInt 65536)))
(DTypeSig true "maxHttpBodyBytes" (TyCon "Int"))
(DFunDef false "maxHttpBodyBytes" () (ELit (LInt 5242880)))
(DTypeSig true "maxHttpRequestLineBytes" (TyCon "Int"))
(DFunDef false "maxHttpRequestLineBytes" () (ELit (LInt 8192)))
(DTypeSig true "maxHttpResponseStatusLineBytes" (TyCon "Int"))
(DFunDef false "maxHttpResponseStatusLineBytes" () (ELit (LInt 8192)))
(DTypeSig true "maxHttpResponseChunkBytes" (TyCon "Int"))
(DFunDef false "maxHttpResponseChunkBytes" () (ELit (LInt 1048576)))
(DTypeSig true "maxHttpHeaderFields" (TyCon "Int"))
(DFunDef false "maxHttpHeaderFields" () (ELit (LInt 100)))
(DTypeSig true "maxHttpTrailerFields" (TyCon "Int"))
(DFunDef false "maxHttpTrailerFields" () (ELit (LInt 32)))
(DTypeSig true "maxHttpChunks" (TyCon "Int"))
(DFunDef false "maxHttpChunks" () (ELit (LInt 65536)))
(DTypeSig true "maxJsonBodyBytes" (TyCon "Int"))
(DFunDef false "maxJsonBodyBytes" () (ELit (LInt 153600)))
(DTypeSig true "maxTextBodyBytes" (TyCon "Int"))
(DFunDef false "maxTextBodyBytes" () (ELit (LInt 102400)))
(DTypeSig true "maxRawBodyBytes" (TyCon "Int"))
(DFunDef false "maxRawBodyBytes" () (ELit (LInt 5242880)))
(DTypeSig true "checkHttpRequestBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpRequestBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpRequestBytes")) (EApp (EVar "Err") (ELit (LString "http: request exceeds 6291456-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpHeaderBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpHeaderBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpHeaderBytes")) (EApp (EVar "Err") (ELit (LString "http: combined header and trailer section exceeds 65536-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpRequestLineBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpRequestLineBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpRequestLineBytes")) (EApp (EVar "Err") (ELit (LString "http: request line exceeds 8192-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpResponseStatusLineBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpResponseStatusLineBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpResponseStatusLineBytes")) (EApp (EVar "Err") (ELit (LString "http: status line exceeds 8192-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpResponseChunkBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpResponseChunkBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpResponseChunkBytes")) (EApp (EVar "Err") (ELit (LString "http: chunk size exceeds 1048576-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpHeaderFields" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpHeaderFields" ((PVar "count")) (EIf (EBinOp ">" (EDictApp "count") (EVar "maxHttpHeaderFields")) (EApp (EVar "Err") (ELit (LString "http: header field count exceeds 100 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpTrailerFields" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpTrailerFields" ((PVar "count")) (EIf (EBinOp ">" (EDictApp "count") (EVar "maxHttpTrailerFields")) (EApp (EVar "Err") (ELit (LString "http: trailer field count exceeds 32 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkHttpChunks" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkHttpChunks" ((PVar "count")) (EIf (EBinOp ">" (EDictApp "count") (EVar "maxHttpChunks")) (EApp (EVar "Err") (ELit (LString "http: chunk count exceeds 65536 resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkJsonBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkJsonBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxJsonBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: JSON body exceeds 153600-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkTextBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkTextBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxTextBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: text body exceeds 102400-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DTypeSig true "checkRawBodyBytes" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "checkRawBodyBytes" ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxRawBodyBytes")) (EApp (EVar "Err") (ELit (LString "http: raw body exceeds 5242880-byte resource limit"))) (EApp (EVar "Ok") (ELit LUnit))))
(DData Abstract "Header" () ((variant "Header" (ConPos (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Abstract "Request" () ((variant "Request" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Bytes") (TyCon "Bool")))) ())
(DData Private "RequestLine" () ((variant "RequestLine" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int")))) ())
(DData Private "HeaderBlock" () ((variant "HeaderBlock" (ConPos (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int")))) ())
(DData Private "BodyMode" () ((variant "NoBody" (ConPos)) (variant "FixedBody" (ConPos (TyCon "Int"))) (variant "ChunkedBody" (ConPos)) (variant "UntilCloseBody" (ConPos))) ())
(DData Private "ParsedBody" () ((variant "ParsedBody" (ConPos (TyCon "Bytes") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int")))) ())
(DTypeSig false "emptyBody" (TyCon "Bytes"))
(DFunDef false "emptyBody" () (EApp (EVar "fromArrayAssumeByteDomain") (EArrayLit)))
(DData Public "HttpParseFailure" () ((variant "HttpMalformed" (ConPos (TyCon "String"))) (variant "HttpResourceExcess" (ConPos (TyCon "String")))) ())
(DData Private "FrameError" () ((variant "Incomplete" (ConPos (TyCon "String"))) (variant "Fatal" (ConPos (TyCon "HttpParseFailure")))) ())
(DTypeSig false "settle" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyVar "a"))))
(DFunDef false "settle" ((PCon "Ok" (PVar "value"))) (EApp (EVar "Ok") (EVar "value")))
(DFunDef false "settle" ((PCon "Err" (PCon "Incomplete" (PVar "message")))) (EApp (EVar "Err") (EApp (EVar "HttpMalformed") (EVar "message"))))
(DFunDef false "settle" ((PCon "Err" (PCon "Fatal" (PVar "failure")))) (EApp (EVar "Err") (EVar "failure")))
(DTypeSig false "malformed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "malformed" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpMalformed") (EVar "message")))))
(DTypeSig false "incomplete" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "incomplete" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Incomplete") (EVar "message"))))
(DTypeSig false "resourceExcess" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "resourceExcess" ((PCon "Ok" (PLit LUnit))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "resourceExcess" ((PCon "Err" (PVar "message"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EVar "message")))))
(DTypeSig true "httpParseFailureMessage" (TyFun (TyCon "HttpParseFailure") (TyCon "String")))
(DFunDef false "httpParseFailureMessage" ((PCon "HttpMalformed" (PVar "message"))) (EVar "message"))
(DFunDef false "httpParseFailureMessage" ((PCon "HttpResourceExcess" (PVar "message"))) (EVar "message"))
(DTypeSig true "headerName" (TyFun (TyCon "Header") (TyCon "String")))
(DFunDef false "headerName" ((PCon "Header" (PVar "name") PWild)) (EVar "name"))
(DTypeSig true "headerValue" (TyFun (TyCon "Header") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "headerValue" ((PCon "Header" PWild (PVar "value"))) (EApp (EVar "arrayCopy") (EVar "value")))
(DTypeSig false "copyHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "copyHeaders" ((PList)) (EListLit))
(DFunDef false "copyHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "Header") (EVar "name")) (EApp (EVar "arrayCopy") (EVar "value"))) (EApp (EVar "copyHeaders") (EVar "rest"))))
(DTypeSig true "requestMethod" (TyFun (TyCon "Request") (TyCon "String")))
(DFunDef false "requestMethod" ((PCon "Request" (PVar "method") PWild PWild PWild PWild PWild)) (EVar "method"))
(DTypeSig true "requestTarget" (TyFun (TyCon "Request") (TyCon "String")))
(DFunDef false "requestTarget" ((PCon "Request" PWild (PVar "target") PWild PWild PWild PWild)) (EVar "target"))
(DTypeSig true "requestHeaders" (TyFun (TyCon "Request") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "requestHeaders" ((PCon "Request" PWild PWild (PVar "headers") PWild PWild PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "requestTrailers" (TyFun (TyCon "Request") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "requestTrailers" ((PCon "Request" PWild PWild PWild (PVar "trailers") PWild PWild)) (EApp (EVar "copyHeaders") (EVar "trailers")))
(DTypeSig true "requestBody" (TyFun (TyCon "Request") (TyCon "Bytes")))
(DFunDef false "requestBody" ((PCon "Request" PWild PWild PWild PWild (PVar "body") PWild)) (EVar "body"))
(DTypeSig true "requestBodyLength" (TyFun (TyCon "Request") (TyCon "Int")))
(DFunDef false "requestBodyLength" ((PCon "Request" PWild PWild PWild PWild (PVar "body") PWild)) (EApp (EVar "bytesLength") (EVar "body")))
(DTypeSig true "requestKeepAlive" (TyFun (TyCon "Request") (TyCon "Bool")))
(DFunDef false "requestKeepAlive" ((PCon "Request" PWild PWild PWild PWild PWild (PVar "keepAlive"))) (EVar "keepAlive"))
(DTypeSig false "validBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validBytes" ((PVar "value") (PVar "i") (PVar "end")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i")) (ELit (LInt 0))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i")) (ELit (LInt 255)))) (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "lowerByte" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "lowerByte" ((PVar "byte")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90)))) (EBinOp "+" (EVar "byte") (ELit (LInt 32))) (EVar "byte")))
(DTypeSig false "lowerAscii" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lowerAscii" ((PVar "input") (PVar "start") (PVar "end")) (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "i")) (EApp (EVar "lowerByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "start") (EVar "i"))))))))
(DTypeSig false "lowerAsciiBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lowerAsciiBytes" ((PVar "input") (PVar "start") (PVar "end")) (EApp (EVar "fromUtf8") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "i")) (EApp (EVar "lowerByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "start") (EVar "i"))))))))
(DTypeSig true "isTokenByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isTokenByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 122))))) (EBinOp "==" (EVar "byte") (ELit (LInt 33)))) (EBinOp "==" (EVar "byte") (ELit (LInt 35)))) (EBinOp "==" (EVar "byte") (ELit (LInt 36)))) (EBinOp "==" (EVar "byte") (ELit (LInt 37)))) (EBinOp "==" (EVar "byte") (ELit (LInt 38)))) (EBinOp "==" (EVar "byte") (ELit (LInt 39)))) (EBinOp "==" (EVar "byte") (ELit (LInt 42)))) (EBinOp "==" (EVar "byte") (ELit (LInt 43)))) (EBinOp "==" (EVar "byte") (ELit (LInt 45)))) (EBinOp "==" (EVar "byte") (ELit (LInt 46)))) (EBinOp "==" (EVar "byte") (ELit (LInt 94)))) (EBinOp "==" (EVar "byte") (ELit (LInt 95)))) (EBinOp "==" (EVar "byte") (ELit (LInt 96)))) (EBinOp "==" (EVar "byte") (ELit (LInt 124)))) (EBinOp "==" (EVar "byte") (ELit (LInt 126)))))
(DTypeSig false "allToken" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allToken" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isTokenByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allToken") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "allTokenBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allTokenBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isTokenByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "isHexByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isHexByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 70))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 102))))))
(DTypeSig false "isUnreservedByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isUnreservedByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 122))))) (EBinOp "==" (EVar "byte") (ELit (LInt 45)))) (EBinOp "==" (EVar "byte") (ELit (LInt 46)))) (EBinOp "==" (EVar "byte") (ELit (LInt 95)))) (EBinOp "==" (EVar "byte") (ELit (LInt 126)))))
(DTypeSig false "isSubDelimiterByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSubDelimiterByte" ((PVar "byte")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 33))) (EBinOp "==" (EVar "byte") (ELit (LInt 36)))) (EBinOp "==" (EVar "byte") (ELit (LInt 38)))) (EBinOp "==" (EVar "byte") (ELit (LInt 39)))) (EBinOp "==" (EVar "byte") (ELit (LInt 40)))) (EBinOp "==" (EVar "byte") (ELit (LInt 41)))) (EBinOp "==" (EVar "byte") (ELit (LInt 42)))) (EBinOp "==" (EVar "byte") (ELit (LInt 43)))) (EBinOp "==" (EVar "byte") (ELit (LInt 44)))) (EBinOp "==" (EVar "byte") (ELit (LInt 59)))) (EBinOp "==" (EVar "byte") (ELit (LInt 61)))))
(DTypeSig false "validTarget" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "validTarget" ((PVar "input") (PVar "pos") (PVar "end") (PVar "query")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "byte") (ELit (LInt 37))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end")) (EVar "query"))) (EBlock (DoLet false false (PVar "pchar") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EBinOp "==" (EVar "byte") (ELit (LInt 58)))) (EBinOp "==" (EVar "byte") (ELit (LInt 64))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EVar "pchar") (EBinOp "==" (EVar "byte") (ELit (LInt 47)))) (EBinOp "&&" (EVar "query") (EBinOp "==" (EVar "byte") (ELit (LInt 63))))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "query")) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "query")) (EBinOp "==" (EVar "byte") (ELit (LInt 63)))) (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "True")) (EVar "False"))))))))))
(DTypeSig false "exactAsciiAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "exactAsciiAt" ((PVar "input") (PVar "start") (PVar "expected")) (EBlock (DoLet false false (PVar "wanted") (EApp (EVar "toUtf8Bytes") (EVar "expected"))) (DoLet false false (PVar "size") (EApp (EVar "bytesLength") (EVar "wanted"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EBinOp "+" (EVar "start") (EVar "size")) (EApp (EVar "bytesLength") (EVar "input"))) (EBinOp "==" (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "start")) (EBinOp "+" (EVar "start") (EVar "size"))) (EVar "wanted"))))))
(DTypeSig false "validFieldValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validFieldValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "validFieldValue") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validFieldValueBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validFieldValueBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "validFieldValueBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig true "findByte" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findByte" ((PVar "value") (PVar "pos") (PVar "end") (PVar "wanted")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (EVar "wanted")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "wanted")))))
(DTypeSig false "findByteBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findByteBytes" ((PVar "input") (PVar "pos") (PVar "end") (PVar "wanted")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (EVar "wanted")) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "wanted")))))
(DTypeSig false "findCrlfChecked" (TyFun (TyCon "String") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))))
(DFunDef false "findCrlfChecked" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "pos") (PVar "limit")) (EIf (EBinOp ">" (EBinOp "-" (EVar "pos") (EVar "start")) (EVar "limit")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EBinOp "++" (EBinOp "++" (ELit (LString "http: ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " exceeds its resource limit")))))) (EIf (EBinOp ">=" (EVar "pos") (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "; expected CRLF")))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 10))) (EApp (EVar "malformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare LF in ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10))) (EApp (EVar "malformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "limit")))))))
(DTypeSig true "findCrlf" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findCrlf" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "Some") (EVar "pos")) (EApp (EApp (EApp (EVar "findCrlf") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "parseRequestLine" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "RequestLine")))))))
(DFunDef false "parseRequestLine" ((PVar "input") (PVar "avail") (PVar "start") (PVar "cursor")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (ELit (LString "request line"))) (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "cursor")) (EVar "maxHttpRequestLineBytes"))) (ELam ((PVar "end")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpRequestLineBytes") (EBinOp "-" (EVar "end") (EVar "start"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "firstSpace")) (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed request line; expected METHOD SP TARGET SP HTTP/1.1")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "secondSpace")) (EIf (EBinOp "||" (EBinOp "==" (EVar "firstSpace") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EVar "start")) (EVar "firstSpace")))) (EApp (EVar "malformed") (ELit (LString "http: invalid method token"))) (EIf (EBinOp "==" (EVar "secondSpace") (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EApp (EVar "malformed") (ELit (LString "http: empty request target"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (ELit (LInt 47))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "validTarget") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "secondSpace")) (EVar "False")))) (EApp (EVar "malformed") (ELit (LString "http: request target must be an origin-form ASCII target without a fragment"))) (EIf (EBinOp "||" (EBinOp "/=" (EBinOp "+" (EVar "secondSpace") (ELit (LInt 9))) (EVar "end")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "exactAsciiAt") (EVar "input")) (EBinOp "+" (EVar "secondSpace") (ELit (LInt 1)))) (ELit (LString "HTTP/1.1"))))) (EApp (EVar "malformed") (ELit (LString "http: only HTTP/1.1 requests are supported"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "RequestLine") (EApp (EVar "fromUtf8Bytes") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "start")) (EVar "firstSpace")))) (EApp (EVar "fromUtf8Bytes") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "secondSpace")))) (EBinOp "+" (EVar "end") (ELit (LInt 2)))))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig true "trimLeftOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimLeftOws" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "trimLeftOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimLeftOwsBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimLeftOwsBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig true "trimRightOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimRightOws" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "end") (EVar "start")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimRightOws") (EVar "value")) (EVar "start")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "end")))
(DTypeSig false "trimRightOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimRightOwsBytes" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "end") (EVar "start")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "trimRightOwsBytes") (EVar "input")) (EVar "start")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "end")))
(DTypeSig false "parseHeaderLine" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Header"))))))
(DFunDef false "parseHeaderLine" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 9)))) (EApp (EVar "malformed") (ELit (LString "http: obsolete folded header lines are forbidden"))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: malformed header field; missing colon")))) (arm (PCon "Some" (PVar "colon")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "colon") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allTokenBytes") (EVar "input")) (EVar "start")) (EVar "colon")))) (EApp (EVar "malformed") (ELit (LString "http: invalid header field name"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validFieldValueBytes") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "malformed") (ELit (LString "http: control byte in header field value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "trimLeftOwsBytes") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "trimRightOwsBytes") (EVar "input")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAsciiBytes") (EVar "input")) (EVar "start")) (EVar "colon"))) (EApp (EVar "toArray") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "valueStart")) (EVar "valueEnd")))))))))))))
(DTypeSig false "forbiddenTrailer" (TyFun (TyCon "Header") (TyCon "Bool")))
(DFunDef false "forbiddenTrailer" ((PCon "Header" (PVar "name") PWild)) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "content-length"))) (EBinOp "==" (EVar "name") (ELit (LString "transfer-encoding")))) (EBinOp "==" (EVar "name") (ELit (LString "trailer")))) (EBinOp "==" (EVar "name") (ELit (LString "host")))) (EBinOp "==" (EVar "name") (ELit (LString "connection")))))
(DTypeSig false "checkFieldCount" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit")))))
(DFunDef false "checkFieldCount" ((PVar "trailer") (PVar "count")) (EIf (EVar "trailer") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpTrailerFields") (EDictApp "count"))) (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpHeaderFields") (EDictApp "count")))))
(DData Private "FieldStep" () ((variant "FieldDone" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "FieldMore" (ConPos (TyCon "Header") (TyCon "Int")))) ())
(DTypeSig false "fieldStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FieldStep")))))))))))
(DFunDef false "fieldStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "cursor") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "trailer")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (EIf (EVar "trailer") (ELit (LString "trailer field")) (ELit (LString "header field")))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "cursor")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "end")) (ELet false (PVar "next") (EBinOp "+" (EVar "end") (ELit (LInt 2))) (ELet false (PVar "totalBytes") (EBinOp "-" (EBinOp "+" (EVar "priorBytes") (EVar "next")) (EVar "sectionStart")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpHeaderBytes") (EVar "totalBytes")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EIf (EBinOp "==" (EVar "end") (EVar "pos")) (EApp (EVar "Ok") (EApp (EApp (EVar "FieldDone") (EVar "next")) (EVar "totalBytes"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "checkFieldCount") (EVar "trailer")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseHeaderLine") (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "field")) (EIf (EBinOp "&&" (EVar "trailer") (EApp (EVar "forbiddenTrailer") (EVar "field"))) (EApp (EVar "malformed") (ELit (LString "http: forbidden framing or routing field in trailer"))) (EApp (EVar "Ok") (EApp (EApp (EVar "FieldMore") (EVar "field")) (EVar "next"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "parseFieldsChecked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "HeaderBlock"))))))))))
(DFunDef false "parseFieldsChecked" ((PVar "input") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "trailer") (PVar "acc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "pos")) (EVar "pos")) (EVar "sectionStart")) (EVar "priorBytes")) (EDictApp "count")) (EVar "trailer"))) (ELam ((PVar "step")) (EMatch (EVar "step") (arm (PCon "FieldDone" (PVar "next") (PVar "totalBytes")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "HeaderBlock") (EApp (EVar "reverse") (EVar "acc"))) (EVar "next")) (EVar "totalBytes")))) (arm (PCon "FieldMore" (PVar "field") (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "next")) (EVar "sectionStart")) (EVar "priorBytes")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EVar "trailer")) (EBinOp "::" (EVar "field") (EVar "acc"))))))))
(DTypeSig true "parseFields" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyTuple (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int")))))))
(DFunDef false "parseFields" ((PVar "input") (PVar "pos") (PVar "trailer")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "HeaderBlock" (PVar "fields") (PVar "next") PWild)) (ETuple (EVar "fields") (EVar "next")))) (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "pos")) (EVar "pos")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "trailer")) (EListLit)))))
(DTypeSig false "countNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))
(DFunDef false "countNamed" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "countNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "findNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "findNamed" (PWild (PList)) (EVar "None"))
(DFunDef false "findNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "findNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "asciiEqualCiGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "asciiEqualCiGo" ((PVar "value") (PVar "expected") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EBinOp "==" (EVar "i") (EApp (EVar "arrayLength") (EVar "expected"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "expected"))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i")) (ELit (LInt 127)))) (EBinOp "==" (EApp (EVar "lowerByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i"))) (EApp (EVar "lowerByte") (EApp (EApp (EMethodRef "index") (EVar "expected")) (EVar "i"))))) (EApp (EApp (EApp (EVar "asciiEqualCiGo") (EVar "value")) (EVar "expected")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "asciiEqualCi" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "asciiEqualCi" ((PVar "value") (PVar "expected")) (EApp (EApp (EApp (EVar "asciiEqualCiGo") (EVar "value")) (EApp (EVar "toUtf8") (EVar "expected"))) (ELit (LInt 0))))
(DTypeSig false "parseDecimalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseDecimalGo" ((PVar "value") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EApp (EVar "Ok") (EVar "acc")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "byte") (ELit (LInt 48))) (EBinOp ">" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "malformed") (ELit (LString "http: invalid Content-Length"))) (EBlock (DoLet false false (PVar "digit") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (DoExpr (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (ELit (LInt 4611686018427387903)) (EVar "digit")) (ELit (LInt 10)))) (EApp (EVar "malformed") (ELit (LString "http: Content-Length overflows Int"))) (EApp (EApp (EApp (EVar "parseDecimalGo") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "digit")))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "value")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "malformed") (ELit (LString "http: empty Content-Length"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseDecimalGo") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpBodyBytes") (EVar "size")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "selectBodyMode" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "BodyMode"))))
(DFunDef false "selectBodyMode" ((PVar "headers")) (EBlock (DoLet false false (PVar "clCount") (EApp (EApp (EVar "countNamed") (ELit (LString "content-length"))) (EVar "headers"))) (DoLet false false (PVar "teCount") (EApp (EApp (EVar "countNamed") (ELit (LString "transfer-encoding"))) (EVar "headers"))) (DoExpr (EIf (EBinOp ">" (EVar "clCount") (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: duplicate Content-Length is ambiguous"))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "clCount") (ELit (LInt 0))) (EBinOp ">" (EVar "teCount") (ELit (LInt 0)))) (EApp (EVar "malformed") (ELit (LString "http: Transfer-Encoding with Content-Length is ambiguous"))) (EIf (EBinOp ">" (EVar "teCount") (ELit (LInt 0))) (EIf (EBinOp "/=" (EVar "teCount") (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: repeated Transfer-Encoding is unsupported"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "transfer-encoding"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EApp (EVar "asciiEqualCi") (EVar "value")) (ELit (LString "chunked"))) (EApp (EVar "Ok") (EVar "ChunkedBody")) (EApp (EVar "malformed") (ELit (LString "http: unsupported transfer coding; expected exactly chunked"))))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: internal transfer framing error")))))) (EIf (EBinOp "==" (EVar "clCount") (ELit (LInt 1))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "content-length"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EApp (EApp (EMethodRef "map") (EVar "FixedBody")) (EApp (EVar "parseContentLength") (EVar "value")))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: internal content framing error"))))) (EApp (EVar "Ok") (EVar "NoBody")))))))))
(DTypeSig false "scanTokenEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanTokenEnd" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isTokenByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "scanTokenEndBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanTokenEndBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isTokenByte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "parseConnectionValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Bool"))))))
(DFunDef false "parseConnectionValue" ((PVar "value") (PVar "pos") (PVar "sawClose")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: empty token in Connection field"))) (EBlock (DoLet false false (PVar "tokenEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "start")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "tokenEnd") (EVar "start")) (EApp (EVar "malformed") (ELit (LString "http: invalid Connection token"))) (EBlock (DoLet false false (PVar "closeNow") (EBinOp "||" (EVar "sawClose") (EBinOp "==" (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (EVar "start")) (EVar "tokenEnd")) (ELit (LString "close"))))) (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "value")) (EVar "tokenEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "after") (EVar "end")) (EApp (EVar "Ok") (EVar "closeNow")) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "after")) (ELit (LInt 44))) (EApp (EVar "malformed") (ELit (LString "http: invalid Connection token list"))) (EApp (EApp (EApp (EVar "parseConnectionValue") (EVar "value")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "closeNow")))))))))))))
(DTypeSig false "keepAliveFromHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Bool"))))
(DFunDef false "keepAliveFromHeaders" ((PList)) (EApp (EVar "Ok") (EVar "True")))
(DFunDef false "keepAliveFromHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "keepAliveFromHeaders") (EVar "rest"))) (ELam ((PVar "restKeepAlive")) (EIf (EBinOp "/=" (EVar "name") (ELit (LString "connection"))) (EApp (EVar "Ok") (EVar "restKeepAlive")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseConnectionValue") (EVar "value")) (ELit (LInt 0))) (EVar "False"))) (ELam ((PVar "closes")) (EApp (EVar "Ok") (EBinOp "&&" (EVar "restKeepAlive") (EApp (EVar "not") (EVar "closes"))))))))))
(DTypeSig false "validRegName" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validRegName" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "byte") (ELit (LInt 37))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end"))))))))
(DTypeSig false "allDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allDigits" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 57)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "decimalValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "decimalValue" ((PVar "value") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "decimalValue") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos"))) (ELit (LInt 48))))))
(DTypeSig false "validIpv4" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "validIpv4" ((PVar "value") (PVar "start") (PVar "end") (PVar "parts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "parts") (ELit (LInt 4))) (EBinOp ">=" (EVar "start") (EVar "end"))) (EVar "False") (EBlock (DoLet false false (PVar "dot") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "start")) (EVar "end")) (ELit (LInt 46))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoLet false false (PVar "size") (EBinOp "-" (EVar "dot") (EVar "start"))) (DoLet false false (PVar "validPart") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "size") (ELit (LInt 1))) (EBinOp "<=" (EVar "size") (ELit (LInt 3)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EVar "start")) (EVar "dot"))) (EBinOp "<=" (EApp (EApp (EApp (EApp (EVar "decimalValue") (EVar "value")) (EVar "start")) (EVar "dot")) (ELit (LInt 0))) (ELit (LInt 255)))) (EBinOp "||" (EBinOp "==" (EVar "size") (ELit (LInt 1))) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "start")) (ELit (LInt 48)))))) (DoExpr (EIf (EApp (EVar "not") (EVar "validPart")) (EVar "False") (EIf (EBinOp "==" (EVar "dot") (EVar "end")) (EBinOp "==" (EVar "parts") (ELit (LInt 3))) (EApp (EApp (EApp (EApp (EVar "validIpv4") (EVar "value")) (EBinOp "+" (EVar "dot") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EVar "parts") (ELit (LInt 1))))))))))
(DTypeSig false "allHex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allHex" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBinOp "&&" (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos"))) (EApp (EApp (EApp (EVar "allHex") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))
(DTypeSig false "validIpv6Go" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "validIpv6Go" ((PVar "value") (PVar "pos") (PVar "end") (PVar "groups") (PVar "compressed")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EIf (EVar "compressed") (EBinOp "<" (EVar "groups") (ELit (LInt 8))) (EBinOp "==" (EVar "groups") (ELit (LInt 8)))) (EBlock (DoLet false false (PVar "colon") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "pos")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "at")) () (EVar "at")))) (DoExpr (EIf (EBinOp "==" (EVar "colon") (EVar "pos")) (EVar "False") (EBlock (DoLet false false (PVar "dot") (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (EVar "pos")) (EVar "colon")) (ELit (LInt 46)))) (DoLet false false (PVar "componentGroups") (EMatch (EVar "dot") (arm (PCon "None") () (EIf (EBinOp "&&" (EBinOp "<=" (EBinOp "-" (EVar "colon") (EVar "pos")) (ELit (LInt 4))) (EApp (EApp (EApp (EVar "allHex") (EVar "value")) (EVar "pos")) (EVar "colon"))) (ELit (LInt 1)) (ELit (LInt 9)))) (arm (PCon "Some" PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "colon") (EVar "end")) (EApp (EApp (EApp (EApp (EVar "validIpv4") (EVar "value")) (EVar "pos")) (EVar "colon")) (ELit (LInt 0)))) (ELit (LInt 2)) (ELit (LInt 9)))))) (DoLet false false (PVar "nextGroups") (EBinOp "+" (EVar "groups") (EVar "componentGroups"))) (DoExpr (EIf (EBinOp ">" (EVar "nextGroups") (ELit (LInt 8))) (EVar "False") (EIf (EBinOp "==" (EVar "colon") (EVar "end")) (EIf (EVar "compressed") (EBinOp "<" (EVar "nextGroups") (ELit (LInt 8))) (EBinOp "==" (EVar "nextGroups") (ELit (LInt 8)))) (EIf (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "colon") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (ELit (LInt 58)))) (EBinOp "&&" (EApp (EVar "not") (EVar "compressed")) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 2)))) (EVar "end")) (EVar "nextGroups")) (EVar "True"))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end")) (EVar "nextGroups")) (EVar "compressed"))))))))))))
(DTypeSig false "validIpv6" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpv6" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "start")) (ELit (LInt 58))) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "start") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (ELit (LInt 58)))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 2)))) (EVar "end")) (ELit (LInt 0))) (EVar "True"))) (EApp (EApp (EApp (EApp (EApp (EVar "validIpv6Go") (EVar "value")) (EVar "start")) (EVar "end")) (ELit (LInt 0))) (EVar "False")))))
(DTypeSig false "scanHex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "scanHex" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EApp (EVar "isHexByte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")))) (EApp (EApp (EApp (EVar "scanHex") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "validIpvFutureTail" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpvFutureTail" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "||" (EApp (EVar "isUnreservedByte") (EVar "byte")) (EApp (EVar "isSubDelimiterByte") (EVar "byte"))) (EBinOp "==" (EVar "byte") (ELit (LInt 58)))) (EApp (EApp (EApp (EVar "validIpvFutureTail") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validIpvFuture" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpvFuture" ((PVar "value") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "start") (EVar "end")) (EBinOp "&&" (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "start")) (ELit (LInt 118))) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "start")) (ELit (LInt 86))))) (EVar "False") (EBlock (DoLet false false (PVar "versionEnd") (EApp (EApp (EApp (EVar "scanHex") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "versionEnd") (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "<" (EVar "versionEnd") (EVar "end"))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "versionEnd")) (ELit (LInt 46)))) (EBinOp "<" (EBinOp "+" (EVar "versionEnd") (ELit (LInt 1))) (EVar "end"))) (EApp (EApp (EApp (EVar "validIpvFutureTail") (EVar "value")) (EBinOp "+" (EVar "versionEnd") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "validIpLiteral" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "validIpLiteral" ((PVar "value") (PVar "start") (PVar "end")) (EBinOp "||" (EApp (EApp (EApp (EVar "validIpv6") (EVar "value")) (EVar "start")) (EVar "end")) (EApp (EApp (EApp (EVar "validIpvFuture") (EVar "value")) (EVar "start")) (EVar "end"))))
(DTypeSig false "validHostAuthority" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "validHostAuthority" ((PVar "value")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoExpr (EIf (EBinOp "==" (EVar "end") (ELit (LInt 0))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 91))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (ELit (LInt 1))) (EVar "end")) (ELit (LInt 93))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "close")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "validIpLiteral") (EVar "value")) (ELit (LInt 1))) (EVar "close")) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "close") (ELit (LInt 1))) (EVar "end")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "close") (ELit (LInt 1))) (EVar "end")) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "close") (ELit (LInt 1)))) (ELit (LInt 58)))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "close") (ELit (LInt 2)))) (EVar "end"))))))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "value")) (ELit (LInt 0))) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (arm (PCon "Some" (PVar "colon")) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "colon") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "validRegName") (EVar "value")) (ELit (LInt 0))) (EVar "colon"))) (EApp (EApp (EApp (EVar "allDigits") (EVar "value")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))))))))))
(DTypeSig false "validateHost" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "validateHost" ((PVar "headers")) (EIf (EBinOp "/=" (EApp (EApp (EVar "countNamed") (ELit (LString "host"))) (EVar "headers")) (ELit (LInt 1))) (EApp (EVar "malformed") (ELit (LString "http: HTTP/1.1 requires exactly one Host field"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "host"))) (EVar "headers")) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EVar "not") (EApp (EVar "validHostAuthority") (EVar "value"))) (EApp (EVar "malformed") (ELit (LString "http: Host field must contain a valid authority"))) (EApp (EVar "Ok") (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: missing Host field")))))))
(DTypeSig false "readSliceAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyCon "Bytes") (TyCon "Int")))))))
(DFunDef false "readSliceAt" ((PVar "input") (PVar "pos") (PVar "size")) (EBlock (DoLet false false (PVar "avail") (EApp (EVar "bytesLength") (EVar "input"))) (DoExpr (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "size"))) (EBinOp "+" (EVar "pos") (EVar "size"))))))))
(DTypeSig false "emitArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyCon "Unit")))))
(DFunDef false "emitArray" ((PVar "bytes") (PVar "i") (PVar "out")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "out"))))))
(DTypeSig true "hexDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexDigit" ((PVar "byte")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 48))) (EBinOp "<=" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 65))) (EBinOp "<=" (EVar "byte") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 55)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 97))) (EBinOp "<=" (EVar "byte") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "byte") (ELit (LInt 87)))) (EVar "None")))))
(DTypeSig false "parseHexSizeGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "parseHexSizeGo" ((PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EVar "hexDigit") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EVar "malformed") (ELit (LString "http: invalid chunk size")))) (arm (PCon "Some" (PVar "digit")) () (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "maxHttpBodyBytes") (EVar "digit")) (ELit (LInt 16)))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk size exceeds decoded body limit"))))) (EApp (EApp (EApp (EApp (EVar "parseHexSizeGo") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "digit"))))))))
(DTypeSig true "skipOws" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipOws" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "skipOwsBytes" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipOwsBytes" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EVar "end")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 9))))) (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "pos")))
(DTypeSig false "scanQuoted" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "scanQuoted" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: unterminated quoted chunk extension"))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: truncated quoted-pair in chunk extension"))) (EBlock (DoLet false false (PVar "escaped") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "escaped") (ELit (LInt 9))) (EBinOp "==" (EVar "escaped") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp ">=" (EVar "escaped") (ELit (LInt 33))) (EBinOp "/=" (EVar "escaped") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: control byte in quoted chunk extension"))))))) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "==" (EVar "byte") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 33))) (EBinOp "/=" (EVar "byte") (ELit (LInt 34)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 92)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: control byte in quoted chunk extension"))))))))))
(DTypeSig false "parseChunkExtensionValue" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseChunkExtensionValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "malformed") (ELit (LString "http: missing chunk extension value"))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "scanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "valueEnd") (EVar "pos")) (EApp (EVar "malformed") (ELit (LString "http: invalid chunk extension value"))) (EApp (EVar "Ok") (EVar "valueEnd"))))))))
(DTypeSig false "parseChunkExtensionsGo" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))))
(DFunDef false "parseChunkExtensionsGo" ((PVar "input") (PVar "pos") (PVar "end")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "malformed") (ELit (LString "http: invalid chunk extension separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEndBytes") (EVar "input")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "malformed") (ELit (LString "http: empty chunk extension name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "afterName") (EVar "end")) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseChunkExtensionValue") (EVar "input")) (EApp (EApp (EApp (EVar "skipOwsBytes") (EVar "input")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (EVar "end"))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "valueEnd")) (EVar "end")))) (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "afterName")) (EVar "end")))))))))))))
(DTypeSig false "parseChunkSize" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "parseChunkSize" ((PVar "input") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "semi") (EMatch (EApp (EApp (EApp (EApp (EVar "findByteBytes") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 59))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "semi") (EVar "start")) (EApp (EVar "malformed") (ELit (LString "http: empty chunk size"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "parseHexSizeGo") (EVar "input")) (EVar "start")) (EVar "semi")) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseChunkExtensionsGo") (EVar "input")) (EVar "semi")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig false "parseChunkedChecked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedBody")))))))))
(DFunDef false "parseChunkedChecked" ((PVar "input") (PVar "pos") (PVar "headerBytes") (PVar "out") (PVar "total") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chunkHeadStep") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "pos")) (EVar "pos")) (EVar "total")) (EDictApp "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ChunkEnd" (PVar "dataPos")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseFieldsChecked") (EVar "input")) (EVar "dataPos")) (EVar "dataPos")) (EVar "headerBytes")) (ELit (LInt 0))) (EVar "True")) (EListLit))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "HeaderBlock" (PVar "trailers") (PVar "finalPos") PWild) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EApp (EVar "buildBytes") (EVar "out"))) (EVar "trailers")) (EVar "finalPos")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm (PCon "ChunkBody" (PVar "dataPos") (PVar "size")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "readSliceAt") (EVar "input")) (EVar "dataPos")) (EVar "size"))) (ELam ((PTuple (PVar "chunk") PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "chunkDataEnd") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (ELet false (PLit LUnit) (EApp (EApp (EVar "appendBytes") (EVar "chunk")) (EVar "out")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "next")) (EVar "headerBytes")) (EVar "out")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EDictApp "count") (ELit (LInt 1))))))))))))))
(DTypeSig true "parseChunked" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyTuple (TyCon "Bytes") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))
(DFunDef false "parseChunked" ((PVar "input") (PVar "pos")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "ParsedBody" (PVar "body") (PVar "trailers") (PVar "next"))) (ETuple (EVar "body") (EVar "trailers") (EVar "next")))) (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "pos")) (ELit (LInt 0))) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DData Private "ChunkHead" () ((variant "ChunkEnd" (ConPos (TyCon "Int"))) (variant "ChunkBody" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "chunkHeadStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ChunkHead")))))))))
(DFunDef false "chunkHeadStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "cursor") (PVar "total") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findCrlfChecked") (ELit (LString "chunk-size line"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "cursor")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "lineEnd")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseChunkSize") (EVar "input")) (EVar "pos")) (EVar "lineEnd"))) (ELam ((PVar "size")) (ELet false (PVar "dataPos") (EBinOp "+" (EVar "lineEnd") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "size") (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "ChunkEnd") (EVar "dataPos"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpChunks") (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EIf (EBinOp ">" (EVar "size") (EBinOp "-" (EVar "maxHttpBodyBytes") (EVar "total"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded chunked body exceeds resource limit"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "ChunkBody") (EVar "dataPos")) (EVar "size"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))
(DTypeSig false "chunkDataEnd" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "chunkDataEnd" ((PVar "input") (PVar "avail") (PVar "dataPos") (PVar "size")) (EBlock (DoLet false false (PVar "afterChunk") (EBinOp "+" (EVar "dataPos") (EVar "size"))) (DoExpr (EIf (EBinOp ">" (EVar "afterChunk") (EVar "avail")) (EApp (EVar "incomplete") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EIf (EBinOp ">" (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))) (EVar "avail")) (EApp (EVar "incomplete") (ELit (LString "http: truncated CRLF after chunk data"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "afterChunk")) (ELit (LInt 13))) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "afterChunk") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "malformed") (ELit (LString "http: missing CRLF after chunk data"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))))))))))
(DTypeSig false "parseBody" (TyFun (TyCon "BodyMode") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedBody")))))))
(DFunDef false "parseBody" ((PCon "NoBody") PWild (PVar "pos") PWild) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EVar "emptyBody")) (EListLit)) (EVar "pos"))))
(DFunDef false "parseBody" ((PCon "FixedBody" (PVar "size")) (PVar "input") (PVar "pos") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "readSliceAt") (EVar "input")) (EVar "pos")) (EVar "size"))) (ELam ((PTuple (PVar "body") (PVar "finalPos"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EVar "body")) (EListLit)) (EVar "finalPos"))))))
(DFunDef false "parseBody" ((PCon "ChunkedBody") (PVar "input") (PVar "pos") (PVar "headerBytes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseChunkedChecked") (EVar "input")) (EVar "pos")) (EVar "headerBytes")) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))
(DFunDef false "parseBody" ((PCon "UntilCloseBody") (PVar "input") (PVar "pos") PWild) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ParsedBody") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EApp (EVar "bytesLength") (EVar "input")))) (EListLit)) (EApp (EVar "bytesLength") (EVar "input")))))
(DTypeSig false "trailingMessage" (TyFun (TyCon "BodyMode") (TyCon "String")))
(DFunDef false "trailingMessage" ((PCon "NoBody")) (ELit (LString "http: unframed or trailing request bytes")))
(DFunDef false "trailingMessage" ((PCon "FixedBody" PWild)) (ELit (LString "http: bytes after framed fixed-length request")))
(DFunDef false "trailingMessage" ((PCon "ChunkedBody")) (ELit (LString "http: bytes after framed chunked request")))
(DData Private "FramedRequest" () ((variant "FramedRequest" (ConPos (TyCon "Request") (TyCon "BodyMode") (TyCon "Int")))) ())
(DData Private "FrameHead" () ((variant "FrameHead" (ConPos (TyCon "RequestLine") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "BodyMode") (TyCon "Bool") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "FrameSpan" () ((variant "FrameSpan" (ConPos (TyCon "FrameHead") (TyCon "Int")))) ())
(DTypeSig false "headHeaderBytes" (TyFun (TyCon "FrameHead") (TyCon "Int")))
(DFunDef false "headHeaderBytes" ((PCon "FrameHead" PWild PWild PWild PWild PWild (PVar "headerBytes"))) (EVar "headerBytes"))
(DTypeSig false "requestLineHeaderPos" (TyFun (TyCon "RequestLine") (TyCon "Int")))
(DFunDef false "requestLineHeaderPos" ((PCon "RequestLine" PWild PWild (PVar "headerPos"))) (EVar "headerPos"))
(DData Private "BodyPhase" () ((variant "BodyUntil" (ConPos (TyCon "Int"))) (variant "BodyChunkSize" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "BodyChunkData" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "BodyTrailers" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "ScanPhase" () ((variant "PhaseLine" (ConPos (TyCon "Int"))) (variant "PhaseFields" (ConPos (TyCon "RequestLine") (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (variant "PhaseBody" (ConPos (TyCon "FrameHead") (TyCon "BodyPhase")))) ())
(DData Private "ScanOutcome" () ((variant "ScanSuspend" (ConPos (TyCon "String") (TyCon "ScanPhase"))) (variant "ScanFatal" (ConPos (TyCon "HttpParseFailure"))) (variant "ScanFramed" (ConPos (TyCon "FrameSpan")))) ())
(DTypeSig false "crlfResume" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "crlfResume" ((PVar "avail") (PVar "lineStart")) (EApp (EApp (EMethodRef "max") (EVar "lineStart")) (EBinOp "-" (EVar "avail") (ELit (LInt 1)))))
(DTypeSig false "buildHead" (TyFun (TyCon "RequestLine") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FrameHead")))))))
(DFunDef false "buildHead" ((PVar "line") (PVar "headers") (PVar "bodyPos") (PVar "headerBytes")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "validateHost") (EVar "headers"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "selectBodyMode") (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "keepAliveFromHeaders") (EVar "headers"))) (ELam ((PVar "keepAlive")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "FrameHead") (EVar "line")) (EVar "headers")) (EVar "mode")) (EVar "keepAlive")) (EVar "bodyPos")) (EVar "headerBytes")))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "headBodyPhase" (TyFun (TyCon "FrameHead") (TyCon "BodyPhase")))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "NoBody") PWild (PVar "bodyPos") PWild)) (EApp (EVar "BodyUntil") (EVar "bodyPos")))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "FixedBody" (PVar "size")) PWild (PVar "bodyPos") PWild)) (EApp (EVar "BodyUntil") (EBinOp "+" (EVar "bodyPos") (EVar "size"))))
(DFunDef false "headBodyPhase" ((PCon "FrameHead" PWild PWild (PCon "ChunkedBody") PWild (PVar "bodyPos") PWild)) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "bodyPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "bodyPos")))
(DTypeSig false "scanBody" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "FrameHead") (TyFun (TyCon "BodyPhase") (TyCon "ScanOutcome"))))))
(DFunDef false "scanBody" (PWild (PVar "avail") (PVar "head") (PCon "BodyUntil" (PVar "finalPos"))) (EIf (EBinOp "<=" (EVar "finalPos") (EVar "avail")) (EApp (EVar "ScanFramed") (EApp (EApp (EVar "FrameSpan") (EVar "head")) (EVar "finalPos"))) (EApp (EApp (EVar "ScanSuspend") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated body at byte ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "avail")))) (ELit (LString "")))) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EVar "BodyUntil") (EVar "finalPos"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyChunkSize" (PVar "chunkPos") (PVar "total") (PVar "count") (PVar "cursor"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "chunkPos")) (EApp (EApp (EMethodRef "max") (EVar "chunkPos")) (EVar "cursor"))) (EVar "total")) (EDictApp "count")) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "chunkPos")) (EVar "total")) (EDictApp "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "chunkPos")))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "ChunkEnd" (PVar "dataPos"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (EVar "dataPos")))) (arm (PCon "Ok" (PCon "ChunkBody" (PVar "dataPos") (PVar "size"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkData") (EVar "dataPos")) (EVar "size")) (EVar "total")) (EDictApp "count"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyChunkData" (PVar "dataPos") (PVar "size") (PVar "total") (PVar "count"))) (EMatch (EApp (EApp (EApp (EApp (EVar "chunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size")) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkData") (EVar "dataPos")) (EVar "size")) (EVar "total")) (EDictApp "count"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "next")) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyChunkSize") (EVar "next")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EVar "next"))))))
(DFunDef false "scanBody" ((PVar "input") (PVar "avail") (PVar "head") (PCon "BodyTrailers" (PVar "sectionStart") (PVar "pos") (PVar "count") (PVar "cursor"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EApp (EMethodRef "max") (EVar "pos")) (EVar "cursor"))) (EVar "sectionStart")) (EApp (EVar "headHeaderBytes") (EVar "head"))) (EDictApp "count")) (EVar "True"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EVar "PhaseBody") (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "sectionStart")) (EVar "pos")) (EDictApp "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "pos")))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "FieldMore" PWild (PVar "next"))) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "BodyTrailers") (EVar "sectionStart")) (EVar "next")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EVar "next")))) (arm (PCon "Ok" (PCon "FieldDone" (PVar "finalPos") PWild)) () (EApp (EVar "ScanFramed") (EApp (EApp (EVar "FrameSpan") (EVar "head")) (EVar "finalPos"))))))))
(DTypeSig false "scanFrom" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ScanPhase") (TyCon "ScanOutcome"))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") (PVar "start") (PCon "PhaseLine" (PVar "cursor"))) (EMatch (EApp (EApp (EApp (EApp (EVar "parseRequestLine") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EMethodRef "max") (EVar "start")) (EVar "cursor"))) (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EVar "PhaseLine") (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "start"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "line")) () (EBlock (DoLet false false (PVar "headerPos") (EApp (EVar "requestLineHeaderPos") (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EListLit)) (EVar "headerPos")) (ELit (LInt 0))) (EVar "headerPos"))))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") (PVar "start") (PCon "PhaseFields" (PVar "line") (PVar "acc") (PVar "pos") (PVar "count") (PVar "cursor"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EApp (EMethodRef "max") (EVar "pos")) (EVar "cursor"))) (EApp (EVar "requestLineHeaderPos") (EVar "line"))) (ELit (LInt 0))) (EDictApp "count")) (EVar "False"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Err" (PCon "Incomplete" (PVar "message"))) () (EApp (EApp (EVar "ScanSuspend") (EVar "message")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EVar "acc")) (EVar "pos")) (EDictApp "count")) (EApp (EApp (EVar "crlfResume") (EVar "avail")) (EVar "pos"))))) (arm (PCon "Err" (PCon "Fatal" (PVar "failure"))) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PCon "FieldMore" (PVar "field") (PVar "next"))) () (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "PhaseFields") (EVar "line")) (EBinOp "::" (EVar "field") (EVar "acc"))) (EVar "next")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EVar "next")))) (arm (PCon "Ok" (PCon "FieldDone" (PVar "bodyPos") (PVar "headerBytes"))) () (EMatch (EApp (EVar "settle") (EApp (EApp (EApp (EApp (EVar "buildHead") (EVar "line")) (EApp (EVar "reverse") (EVar "acc"))) (EVar "bodyPos")) (EVar "headerBytes"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "ScanFatal") (EVar "failure"))) (arm (PCon "Ok" (PVar "head")) () (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EApp (EVar "headBodyPhase") (EVar "head"))))))))))
(DFunDef false "scanFrom" ((PVar "input") (PVar "avail") PWild (PCon "PhaseBody" (PVar "head") (PVar "phase"))) (EApp (EApp (EApp (EApp (EVar "scanBody") (EVar "input")) (EVar "avail")) (EVar "head")) (EVar "phase")))
(DTypeSig false "frameSpanAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FrameSpan")))))
(DFunDef false "frameSpanAt" ((PVar "input") (PVar "start")) (EBlock (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "start")) (EApp (EVar "PhaseLine") (EVar "start")))) (DoExpr (EMatch (EVar "outcome") (arm (PCon "ScanSuspend" (PVar "message") PWild) () (EApp (EVar "Err") (EApp (EVar "Incomplete") (EVar "message")))) (arm (PCon "ScanFatal" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "Fatal") (EVar "failure")))) (arm (PCon "ScanFramed" (PVar "span")) () (EApp (EVar "Ok") (EVar "span")))))))
(DTypeSig false "frameFromSpan" (TyFun (TyCon "Bytes") (TyFun (TyCon "FrameHead") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FramedRequest"))))))
(DFunDef false "frameFromSpan" ((PVar "input") (PCon "FrameHead" (PCon "RequestLine" (PVar "method") (PVar "target") PWild) (PVar "headers") (PVar "mode") (PVar "keepAlive") (PVar "bodyPos") (PVar "headerBytes")) (PVar "finalPos")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "parseBody") (EVar "mode")) (EVar "input")) (EVar "bodyPos")) (EVar "headerBytes"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ParsedBody" (PVar "body") (PVar "trailers") PWild) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "FramedRequest") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Request") (EVar "method")) (EVar "target")) (EVar "headers")) (EVar "trailers")) (EVar "body")) (EVar "keepAlive"))) (EVar "mode")) (EVar "finalPos")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "frameRequestAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "FramedRequest")))))
(DFunDef false "frameRequestAt" ((PVar "input") (PVar "start")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "frameSpanAt") (EVar "input")) (EVar "start"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "FrameSpan" (PVar "head") (PVar "finalPos")) () (EApp (EApp (EApp (EVar "frameFromSpan") (EVar "input")) (EVar "head")) (EVar "finalPos"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseWholeBuffer" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Request"))))
(DFunDef false "parseWholeBuffer" ((PVar "input")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resourceExcess") (EApp (EVar "checkHttpRequestBytes") (EApp (EVar "bytesLength") (EVar "input"))))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "frameRequestAt") (EVar "input")) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "FramedRequest" (PVar "request") (PVar "mode") (PVar "finalPos")) () (EIf (EBinOp "/=" (EVar "finalPos") (EApp (EVar "bytesLength") (EVar "input"))) (EApp (EVar "malformed") (EApp (EVar "trailingMessage") (EVar "mode"))) (EApp (EVar "Ok") (EVar "request")))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "parseRequestClassified" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "Request"))))
(DFunDef false "parseRequestClassified" ((PVar "input")) (EApp (EVar "settle") (EApp (EVar "parseWholeBuffer") (EVar "input"))))
(DData Public "HttpFrame" () ((variant "HttpNeedMore" (ConPos)) (variant "HttpFramedAt" (ConPos (TyCon "Int"))) (variant "HttpFrameFailed" (ConPos (TyCon "HttpParseFailure")))) ())
(DTypeSig false "requestBytesVerdict" (TyFun (TyCon "Int") (TyFun (TyCon "HttpFrame") (TyCon "HttpFrame"))))
(DFunDef false "requestBytesVerdict" ((PVar "size") (PVar "framed")) (EMatch (EApp (EVar "checkHttpRequestBytes") (EVar "size")) (arm (PCon "Ok" (PLit LUnit)) () (EVar "framed")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpResourceExcess") (EVar "message"))))))
(DData Abstract "HttpScan" () ((variant "HttpScan" (ConPos (TyCon "ScanPhase")))) ())
(DTypeSig true "httpScanStart" (TyCon "HttpScan"))
(DFunDef false "httpScanStart" () (EApp (EVar "HttpScan") (EApp (EVar "PhaseLine") (ELit (LInt 0)))))
(DTypeSig true "httpScanInHeaders" (TyFun (TyCon "HttpScan") (TyCon "Bool")))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseLine" PWild))) (EVar "True"))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseFields" PWild PWild PWild PWild PWild))) (EVar "True"))
(DFunDef false "httpScanInHeaders" ((PCon "HttpScan" (PCon "PhaseBody" PWild PWild))) (EVar "False"))
(DTypeSig true "httpScanBodyRemaining" (TyFun (TyCon "HttpScan") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "httpScanBodyRemaining" ((PCon "HttpScan" (PCon "PhaseBody" PWild (PCon "BodyUntil" (PVar "finalPos")))) (PVar "avail")) (EApp (EVar "Some") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "finalPos") (EVar "avail")))))
(DFunDef false "httpScanBodyRemaining" (PWild PWild) (EVar "None"))
(DTypeSig false "scanVerdict" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyFun (TyCon "ScanOutcome") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan")))))))
(DFunDef false "scanVerdict" (PWild (PVar "start") (PVar "scanned") (PCon "ScanFramed" (PCon "FrameSpan" PWild (PVar "finalPos")))) (ETuple (EApp (EApp (EVar "requestBytesVerdict") (EBinOp "-" (EVar "finalPos") (EVar "start"))) (EApp (EVar "HttpFramedAt") (EVar "finalPos"))) (EVar "scanned")))
(DFunDef false "scanVerdict" (PWild PWild (PVar "scanned") (PCon "ScanFatal" (PVar "failure"))) (ETuple (EApp (EVar "HttpFrameFailed") (EVar "failure")) (EVar "scanned")))
(DFunDef false "scanVerdict" ((PVar "avail") (PVar "start") PWild (PCon "ScanSuspend" PWild (PVar "phase"))) (ETuple (EApp (EApp (EVar "requestBytesVerdict") (EBinOp "-" (EVar "avail") (EVar "start"))) (EVar "HttpNeedMore")) (EApp (EVar "HttpScan") (EVar "phase"))))
(DTypeSig true "scanRequestBoundaryWithin" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan")))))))
(DFunDef false "scanRequestBoundaryWithin" ((PVar "input") (PVar "avail") (PVar "start") (PCon "HttpScan" (PVar "phase"))) (EBlock (DoLet false false (PVar "unchanged") (EApp (EVar "HttpScan") (EVar "phase"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "avail") (ELit (LInt 0))) (EBinOp ">" (EVar "avail") (EApp (EVar "bytesLength") (EVar "input")))) (ETuple (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpMalformed") (ELit (LString "http: scan length outside buffer")))) (EVar "unchanged")) (EIf (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp ">" (EVar "start") (EVar "avail"))) (ETuple (EApp (EVar "HttpFrameFailed") (EApp (EVar "HttpMalformed") (ELit (LString "http: scan offset outside buffer")))) (EVar "unchanged")) (EApp (EApp (EApp (EApp (EVar "scanVerdict") (EVar "avail")) (EVar "start")) (EApp (EVar "HttpScan") (EVar "phase"))) (EApp (EApp (EApp (EApp (EVar "scanFrom") (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "phase"))))))))
(DTypeSig true "scanRequestBoundaryFrom" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "HttpScan") (TyTuple (TyCon "HttpFrame") (TyCon "HttpScan"))))))
(DFunDef false "scanRequestBoundaryFrom" ((PVar "input") (PVar "start") (PVar "scan")) (EApp (EApp (EApp (EApp (EVar "scanRequestBoundaryWithin") (EVar "input")) (EApp (EVar "bytesLength") (EVar "input"))) (EVar "start")) (EVar "scan")))
(DTypeSig true "scanRequestBoundary" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyCon "HttpFrame"))))
(DFunDef false "scanRequestBoundary" ((PVar "input") (PVar "start")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "scanRequestBoundaryFrom") (EVar "input")) (EVar "start")) (EVar "httpScanStart"))))
(DTypeSig true "parseRequestAt" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "Request"))))))
(DFunDef false "parseRequestAt" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp "<" (EVar "end") (EVar "start"))) (EBinOp ">" (EVar "end") (EApp (EVar "bytesLength") (EVar "input")))) (EApp (EVar "Err") (EApp (EVar "HttpMalformed") (ELit (LString "http: request frame bounds outside buffer")))) (EApp (EVar "parseRequestClassified") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "start")) (EVar "end")))))
(DTypeSig true "parseRequest" (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Request"))))
(DFunDef false "parseRequest" ((PVar "input")) (EMatch (EApp (EVar "parseRequestClassified") (EVar "input")) (arm (PCon "Ok" (PVar "request")) () (EApp (EVar "Ok") (EVar "request"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "httpParseFailureMessage") (EVar "failure"))))))
(DData Abstract "ParsedResponse" () ((variant "ParsedResponse" (ConPos (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig true "parsedResponseStatus" (TyFun (TyCon "ParsedResponse") (TyCon "Int")))
(DFunDef false "parsedResponseStatus" ((PCon "ParsedResponse" (PVar "status") PWild PWild PWild PWild)) (EVar "status"))
(DTypeSig true "parsedResponseReason" (TyFun (TyCon "ParsedResponse") (TyCon "String")))
(DFunDef false "parsedResponseReason" ((PCon "ParsedResponse" PWild (PVar "reason") PWild PWild PWild)) (EVar "reason"))
(DTypeSig true "parsedResponseHeaders" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "parsedResponseHeaders" ((PCon "ParsedResponse" PWild PWild (PVar "headers") PWild PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "parsedResponseTrailers" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "parsedResponseTrailers" ((PCon "ParsedResponse" PWild PWild PWild (PVar "trailers") PWild)) (EApp (EVar "copyHeaders") (EVar "trailers")))
(DTypeSig true "parsedResponseBody" (TyFun (TyCon "ParsedResponse") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "parsedResponseBody" ((PCon "ParsedResponse" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayCopy") (EVar "body")))
(DTypeSig true "parsedResponseBodyLength" (TyFun (TyCon "ParsedResponse") (TyCon "Int")))
(DFunDef false "parsedResponseBodyLength" ((PCon "ParsedResponse" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayLength") (EVar "body")))
(DData Private "ResponseStatusLine" () ((variant "ResponseStatusLine" (ConPos (TyCon "Int") (TyCon "String") (TyCon "Int")))) ())
(DData Private "ResponseFieldStep" () ((variant "ResponseFieldDone" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "ResponseFieldMore" (ConPos (TyCon "Header") (TyCon "Int")))) ())
(DTypeSig false "responseMalformed" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyVar "a"))))
(DFunDef false "responseMalformed" ((PVar "message")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpMalformed") (EVar "message")))))
(DTypeSig false "responseResourceExcess" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))
(DFunDef false "responseResourceExcess" ((PCon "Ok" (PLit LUnit))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "responseResourceExcess" ((PCon "Err" (PVar "message"))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EVar "message")))))
(DTypeSig false "responseFindCrlf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))))
(DFunDef false "responseFindCrlf" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "limit")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlfGo") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EVar "start")) (EVar "limit")))
(DTypeSig false "responseFindCrlfGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))))
(DFunDef false "responseFindCrlfGo" ((PVar "label") (PVar "input") (PVar "avail") (PVar "start") (PVar "pos") (PVar "limit")) (EIf (EBinOp ">" (EBinOp "-" (EVar "pos") (EVar "start")) (EVar "limit")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (EBinOp "++" (EBinOp "++" (ELit (LString "http: ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " exceeds its resource limit")))))) (EIf (EBinOp ">=" (EVar "pos") (EVar "avail")) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: truncated ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "; expected CRLF")))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 10))) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare LF in ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "")))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 13))) (EIf (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "avail")) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (EBinOp "++" (EBinOp "++" (ELit (LString "http: bare CR in ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "")))) (EApp (EVar "Ok") (EVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlfGo") (EVar "label")) (EVar "input")) (EVar "avail")) (EVar "start")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "limit")))))))
(DTypeSig false "responseParseDecimalGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseDecimalGo" ((PVar "value") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EApp (EVar "Ok") (EVar "acc")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "byte") (ELit (LInt 48))) (EBinOp ">" (EVar "byte") (ELit (LInt 57)))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid decimal field"))) (EBlock (DoLet false false (PVar "digit") (EBinOp "-" (EVar "byte") (ELit (LInt 48)))) (DoExpr (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "intMaxBound") (EVar "digit")) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (ELit (LString "http: decimal field overflows Int"))) (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "digit")))))))))))
(DTypeSig false "responseParseStatusLine" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseStatusLine")))))
(DFunDef false "responseParseStatusLine" ((PVar "input") (PVar "avail")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "status line"))) (EVar "input")) (EVar "avail")) (ELit (LInt 0))) (EVar "maxHttpResponseStatusLineBytes"))) (ELam ((PVar "end")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "responseResourceExcess") (EApp (EVar "checkHttpResponseStatusLineBytes") (EVar "end")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (ELit (LInt 0))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed status line; expected HTTP-version SP status SP reason")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "firstSpace")) (EApp (EApp (EMethodRef "andThen") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EVar "end")) (ELit (LInt 32))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed status line; expected HTTP-version SP status SP reason")))) (arm (PCon "Some" (PVar "pos")) () (EApp (EVar "Ok") (EVar "pos"))))) (ELam ((PVar "secondSpace")) (ELet false (PVar "versionBytes") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (ELit (LInt 0))) (EVar "firstSpace")) (EIf (EBinOp "||" (EBinOp "/=" (EVar "firstSpace") (ELit (LInt 8))) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "versionBytes") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.1")))) (EBinOp "==" (EVar "versionBytes") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.0"))))))) (EApp (EVar "responseMalformed") (ELit (LString "http: only HTTP/1.0 and HTTP/1.1 responses are supported"))) (EIf (EBinOp "/=" (EBinOp "-" (EBinOp "-" (EVar "secondSpace") (EVar "firstSpace")) (ELit (LInt 1))) (ELit (LInt 3))) (EApp (EVar "responseMalformed") (ELit (LString "http: status code must be exactly three digits"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 1)))) (EBinOp "+" (EVar "firstSpace") (ELit (LInt 4))))) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "status")) (EIf (EBinOp "||" (EBinOp "<" (EVar "status") (ELit (LInt 100))) (EBinOp ">" (EVar "status") (ELit (LInt 999)))) (EApp (EVar "responseMalformed") (ELit (LString "http: status code out of range"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "ResponseStatusLine") (EVar "status")) (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EBinOp "+" (EVar "secondSpace") (ELit (LInt 1)))) (EVar "end")))) (EBinOp "+" (EVar "end") (ELit (LInt 2)))))))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "responseParseHeaderLine" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Header"))))))
(DFunDef false "responseParseHeaderLine" ((PVar "input") (PVar "start") (PVar "end")) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 9)))) (EApp (EVar "responseMalformed") (ELit (LString "http: obsolete folded header lines are forbidden"))) (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 58))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: malformed header field; missing colon")))) (arm (PCon "Some" (PVar "colon")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "colon") (EVar "start")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allToken") (EVar "input")) (EVar "start")) (EVar "colon")))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid header field name"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validFieldValue") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in header field value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "trimLeftOws") (EVar "input")) (EBinOp "+" (EVar "colon") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "trimRightOws") (EVar "input")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "input")) (EVar "start")) (EVar "colon"))) (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "valueStart")) (EVar "valueEnd"))))))))))))
(DTypeSig false "responseFieldStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseFieldStep")))))))))
(DFunDef false "responseFieldStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "header field"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "end")) (ELet false (PVar "next") (EBinOp "+" (EVar "end") (ELit (LInt 2))) (ELet false (PVar "totalBytes") (EBinOp "-" (EBinOp "+" (EVar "priorBytes") (EVar "next")) (EVar "sectionStart")) (EIf (EBinOp ">" (EVar "totalBytes") (EVar "maxHttpHeaderBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: combined header and trailer section exceeds 65536-byte resource limit"))))) (EIf (EBinOp "==" (EVar "end") (EVar "pos")) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseFieldDone") (EVar "next")) (EVar "totalBytes"))) (EIf (EBinOp ">" (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EVar "maxHttpHeaderFields")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: header field count exceeds 100 resource limit"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseHeaderLine") (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "field")) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseFieldMore") (EVar "field")) (EVar "next")))))))))))))
(DTypeSig false "responseParseFields" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "responseParseFields" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "sectionStart") (PVar "priorBytes") (PVar "count") (PVar "acc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseFieldStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "sectionStart")) (EVar "priorBytes")) (EDictApp "count"))) (ELam ((PVar "step")) (EMatch (EVar "step") (arm (PCon "ResponseFieldDone" (PVar "next") (PVar "totalBytes")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EVar "next") (EVar "totalBytes")))) (arm (PCon "ResponseFieldMore" (PVar "field") (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "next")) (EVar "sectionStart")) (EVar "priorBytes")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))) (EBinOp "::" (EVar "field") (EVar "acc"))))))))
(DTypeSig false "responseCountNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))
(DFunDef false "responseCountNamed" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "responseCountNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "responseCountNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "responseFindNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "responseFindNamed" (PWild (PList)) (EVar "None"))
(DFunDef false "responseFindNamed" ((PVar "wanted") (PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "wanted")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "responseFindNamed") (EVar "wanted")) (EVar "rest"))))
(DTypeSig false "responseImpliesNoBody" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "responseImpliesNoBody" ((PVar "status")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "status") (ELit (LInt 100))) (EBinOp "<" (EVar "status") (ELit (LInt 200)))) (EBinOp "==" (EVar "status") (ELit (LInt 204)))) (EBinOp "==" (EVar "status") (ELit (LInt 304)))))
(DTypeSig false "responseSelectBodyMode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "BodyMode")))))
(DFunDef false "responseSelectBodyMode" ((PVar "status") (PVar "headers")) (EBlock (DoLet false false (PVar "clCount") (EApp (EApp (EVar "responseCountNamed") (ELit (LString "content-length"))) (EVar "headers"))) (DoLet false false (PVar "teCount") (EApp (EApp (EVar "responseCountNamed") (ELit (LString "transfer-encoding"))) (EVar "headers"))) (DoExpr (EIf (EBinOp ">" (EVar "clCount") (ELit (LInt 1))) (EApp (EVar "responseMalformed") (ELit (LString "http: duplicate Content-Length is ambiguous"))) (EIf (EBinOp "&&" (EBinOp ">" (EVar "clCount") (ELit (LInt 0))) (EBinOp ">" (EVar "teCount") (ELit (LInt 0)))) (EApp (EVar "responseMalformed") (ELit (LString "http: Transfer-Encoding with Content-Length is ambiguous"))) (EIf (EBinOp ">" (EVar "teCount") (ELit (LInt 0))) (EIf (EBinOp "/=" (EVar "teCount") (ELit (LInt 1))) (EApp (EVar "responseMalformed") (ELit (LString "http: repeated Transfer-Encoding is unsupported"))) (EMatch (EApp (EApp (EVar "responseFindNamed") (ELit (LString "transfer-encoding"))) (EVar "headers")) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: missing Transfer-Encoding value")))) (arm (PCon "Some" (PVar "value")) () (EIf (EApp (EApp (EVar "asciiEqualCi") (EVar "value")) (ELit (LString "chunked"))) (EApp (EVar "Ok") (EVar "ChunkedBody")) (EApp (EVar "responseMalformed") (ELit (LString "http: unsupported Transfer-Encoding coding"))))))) (EMatch (EApp (EApp (EVar "responseFindNamed") (ELit (LString "content-length"))) (EVar "headers")) (arm (PCon "None") () (EIf (EApp (EVar "responseImpliesNoBody") (EVar "status")) (EApp (EVar "Ok") (EVar "NoBody")) (EApp (EVar "Ok") (EVar "UntilCloseBody")))) (arm (PCon "Some" (PVar "value")) () (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "responseMalformed") (ELit (LString "http: empty Content-Length"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseDecimalGo") (EVar "value")) (ELit (LInt 0))) (ELit (LInt 0)))) (ELam ((PVar "size")) (EIf (EBinOp ">" (EVar "size") (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))))) (EApp (EVar "Ok") (EApp (EVar "FixedBody") (EVar "size")))))))))))))))
(DTypeSig false "responseParseHexSizeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseParseHexSizeGo" ((PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (EVar "acc")) (EMatch (EApp (EVar "hexDigit") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk size")))) (arm (PCon "Some" (PVar "digit")) () (EIf (EBinOp ">" (EVar "acc") (EBinOp "/" (EBinOp "-" (EVar "maxHttpResponseChunkBytes") (EVar "digit")) (ELit (LInt 16)))) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk size exceeds resource limit"))))) (EApp (EApp (EApp (EApp (EVar "responseParseHexSizeGo") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "digit"))))))))
(DTypeSig false "responseScanQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseScanQuoted" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: unterminated quoted chunk extension"))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated quoted-pair in chunk extension"))) (EBlock (DoLet false false (PVar "escaped") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "escaped") (ELit (LInt 9))) (EBinOp "==" (EVar "escaped") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp ">=" (EVar "escaped") (ELit (LInt 33))) (EBinOp "/=" (EVar "escaped") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in quoted chunk extension"))))))) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "==" (EVar "byte") (ELit (LInt 32)))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 33))) (EBinOp "/=" (EVar "byte") (ELit (LInt 34)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 92)))) (EBinOp "/=" (EVar "byte") (ELit (LInt 127))))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: control byte in quoted chunk extension"))))))))))
(DTypeSig false "responseParseChunkExtensionValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseChunkExtensionValue" ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "responseMalformed") (ELit (LString "http: missing chunk extension value"))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "responseScanQuoted") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "valueEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "valueEnd") (EVar "pos")) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk extension value"))) (EApp (EVar "Ok") (EVar "valueEnd"))))))))
(DTypeSig false "responseParseChunkExtensionsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Unit"))))))
(DFunDef false "responseParseChunkExtensionsGo" ((PVar "input") (PVar "pos") (PVar "end")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "responseMalformed") (ELit (LString "http: invalid chunk extension separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "input")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "responseMalformed") (ELit (LString "http: empty chunk extension name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "afterName") (EVar "end")) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseChunkExtensionValue") (EVar "input")) (EApp (EApp (EApp (EVar "skipOws") (EVar "input")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (EVar "end"))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "valueEnd")) (EVar "end")))) (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "afterName")) (EVar "end")))))))))))))
(DTypeSig false "responseParseChunkSize" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int"))))))
(DFunDef false "responseParseChunkSize" ((PVar "input") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "semi") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 59))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "semi") (EVar "start")) (EApp (EVar "responseMalformed") (ELit (LString "http: empty chunk size"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseParseHexSizeGo") (EVar "input")) (EVar "start")) (EVar "semi")) (ELit (LInt 0)))) (ELam ((PVar "size")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseChunkExtensionsGo") (EVar "input")) (EVar "semi")) (EVar "end"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EVar "size"))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DData Private "ResponseChunkHead" () ((variant "ResponseChunkEnd" (ConPos (TyCon "Int"))) (variant "ResponseChunkBody" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "responseChunkHeadStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ResponseChunkHead")))))))
(DFunDef false "responseChunkHeadStep" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "responseFindCrlf") (ELit (LString "chunk-size line"))) (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "maxHttpHeaderBytes"))) (ELam ((PVar "lineEnd")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "responseParseChunkSize") (EVar "input")) (EVar "pos")) (EVar "lineEnd"))) (ELam ((PVar "size")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "responseResourceExcess") (EApp (EVar "checkHttpResponseChunkBytes") (EVar "size")))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "dataPos") (EBinOp "+" (EVar "lineEnd") (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "size") (ELit (LInt 0))) (EApp (EVar "Ok") (EApp (EVar "ResponseChunkEnd") (EVar "dataPos"))) (EIf (EBinOp ">" (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EVar "maxHttpChunks")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: chunk count exceeds 65536 resource limit"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "ResponseChunkBody") (EVar "dataPos")) (EVar "size"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "responseReadSliceAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))))))
(DFunDef false "responseReadSliceAt" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "size")) (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated chunk body"))) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "size"))) (EBinOp "+" (EVar "pos") (EVar "size"))))))
(DTypeSig false "responseChunkDataEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseChunkDataEnd" ((PVar "input") (PVar "avail") (PVar "dataPos") (PVar "size")) (EBlock (DoLet false false (PVar "afterChunk") (EBinOp "+" (EVar "dataPos") (EVar "size"))) (DoExpr (EIf (EBinOp ">" (EVar "afterChunk") (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated chunk body"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: truncated CRLF after chunk data"))) (EIf (EBinOp "||" (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "afterChunk")) (ELit (LInt 13))) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "afterChunk") (ELit (LInt 1)))) (ELit (LInt 10)))) (EApp (EVar "responseMalformed") (ELit (LString "http: missing CRLF after chunk data"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "afterChunk") (ELit (LInt 2))))))))))
(DTypeSig false "responseParseChunked" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))))))
(DFunDef false "responseParseChunked" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "out") (PVar "total") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EDictApp "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ResponseChunkEnd" (PVar "dataPos")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "trailers") (PVar "finalPos") PWild)) (EApp (EVar "Ok") (ETuple (EApp (EVar "buildArray") (EVar "out")) (EVar "trailers") (EVar "finalPos")))))) (arm (PCon "ResponseChunkBody" (PVar "dataPos") (PVar "size")) () (EIf (EBinOp ">" (EBinOp "+" (EVar "total") (EVar "size")) (EVar "maxHttpBodyBytes")) (EApp (EVar "Err") (EApp (EVar "Fatal") (EApp (EVar "HttpResourceExcess") (ELit (LString "http: decoded body exceeds 5242880-byte resource limit"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseReadSliceAt") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PTuple (PVar "chunk") PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (ELet false (PLit LUnit) (EApp (EApp (EApp (EVar "emitArray") (EVar "chunk")) (ELit (LInt 0))) (EVar "out")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseChunked") (EVar "input")) (EVar "avail")) (EVar "next")) (EVar "out")) (EBinOp "+" (EVar "total") (EVar "size"))) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))))))))))))))
(DTypeSig false "responseParseBody" (TyFun (TyCon "BodyMode") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyTuple (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Int"))))))))
(DFunDef false "responseParseBody" ((PCon "NoBody") PWild PWild (PVar "pos")) (EApp (EVar "Ok") (ETuple (EArrayLit) (EListLit) (EVar "pos"))))
(DFunDef false "responseParseBody" ((PCon "FixedBody" (PVar "size")) (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseReadSliceAt") (EVar "input")) (EVar "avail")) (EVar "pos")) (EVar "size"))) (ELam ((PTuple (PVar "body") (PVar "finalPos"))) (EApp (EVar "Ok") (ETuple (EVar "body") (EListLit) (EVar "finalPos"))))))
(DFunDef false "responseParseBody" ((PCon "ChunkedBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseChunked") (EVar "input")) (EVar "avail")) (EVar "pos")) (EApp (EVar "newBuilder") (ELit LUnit))) (ELit (LInt 0))) (ELit (LInt 0))))
(DFunDef false "responseParseBody" ((PCon "UntilCloseBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EVar "Ok") (ETuple (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EVar "avail")) (EListLit) (EVar "avail"))))
(DTypeSig true "parseResponseClassified" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "HttpParseFailure")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponseClassified" ((PVar "input")) (EApp (EVar "settle") (EApp (EVar "parseResponseChecked") (EVar "input"))))
(DTypeSig false "parseResponseChecked" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponseChecked" ((PVar "input")) (ELet false (PVar "avail") (EApp (EVar "arrayLength") (EVar "input")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "responseParseStatusLine") (EVar "input")) (EVar "avail"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ResponseStatusLine" (PVar "status") (PVar "reason") (PVar "lineEnd")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "lineEnd")) (EVar "lineEnd")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "headers") (PVar "headerEnd") PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "responseSelectBodyMode") (EVar "status")) (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseParseBody") (EVar "mode")) (EVar "input")) (EVar "avail")) (EVar "headerEnd"))) (ELam ((PTuple (PVar "body") (PVar "trailers") (PVar "finalPos"))) (EIf (EBinOp "/=" (EVar "finalPos") (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: bytes after framed response"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "ParsedResponse") (EVar "status")) (EVar "reason")) (EVar "headers")) (EVar "trailers")) (EVar "body"))))))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "parseResponse" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ParsedResponse"))))
(DFunDef false "parseResponse" ((PVar "input")) (EMatch (EApp (EVar "parseResponseClassified") (EVar "input")) (arm (PCon "Ok" (PVar "response")) () (EApp (EVar "Ok") (EVar "response"))) (arm (PCon "Err" (PVar "failure")) () (EApp (EVar "Err") (EApp (EVar "httpParseFailureMessage") (EVar "failure"))))))
(DTest false "response malformed diagnostics use the public http vocabulary" (EMatch (EApp (EVar "parseResponseClassified") (EArrayLit)) (arm (PCon "Err" (PCon "HttpMalformed" (PVar "message"))) () (EApp (EApp (EVar "expectEqual") (ELit (LString "http: truncated status line; expected CRLF"))) (EVar "message"))) (arm PWild () (EApp (EVar "expectTrue") (EVar "False")))))
(DTest false "response resource diagnostics use the public http vocabulary" (EBlock (DoLet false false (PVar "input") (EApp (EVar "toUtf8") (ELit (LString "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n100001\r\n")))) (DoExpr (EMatch (EApp (EVar "parseResponseClassified") (EVar "input")) (arm (PCon "Err" (PCon "HttpResourceExcess" (PVar "message"))) () (EApp (EApp (EVar "expectEqual") (ELit (LString "http: chunk size exceeds resource limit"))) (EVar "message"))) (arm PWild () (EApp (EVar "expectTrue") (EVar "False")))))))
(DTypeSig false "responseScanChunkedEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseScanChunkedEnd" ((PVar "input") (PVar "avail") (PVar "pos") (PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkHeadStep") (EVar "input")) (EVar "avail")) (EVar "pos")) (EDictApp "count"))) (ELam ((PVar "head")) (EMatch (EVar "head") (arm (PCon "ResponseChunkEnd" (PVar "dataPos")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "dataPos")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple PWild (PVar "finalPos") PWild)) (EApp (EVar "Ok") (EVar "finalPos"))))) (arm (PCon "ResponseChunkBody" (PVar "dataPos") (PVar "size")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "responseChunkDataEnd") (EVar "input")) (EVar "avail")) (EVar "dataPos")) (EVar "size"))) (ELam ((PVar "next")) (EApp (EApp (EApp (EApp (EVar "responseScanChunkedEnd") (EVar "input")) (EVar "avail")) (EVar "next")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))))))))))
(DTypeSig false "responseScanBodyEnd" (TyFun (TyCon "BodyMode") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))))
(DFunDef false "responseScanBodyEnd" ((PCon "NoBody") PWild PWild (PVar "pos")) (EApp (EVar "Ok") (EVar "pos")))
(DFunDef false "responseScanBodyEnd" ((PCon "FixedBody" (PVar "size")) PWild (PVar "avail") (PVar "pos")) (EIf (EBinOp ">" (EBinOp "+" (EVar "pos") (EVar "size")) (EVar "avail")) (EApp (EVar "responseMalformed") (ELit (LString "http: declared body is still arriving"))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (EVar "size")))))
(DFunDef false "responseScanBodyEnd" ((PCon "ChunkedBody") (PVar "input") (PVar "avail") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "responseScanChunkedEnd") (EVar "input")) (EVar "avail")) (EVar "pos")) (ELit (LInt 0))))
(DFunDef false "responseScanBodyEnd" ((PCon "UntilCloseBody") PWild PWild PWild) (EApp (EVar "responseMalformed") (ELit (LString "http: close-delimited response ends only at the close"))))
(DTypeSig false "responseScanEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "FrameError")) (TyCon "Int")))))
(DFunDef false "responseScanEnd" ((PVar "input") (PVar "avail")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "responseParseStatusLine") (EVar "input")) (EVar "avail"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "ResponseStatusLine" (PVar "status") PWild (PVar "lineEnd")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "responseParseFields") (EVar "input")) (EVar "avail")) (EVar "lineEnd")) (EVar "lineEnd")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (ELam ((PTuple (PVar "headers") (PVar "headerEnd") PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "responseSelectBodyMode") (EVar "status")) (EVar "headers"))) (ELam ((PVar "mode")) (EApp (EApp (EApp (EApp (EVar "responseScanBodyEnd") (EVar "mode")) (EVar "input")) (EVar "avail")) (EVar "headerEnd"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "responseBoundaryWithin" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "responseBoundaryWithin" ((PVar "input") (PVar "avail")) (EIf (EBinOp "||" (EBinOp "<" (EVar "avail") (ELit (LInt 0))) (EBinOp ">" (EVar "avail") (EApp (EVar "arrayLength") (EVar "input")))) (EVar "None") (EMatch (EApp (EApp (EVar "responseScanEnd") (EVar "input")) (EVar "avail")) (arm (PCon "Ok" (PVar "end")) () (EApp (EVar "Some") (EVar "end"))) (arm (PCon "Err" PWild) () (EVar "None")))))
(DTypeSig true "responseBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "responseBoundary" ((PVar "input")) (EApp (EApp (EVar "responseBoundaryWithin") (EVar "input")) (EApp (EVar "arrayLength") (EVar "input"))))
(DData Abstract "Response" () ((variant "Response" (ConPos (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig false "validResponseValue" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validResponseValue" ((PVar "value") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "value"))) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "<=" (EVar "byte") (ELit (LInt 126)))) (EApp (EApp (EVar "validResponseValue") (EVar "value")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "makeHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Header")))))
(DFunDef false "makeHeader" ((PVar "name") (PVar "value")) (EBlock (DoLet false false (PVar "nameBytes") (EApp (EVar "toUtf8") (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "allToken") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "nameBytes"))))) (EApp (EVar "Err") (ELit (LString "http: invalid response header field name"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "value")))) (EApp (EVar "not") (EApp (EApp (EVar "validResponseValue") (EVar "value")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "http: control or non-ASCII byte in response header field value"))) (EApp (EVar "Ok") (EApp (EApp (EVar "Header") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "nameBytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "nameBytes")))) (EApp (EVar "arrayCopy") (EVar "value")))))))))
(DTypeSig false "validReason" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "validReason" ((PVar "reason")) (EApp (EApp (EVar "validResponseValue") (EApp (EVar "toUtf8") (EVar "reason"))) (ELit (LInt 0))))
(DTypeSig false "hasReservedResponseField" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyCon "Bool")))
(DFunDef false "hasReservedResponseField" ((PList)) (EVar "False"))
(DFunDef false "hasReservedResponseField" ((PCons (PCon "Header" (PVar "name") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "content-length"))) (EBinOp "==" (EVar "name") (ELit (LString "transfer-encoding")))) (EApp (EVar "hasReservedResponseField") (EVar "rest"))))
(DTypeSig true "makeResponse" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Response")))))))
(DFunDef false "makeResponse" ((PVar "status") (PVar "reason") (PVar "headers") (PVar "body")) (EIf (EBinOp "||" (EBinOp "<" (EVar "status") (ELit (LInt 100))) (EBinOp ">" (EVar "status") (ELit (LInt 599)))) (EApp (EVar "Err") (ELit (LString "http: response status must be between 100 and 599"))) (EIf (EApp (EVar "not") (EApp (EVar "validReason") (EVar "reason"))) (EApp (EVar "Err") (ELit (LString "http: invalid control or non-ASCII byte in response reason phrase"))) (EIf (EApp (EVar "hasReservedResponseField") (EVar "headers")) (EApp (EVar "Err") (ELit (LString "http: response framing fields are reserved"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "body")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "body")))) (EApp (EVar "Err") (ELit (LString "http: response body element outside byte range 0..255"))) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "Response") (EVar "status")) (EVar "reason")) (EApp (EVar "copyHeaders") (EVar "headers"))) (EApp (EVar "arrayCopy") (EVar "body")))))))))
(DTypeSig true "responseStatus" (TyFun (TyCon "Response") (TyCon "Int")))
(DFunDef false "responseStatus" ((PCon "Response" (PVar "status") PWild PWild PWild)) (EVar "status"))
(DTypeSig true "responseHeaders" (TyFun (TyCon "Response") (TyApp (TyCon "List") (TyCon "Header"))))
(DFunDef false "responseHeaders" ((PCon "Response" PWild PWild (PVar "headers") PWild)) (EApp (EVar "copyHeaders") (EVar "headers")))
(DTypeSig true "responseBody" (TyFun (TyCon "Response") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "responseBody" ((PCon "Response" PWild PWild PWild (PVar "body"))) (EApp (EVar "arrayCopy") (EVar "body")))
(DTypeSig true "responseReason" (TyFun (TyCon "Response") (TyCon "String")))
(DFunDef false "responseReason" ((PCon "Response" PWild (PVar "reason") PWild PWild)) (EVar "reason"))
(DTypeSig false "emitAscii" (TyFun (TyCon "String") (TyFun (TyCon "Builder") (TyCon "Unit"))))
(DFunDef false "emitAscii" ((PVar "text") (PVar "out")) (EApp (EApp (EApp (EVar "emitArray") (EApp (EVar "toUtf8") (EVar "text"))) (ELit (LInt 0))) (EVar "out")))
(DTypeSig false "emitResponseHeaders" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyFun (TyCon "Builder") (TyCon "Unit"))))
(DFunDef false "emitResponseHeaders" ((PList) PWild) (ELit LUnit))
(DFunDef false "emitResponseHeaders" ((PCons (PCon "Header" (PVar "name") (PVar "value")) (PVar "rest")) (PVar "out")) (EBlock (DoExpr (EApp (EApp (EVar "emitAscii") (EVar "name")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString ": "))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "value")) (ELit (LInt 0))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitResponseHeaders") (EVar "rest")) (EVar "out")))))
(DTypeSig true "serializeResponse" (TyFun (TyCon "Response") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "serializeResponse" ((PCon "Response" (PVar "status") (PVar "reason") (PVar "headers") (PVar "body"))) (EBlock (DoLet false false (PVar "out") (EApp (EVar "newBuilder") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "HTTP/1.1 "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EApp (EVar "intToString") (EVar "status"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString " "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EVar "reason")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitResponseHeaders") (EVar "headers")) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "content-length: "))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "body")))) (EVar "out"))) (DoExpr (EApp (EApp (EVar "emitAscii") (ELit (LString "\r\n\r\n"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EVar "emitArray") (EVar "body")) (ELit (LInt 0))) (EVar "out"))) (DoExpr (EApp (EVar "buildArray") (EVar "out")))))
(DData Abstract "MediaType" () ((variant "MediaType" (ConPos (TyCon "String") (TyCon "String")))) ())
(DData Public "DecodedBody" () ((variant "JsonBody" (ConPos (TyCon "MediaType") (TyCon "Json"))) (variant "TextBody" (ConPos (TyCon "MediaType") (TyCon "String"))) (variant "RawBody" (ConPos (TyCon "MediaType") (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Public "QueryParam" () ((variant "QueryParam" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "percentNibble" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "percentNibble" ((PVar "byte")) (EApp (EVar "hexDigit") (EVar "byte")))
(DTypeSig false "decodeQueryBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "decodeQueryBytes" ((PVar "input") (PVar "pos") (PVar "end") (PVar "out")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (ELit (LInt 37))) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EVar "emitU8") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EVar "out")))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 2))) (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: malformed percent escape in query"))) (EMatch (ETuple (EApp (EVar "percentNibble") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EApp (EVar "percentNibble") (EApp (EApp (EMethodRef "index") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))))) (arm (PTuple (PCon "Some" (PVar "high")) (PCon "Some" (PVar "low"))) () (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EVar "emitU8") (EBinOp "+" (EBinOp "*" (EVar "high") (ELit (LInt 16))) (EVar "low"))) (EVar "out"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 3)))) (EVar "end")) (EVar "out"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "http: malformed percent escape in query")))))))))
(DTypeSig false "continuation" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "continuation" ((PVar "byte")) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 128))) (EBinOp "<=" (EVar "byte") (ELit (LInt 191)))))
(DTypeSig false "utf8Step" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8Step" ((PVar "bytes") (PVar "i")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "arrayLength") (EVar "bytes"))) (DoLet false false (PVar "b0") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i"))) (DoExpr (EIf (EBinOp "<=" (EVar "b0") (ELit (LInt 127))) (EApp (EVar "Some") (ETuple (EVar "b0") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 194))) (EBinOp "<=" (EVar "b0") (ELit (LInt 223)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 192))) (ELit (LInt 64))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 224))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 160)))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 191)))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 225))) (EBinOp "<=" (EVar "b0") (ELit (LInt 236)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 238))) (EBinOp "<=" (EVar "b0") (ELit (LInt 239)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 237))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128)))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 159)))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 224))) (ELit (LInt 4096))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 240))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 144)))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 191)))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "b0") (ELit (LInt 241))) (EBinOp "<=" (EVar "b0") (ELit (LInt 243)))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "b0") (ELit (LInt 244))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "size"))) (EBinOp ">=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128)))) (EBinOp "<=" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 143)))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))))) (EApp (EVar "continuation") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))))) (EApp (EVar "Some") (ETuple (EBinOp "-" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "b0") (ELit (LInt 240))) (ELit (LInt 262144))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 128))) (ELit (LInt 4096)))) (EBinOp "*" (EBinOp "-" (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 128))) (ELit (LInt 64)))) (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3))))) (ELit (LInt 128))) (EBinOp "+" (EVar "i") (ELit (LInt 4))))) (EVar "None")))))))))))))
(DTypeSig false "validUtf8From" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validUtf8From" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EMatch (EApp (EApp (EVar "utf8Step") (EVar "bytes")) (EVar "i")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "next"))) () (EApp (EApp (EVar "validUtf8From") (EVar "bytes")) (EVar "next"))))))
(DTypeSig false "validQueryTextFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validQueryTextFrom" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EMatch (EApp (EApp (EVar "utf8Step") (EVar "bytes")) (EVar "i")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "code") (PVar "next"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "code") (ELit (LInt 31))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">=" (EVar "code") (ELit (LInt 127))) (EBinOp "<=" (EVar "code") (ELit (LInt 159)))))) (EApp (EApp (EVar "validQueryTextFrom") (EVar "bytes")) (EVar "next")))))))
(DTypeSig false "decodeQueryPart" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "decodeQueryPart" ((PVar "input") (PVar "start") (PVar "end")) (ELet false (PVar "out") (EApp (EVar "newBuilder") (ELit LUnit)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decodeQueryBytes") (EVar "input")) (EVar "start")) (EVar "end")) (EVar "out"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "decoded") (EApp (EVar "buildArray") (EVar "out")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validQueryTextFrom") (EVar "decoded")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: query component is invalid UTF-8 or contains a control character"))) (EApp (EVar "Ok") (EApp (EVar "fromUtf8") (EVar "decoded")))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "parseQueryFields" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "QueryParam")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "QueryParam")))))))
(DFunDef false "parseQueryFields" ((PVar "input") (PVar "start") (PVar "acc")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "input"))) (DoExpr (EIf (EBinOp ">=" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))) (EBlock (DoLet false false (PVar "amp") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "end")) (ELit (LInt 38))) (arm (PCon "None") () (EVar "end")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoLet false false (PVar "equals") (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "input")) (EVar "start")) (EVar "amp")) (ELit (LInt 61))) (arm (PCon "None") () (EVar "amp")) (arm (PCon "Some" (PVar "pos")) () (EVar "pos")))) (DoExpr (EIf (EBinOp "==" (EVar "equals") (EVar "start")) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decodeQueryPart") (EVar "input")) (EVar "start")) (EVar "equals"))) (ELam ((PVar "name")) (EIf (EBinOp "==" (EVar "name") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EMethodRef "andThen") (EIf (EBinOp "==" (EVar "equals") (EVar "amp")) (EApp (EVar "Ok") (ELit (LString ""))) (EApp (EApp (EApp (EVar "decodeQueryPart") (EVar "input")) (EBinOp "+" (EVar "equals") (ELit (LInt 1)))) (EVar "amp")))) (ELam ((PVar "value")) (ELet false (PVar "next") (EIf (EBinOp "==" (EVar "amp") (EVar "end")) (EVar "end") (EBinOp "+" (EVar "amp") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "next") (EVar "end")) (EBinOp "<" (EVar "amp") (EVar "end"))) (EApp (EVar "Err") (ELit (LString "http: empty query parameter name"))) (EApp (EApp (EApp (EVar "parseQueryFields") (EVar "input")) (EVar "next")) (EBinOp "::" (EApp (EApp (EVar "QueryParam") (EVar "name")) (EVar "value")) (EVar "acc")))))))))))))))))
(DTypeSig true "parseTargetQuery" (TyFun (TyCon "Request") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "QueryParam"))))))
(DFunDef false "parseTargetQuery" ((PCon "Request" PWild (PVar "target") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "bytes") (EApp (EVar "toUtf8") (EVar "target"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LInt 35))) (arm (PCon "Some" PWild) () (EApp (EVar "Err") (ELit (LString "http: fragment is forbidden in request target")))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "findByte") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LInt 63))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "target") (EListLit)))) (arm (PCon "Some" (PVar "queryAt")) () (ELet false (PVar "path") (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EMethodRef "slice") (EVar "bytes")) (ELit (LInt 0))) (EVar "queryAt"))) (EIf (EBinOp "==" (EBinOp "+" (EVar "queryAt") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EApp (EVar "Ok") (ETuple (EVar "path") (EListLit))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseQueryFields") (EVar "bytes")) (EBinOp "+" (EVar "queryAt") (ELit (LInt 1)))) (EListLit))) (ELam ((PVar "params")) (EApp (EVar "Ok") (ETuple (EVar "path") (EVar "params"))))))))))))))
(DTypeSig true "mediaTypeType" (TyFun (TyCon "MediaType") (TyCon "String")))
(DFunDef false "mediaTypeType" ((PCon "MediaType" (PVar "kind") PWild)) (EVar "kind"))
(DTypeSig true "mediaTypeSubtype" (TyFun (TyCon "MediaType") (TyCon "String")))
(DFunDef false "mediaTypeSubtype" ((PCon "MediaType" PWild (PVar "subtype"))) (EVar "subtype"))
(DTypeSig false "validMediaBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "validMediaBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True") (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i"))) (DoExpr (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "byte") (ELit (LInt 9))) (EBinOp "&&" (EBinOp ">=" (EVar "byte") (ELit (LInt 32))) (EBinOp "<=" (EVar "byte") (ELit (LInt 126))))) (EApp (EApp (EVar "validMediaBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig false "scanMediaQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "scanMediaQuoted" ((PVar "value") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: unterminated quoted media-type parameter"))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 34))) (EApp (EVar "Ok") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 92))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EBinOp "+" (EVar "pos") (ELit (LInt 1))) (EVar "end")) (EBinOp "<" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 32)))) (EBinOp ">" (EApp (EApp (EMethodRef "index") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (ELit (LInt 126)))) (EApp (EVar "Err") (ELit (LString "http: invalid quoted media-type parameter"))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 2)))) (EVar "end"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 32))) (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "pos")) (ELit (LInt 127)))) (EApp (EVar "Err") (ELit (LString "http: control byte in media-type parameter"))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))))))
(DTypeSig false "parseMediaParameters" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "parseMediaParameters" ((PVar "value") (PVar "pos") (PVar "end") (PVar "count")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EVar "pos")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "start") (EVar "end")) (EApp (EVar "Ok") (ELit LUnit)) (EIf (EBinOp ">=" (EDictApp "count") (ELit (LInt 32))) (EApp (EVar "Err") (ELit (LString "http: media type has too many parameters"))) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "start")) (ELit (LInt 59))) (EApp (EVar "Err") (ELit (LString "http: invalid media-type parameter separator"))) (EBlock (DoLet false false (PVar "nameStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EVar "end"))) (DoLet false false (PVar "nameEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "nameStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "nameEnd") (EVar "nameStart")) (EApp (EVar "Err") (ELit (LString "http: empty media-type parameter name"))) (EBlock (DoLet false false (PVar "afterName") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EVar "nameEnd")) (EVar "end"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "afterName") (EVar "end")) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "afterName")) (ELit (LInt 61)))) (EApp (EVar "Err") (ELit (LString "http: media-type parameter requires a value"))) (EBlock (DoLet false false (PVar "valueStart") (EApp (EApp (EApp (EVar "skipOws") (EVar "value")) (EBinOp "+" (EVar "afterName") (ELit (LInt 1)))) (EVar "end"))) (DoExpr (EIf (EBinOp ">=" (EVar "valueStart") (EVar "end")) (EApp (EVar "Err") (ELit (LString "http: media-type parameter requires a value"))) (EApp (EApp (EMethodRef "andThen") (EIf (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "valueStart")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "scanMediaQuoted") (EVar "value")) (EBinOp "+" (EVar "valueStart") (ELit (LInt 1)))) (EVar "end")) (EBlock (DoLet false false (PVar "tokenEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "valueStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "tokenEnd") (EVar "valueStart")) (EApp (EVar "Err") (ELit (LString "http: invalid media-type parameter value"))) (EApp (EVar "Ok") (EVar "tokenEnd"))))))) (ELam ((PVar "valueEnd")) (EApp (EApp (EApp (EApp (EVar "parseMediaParameters") (EVar "value")) (EVar "valueEnd")) (EVar "end")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1)))))))))))))))))))))
(DTypeSig true "parseMediaType" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "MediaType"))))
(DFunDef false "parseMediaType" ((PVar "value")) (EBlock (DoLet false false (PVar "end") (EApp (EVar "arrayLength") (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "end") (ELit (LInt 0))) (EBinOp ">" (EVar "end") (ELit (LInt 4096)))) (EApp (EVar "Err") (ELit (LString "http: media type exceeds its 4096-byte resource limit"))) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EApp (EVar "validBytes") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (EApp (EVar "not") (EApp (EApp (EVar "validMediaBytes") (EVar "value")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "http: media type must be bounded ASCII"))) (EBlock (DoLet false false (PVar "typeEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (ELit (LInt 0))) (EVar "end"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "typeEnd") (ELit (LInt 0))) (EBinOp ">=" (EVar "typeEnd") (EVar "end"))) (EBinOp "/=" (EApp (EApp (EMethodRef "index") (EVar "value")) (EVar "typeEnd")) (ELit (LInt 47)))) (EApp (EVar "Err") (ELit (LString "http: invalid media type"))) (EBlock (DoLet false false (PVar "subtypeStart") (EBinOp "+" (EVar "typeEnd") (ELit (LInt 1)))) (DoLet false false (PVar "subtypeEnd") (EApp (EApp (EApp (EVar "scanTokenEnd") (EVar "value")) (EVar "subtypeStart")) (EVar "end"))) (DoExpr (EIf (EBinOp "==" (EVar "subtypeEnd") (EVar "subtypeStart")) (EApp (EVar "Err") (ELit (LString "http: invalid media subtype"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "parseMediaParameters") (EVar "value")) (EVar "subtypeEnd")) (EVar "end")) (ELit (LInt 0)))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EApp (EApp (EVar "MediaType") (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (ELit (LInt 0))) (EVar "typeEnd"))) (EApp (EApp (EApp (EVar "lowerAscii") (EVar "value")) (EVar "subtypeStart")) (EVar "subtypeEnd"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))))))
(DTypeSig false "contentType" (TyFun (TyApp (TyCon "List") (TyCon "Header")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "MediaType"))))
(DFunDef false "contentType" ((PVar "headers")) (EBlock (DoLet false false (PVar "count") (EApp (EApp (EVar "countNamed") (ELit (LString "content-type"))) (EVar "headers"))) (DoExpr (EIf (EBinOp "==" (EDictApp "count") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "http: request body requires Content-Type"))) (EIf (EBinOp ">" (EDictApp "count") (ELit (LInt 1))) (EApp (EVar "Err") (ELit (LString "http: duplicate Content-Type"))) (EMatch (EApp (EApp (EVar "findNamed") (ELit (LString "content-type"))) (EVar "headers")) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "http: request body requires Content-Type")))) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "parseMediaType") (EVar "value")))))))))
(DTypeSig true "decodeRequestBody" (TyFun (TyCon "Request") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "DecodedBody"))))
(DFunDef false "decodeRequestBody" ((PCon "Request" PWild PWild (PVar "headers") PWild (PVar "packed") PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "contentType") (EVar "headers"))) (ELam ((PVar "mediaType")) (ELet false (PVar "size") (EApp (EVar "bytesLength") (EVar "packed")) (EMatch (EVar "mediaType") (arm (PCon "MediaType" (PLit (LString "application")) (PLit (LString "json"))) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "checkJsonBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "body") (EApp (EVar "toArray") (EVar "packed")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validUtf8From") (EVar "body")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: JSON body is not valid UTF-8"))) (EMatch (EApp (EVar "parse") (EApp (EVar "fromUtf8") (EVar "body"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "http: invalid JSON body: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "value")) () (EApp (EVar "Ok") (EApp (EApp (EVar "JsonBody") (EVar "mediaType")) (EVar "value")))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm (PCon "MediaType" (PLit (LString "text")) PWild) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "checkTextBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (ELet false (PVar "body") (EApp (EVar "toArray") (EVar "packed")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "validUtf8From") (EVar "body")) (ELit (LInt 0)))) (EApp (EVar "Err") (ELit (LString "http: text body is not valid UTF-8"))) (EApp (EVar "Ok") (EApp (EApp (EVar "TextBody") (EVar "mediaType")) (EApp (EVar "fromUtf8") (EVar "body"))))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (arm PWild () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "checkRawBodyBytes") (EVar "size"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PLit LUnit) () (EApp (EVar "Ok") (EApp (EApp (EVar "RawBody") (EVar "mediaType")) (EApp (EVar "toArray") (EVar "packed"))))) (arm PWild () (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
