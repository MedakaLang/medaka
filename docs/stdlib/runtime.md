# runtime

> These are the host primitives. They are in scope everywhere without an
> import, and their `<type><Op>` names (`stringToUpper`, `intToString`)
> mark them as the primitive layer. Prefer the library name where one
> exists (`string.toUpper`, `string.toFloat`), and reach for a name on this
> page only when no library module covers it.

## `putStr`

```
putStr : String -> <Stdout> Unit
```

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
readFile : String -> <FileRead _> Result String String
```

## `readFileBytes`

```
readFileBytes : String -> <FileRead _> Result String (Array Int)
```

## `bitAnd`

```
bitAnd : Int -> Int -> Int
```

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
writeFile : String -> String -> <FileWrite _> Result String Unit
```

## `writeFileBytes`

```
writeFileBytes : String -> Array Int -> <FileWrite _> Result String Unit
```

## `runCommand`

```
runCommand : String -> List String -> <Exec _> Result String (Int, String, String)
```

## `exit`

```
exit : Int -> Unit
```

## `panic`

```
panic : String -> a
```

## `args`

```
args : Unit -> <Env> List String
```

## `getEnv`

```
getEnv : String -> <Env _> Option String
```

## `executablePath`

```
executablePath : Unit -> <Env> String
```

## `fileExists`

```
fileExists : String -> <FileRead _> Bool
```

## `canonicalizePath`

```
canonicalizePath : String -> <FileRead _> String
```

## `appendFile`

```
appendFile : String -> String -> <FileWrite _> Result String Unit
```

## `listDir`

```
listDir : String -> <FileRead _> Result String (List String)
```

## `makeDir`

```
makeDir : String -> <FileWrite _> Result String Unit
```

## `removeFile`

```
removeFile : String -> <FileWrite _> Result String Unit
```

## `rename`

```
rename : String -> String -> <FileWrite _> Result String Unit
```

## `removeDir`

```
removeDir : String -> <FileWrite _> Result String Unit
```

## `statFile`

```
statFile : String -> <FileRead _> Result String (Int, Bool, Bool, Float)
```

## `netResolve`

```
netResolve : String -> <Net _> Result String (List String)
```

## `netTcpConnect`

```
netTcpConnect : String -> Int -> <Net _> Result String Int
```

## `netTcpListen`

```
netTcpListen : String -> Int -> <Net _> Result String Int
```

## `netListenPort`

```
netListenPort : Int -> <Net _> Result String Int
```

## `netTcpAccept`

```
netTcpAccept : Int -> <Net _> Result String Int
```

## `netSend`

```
netSend : Int -> Array Int -> <Net _> Result String Int
```

## `netRecv`

```
netRecv : Int -> Int -> <Net _> Result String (Array Int)
```

## `netShutdown`

```
netShutdown : Int -> Int -> <Net _> Result String Unit
```

## `netClose`

```
netClose : Int -> <Net _> Result String Unit
```

## `netSetTimeout`

```
netSetTimeout : Int -> Int -> <Net _> Result String Unit
```

## `ePutStr`

```
ePutStr : String -> <Stderr> Unit
```

## `ePutStrLn`

```
ePutStrLn : String -> <Stderr> Unit
```

## `readLineOpt`

```
readLineOpt : Unit -> <Stdin> Option String
```

## `readAll`

```
readAll : Unit -> <Stdin> String
```

## `readExactly`

```
readExactly : Int -> <Stdin> Option String
```

## `flushStdout`

```
flushStdout : Unit -> <Stdout> Unit
```

## `wallTimeSec`

```
wallTimeSec : Unit -> <Clock> Float
```

## `monotonicSec`

```
monotonicSec : Unit -> <Clock> Float
```

## `sleepMs`

```
sleepMs : Int -> <Clock> Unit
```

## `allocBytes`

```
allocBytes : Unit -> <IO> Float
```

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

## `sqrt`

```
sqrt : Float -> Float
```

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

## `floatToBytes64`

```
floatToBytes64 : Float -> Array Int
```

## `intMinBound`

```
intMinBound : Int
```

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

## `floatToString`

```
floatToString : Float -> String
```

## `arrayLength`

```
arrayLength : Array a -> Int
```

## `arrayMake`

```
arrayMake : Int -> a -> Array a
```

## `arrayMakeWith`

```
arrayMakeWith : Int -> (Int -> a) -> Array a
```

## `arrayCopy`

```
arrayCopy : Array a -> Array a
```

## `arrayFromList`

```
arrayFromList : List a -> Array a
```

## `stringToChars`

```
stringToChars : String -> Array Char
```

## `stringFromChars`

```
stringFromChars : Array Char -> String
```

## `stringToUtf8Bytes`

```
stringToUtf8Bytes : String -> Array Int
```

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

