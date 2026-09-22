# http

HTTP/1.1 message framing: request parsing, response building, and
response parsing, over bytes the caller supplies.

Nothing here touches a socket or a file. `net` is the socket layer; this
module turns the bytes it read into a `Request`, and a `Response` into
the bytes to write. There is no client: the module opens no connection
and speaks no TLS.

A request must be a complete HTTP/1.1 message with an origin-form
target. Header fields keep their received order and duplicates, bodies
stay raw bytes with any chunked coding removed, and whether the
connection stays open is reported as a `Bool`.

Every size and count the framer bounds is an exported `max*` value with
a matching `check*` predicate, so a caller can test a limit without
building a request that reaches it.

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
checkHttpRequestBytes size
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
checkHttpHeaderBytes size
```

`Ok` when `size` is within `maxHttpHeaderBytes`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpBodyBytes`

```
checkHttpBodyBytes : Int -> Result String Unit
checkHttpBodyBytes size
```

`Ok` when `size` is within `maxHttpBodyBytes`, `Err` with the diagnostic
the framer reports otherwise.

### `checkHttpRequestLineBytes`

```
checkHttpRequestLineBytes : Int -> Result String Unit
checkHttpRequestLineBytes size
```

`Ok` when `size` is within `maxHttpRequestLineBytes`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpResponseStatusLineBytes`

```
checkHttpResponseStatusLineBytes : Int -> Result String Unit
checkHttpResponseStatusLineBytes size
```

`Ok` when `size` is within `maxHttpResponseStatusLineBytes`, `Err` with
the diagnostic the framer reports otherwise.

### `checkHttpResponseChunkBytes`

```
checkHttpResponseChunkBytes : Int -> Result String Unit
checkHttpResponseChunkBytes size
```

`Ok` when `size` is within `maxHttpResponseChunkBytes`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpHeaderFields`

```
checkHttpHeaderFields : Int -> Result String Unit
checkHttpHeaderFields count
```

`Ok` when `count` is within `maxHttpHeaderFields`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpTrailerFields`

```
checkHttpTrailerFields : Int -> Result String Unit
checkHttpTrailerFields count
```

`Ok` when `count` is within `maxHttpTrailerFields`, `Err` with the
diagnostic the framer reports otherwise.

### `checkHttpChunks`

```
checkHttpChunks : Int -> Result String Unit
checkHttpChunks count
```

`Ok` when `count` is within `maxHttpChunks`, `Err` with the diagnostic
the framer reports otherwise.

### `checkJsonBodyBytes`

```
checkJsonBodyBytes : Int -> Result String Unit
checkJsonBodyBytes size
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
checkTextBodyBytes size
```

`Ok` when `size` is within `maxTextBodyBytes`, `Err` with the diagnostic
`decodeRequestBody` reports otherwise.

### `checkRawBodyBytes`

```
checkRawBodyBytes : Int -> Result String Unit
checkRawBodyBytes size
```

`Ok` when `size` is within `maxRawBodyBytes`, `Err` with the diagnostic
`decodeRequestBody` reports otherwise.

## Requests

### `Header`

```
data Header  -- abstract: the constructors are not exported
```

One header or trailer field: a name and a value. The name is lowercase
ASCII; the value is raw bytes with surrounding whitespace removed.

### `Request`

```
data Request  -- abstract: the constructors are not exported
```

A framed HTTP/1.1 request. Values come only from the parsers in this
module; the `request*` accessors read its parts.

### `HttpParseFailure`

```
data HttpParseFailure
  = HttpMalformed String
  | HttpResourceExcess String
