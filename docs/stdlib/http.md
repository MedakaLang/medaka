# http

Pure, bounded HTTP/1.1 request framing and response building.

The parser accepts exactly one complete origin-form HTTP/1.1 request. It
preserves field order and duplicates until framing has been validated,
keeps bodies as raw bytes, and exposes connection lifetime as plain data.
No socket, filesystem, or other effect is involved, so a caller supplies
the bytes and decides what to do with the frame. `net` is the socket
layer.

Every ceiling the framer enforces is an exported `max*` value paired with
a `check*` predicate, so a caller can test either side of a boundary
without building a maximum-sized request.

## Resource limits

### `maxHttpRequestBytes`

```
maxHttpRequestBytes : Int
```

The ceiling on one raw request, request line and framing bytes included.

```medaka
> maxHttpRequestBytes
6291456
```

### `maxHttpHeaderBytes`

```
maxHttpHeaderBytes : Int
```

The ceiling on the combined header and trailer sections of one request or
response.

### `maxHttpBodyBytes`

```
maxHttpBodyBytes : Int
```

The ceiling on one decoded body, after chunked transfer coding is removed.

### `maxHttpRequestLineBytes`

```
maxHttpRequestLineBytes : Int
```

The ceiling on one request line.

### `maxHttpResponseStatusLineBytes`

```
maxHttpResponseStatusLineBytes : Int
```

The ceiling on one response status line.

### `maxHttpResponseChunkBytes`

```
maxHttpResponseChunkBytes : Int
```

The ceiling on one response chunk's declared size.

### `maxHttpHeaderFields`

```
maxHttpHeaderFields : Int
```

The ceiling on the number of header fields in one request or response.

### `maxHttpTrailerFields`

```
maxHttpTrailerFields : Int
```

The ceiling on the number of trailer fields in one request.

### `maxHttpChunks`

```
maxHttpChunks : Int
```

The ceiling on the number of chunks in one chunked body.

### `maxJsonBodyBytes`

```
maxJsonBodyBytes : Int
```

The ceiling on a body decoded as JSON by `decodeRequestBody`.

### `maxTextBodyBytes`

```
maxTextBodyBytes : Int
```

The ceiling on a body decoded as text by `decodeRequestBody`.

### `maxRawBodyBytes`

```
maxRawBodyBytes : Int
```

The ceiling on a body kept as raw bytes by `decodeRequestBody`.

### `checkHttpRequestBytes`

```
checkHttpRequestBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpRequestBytes`, `Err` with the
diagnostic the framer reports otherwise.

```medaka
> isOk (checkHttpRequestBytes maxHttpRequestBytes)
True
```

### `checkHttpHeaderBytes`

```
checkHttpHeaderBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpHeaderBytes`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpBodyBytes`

```
checkHttpBodyBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpBodyBytes`, `Err` with the diagnostic
the framer reports otherwise.

### `checkHttpRequestLineBytes`

```
checkHttpRequestLineBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpRequestLineBytes`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpResponseStatusLineBytes`

```
checkHttpResponseStatusLineBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpResponseStatusLineBytes`.

### `checkHttpResponseChunkBytes`

```
checkHttpResponseChunkBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxHttpResponseChunkBytes`.

### `checkHttpHeaderFields`

```
checkHttpHeaderFields : Int -> Result String Unit
```

`Ok` when `count` is within `maxHttpHeaderFields`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpTrailerFields`

```
checkHttpTrailerFields : Int -> Result String Unit
```

`Ok` when `count` is within `maxHttpTrailerFields`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpChunks`

```
checkHttpChunks : Int -> Result String Unit
```

`Ok` when `count` is within `maxHttpChunks`, `Err` with the diagnostic
the framer reports otherwise.

### `checkJsonBodyBytes`

```
checkJsonBodyBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxJsonBodyBytes`, `Err` with the diagnostic
`decodeRequestBody` reports otherwise.

```medaka
> isErr (checkJsonBodyBytes (maxJsonBodyBytes + 1))
True
```

### `checkTextBodyBytes`

```
checkTextBodyBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxTextBodyBytes`, `Err` with the diagnostic
`decodeRequestBody` reports otherwise.

### `checkRawBodyBytes`

```
checkRawBodyBytes : Int -> Result String Unit
```

`Ok` when `size` is within `maxRawBodyBytes`, `Err` with the diagnostic
`decodeRequestBody` reports otherwise.

