# runtime

Built-in extern declarations.
Every name here must have a matching OCaml implementation in lib/eval.ml.
To add a new primitive: add an extern line here, add its OCaml impl in
eval.ml's `primitives` list, and (if non-pure) its effect annotation here
ensures eff_env is seeded automatically.

`pure` and `map` are *not* externs: they're interface methods of
Applicative and Mappable declared in stdlib/core.mdk, and dispatched
through user-written impl bodies.

## `putStr`

```
putStr : String -> <Stdout> Unit
```

Raw string output (Phase 111).  `print`/`println` are *not* externs anymore:
they're Medaka functions in core.mdk that render via `Display` and call these.

## `putStrLn`

```
putStrLn : String -> <Stdout> Unit
```

## `Ref`

```
Ref : a -> Ref a
```

## `setRef`

```
setRef : Ref a -> a -> Unit
```

## `hashInt`

```
hashInt : Int -> Int
```

Per-type Hashable hashers — SPECIFIED deterministic algorithms, byte-identical
in lib/eval.ml (oracle) and runtime/medaka_rt.c (native): hashInt/hashChar/
hashFloat = SplitMix64-finalizer mix, hashString = FNV-1a, hashBool = 0/1; all
masked to [0, 2^30) (non-negative).  Replaced the old structural __hashRaw,
which the type-erased native runtime cannot replicate.  Called by the primitive
`Hashable` impls in core.mdk; derived/compound impls compose them via `hash`.

## `hashFloat`

```
hashFloat : Float -> Int
```

## `hashString`

```
hashString : String -> Int
```

## `hashChar`

```
hashChar : Char -> Int
```

## `hashBool`

```
hashBool : Bool -> Int
```

## `pi`

```
pi : Float
```

## `e`

```
e : Float
```

## `readLine`

```
readLine : Unit -> <Stdin> String
```

## `readFile`

```
readFile : String -> <FileRead> Result String String
```

## `readFileBytes`

```
readFileBytes : String -> <FileRead> Result String (Array Int)
```

Read a file as RAW BYTES (no UTF-8 decode): Ok (Array Int) of byte values
0..255, or Err msg on failure.  Mirrors readFile but builds an Array of
tagged ints instead of a String.  For SQLite/binary read paths.

## `bitAnd`

```
bitAnd : Int -> Int -> Int
```

Bitwise / shift primitives (PURE).  Defined on the 63-bit Int rep; native
(C) == OCaml for NON-NEGATIVE operands (the binary-decoding case).
shiftRight is LOGICAL (unsigned): OCaml lsr, C >> on the untagged value.

## `bitOr`

```
bitOr : Int -> Int -> Int
```

## `bitXor`

```
bitXor : Int -> Int -> Int
```

## `shiftLeft`

```
shiftLeft : Int -> Int -> Int
```

## `shiftRight`

```
shiftRight : Int -> Int -> Int
```

## `bitNot`

```
bitNot : Int -> Int
```

## `writeFile`

```
writeFile : String -> String -> <FileWrite> Result String Unit
```

## `writeFileBytes`

```
writeFileBytes : String -> Array Int -> <FileWrite> Result String Unit
```

Write raw bytes (Array Int, values 0..255) to a file, truncating.  The
byte-clean write counterpart of readFileBytes.  Returns Ok () on success
or Err msg on failure.

## `runCommand`

```
runCommand : String -> List String -> <Exec> Result String (Int, String, String)
```

Run a subprocess: prog args -> Ok (exitCode, stdout, stderr) | Err osError.
Return type: Result String (Int, String, String) (Result e a: e=error, a=ok).
stdout and stderr are captured as strings.  On spawn failure (e.g. ENOENT)
returns Err with the OS error message; exit-code non-zero is still Ok.
Used by a Medaka-hosted medaka build to invoke clang and the emitter.

## `exit`

```
exit : Int -> Unit
```

## `panic`

```
panic : String -> a
```

