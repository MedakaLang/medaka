# runtime

> These are the host primitives. They are in scope everywhere without an
> import, and their `<type><Op>` names (`stringToUpper`, `intToString`)
> mark them as the primitive layer. Prefer the library name where one
> exists (`string.toUpper`, `string.toFloat`), and reach for a name on this
> page only when no library module covers it.

The host primitives.

Every name here is an `extern` implemented by the runtime, in scope in
every program without an import. Most have a friendlier form in a
library module (`string.toUpper` over `stringToUpper`, `io.readLines`
over `readFile`); use this page when no library module covers what you
need.

An effect on a return type (`<Stdout>`, `<FileRead>`, `<Net>`,
`<IO>`) names what the primitive touches. A primitive with no effect is
pure. Mutation of a `Ref` or an array carries no effect.

## Output

### `putStr`

```
putStr : String -> <Stdout> Unit
```

Writes a string to standard output.

### `putStrLn`

```
putStrLn : String -> <Stdout> Unit
```

Writes a string and a newline to standard output.

### `ePutStr`

```
ePutStr : String -> <Stderr> Unit
```

Writes a string to standard error.

### `ePutStrLn`

```
ePutStrLn : String -> <Stderr> Unit
```

Writes a string and a newline to standard error.

### `flushStdout`

```
flushStdout : Unit -> <Stdout> Unit
```

Flushes buffered standard output.

## Input

### `readLine`

```
readLine : Unit -> <Stdin> String
```

Reads one line from standard input, without its newline.

### `readLineOpt`

```
readLineOpt : Unit -> <Stdin> Option String
```

Reads one line from standard input, or `None` at end of input.

### `readAll`

```
readAll : Unit -> <Stdin> String
```

Reads all of standard input.

### `readExactly`

```
readExactly : Int -> <Stdin> Option String
```

Reads exactly the given number of bytes from standard input, or `None`
at end of input or on a short read.

## Mutable references

### `Ref`

```
Ref : a -> Ref a
```

A new mutable cell holding a value. Read it with `!r` and write it
with `r := v`.

## Files

### `readFile`

```
readFile : (path : String) -> <FileRead path> Result String String
```

The contents of a file as a string, or `Err` with the host's message.

### `readFileBytes`

```
readFileBytes : (path : String) -> <FileRead path> Result String (Array Int)
```

The contents of a file as bytes, `0` to `255` each, or `Err` with the
host's message.

### `writeFile`

```
writeFile : (path : String) -> String -> <FileWrite path> Result String Unit
```

Writes a string to a file, replacing any existing contents.

### `writeFileBytes`

```
writeFileBytes : (path : String) -> Array Int -> <FileWrite path> Result String Unit
```

Writes bytes, `0` to `255` each, to a file, replacing any existing
contents.

### `writeFileMode`

```
writeFileMode : (path : String) -> Int -> String -> <FileWrite path> Result String Unit
```

Writes a string to a file, replacing any existing contents, and leaves
the file at exactly the permission bits the given mode names (`384` is
`rw-------`, `420` is `rw-r--r--`).

The contents never exist at a wider mode: the mode is set on the open
file before the first byte is written, so neither the process umask nor a
pre-existing file's own mode can widen the result.

### `appendFile`

```
appendFile : (path : String) -> String -> <FileWrite path> Result String Unit
```

Appends a string to a file, creating it when it does not exist.

### `fileExists`

```
fileExists : (path : String) -> <FileRead path> Bool
```

Whether a path exists.

### `fileMode`

```
fileMode : (path : String) -> <FileRead path> Result String Int
```

A path's permission bits, `0` to `4095` (`384` is `rw-------`), or
`Err` with the host's message. Symbolic links are followed.

### `canonicalizePath`

```
canonicalizePath : (path : String) -> <FileRead path> String
```

The absolute path with `.`, `..`, and symbolic links resolved. The
input, unchanged, when it cannot be resolved.

### `listDir`

```
listDir : (path : String) -> <FileRead path> Result String (List String)
```

The names of the entries in a directory.

### `makeDir`