## Requests

### `Header`

```
data Header
  = Header String (Array Int)
```

An ordered HTTP field. Names are canonical lowercase ASCII; values are
raw bytes with surrounding optional whitespace removed.

### `Request`

```
data Request
  = Request String String (List Header) (List Header) Bytes Bool
```

A fully framed HTTP/1.1 request. Constructors stay private so callers
cannot manufacture a request that bypassed framing checks.

### `HttpParseFailure`

```
data HttpParseFailure
  = HttpMalformed String
  | HttpResourceExcess String
```

Structural classification for request-framing failures. The diagnostic is
retained for direct parser callers, while the server can select 400 versus
413 without inspecting diagnostic text.

### `httpParseFailureMessage`

```
httpParseFailureMessage : HttpParseFailure -> String
```

The diagnostic a framing failure carries, whichever class it is.

### `headerName`

```
headerName : Header -> String
```

The field's canonical lowercase ASCII name.

### `headerValue`

```
headerValue : Header -> Array Int
```

The field's raw value bytes, with surrounding optional whitespace
already removed. The result is a copy, so mutating it cannot reach the
header.

### `requestMethod`

```
requestMethod : Request -> String
```

The request method token, exactly as it was received.

### `requestTarget`

```
requestTarget : Request -> String
```

The origin-form request target, still percent-encoded. `parseTargetQuery`
splits and decodes it.

### `requestHeaders`

```
requestHeaders : Request -> List Header
```

The header fields in received order, duplicates retained.

### `requestTrailers`

```
requestTrailers : Request -> List Header
```

The trailer fields in received order, empty for a request that was not
chunked.

### `requestBody`

```
requestBody : Request -> Bytes
```

The decoded body bytes, with any chunked transfer coding removed. The
stored body is already a private copy that framing cut out of the input
(`bytes.slice` copies), and nothing else holds it, so this hands it out
rather than copying again; a caller wanting an `Array Int` writes
`toArray` and pays for the unpacking where it asked for it.

### `requestBodyLength`

```
requestBodyLength : Request -> Int
```

Length of the framed body without copying its attacker-controlled bytes.

### `requestKeepAlive`

```
requestKeepAlive : Request -> Bool
```

Whether the connection stays open after this request, as its Connection
field settled it.

### `isTokenByte`

```
isTokenByte : Int -> Bool
```

Whether `byte` is one of HTTP's ASCII token bytes.

### `findByte`

```
findByte : Array Int -> Int -> Int -> Int -> Option Int
```

Find `wanted` in the half-open range `value[pos, end)`. No element at or
beyond `end` is inspected.

### `trimLeftOws`

```
trimLeftOws : Array Int -> Int -> Int -> Int
```

Skip optional whitespace in the half-open range `value[pos, end)`.

### `trimRightOws`

```
trimRightOws : Array Int -> Int -> Int -> Int
```

Trim optional whitespace from the right edge of `value[start, end)`.

### `parseFields`

```
parseFields : Bytes -> Int -> Bool -> Result HttpParseFailure (List Header, Int)
```

Parse a complete header or trailer section beginning at `pos`. Fields
retain their received order and duplicates, names are lowercased, and
surrounding optional whitespace is removed from values. When `trailer` is
`True`, framing and routing fields forbidden in trailers are rejected.
The returned offset is just past the section's empty-line CRLF.

### `hexDigit`

```
hexDigit : Int -> Option Int
```

Decode one ASCII hexadecimal digit.

### `skipOws`

```
skipOws : Array Int -> Int -> Int -> Int
```

Skip optional whitespace in the half-open range `value[pos, end)`.

### `parseChunked`

```
parseChunked : Bytes -> Int -> Result HttpParseFailure (Bytes, List Header, Int)
```

Decode one complete chunked body beginning at `pos`. The result contains
the decoded bytes, retained trailer fields, and the offset just past the
terminating trailer section. Per-chunk, decoded-body, chunk-count, trailer,
and framing ceilings are enforced before the result is returned.

### `parseRequestClassified`

```
parseRequestClassified : Bytes -> Result HttpParseFailure Request
```

Parse one complete request while preserving structural failure class.

## Incremental framing

### `HttpFrame`

```
data HttpFrame
  = HttpNeedMore
  | HttpFramedAt Int
  | HttpFrameFailed HttpParseFailure
```