## `indexError`

```
indexError : String -> a
```

Coded-OOB abort, for a container's own `Index`/`IndexMut` impl to raise on
out-of-bounds access.  Reuses the existing E-INDEX-OOB abort machinery every
backend already has for the built-in index paths (native @mdk_oob, wasm's
E-INDEX-OOB trap) -- unlike `panic`, which is always coded E-PANIC.

## `indexErrorAt`

```
indexErrorAt : Int -> a
```

Coded-OOB abort carrying the offending index, for a container's own
`Index`/`IndexMut` impl (#1787).  Prefer this over `indexError` with an
interpolated message: `indexError`'s message is DROPPED by the native and wasm
backends (they raise a fixed-text E-INDEX-OOB abort), so interpolating one made
`run` and a built binary disagree, and the dead string-building cost enough LLVM
inline budget to stop `index`/`setIndex` inlining into hot loops.  Here the index
is formatted by the abort itself (native @mdk_oob_at), so every engine that can
report it does.

## `sliceError`

```
sliceError : Int -> Int -> a
```

Coded-OOB abort for a container's own `Slice` impl to raise on an
out-of-bounds slice range (#670).  Args are `(lo, hiIncl)` -- the original low
bound and the INCLUSIVE upper bound (adjusted end - 1) -- so the message reads
`slice [lo..hiIncl] out of bounds`, byte-identical to the interpreter's
`sliceArray` abort.  Reuses the existing E-SLICE-OOB abort machinery every
backend already has for the built-in slice path (native @mdk_slice_oob, wasm's
E-SLICE-OOB trap) -- unlike `panic`, which is always coded E-PANIC.

## `stashRunStdout`

```
stashRunStdout : String -> Unit
```

Internal `medaka run` plumbing ("run drops stdout on panic" fix). `run`'s
tree-walking interpreter buffers a program's stdout in an in-language
Ref<String> (eval.mdk's outputRef) and writes it out only after `main`
returns NORMALLY -- so a panicking program's buffered stdout used to be
silently discarded (Medaka panics are NOT catchable; there is no unwind
path back to that final write). These two internal-only externs let
eval.mdk register the buffer with the native runtime so every abort path
(panic / index-OOB / non-exhaustive-match / stack-overflow / a fatal
signal) can flush it before dying -- see runtime/medaka_rt.c's
mdk_flush_run_stdout_on_abort. Not for general use: `stashRunStdout` takes
an O(1) pointer+length snapshot (no allocation, no observable effect by
itself) and `enableRunStdoutFlush` is called exactly once, only by the
real `medaka run` CLI driver -- never by the pure differential-oracle eval
probes, which share this same source but never call it, so their captured
output is unaffected.

## `enableRunStdoutFlush`

```
enableRunStdoutFlush : Unit -> Unit
```

## `args`

```
args : Unit -> <Env> List String
```

io Module 7.  Higher-level ergonomics (eprint/eprintln/readLines) live in
stdlib/io.mdk; these are the irreducible host primitives.

## `getEnv`

```
getEnv : String -> <Env> Option String
```

io Module 7.  Higher-level ergonomics (eprint/eprintln/readLines) live in
stdlib/io.mdk; these are the irreducible host primitives.
program args after the script name

## `executablePath`

```
executablePath : Unit -> <Env> String
```

io Module 7.  Higher-level ergonomics (eprint/eprintln/readLines) live in
stdlib/io.mdk; these are the irreducible host primitives.
program args after the script name
environment variable, or None
Absolute path of the running executable (realpath-resolved).  Lets a
relocated `medaka` binary derive an exe-relative default MEDAKA_ROOT instead
of assuming it runs inside the repo (DISTRIBUTION-DESIGN.md D1).

## `buildFingerprint`

```
buildFingerprint : Unit -> <Env> String
```

Compiler-source fingerprint this binary was BUILT from, baked at C-compile
time by test/build_native_medaka.sh (-DMEDAKA_SRC_FP).  "" on any build path
that does not bake it (cold seed bootstrap, oracle builds, a shipped binary).
The CLI recomputes the same fingerprint over the LIVE compiler/ sources and
warns when they diverge (issue #89 staleness guard).  Native-only.

## `fileExists`

```
fileExists : String -> <FileRead> Bool
```

## `canonicalizePath`

```
canonicalizePath : String -> <FileRead> String
```

## `appendFile`

```
appendFile : String -> String -> <FileWrite> Result String Unit
```

realpath(3): resolve ./../symlinks to an absolute path; input unchanged on failure

## `listDir`

```
listDir : String -> <FileRead> Result String (List String)
```

## `makeDir`

```
makeDir : String -> <FileWrite> Result String Unit
```

directory entries (names)

## `removeFile`

```
removeFile : String -> <FileWrite> Result String Unit
```

directory entries (names)
create directory (mkdir 0o755)

## `rename`

```
rename : String -> String -> <FileWrite> Result String Unit
```

directory entries (names)
create directory (mkdir 0o755)
unlink(2): delete a file.  Err (strerror) on failure

## `removeDir`

```
removeDir : String -> <FileWrite> Result String Unit
```

directory entries (names)
create directory (mkdir 0o755)
unlink(2): delete a file.  Err (strerror) on failure
rename(2) old new: move/rename a path.  Err (strerror) on failure

## `statFile`

```
statFile : String -> <FileRead> Result String (Int, Bool, Bool, Float)
```

directory entries (names)
create directory (mkdir 0o755)
unlink(2): delete a file.  Err (strerror) on failure
rename(2) old new: move/rename a path.  Err (strerror) on failure
rmdir(2): remove an EMPTY directory only.  Err (strerror) on failure
stat(2): (sizeBytes, isDir, isFile, mtimeSeconds).  Err (strerror) if the path
does not exist / cannot be stat'd.  Mirrors runCommand's tuple-return shape.

## `netResolve`

```
netResolve : String -> <Net> Result String (List String)
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.

## `netTcpConnect`

```
netTcpConnect : String -> Int -> <Net> Result String Int
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings

## `netTcpListen`

```
netTcpListen : String -> Int -> <Net> Result String Int
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)

## `netListenPort`

```
netListenPort : Int -> <Net> Result String Int
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd

## `netTcpAccept`

```
netTcpAccept : Int -> <Net> Result String Int
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)

## `netSend`

```
netSend : Int -> Array Int -> <Net> Result String Int
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)

## `netRecv`

```
netRecv : Int -> Int -> <Net> Result String (Array Int)
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)

## `netShutdown`

```
netShutdown : Int -> Int -> <Net> Result String Unit
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)
fd, maxBytes -> bytes read (empty Array = EOF)

## `netClose`

```
netClose : Int -> <Net> Result String Unit
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)
fd, maxBytes -> bytes read (empty Array = EOF)
fd, how (0=read,1=write,2=both) -> shutdown(2)

## `netSetTimeout`

```
netSetTimeout : Int -> Int -> <Net> Result String Unit
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)
fd, maxBytes -> bytes read (empty Array = EOF)
fd, how (0=read,1=write,2=both) -> shutdown(2)
fd -> close(2); idempotent-safe in the C shim

## `ePutStr`

```
ePutStr : String -> <Stderr> Unit
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)
fd, maxBytes -> bytes read (empty Array = EOF)
fd, how (0=read,1=write,2=both) -> shutdown(2)
fd -> close(2); idempotent-safe in the C shim
fd, milliseconds (0=blocking) -> SO_RCVTIMEO+SO_SNDTIMEO

## `ePutStrLn`

```
ePutStrLn : String -> <Stderr> Unit
```

Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
getaddrinfo: hostname -> numeric IP strings
host, port -> connected fd (does DNS internally)
bind addr, port (0=ephemeral) -> listening fd
listening fd -> actual bound port (for port 0)
listening fd -> accepted connection fd (blocks)
fd, bytes -> count actually written (may be < len)
fd, maxBytes -> bytes read (empty Array = EOF)
fd, how (0=read,1=write,2=both) -> shutdown(2)
fd -> close(2); idempotent-safe in the C shim
fd, milliseconds (0=blocking) -> SO_RCVTIMEO+SO_SNDTIMEO
raw stderr output

## `readLineOpt`

```
readLineOpt : Unit -> <Stdin> Option String
```

## `readAll`

```
readAll : Unit -> <Stdin> String
```

one stdin line, None at EOF

## `readExactly`

```
readExactly : Int -> <Stdin> Option String
```

one stdin line, None at EOF
all of stdin

## `flushStdout`

```
flushStdout : Unit -> <Stdout> Unit
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read

## `wallTimeSec`

```
wallTimeSec : Unit -> <Clock> Float
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read
flush buffered stdout (LSP stdio framing)

## `monotonicSec`

```
monotonicSec : Unit -> <Clock> Float
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read
flush buffered stdout (LSP stdio framing)
wall-clock time in seconds (gettimeofday)

## `sleepMs`

```
sleepMs : Int -> <Clock> Unit
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read
flush buffered stdout (LSP stdio framing)
wall-clock time in seconds (gettimeofday)
monotonic clock in seconds (clock_gettime CLOCK_MONOTONIC); for measuring intervals

## `allocBytes`

```
allocBytes : Unit -> <IO> Float
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read
flush buffered stdout (LSP stdio framing)
wall-clock time in seconds (gettimeofday)
monotonic clock in seconds (clock_gettime CLOCK_MONOTONIC); for measuring intervals
sleep for N milliseconds (nanosleep)

## `__fallthrough__`

```
__fallthrough__ : Unit -> a
```

one stdin line, None at EOF
all of stdin
read exactly N bytes; None at EOF or short read
flush buffered stdout (LSP stdio framing)
wall-clock time in seconds (gettimeofday)
monotonic clock in seconds (clock_gettime CLOCK_MONOTONIC); for measuring intervals
sleep for N milliseconds (nanosleep)
total GC-allocated bytes since process start (Gc.allocated_bytes proxy)
Internal: the terminator of a desugared guard chain (Phase 91).  Raises the
same "no clause matched" signal as a failed pattern, so when a function
clause's guards all fail, dispatch falls through to the next pattern clause
(Haskell semantics) instead of aborting.  Not meant for direct use.

## `randomInt`

```
randomInt : Int -> Int -> <Rand> Int
```

## `randomBool`

```
randomBool : Unit -> <Rand> Bool
```

## `randomFloat`

```
randomFloat : Unit -> <Rand> Float
```

## `randomChar`

```
randomChar : Unit -> <Rand> Char
```

## `setSeed`

```
setSeed : Int -> <Rand> Unit
```

## `osEntropyBytes`

```
osEntropyBytes : Int -> <Rand> Array Int
```

Return exactly `n` bytes from the operating system entropy
source. Panics for a negative length or if the host source fails. This is
intentionally separate from the deterministic, seedable `random*` family.

## `charToStr`

```
charToStr : Char -> String
```

## `intToFloat`

```
intToFloat : Int -> Float
```

## `floatToInt`

```
floatToInt : Float -> Int
```

## `floatRem`

```
floatRem : Float -> Float -> Float
```

floatRem a b = a - b * trunc(a/b)  (C fmod == LLVM frem == OCaml Float.rem).
Backs the `Float % Float` operator in the interpreter so `run` matches `build`
(which emits `frem` inline) EXACTLY.  Pure.

## `sqrt`

```
sqrt : Float -> Float
```

── libm math externs (native/LLVM only) ────────────────────────────────
One-arg and two-arg transcendental / root / rounding functions, each a
direct call into the C runtime's math.h shim (mirrors floatRem/fmod).
All pure.  NOTE: wasm does NOT port these (they trap on wasm, like every
non-ported float extern); native/LLVM is the only backend.

## `cbrt`

```
cbrt : Float -> Float
```

## `exp`

```
exp : Float -> Float
```

## `log`

```
log : Float -> Float
```

## `log2`

```
log2 : Float -> Float
```

## `log10`

```
log10 : Float -> Float
```

## `sin`

```
sin : Float -> Float
```

## `cos`

```
cos : Float -> Float
```

## `tan`

```
tan : Float -> Float
```

## `asin`

```
asin : Float -> Float
```

## `acos`

```
acos : Float -> Float
```

## `atan`

```
atan : Float -> Float
```

## `sinh`

```
sinh : Float -> Float
```

## `cosh`

```
cosh : Float -> Float
```

## `tanh`

```
tanh : Float -> Float
```

## `floor`

```
floor : Float -> Float
```

## `ceil`

```
ceil : Float -> Float
```

## `round`

```
round : Float -> Float
```

## `trunc`

```
trunc : Float -> Float
```

## `pow`

```
pow : Float -> Float -> Float
```

## `atan2`

```
atan2 : Float -> Float -> Float
```

## `hypot`

```
hypot : Float -> Float -> Float
```

## `intBitsToFloat`

```
intBitsToFloat : Int -> Float
```

Bit-level reinterpretation of a 63-bit Int as an IEEE 754 double.
Medaka Int is 63-bit (see intMaxBound), so this can only construct floats
whose bit pattern fits in 63 bits; arbitrary 64-bit patterns (bit 62/63
set: negative floats, large exponents, top-bit NaN/inf) must go through
`bytesToFloat64` instead.  Inverse of Int64.bits_of_float / C
memcpy(&bits,&d,8) for the patterns it can represent.  Pure.

## `bytesToFloat64`

```
bytesToFloat64 : Array Int -> Int -> Float
```

Read 8 bytes big-endian from `arr` starting at byte index `off` and
reinterpret as an IEEE 754 double.  Bytes in `arr` are Int values 0..255.
Pure (no IO; the array is read-only).

## `floatToBytes64`

```
floatToBytes64 : Float -> Array Int
```

Inverse of `bytesToFloat64`: encode a Float as 8 big-endian IEEE 754 bytes
and return them as an Array of 8 Ints (each 0..255).  Pure.

## `intMinBound`

```
intMinBound : Int
```

Platform bounds backing `impl Bounded Int`/`Bounded Char` in core.mdk.
Int bounds are the 63-bit OCaml `int` limits; Char bounds are U+0000 / U+10FFFF.

## `intMaxBound`

```
intMaxBound : Int
```

## `charMinBound`

```
charMinBound : Char
```

## `charMaxBound`

```
charMaxBound : Char
```

## `intToString`

```
intToString : Int -> String
```

Leaf renderers backing the `Debug` impls in core.mdk / string.mdk.  These
expose the same OCaml formatting `pp_value` uses, so `debug` agrees with
`println` on numbers.  `debugStringLit`/`debugCharLit` produce the *quoted,
escaped* literal form (round-trippable into source), so `debug` on a String
intentionally differs from `println` (cf. Haskell `show` vs `putStr`).

## `floatToString`

```
floatToString : Float -> String
```

## `debugStringLit`

```
debugStringLit : String -> String
```

## `debugCharLit`

```
debugCharLit : Char -> String
```

## `assertSnapshot`

```
assertSnapshot : String -> String -> <IO> Unit
```

## `arrayLength`

```
arrayLength : Array a -> Int
```

Array primitives.  These are the minimal kernel; stdlib/array.mdk is
built on top.  *Unsafe variants skip the bounds check — they're used by
stdlib internals where the surrounding loop already enforces validity.
Public, bounds-checked indexing goes through `arr[i]` (panics on OOB).

## `arrayMake`

```
arrayMake : Int -> a -> Array a
```

## `arrayMakeWith`

```
arrayMakeWith : Int -> (Int -> a) -> Array a
```

## `arrayGetUnsafe`

```
arrayGetUnsafe : Int -> Array a -> a
```

## `arraySetUnsafe`

```
arraySetUnsafe : Int -> a -> Array a -> Unit
```

## `arrayCopy`

```
arrayCopy : Array a -> Array a
```

## `arrayBlit`

```
arrayBlit : Array a -> Int -> Array a -> Int -> Int -> Unit
```

## `arrayFill`

```
arrayFill : a -> Array a -> Unit
```

## `arrayFromList`

```
arrayFromList : List a -> Array a
```

Pure wrapper.  Encapsulates "alloc + locally mutate + return fresh" as a
plain pure function (historical note: this used to matter because mutation
carried a `<Mut>` effect and Medaka has no effect masking; since mutation is
untracked, that concession is now moot — the function is just pure).

## `stringToChars`

```
stringToChars : String -> Array Char
```

String/Char kernel (Phase 75).  String is a sequence of Unicode codepoints,
UTF-8 backed; Char is one codepoint.  The bridge to Array Char + the few
codepoint-aware perf externs below are the minimal host surface; the bulk of
stdlib/string.mdk is written in Medaka on top.  Char classification/case
folding (charIs*/charTo*, below) is ASCII-only, not Unicode (issue #417).

## `stringFromChars`

```
stringFromChars : Array Char -> String
```

## `stringToUtf8Bytes`

```
stringToUtf8Bytes : String -> Array Int
```

UTF-8 codec (BOTH directions).  stringToUtf8Bytes exposes the String's raw
UTF-8 backing as Int bytes 0..255 (O(n) copy, NO codepoint re-encode);
stringFromUtf8Bytes blits Int bytes (low 8 bits each) back into a String.
Decode is PERMISSIVE (bytes are blitted verbatim; the cached codepoint count
is recomputed by the standard non-continuation-byte rule).  For valid UTF-8
(e.g. SQLite text) `fromUtf8 (toUtf8 s) == s` byte-for-byte.

## `stringFromUtf8Bytes`

```
stringFromUtf8Bytes : Array Int -> String
```

## `charCode`

```
charCode : Char -> Int
```

## `charFromCode`

```
charFromCode : Int -> Option Char
```

## `stringLength`

```
stringLength : String -> Int
```

## `stringSlice`

```
stringSlice : Int -> Int -> String -> String
```

## `stringConcat`

```
stringConcat : List String -> String
```

## `stringIndexOf`

```
stringIndexOf : String -> String -> Option Int
```

## `stringCompare`

```
stringCompare : String -> String -> Ordering
```

## `stringToFloat`

```
stringToFloat : String -> Option Float
```

## `charIsAlpha`

```
charIsAlpha : Char -> Bool
```

Char classification & case folding (Phase 75).  **ASCII-only** (issue
#417) — plain 'a'..'z'/'A'..'Z' byte tests in runtime/medaka_rt.c, no
Unicode character database.  A non-ASCII byte (UTF-8 lead/continuation,
>= 0x80) passes through every one of these unchanged: charToUpper/
charToLower are Char -> Char and are the identity outside 'a'..'z'/
'A'..'Z'; stringToUpper/stringToLower are the same byte-wise ASCII map
over a String (NOT full Unicode case folding, and no 1 -> N expansion).

## `charIsSpace`

```
charIsSpace : Char -> Bool
```

## `charIsUpper`

```
charIsUpper : Char -> Bool
```

## `charIsLower`

```
charIsLower : Char -> Bool
```

## `charIsPunct`

```
charIsPunct : Char -> Bool
```

## `charToUpper`

```
charToUpper : Char -> Char
```

## `charToLower`

```
charToLower : Char -> Char
```

## `stringToUpper`

```
stringToUpper : String -> String
```

## `stringToLower`

```
stringToLower : String -> String
```