```
makeDir : (path : String) -> <FileWrite path> Result String Unit
```

Creates a directory.

### `removeFile`

```
removeFile : (path : String) -> <FileWrite path> Result String Unit
```

Deletes a file.

### `rename`

```
rename : (src : String) -> (dst : String) -> <FileWrite src, FileWrite dst> Result String Unit
```

Moves or renames a path.

### `fsync`

```
fsync : (path : String) -> <FileWrite path> Result String Unit
```

Flushes a path's contents to durable storage. Works on a regular file or
a directory; the durability of a `rename` is a property of the containing
directory, not of either file.

### `removeDir`

```
removeDir : (path : String) -> <FileWrite path> Result String Unit
```

Removes an empty directory.

### `statFile`

```
statFile : (path : String) -> <FileRead path> Result String (Int, Bool, Bool, Float)
```

A path's size in bytes, whether it is a directory, whether it is a
regular file, and its modification time in seconds. `fs.stat` returns the
same as a record.

## Processes and environment

### `args`

```
args : Unit -> <Env> List String
```

The command-line arguments after the program name.

### `getEnv`

```
getEnv : (name : String) -> <Env name> Option String
```

The value of an environment variable, or `None` when it is unset.

### `executablePath`

```
executablePath : Unit -> <Env> String
```

The absolute path of the running executable.

### `runCommand`

```
runCommand : (program : String) -> List String -> <Exec program> Result String (Int, String, String)
```

Runs a program with arguments and waits for it. `Ok` carries the exit
code, the captured standard output, and the captured standard error; a
non-zero exit code is still `Ok`. `Err` carries the host's message when
the program could not be started.

### `exit`

```
exit : Int -> Unit
```

Ends the program with an exit code.

### `panic`

```
panic : String -> a
```

Aborts the program with a message. Panics cannot be caught.

## Networking

### `netResolve`

```
netResolve : (host : String) -> <Net host> Result String (List String)
```

The numeric addresses a host name resolves to.

### `netTcpConnect`

```
netTcpConnect : (host : String) -> Int -> <Net host> Result String Int
```

Opens a TCP connection to a host and port. The result is the
connection's descriptor.

### `netTcpListen`

```
netTcpListen : (host : String) -> Int -> <Net host> Result String Int
```

Starts listening for TCP connections on an address and port. Port `0`
picks a free port. The result is the listener's descriptor.

### `netListenPort`

```
netListenPort : Int -> <Net> Result String Int
```

The port a listener is bound to. Use it after listening on port `0`.

### `netTcpAccept`

```
netTcpAccept : Int -> <Net> Result String Int
```

Waits for the next connection on a listener. The result is the
connection's descriptor.

### `netSend`

```
netSend : Int -> Array Int -> <Net> Result String Int
```

Sends bytes on a connection. The result is the number of bytes
written, which may be fewer than given.

### `netSendFrom`

```
netSendFrom : Int -> Array Int -> Int -> <Net> Result String Int
```

Sends bytes starting at the given offset into the array. The result is the number
of bytes written, which may be fewer than given and is limited to 64 KiB per
call so a loop can retain one array while advancing through it.

### `netRecv`

```
netRecv : Int -> Int -> <Net> Result String (Array Int)
```

Receives up to the given number of bytes from a connection. An empty array means the
other side has closed.

### `netShutdown`

```
netShutdown : Int -> Int -> <Net> Result String Unit
```

Shuts down one or both directions of a connection: `0` for reading,
`1` for writing, `2` for both.

### `netClose`

```
netClose : Int -> <Net> Result String Unit
```

Closes a descriptor.

### `netSetTimeout`

```
netSetTimeout : Int -> Int -> <Net> Result String Unit
```

Sets a connection's send and receive timeout in milliseconds. `0`
means no timeout.

### `pdsSignalStart`

```
pdsSignalStart : Unit -> <Net> Result String Int
```

Installs an opt-in SIGTERM handler for a native PDS, returning a pipe
descriptor readable on shutdown. A binary that never calls this retains
the operating system's default signal behavior. Call once after bind.

### `pdsSignalRequested`