Where a scan over a byte buffer stopped. `HttpNeedMore` is the one verdict
more bytes can change; `HttpFramedAt` reports the index one past the last
byte of the framed request, which is where the next one begins.

### `HttpScan`

```
data HttpScan
  = HttpScan ScanPhase
```

How far a scan of a growing buffer has already got. The type is opaque:
a caller obtains one from `httpScanStart`, hands it back to
`scanRequestBoundaryFrom` with the same request `start` and a buffer that has
only grown at its end, and gets a fresh one to carry to the next read.

A state is only meaningful for the buffer prefix it was produced from. Any
other buffer, or a different `start`, needs `httpScanStart` again, which is
what a caller does at a request boundary, since the next request is a new
scan. Nothing is lost by starting over: a fresh state reaches exactly the
verdict a resumed one does.

### `httpScanStart`

```
httpScanStart : HttpScan
```

A scan that has read nothing.

### `httpScanInHeaders`

```
httpScanInHeaders : HttpScan -> Bool
```

Whether a scan that has not yet framed a request is still inside the
request line or the header fields, meaning the request's header section has
not been terminated. Only this module can answer it, the scan's phase being
private, so a caller that budgets the header phase apart from the body has
no other way to tell the two apart. A scan that already framed a request
reports False: its header section ended.

### `httpScanBodyRemaining`

```
httpScanBodyRemaining : HttpScan -> Int -> Option Int
```

How many further bytes this scan needs before the request it is framing is
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
able to disagree with this one.

### `scanRequestBoundaryWithin`

```
scanRequestBoundaryWithin : Bytes -> Int -> Int -> HttpScan -> (HttpFrame, HttpScan)
```

Find the end of the first complete request at or after `start` in the first
`avail` bytes of `input`, resuming the scan `state` left off at. Bytes of
`input` at or past `avail` are not input: they are whatever a caller's
backing array holds beyond what it has received, so no framing decision may
read them. A buffer whose pending bytes already exceed the per-request
ceiling is rejected rather than left pending, so a caller can bound what it
buffers.

The cost of a resumed scan is proportional to the bytes that arrived since
the state was produced, not to the bytes already buffered, because every
suspension point is one only later bytes can move past.

### `scanRequestBoundaryFrom`

```
scanRequestBoundaryFrom : Bytes -> Int -> HttpScan -> (HttpFrame, HttpScan)
```

Scan a buffer whose every byte is received input. This is
`scanRequestBoundaryWithin` at the buffer's full length, so a caller that
keeps no spare capacity needs to know nothing about the distinction.

### `scanRequestBoundary`

```
scanRequestBoundary : Bytes -> Int -> HttpFrame
```

Find the end of the first complete request at or after `start` without a
prior scan. This is `scanRequestBoundaryFrom` from `httpScanStart`, so a
whole-buffer scan and a resumed one cannot be two different framers.

### `parseRequestAt`

```
parseRequestAt : Bytes -> Int -> Int -> Result HttpParseFailure Request
```

Parse the frame `[start, end)` exactly as `parseRequestClassified` parses
that region on its own, so a scanned boundary and a parse cannot disagree.

### `parseRequest`

```
parseRequest : Bytes -> Result String Request
```

Parse one complete request, reporting a failure as its diagnostic alone.
`parseRequestClassified` keeps the structural class a caller needs to
choose 400 against 413.

## Response parsing

### `ParsedResponse`

```
data ParsedResponse
  = ParsedResponse Int String (List Header) (List Header) (Array Int)
```

A parsed HTTP/1.0 or HTTP/1.1 response. Fields and trailers retain their
received order and duplicates; the body has any chunked transfer coding
removed. The constructor is private so every value has passed the framing
and resource checks below.

### `parsedResponseStatus`

```
parsedResponseStatus : ParsedResponse -> Int
```

The parsed response's status code.

### `parsedResponseReason`

```
parsedResponseReason : ParsedResponse -> String
```

The parsed response's reason phrase, exactly as received.

### `parsedResponseHeaders`

```
parsedResponseHeaders : ParsedResponse -> List Header
```

The parsed response fields in received order, duplicates retained.

### `parsedResponseTrailers`

```
parsedResponseTrailers : ParsedResponse -> List Header
```

Parsed trailer fields in received order, or an empty list for a body
without chunked transfer coding.