```

Why framing failed. `HttpMalformed` is a message the grammar rejects;
`HttpResourceExcess` is one that exceeds a `max*` ceiling. A server answers
the first with 400 and the second with 413. Both carry the diagnostic.

### `httpParseFailureMessage`

```
httpParseFailureMessage : HttpParseFailure -> String
```

The diagnostic a framing failure carries, whichever class it is.

### `headerName`

```
headerName : Header -> String
```

The field's name, in lowercase ASCII.

### `headerValue`

```
headerValue : Header -> Array Int
```

The field's value bytes, with surrounding whitespace removed. The result
is a copy.

### `requestMethod`

```
requestMethod : Request -> String
```

The request method token, exactly as it was received.

### `requestTarget`

```
requestTarget : Request -> String
```

The request target, still percent-encoded. `parseTargetQuery` splits and
decodes it.

### `requestHeaders`

```
requestHeaders : Request -> List Header
```

The header fields in received order, duplicates retained.

### `requestTrailers`

```
requestTrailers : Request -> List Header
```

The trailer fields in received order, empty for a request whose body was
not chunked.

### `requestBody`

```
requestBody : Request -> Bytes
```

The body, with any chunked transfer coding removed. Empty for a request
without a body.

### `requestBodyLength`

```
requestBodyLength : Request -> Int
```

The byte length of the decoded body.

### `requestKeepAlive`

```
requestKeepAlive : Request -> Bool
```

Whether the connection stays open after this request. `False` when a
`Connection` field lists `"close"`, otherwise `True`.

### `isTokenByte`

```
isTokenByte : Int -> Bool
isTokenByte byte
```

Whether `byte` is one of the ASCII bytes HTTP allows in a token, such as
a method or a field name.

### `findByte`

```
findByte : Array Int -> Int -> Int -> Int -> Option Int
findByte value pos end wanted
```

The index of the first `wanted` in `value[pos, end)`, or `None`. No
element at or past `end` is read.

### `trimLeftOws`

```
trimLeftOws : Array Int -> Int -> Int -> Int
trimLeftOws value pos end
```

The index of the first byte in `value[pos, end)` that is not a space or
a tab, or `end` when they all are.

### `trimRightOws`

```
trimRightOws : Array Int -> Int -> Int -> Int
trimRightOws value start end
```

The index one past the last byte in `value[start, end)` that is not a
space or a tab, or `start` when they all are.

### `parseFields`

```
parseFields : Bytes -> Int -> Bool -> Result HttpParseFailure (List Header, Int)
parseFields input pos trailer
```

The fields of the header or trailer section starting at `pos`, and the
offset just past the blank line that ends it.

Names are lowercased, values lose their surrounding whitespace, and order
and duplicates are kept. When `trailer` is `True`, the fields that may
not appear in a trailer (`Content-Length`, `Transfer-Encoding`,
`Trailer`, `Host`, `Connection`) are rejected.

### `hexDigit`

```
hexDigit : Int -> Option Int
hexDigit byte
```

The value of one ASCII hexadecimal digit, or `None` when `byte` is not
one. Both letter cases are accepted.

### `skipOws`

```
skipOws : Array Int -> Int -> Int -> Int
skipOws value pos end
```

The index of the first byte in `value[pos, end)` that is not a space or
a tab, or `end` when they all are. The same as `trimLeftOws`.

### `parseChunked`

```
parseChunked : Bytes -> Int -> Result HttpParseFailure (Bytes, List Header, Int)
parseChunked input pos
```

The decoded bytes of the chunked body starting at `pos`, its trailer
fields, and the offset just past the trailer section.

Chunk size, chunk count, decoded body size, trailer count, and trailer
section size are each checked against their `max*` ceiling.

### `parseRequestClassified`

```
parseRequestClassified : Bytes -> Result HttpParseFailure Request
parseRequestClassified input
```

The request framed by a buffer that holds exactly one complete request,
or the failure with its class. Bytes after the request are an error.

## Incremental framing

### `HttpFrame`

```
data HttpFrame
  = HttpNeedMore
  | HttpFramedAt Int
  | HttpFrameFailed HttpParseFailure