```
pdsSignalRequested : Unit -> <Net> Bool
```

Whether SIGTERM has been observed since `pdsSignalStart`. Stays true;
the descriptor remains readable. Only call from ordinary task context.

### `ioPoll`

```
ioPoll : Array Int -> Array Int -> Int -> <Net> Result String (Array Int)
```

Waits until any of the descriptors is ready, or the timeout in
milliseconds passes (`-1` waits forever). The interests are parallel to the
descriptors: bit 1 asks for readable, bit 2 for writable. The result is parallel too: bit 1 readable, bit 2 writable,
both bits on an error or hangup so a retry surfaces the error.

### `netSetNonblock`

```
netSetNonblock : Int -> Bool -> <Net> Result String Unit
```

Switches a socket's non-blocking mode on or off.

### `netTryAccept`

```
netTryAccept : Int -> <Net> Result String (Option Int)
```

`netTcpAccept` that returns `None` instead of blocking.

### `netConnectStart`

```
netConnectStart : (host : String) -> Int -> <Net host> Result String Int
```

`netTcpConnect` that returns as soon as the handshake is under way. The
result is a non-blocking descriptor that is not connected yet: wait for it
to become writable, then ask `netConnectCheck` whether it arrived. Name
resolution still blocks.

### `netConnectCheck`

```
netConnectCheck : Int -> <Net> Result String (Option Unit)
```

Whether a descriptor from `netConnectStart` has finished its handshake.
`None` means not yet, so a woken task asks again rather than trusting the
wake. `Err` is the handshake's own failure (a refused or unreachable peer)
and leaves the descriptor for the caller to close.

### `netTryRecv`

```
netTryRecv : Int -> Int -> <Net> Result String (Option (Array Int))
```

`netRecv` that returns `None` instead of blocking. `Some []` is end of
stream.

### `netTryRecvBytes`

```
netTryRecvBytes : Int -> Int -> <Net> Result String (Option ByteBlock)
```

`netTryRecv` delivering the chunk as a packed block, one byte per byte
rather than one boxed word per byte. `Some` an empty block is end of
stream. The block is allocated for this call alone and reaches the caller
with no other reference to it.

### `netTrySend`

```
netTrySend : Int -> Array Int -> <Net> Result String (Option Int)
```

`netSend` that returns `None` instead of blocking. `Some n` is the count
written, which may be short.

### `netTrySendFrom`

```
netTrySendFrom : Int -> Array Int -> Int -> <Net> Result String (Option Int)
```

`netTrySend` starting at the given offset into the array, sending at most 64 KiB
per call, so a loop over a large payload pays only for the bytes it sends.

## Time

### `wallTimeSec`

```
wallTimeSec : Unit -> <Clock> Float
```

The wall-clock time in seconds since the epoch.

### `monotonicSec`

```
monotonicSec : Unit -> <Clock> Float
```

A monotonic clock reading in seconds, for measuring intervals.

### `sleepMs`

```
sleepMs : Int -> <Clock> Unit
```

Pauses the program for a number of milliseconds.

### `allocBytes`

```
allocBytes : Unit -> <IO> Float
```

The total number of bytes the program has allocated.

## Random numbers

### `randomInt`

```
randomInt : Int -> Int -> <Rand> Int
```

A random integer between its two arguments, inclusive.

### `randomBool`

```
randomBool : Unit -> <Rand> Bool
```

A random boolean.

### `randomFloat`

```
randomFloat : Unit -> <Rand> Float
```

A random float.

### `randomChar`

```
randomChar : Unit -> <Rand> Char
```

A random character.

### `setSeed`

```
setSeed : Int -> <Rand> Unit
```

Seeds the random number generator, making the following draws
repeatable.

### `osEntropyBytes`

```
osEntropyBytes : Int -> <Rand> Array Int
```

Exactly the given number of bytes from the operating system's entropy
source.
Independent of `setSeed`. Panics for a negative length or when the source
fails.

## Hashing

### `hashInt`

```
hashInt : Int -> Int
```

The hash of an integer.

### `hashFloat`