### `parsedResponseBody`

```
parsedResponseBody : ParsedResponse -> Array Int
```

The decoded response body, with chunk framing removed.

### `parsedResponseBodyLength`

```
parsedResponseBodyLength : ParsedResponse -> Int
```

The decoded response body's length without copying it.

### `parseResponseClassified`

```
parseResponseClassified : Array Int -> Result HttpParseFailure ParsedResponse
```

Parse one complete HTTP response with structural failure classification.
Status lines, fields, chunks, decoded bodies, and trailers are bounded.
Transfer-coding tokens are compared as ASCII case-insensitively. A response
without a declared length is close-delimited unless its status forbids a
body.

### `parseResponse`

```
parseResponse : Array Int -> Result String ParsedResponse
```

`parseResponseClassified` with its structural class collapsed to the
diagnostic string.

```medaka
> isErr (parseResponse [||])
True
```

### `responseBoundaryWithin`

```
responseBoundaryWithin : Array Int -> Int -> Option Int
```

The offset just past the first response framed by `input[0, avail)`, or
`None` when that prefix is incomplete, malformed, or close-delimited.
Bytes at or beyond `avail` are never inspected. A returned boundary may be
less than `avail` when another message follows it.

### `responseBoundary`

```
responseBoundary : Array Int -> Option Int
```

`responseBoundaryWithin` over all bytes in `input`.

## Response building

### `Response`

```
data Response
  = Response Int String (List Header) (Array Int)
```

A buffered HTTP response. The constructor is private: responses can only
be obtained through `makeResponse`, after their status line and fields have
been checked for response splitting and reserved framing fields.

### `makeHeader`

```
makeHeader : String -> Array Int -> Result String Header
```

Construct a safe response field. Names are canonicalized to lowercase;
values must be printable ASCII and therefore cannot contain CR, LF, or any
other control byte.

### `makeResponse`

```
makeResponse : Int -> String -> List Header -> Array Int -> Result String Response
```

Construct a deterministic buffered response. The serializer owns all
framing, so callers cannot supply Content-Length or Transfer-Encoding.

### `responseStatus`

```
responseStatus : Response -> Int
```

The response status code.

### `responseHeaders`

```
responseHeaders : Response -> List Header
```

The caller's response fields in the order they were supplied. The
computed Content-Length is added by `serializeResponse` and is not among
them.

### `responseBody`

```
responseBody : Response -> Array Int
```

The response body bytes.

### `responseReason`

```
responseReason : Response -> String
```

The response reason phrase, exactly as constructed.

### `serializeResponse`

```
serializeResponse : Response -> Array Int
```

Serialize a complete HTTP/1.1 response. Caller fields remain in their
original order and exactly one computed Content-Length follows them.

## Targets, media types, and bodies

### `MediaType`

```
data MediaType
  = MediaType String String
```

A parsed, canonical media type, holding only the lowercased type and
subtype. `parseMediaType` validates any parameters but does not retain
them.

### `DecodedBody`

```
data DecodedBody
  = JsonBody MediaType Json
  | TextBody MediaType String
  | RawBody MediaType (Array Int)
```

A request body decoded according to its media type. JSON and text are
strictly UTF-8; every other media type keeps its raw bytes.

### `QueryParam`

```
data QueryParam
  = QueryParam String String
```

One decoded query parameter: its name and its value, empty when the
query gave it none.

### `parseTargetQuery`

```
parseTargetQuery : Request -> Result String (String, List QueryParam)
```

Split and decode the validated origin target. Ordered duplicates and
empty values are retained; `+` is ordinary URI data and remains literal.

### `mediaTypeType`

```
mediaTypeType : MediaType -> String
```

The lowercased type, such as `"text"` for `text/plain`.

### `mediaTypeSubtype`

```
mediaTypeSubtype : MediaType -> String
```

The lowercased subtype, such as `"plain"` for `text/plain`.

### `parseMediaType`

```
parseMediaType : Array Int -> Result String MediaType
```

Parse a bounded ASCII media type. Type and subtype matching is
case-insensitive and returned in canonical lowercase form.

### `decodeRequestBody`

```
decodeRequestBody : Request -> Result String DecodedBody
```

Decode a framed request body according to its supplied media type. JSON
and text are strictly UTF-8 and have narrower endpoint limits; all other
valid media types retain their raw bytes.