```

The verdict of a scan. `HttpNeedMore` means more bytes could still
complete the request. `HttpFramedAt n` means a complete request ends at
that offset, where the next one begins. `HttpFrameFailed` means no further byte
can help.

### `HttpScan`

```
data HttpScan  -- abstract: the constructors are not exported
```

The progress of a scan over a buffer that is still growing.

Begin with `httpScanStart`, pass the state to `scanRequestBoundaryFrom`
or `scanRequestBoundaryWithin` with the same `start` and a buffer that
has only grown at its end, and keep the returned state for the next read.
A state describes one buffer prefix: for a different buffer, a different
`start`, or the next request, begin again from `httpScanStart`. Starting
over reaches the same verdict as resuming; it only rescans.

### `httpScanStart`

```
httpScanStart : HttpScan
```

A scan that has read nothing.

### `httpScanInHeaders`

```
httpScanInHeaders : HttpScan -> Bool
```

Whether the scan is still inside the request line or the header fields.

`False` once the blank line ending the header section has been read,
including for a scan that has framed a whole request.

### `httpScanBodyRemaining`

```
httpScanBodyRemaining : HttpScan -> Int -> Option Int
httpScanBodyRemaining _ avail
```

How many bytes beyond the first `avail` the request still needs, or
`None` when that is not yet known.

It is known once the header section has fixed where the body ends: a
`Content-Length` body or no body at all. While the scan is still in the
header section, and for a chunked body, which declares its length one
chunk at a time, the answer is `None`.

### `scanRequestBoundaryWithin`

```
scanRequestBoundaryWithin : Bytes -> Int -> Int -> HttpScan -> (HttpFrame, HttpScan)
scanRequestBoundaryWithin input avail start _
```

The end of the first complete request at or after `start` within the
first `avail` bytes of `input`, resumed from a prior scan state, together
with the state to resume from next time.

Bytes at or past `avail` are never read, so a caller can scan a buffer
that is only partly filled. A pending request already larger than
`maxHttpRequestBytes` is reported as `HttpFrameFailed` rather than
`HttpNeedMore`. An `avail` outside the buffer, or a `start` outside
`[0, avail]`, fails as `HttpMalformed` and leaves the state unchanged.
A resumed scan costs time proportional to the bytes that arrived since the
state was produced.

### `scanRequestBoundaryFrom`

```
scanRequestBoundaryFrom : Bytes -> Int -> HttpScan -> (HttpFrame, HttpScan)
scanRequestBoundaryFrom input start scan
```

`scanRequestBoundaryWithin` over every byte of `input`.

### `scanRequestBoundary`

```
scanRequestBoundary : Bytes -> Int -> HttpFrame
scanRequestBoundary input start
```

The verdict of `scanRequestBoundaryFrom` started from `httpScanStart`,
without the state.

### `parseRequestAt`

```
parseRequestAt : Bytes -> Int -> Int -> Result HttpParseFailure Request
parseRequestAt input start end
```

The request framed by `input[start, end)`, parsed as
`parseRequestClassified` parses that slice on its own. Bounds outside the
buffer fail as `HttpMalformed`.

### `parseRequest`

```
parseRequest : Bytes -> Result String Request
parseRequest input
```

`parseRequestClassified` with the failure reduced to its diagnostic.
Use the classified form to tell a 400 from a 413.

## Response parsing

### `ParsedResponse`

```
data ParsedResponse  -- abstract: the constructors are not exported
```

A parsed HTTP/1.0 or HTTP/1.1 response.

Fields and trailers keep their received order and duplicates; the body
has any chunked transfer coding removed. Values come only from
`parseResponseClassified` and `parseResponse`.

### `parsedResponseStatus`

```
parsedResponseStatus : ParsedResponse -> Int
```

The status code.

### `parsedResponseReason`

```
parsedResponseReason : ParsedResponse -> String
```

The reason phrase, exactly as received.

### `parsedResponseHeaders`

```
parsedResponseHeaders : ParsedResponse -> List Header
```

The header fields in received order, duplicates retained.

### `parsedResponseTrailers`

```
parsedResponseTrailers : ParsedResponse -> List Header
```

The trailer fields in received order, empty for a body that was not
chunked.

### `parsedResponseBody`

```
parsedResponseBody : ParsedResponse -> Array Int
```

The body, with any chunked transfer coding removed. The result is a
copy.

### `parsedResponseBodyLength`

```
parsedResponseBodyLength : ParsedResponse -> Int
```

The byte length of the decoded body.

### `parseResponseClassified`

```
parseResponseClassified : Array Int -> Result HttpParseFailure ParsedResponse
parseResponseClassified input
```

The response framed by a buffer that holds exactly one complete
response, or the failure with its class.

The status line, fields, chunks, decoded body, and trailers are each
bounded by their `max*` ceiling. A response with neither a
`Content-Length` nor a chunked `Transfer-Encoding` runs to the end of the
buffer, unless its status code (1xx, 204, or 304) forbids a body.

### `parseResponse`

```
parseResponse : Array Int -> Result String ParsedResponse
parseResponse input
```

`parseResponseClassified` with the failure reduced to its diagnostic.

```medaka
> isErr (parseResponse [||])
True
```

### `responseBoundaryWithin`

```
responseBoundaryWithin : Array Int -> Int -> Option Int
responseBoundaryWithin input avail
```

The offset just past the first complete response in `input[0, avail)`,
or `None` when that prefix is incomplete, malformed, or a response that
ends only when the connection closes.

Bytes at or past `avail` are never read. The offset is less than `avail`
when another message follows the response.

### `responseBoundary`

```
responseBoundary : Array Int -> Option Int
responseBoundary input
```

`responseBoundaryWithin` over all bytes in `input`.

## Response building

### `Response`

```
data Response  -- abstract: the constructors are not exported
```

A response ready to serialize. Values come only from `makeResponse`,
which checks the status, the reason phrase, and the fields.

### `makeHeader`

```
makeHeader : String -> Array Int -> Result String Header
makeHeader name value
```

A response field with `name` lowercased, or `Err` when `name` is not a
token or `value` is not printable ASCII. Control bytes, CR and LF among
them, are rejected, so a field cannot split the response.

### `makeResponse`

```
makeResponse : Int -> String -> List Header -> Array Int -> Result String Response
makeResponse status reason headers body
```

A response with the given status, reason phrase, fields, and body, or
`Err` when one of them is invalid.

`status` must be from 100 to 599, `reason` printable ASCII, and every
element of `body` from 0 to 255. `headers` may not include
`Content-Length` or `Transfer-Encoding`; `serializeResponse` writes the
framing itself.

### `responseStatus`

```
responseStatus : Response -> Int
```

The status code.

### `responseHeaders`

```
responseHeaders : Response -> List Header
```

The fields given to `makeResponse`, in that order. The `Content-Length`
that `serializeResponse` adds is not among them.

### `responseBody`

```
responseBody : Response -> Array Int
```

The body bytes. The result is a copy.

### `responseReason`

```
responseReason : Response -> String
```

The reason phrase, as given to `makeResponse`.

### `serializeResponse`

```
serializeResponse : Response -> Array Int
```

The bytes of the response as an HTTP/1.1 message: the status line, the
fields in their given order, one `content-length` field, a blank line,
and the body.

## Targets, media types, and bodies

### `MediaType`

```
data MediaType  -- abstract: the constructors are not exported
```

A media type reduced to its type and subtype, both lowercased.
Parameters are checked by `parseMediaType` and then dropped.

### `DecodedBody`

```
data DecodedBody
  = JsonBody MediaType Json
  | TextBody MediaType String
  | RawBody MediaType (Array Int)