```
hashFloat : Float -> Int
```

The hash of a float.

### `hashString`

```
hashString : String -> Int
```

The hash of a string.

### `hashChar`

```
hashChar : Char -> Int
```

The hash of a character.

### `hashBool`

```
hashBool : Bool -> Int
```

The hash of a boolean.

## Numbers

### `pi`

```
pi : Float
```

The constant π.

### `e`

```
e : Float
```

The constant e, the base of natural logarithms.

### `intMinBound`

```
intMinBound : Int
```

The smallest `Int`.

### `intMaxBound`

```
intMaxBound : Int
```

The largest `Int`.

### `charMinBound`

```
charMinBound : Char
```

The smallest `Char`, U+0000.

### `charMaxBound`

```
charMaxBound : Char
```

The largest `Char`, U+10FFFF.

### `intToFloat`

```
intToFloat : Int -> Float
```

An integer as a float.

### `floatToInt`

```
floatToInt : Float -> Int
```

A float truncated towards zero as an integer.

### `floatRem`

```
floatRem : Float -> Float -> Float
```

The remainder of `a / b` with the sign of `a`, as the `%` operator
computes it for floats.

### `bitAnd`

```
bitAnd : Int -> Int -> Int
```

Bitwise and.

### `bitOr`

```
bitOr : Int -> Int -> Int
```

Bitwise or.

### `bitXor`

```
bitXor : Int -> Int -> Int
```

Bitwise exclusive or.

### `shiftLeft`

```
shiftLeft : Int -> Int -> Int
```

The first argument shifted left by the second, in bits. The bits shifted
past bit 62 are discarded, so bit 62 becomes the sign, and an amount of 63
or more gives `0`. A negative amount panics.

### `shiftRight`

```
shiftRight : Int -> Int -> Int
```

The first argument shifted right by the second, in bits, each vacated bit
a copy of the sign. An amount of 63 or more gives `0`, or `-1` for a
negative value. A negative amount panics.

### `bitNot`

```
bitNot : Int -> Int
```

Bitwise complement.

## Math

### `sqrt`

```
sqrt : Float -> Float
```

The square root.

### `cbrt`

```
cbrt : Float -> Float
```

The cube root.

### `exp`

```
exp : Float -> Float
```

e raised to the given power.

### `log`

```
log : Float -> Float
```

The natural logarithm.

### `log2`

```
log2 : Float -> Float
```

The base-2 logarithm.

### `log10`

```
log10 : Float -> Float
```

The base-10 logarithm.

### `sin`

```
sin : Float -> Float
```

The sine of an angle in radians.

### `cos`

```
cos : Float -> Float
```

The cosine of an angle in radians.

### `tan`

```
tan : Float -> Float
```

The tangent of an angle in radians.

### `asin`

```
asin : Float -> Float
```

The arc sine, in radians.

### `acos`

```
acos : Float -> Float
```

The arc cosine, in radians.

### `atan`

```
atan : Float -> Float
```

The arc tangent, in radians.

### `sinh`

```
sinh : Float -> Float
```

The hyperbolic sine.

### `cosh`

```
cosh : Float -> Float
```

The hyperbolic cosine.

### `tanh`

```
tanh : Float -> Float
```

The hyperbolic tangent.

### `floor`

```
floor : Float -> Float
```

The largest integral value not greater than the argument.

### `ceil`

```
ceil : Float -> Float
```

The smallest integral value not less than the argument.

### `round`

```
round : Float -> Float
```

The nearest integral value, with halves rounded away from zero.

### `trunc`

```
trunc : Float -> Float
```

The integral part of the argument, rounding towards zero.

### `pow`

```
pow : Float -> Float -> Float
```

The first argument raised to the power of the second.

### `atan2`

```
atan2 : Float -> Float -> Float
```

The angle in radians of the point `(x, y)`, given as `atan2 y x`.

### `hypot`

```
hypot : Float -> Float -> Float
```

The length of the hypotenuse, `sqrt (x * x + y * y)`, without
intermediate overflow.

### `intBitsToFloat`

```
intBitsToFloat : Int -> Float
```

The float whose IEEE 754 bit pattern is the given integer.

### `floatToBytes64`

```
floatToBytes64 : Float -> Array Int
```

A float as its eight big-endian IEEE 754 bytes, `0` to `255` each.

## Rendering

### `intToString`

```
intToString : Int -> String
```

An integer in decimal.

### `floatToString`

```
floatToString : Float -> String
```

A float in decimal.

## Arrays

### `arrayLength`

```
arrayLength : Array a -> Int
```

The number of elements.

### `arrayMake`

```
arrayMake : Int -> a -> Array a
```

A new array of the given length, every element a copy of the value.

### `arrayMakeWith`

```
arrayMakeWith : Int -> (Int -> <e> a) -> <e> Array a
```

A new array of the given length whose element at each index is the
function applied to that index.

### `arrayCopy`

```
arrayCopy : Array a -> Array a
```

A new array with the same elements.

### `arrayFromList`

```
arrayFromList : List a -> Array a
```

A new array holding the elements of a list.

## Byte blocks

### `byteBlockLength`

```
byteBlockLength : ByteBlock -> Int
```

The number of bytes.

### `byteBlockToIntArray`

```
byteBlockToIntArray : ByteBlock -> Array Int
```

A new array holding each byte as an `Int` in the range 0 to 255.

### `byteBlockFromString`

```
byteBlockFromString : String -> ByteBlock
```

A new block holding the UTF-8 encoding of a string.

## Strings

### `stringToChars`

```
stringToChars : String -> Array Char
```

The codepoints of a string.

### `stringFromChars`

```
stringFromChars : Array Char -> String
```

A string built from an array of characters.

### `stringToUtf8Bytes`

```
stringToUtf8Bytes : String -> Array Int
```

The UTF-8 encoding of a string, one byte (`0` to `255`) per element.

### `stringFromUtf8Bytes`

```
stringFromUtf8Bytes : Array Int -> String
```

The string encoded by an array of UTF-8 bytes. Only the low eight bits
of each element are used.

### `charToStr`

```
charToStr : Char -> String
```

A one-character string.

### `charCode`

```
charCode : Char -> Int
```

A character's codepoint.

### `charFromCode`

```
charFromCode : Int -> Option Char
```

The character with a codepoint, or `None` when the codepoint is not a
Unicode scalar value.

### `stringLength`

```
stringLength : String -> Int
```

The number of codepoints in a string.

### `stringSlice`

```
stringSlice : Int -> Int -> String -> String
```

The characters at positions `[lo, hi)`, clamped to the string.

### `stringConcat`

```
stringConcat : List String -> String
```

The strings joined end to end.

### `stringIndexOf`

```
stringIndexOf : String -> String -> Option Int
```

The position of the first occurrence of the first string in the second,
or `None`.

### `stringCompare`

```
stringCompare : String -> String -> Ordering
```

The ordering of two strings, by codepoint.

### `stringToFloat`

```
stringToFloat : String -> Option Float
```

The float written in a string, or `None`.

## Characters

### `charIsAlpha`

```
charIsAlpha : Char -> Bool
```

Whether a character is an ASCII letter.

### `charIsSpace`

```
charIsSpace : Char -> Bool
```

Whether a character is ASCII whitespace.

### `charIsUpper`

```
charIsUpper : Char -> Bool
```

Whether a character is an ASCII uppercase letter.

### `charIsLower`

```
charIsLower : Char -> Bool
```

Whether a character is an ASCII lowercase letter.

### `charIsPunct`

```
charIsPunct : Char -> Bool
```

Whether a character is ASCII punctuation.

### `charToUpper`

```
charToUpper : Char -> Char
```

An ASCII letter in uppercase. Any other character is unchanged.

### `charToLower`

```
charToLower : Char -> Char
```

An ASCII letter in lowercase. Any other character is unchanged.

### `stringToUpper`

```
stringToUpper : String -> String
```

A string with every ASCII letter in uppercase.

### `stringToLower`

```
stringToLower : String -> String
```

A string with every ASCII letter in lowercase.