```

A request body decoded by its media type. An `application/json` body is
parsed as JSON, a `text/*` body is decoded as UTF-8 text, and every other
type keeps its bytes.

### `QueryParam`

```
data QueryParam
  = QueryParam String String
```

One query parameter: its name and its decoded value, `""` when the
query gave it none.

### `parseTargetQuery`

```
parseTargetQuery : Request -> Result String (String, List QueryParam)
```

The path and the query parameters of the request target, with percent
escapes decoded.

Parameters keep their order and duplicates, and a parameter without `=`
has the value `""`. A `+` stays a literal `+`. `Err` on a malformed
percent escape, an empty parameter name, or a component that is not
UTF-8 text.

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
parseMediaType value
```

The media type in `value`, with type and subtype lowercased, or `Err`
when it is not one. Parameters are checked for form and then dropped.
`value` must be ASCII and at most 4096 bytes.

### `decodeRequestBody`

```
decodeRequestBody : Request -> Result String DecodedBody
```

The request body decoded by its `Content-Type`.

`Err` when the field is missing or repeated, when the media type is
invalid, when the body exceeds the ceiling for its kind
(`maxJsonBodyBytes`, `maxTextBodyBytes`, or `maxRawBodyBytes`), or when a
JSON or text body is not valid UTF-8.

